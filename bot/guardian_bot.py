#!/usr/bin/env python3
"""
Umbrel Guardian - Telegram Bot
Polls Telegram for commands and runs local scripts to respond.
"""

import os
import re
import sys
import signal
import time
import subprocess
import requests
import logging

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-8s [guardian-bot] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S"
)
log = logging.getLogger(__name__)

# Config path can be overridden via env var (useful for testing)
CONFIG_PATH = os.environ.get(
    "GUARDIAN_CONFIG",
    "/home/umbrel/umbrel/umbrel-guardian/config.env"
)

# Scripts live one directory up from bot/
SCRIPTS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts")

# Exponential backoff constants for Telegram API errors
_BACKOFF_INITIAL = 1
_BACKOFF_MAX = 60

# ── Security: input validation ────────────────────────────────────────────────

_APP_ID_RE = re.compile(r'^[a-zA-Z0-9_-]{1,64}$')

def valid_app_id(app_id):
    """Validate app ID — letters, numbers, hyphens, underscores only (max 64 chars)."""
    return bool(_APP_ID_RE.match(app_id))

# ── Security: rate limiting ───────────────────────────────────────────────────

_last_command = {}   # {chat_id: timestamp}
RATE_LIMIT_SECONDS = 5

def rate_limited(chat_id):
    """Return True if the user is sending commands too fast."""
    now = time.time()
    last = _last_command.get(chat_id, 0)
    if now - last < RATE_LIMIT_SECONDS:
        return True
    _last_command[chat_id] = now
    return False

# ── Security: safe mode (/lock, /unlock) ──────────────────────────────────────

_locked = False

SAFE_COMMANDS = {"/status", "/help", "/start", "/lock", "/unlock", "/uptime", "/apps", "/health"}


def handle_lock(text, token, chat_id, cfg):
    """Handle /lock and /unlock commands. Returns True if handled."""
    global _locked
    lower = text.lower().strip()

    if lower == "/lock":
        pin = cfg.get("LOCK_PIN", "").strip()
        if not pin:
            send_message(token, chat_id,
                         "⚠️ Cannot lock: no LOCK_PIN configured in config.env.\n"
                         "Set a PIN first, then use /lock.")
            return True
        _locked = True
        send_message(token, chat_id,
                     "🔒 Safe mode ON. Only /status, /help, /apps, /uptime, /health active.\n"
                     "Use /unlock <PIN> to restore.")
        return True

    if lower.startswith("/unlock"):
        pin = cfg.get("LOCK_PIN", "").strip()
        if not pin:
            send_message(token, chat_id, "⚠️ No LOCK_PIN configured in config.env.")
            return True
        parts = text.split(None, 1)
        if len(parts) < 2 or parts[1].strip() != pin:
            send_message(token, chat_id, "❌ Incorrect PIN.")
            return True
        _locked = False
        send_message(token, chat_id, "🔓 Safe mode OFF. All commands restored.")
        return True

    return False


def load_config(path):
    """
    Load key=value config file.
    Uses str.partition("=") so values containing "=" (like bot tokens) are safe.
    """
    cfg = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                key, _, value = line.partition("=")
                cfg[key.strip()] = value.strip()
    except FileNotFoundError:
        log.error(f"Config not found: {path}")
        sys.exit(1)
    return cfg


def parse_chat_ids(cfg):
    """
    Return list of chat IDs for *sending* messages.
    Supports CHAT_IDS (comma-separated) with fallback to CHAT_ID.
    """
    raw = cfg.get("CHAT_IDS", cfg.get("CHAT_ID", "")).strip()
    ids = [cid.strip() for cid in raw.split(",") if cid.strip()]
    return ids


def parse_allowed_users(cfg, chat_ids):
    """
    Return set of user IDs authorized to *issue commands*.
    Uses ALLOWED_USERS if set; otherwise falls back to chat_ids.
    This lets you have notification recipients who aren't command-authorized,
    or command-authorized users who don't get broadcast alerts.
    """
    raw = cfg.get("ALLOWED_USERS", "").strip()
    if raw:
        return set(uid.strip() for uid in raw.split(",") if uid.strip())
    return set(chat_ids)


def escape_mdv2(text):
    """Escape special characters for Telegram MarkdownV2."""
    return re.sub(r'([_*\[\]()~`>#+=|{}.!\\-])', r'\\\1', text)


# SECURITY: Never log 'token' or 'payload' — they contain the bot token
def send_message(token, chat_id, text, parse_mode=None):
    """Send a Telegram message. Splits long messages automatically."""
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    for chunk in [text[i:i+4096] for i in range(0, len(text), 4096)]:
        payload = {"chat_id": chat_id, "text": chunk, "disable_web_page_preview": True}
        if parse_mode:
            payload["parse_mode"] = parse_mode
        try:
            r = requests.post(url, data=payload, timeout=10)
            r.raise_for_status()
        except Exception as e:
            log.error(f"Failed to send message to {chat_id}: {e}")


def broadcast(token, chat_ids, text, parse_mode=None):
    """Send a message to all authorized chat IDs."""
    for cid in chat_ids:
        send_message(token, cid, text, parse_mode=parse_mode)


def get_updates(token, offset, timeout=30):
    """
    Long-poll Telegram for new updates.
    Returns list of update dicts on success, None on error (triggers backoff).
    Empty list is normal (timeout with no messages).
    """
    url = f"https://api.telegram.org/bot{token}/getUpdates"
    try:
        r = requests.get(
            url,
            params={"offset": offset, "timeout": timeout},
            timeout=timeout + 5
        )
        r.raise_for_status()
        return r.json().get("result", [])
    except requests.exceptions.Timeout:
        return []   # normal for long-polling; not an error
    except Exception as e:
        log.error(f"getUpdates error: {e}")
        return None  # signals caller to back off


def run_script(script_name, *args, timeout=60):
    """Run a shell script from the scripts/ directory and return its output."""
    script_path = os.path.join(SCRIPTS_DIR, script_name)
    if not os.path.isfile(script_path):
        return f"⚠️ Script not found: {script_name}"
    try:
        result = subprocess.run(
            [script_path] + list(args),
            capture_output=True,
            text=True,
            timeout=timeout
        )
        output = result.stdout.strip()
        if not output:
            output = result.stderr.strip()
        return output or "(no output)"
    except subprocess.TimeoutExpired:
        return f"⚠️ Command timed out after {timeout} seconds."
    except Exception as e:
        return f"⚠️ Error running {script_name}: {e}"


HELP_TEXT = r"""🛡 *Umbrel Guardian*

*Commands:*
/status — System overview \(disk, RAM, CPU, uptime\)
/uptime — Show system uptime
/apps — App states \(running / stopped\)
/health — Run a health check now
/restart \<app\_id\> — Restart a specific app
/restart unhealthy — Restart all non\-ready apps
/logs \<app\_id\> \[lines\] — Recent container logs \(default: 50\)
/backup — Trigger a manual backup now
/lock — Enable safe mode \(disable dangerous commands\)
/unlock \<PIN\> — Disable safe mode
/help — Show this message
"""


def handle_command(text, token, chat_id, chat_ids, cfg):
    """Route a Telegram command to the appropriate script."""
    text = text.strip()

    # Backward-compat: /restart_nextcloud → /restart nextcloud
    # (matches the old UmbrelGuard button style)
    m = re.match(r'^/restart_([a-zA-Z0-9_-]+)$', text, re.IGNORECASE)
    if m:
        text = f"/restart {m.group(1)}"

    lower = text.lower()

    # ── Safe mode gate ────────────────────────────────────────────────────────
    if handle_lock(text, token, chat_id, cfg):
        return
    if _locked and lower.split()[0] not in SAFE_COMMANDS:
        send_message(token, chat_id, "🔒 Safe mode is active. Use /unlock <PIN> to restore.")
        return

    # ── Command dispatch ──────────────────────────────────────────────────────

    if lower in ("/start", "/help"):
        send_message(token, chat_id, HELP_TEXT, parse_mode="MarkdownV2")

    elif lower == "/status":
        out = run_script("system_status.sh")
        send_message(token, chat_id, out)

    elif lower == "/uptime":
        try:
            result = subprocess.run(
                ["uptime", "-p"], capture_output=True, text=True, timeout=5
            )
            up_pretty = result.stdout.strip()
        except Exception:
            up_pretty = ""
        try:
            result2 = subprocess.run(
                ["uptime"], capture_output=True, text=True, timeout=5
            )
            up_raw = result2.stdout.strip()
        except Exception:
            up_raw = "(unavailable)"
        out = f"⏱ Uptime:\n{up_pretty}\n{up_raw}" if up_pretty else f"⏱ Uptime:\n{up_raw}"
        send_message(token, chat_id, out)

    elif lower == "/health":
        send_message(token, chat_id, "🔍 Running health check...")
        out = run_script("health_check.sh", "--force")
        # health_check.sh sends alerts directly via telegram_send.sh,
        # so we only need to reply if there was no output (script handles notification)
        if "Script not found" in out or "Error running" in out:
            send_message(token, chat_id, out)

    elif lower == "/apps":
        out = run_script("apps_status.sh")
        send_message(token, chat_id, out)

    elif lower.startswith("/restart"):
        parts = text.split(None, 1)
        if len(parts) < 2 or not parts[1].strip():
            send_message(
                token, chat_id,
                "Usage:\n/restart <app_id>\n/restart unhealthy\nExample: /restart bitcoin-node"
            )
            return
        arg = parts[1].strip()
        if arg.lower() == "unhealthy":
            send_message(token, chat_id, "🔄 Restarting all unhealthy apps...")
            out = run_script("restart_unhealthy.sh", timeout=120)
            broadcast(token, chat_ids, out)
        else:
            if not valid_app_id(arg):
                send_message(token, chat_id, "⚠️ Invalid app ID.")
                return
            send_message(token, chat_id, f"🔄 Restarting {arg}...")
            out = run_script("restart_app.sh", arg, timeout=180)
            broadcast(token, chat_ids, out)

    elif lower.startswith("/logs"):
        parts = text.split(None, 2)
        if len(parts) < 2:
            send_message(token, chat_id,
                         "Usage: /logs <app_id> [lines]\nExample: /logs bitcoin-node 30")
            return
        app_id = parts[1].strip()
        if not valid_app_id(app_id):
            send_message(token, chat_id, "⚠️ Invalid app ID.")
            return
        lines = parts[2].strip() if len(parts) > 2 else "50"
        if not lines.isdigit():
            send_message(token, chat_id, "⚠️ Line count must be a number.")
            return
        out = run_script("app_logs.sh", app_id, lines)
        send_message(token, chat_id, f"📋 Logs for {app_id} (last {lines} lines):\n{out}")

    elif lower == "/backup":
        send_message(token, chat_id, "⏳ Starting backup, this may take a while...")
        # Touch a trigger file — a systemd .path unit watches for it and
        # starts umbrel-guardian-backup.service (runs as root, own cgroup).
        # No sudo needed; works inside ProtectSystem=strict sandbox.
        trigger = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            ".backup-trigger",
        )
        try:
            with open(trigger, "w") as f:
                f.write("")
        except OSError as e:
            send_message(token, chat_id, f"❌ Could not trigger backup: {e}")

    else:
        send_message(token, chat_id, f"Unknown command: {text}\nUse /help to see available commands.")


def main():
    cfg = load_config(CONFIG_PATH)
    token = cfg.get("BOT_TOKEN", "").strip()
    chat_ids = parse_chat_ids(cfg)
    allowed_users = parse_allowed_users(cfg, chat_ids)

    if not token or not chat_ids:
        log.error("BOT_TOKEN and CHAT_ID (or CHAT_IDS) must be set in config.env")
        sys.exit(1)

    # SECURITY: log masked token only — never print full token
    log.info(f"Bot token loaded (ends ...{token[-4:]})")
    log.info(f"Notification targets: {chat_ids}")
    log.info(f"Authorized users:     {allowed_users}")

    # ── Signal handlers ───────────────────────────────────────────────────────

    def handle_shutdown(signum, frame):
        log.info(f"Signal {signum} received — sending shutdown notification")
        broadcast(token, chat_ids, "🛡 Umbrel Guardian is going offline.")
        sys.exit(0)

    def handle_sighup(signum, frame):
        nonlocal cfg, token, chat_ids, allowed_users
        log.info("SIGHUP received — reloading config")
        cfg = load_config(CONFIG_PATH)
        token = cfg.get("BOT_TOKEN", "").strip()
        chat_ids = parse_chat_ids(cfg)
        allowed_users = parse_allowed_users(cfg, chat_ids)
        log.info(f"Config reloaded. Chat IDs: {chat_ids}, Allowed: {allowed_users}")

    signal.signal(signal.SIGTERM, handle_shutdown)
    signal.signal(signal.SIGINT, handle_shutdown)
    signal.signal(signal.SIGHUP, handle_sighup)

    # ── Startup ───────────────────────────────────────────────────────────────

    log.info("Umbrel Guardian bot starting...")

    # Clear any existing webhook and drop pending updates to avoid 409 conflicts
    try:
        r = requests.post(
            f"https://api.telegram.org/bot{token}/deleteWebhook",
            data={"drop_pending_updates": True},
            timeout=10
        )
        r.raise_for_status()
        log.info("Webhook cleared, pending updates dropped")
    except Exception as e:
        log.warning(f"deleteWebhook failed (non-fatal): {e}")

    broadcast(token, chat_ids, "🛡 Umbrel Guardian is online. Send /help for commands.")

    # ── Main poll loop ────────────────────────────────────────────────────────

    # offset tracks which updates we've already processed.
    # It must be updated OUTSIDE the inner loop to persist across poll cycles.
    offset = 0
    backoff = _BACKOFF_INITIAL

    while True:
        updates = get_updates(token, offset)

        if updates is None:
            # API error — back off exponentially
            log.warning(f"API error — retrying in {backoff}s")
            time.sleep(backoff)
            backoff = min(backoff * 2, _BACKOFF_MAX)
            continue

        backoff = _BACKOFF_INITIAL  # reset on successful poll

        for update in updates:
            # Always advance offset, even if we skip the update
            offset = update["update_id"] + 1

            msg = update.get("message") or update.get("edited_message", {})
            text = msg.get("text", "")
            from_id = str(msg.get("chat", {}).get("id", ""))

            # Security: reject non-private chats (groups, channels)
            chat_type = msg.get("chat", {}).get("type", "")
            if chat_type != "private":
                log.warning(f"Ignoring non-private chat: {chat_type} from {from_id}")
                continue

            # Security: only respond to explicitly authorized users
            if from_id not in allowed_users:
                log.warning(f"Ignoring message from unauthorized user: {from_id}")
                continue

            if text.startswith("/"):
                # Don't rate-limit harmless read-only commands
                cmd_word = text.lower().split()[0]
                if cmd_word not in ("/help", "/start") and rate_limited(from_id):
                    send_message(token, from_id, "⏱ Please wait before sending another command.")
                    continue

                log.info(f"Command from {from_id}: {text}")
                handle_command(text, token, from_id, chat_ids, cfg)

        time.sleep(1)


if __name__ == "__main__":
    main()

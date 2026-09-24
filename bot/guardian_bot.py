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

# ── System control commands ──────────────────────────────────────────────────
# Two-step confirm flow: user sends /system_reboot, bot replies asking for
# /system_reboot_confirm within SYSTEM_CONFIRM_TIMEOUT seconds, then executes
# via system_control.sh (run as root through sudoers NOPASSWD).
_SYSTEM_CONTROL_SH = os.path.join(SCRIPTS_DIR, "system_control.sh")
SYSTEM_CONFIRM_TIMEOUT = 30  # seconds

SYSTEM_COMMANDS = {
    "/system_reboot": {
        "action": "reboot",
        "warning": (
            "⚠️ This will REBOOT the Pi in ~60 seconds.\n"
            "All apps will be unavailable during the reboot."
        ),
        "ack": (
            "🔄 Reboot scheduled for ~60 seconds from now.\n"
            "Cancel with /system_cancel if you change your mind."
        ),
    },
    "/system_shutdown": {
        "action": "shutdown",
        "warning": (
            "⚠️ This will POWER OFF the Pi in ~60 seconds.\n"
            "You'll need physical access to power it back on."
        ),
        "ack": (
            "⏻ Shutdown scheduled for ~60 seconds from now.\n"
            "Cancel with /system_cancel if you change your mind."
        ),
    },
    "/restart_docker": {
        "action": "restart-docker",
        "warning": (
            "⚠️ This will restart the Docker daemon.\n"
            "ALL containers (apps + umbreld) will briefly stop and restart."
        ),
        "ack": "🔄 Restarting Docker — apps will return shortly.",
    },
    "/restart_umbrel": {
        "action": "restart-umbrel",
        "warning": (
            "⚠️ This will restart umbreld (Umbrel's orchestration daemon).\n"
            "The web UI will briefly be unavailable."
        ),
        "ack": "🔄 Restarting umbreld.",
    },
}

# chat_id → (system_command, expires_at_epoch)
_pending_system_confirm = {}

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

# Read-only commands that stay available in safe mode. Everything here must be
# incapable of changing the node's state.
# /schedule only reads. The three setters that change it are deliberately absent:
# safe mode exists to stop the bot changing anything, and quietly reducing how
# often the node is checked is exactly the kind of change it should refuse.
SAFE_COMMANDS = {"/status", "/help", "/start", "/lock", "/unlock", "/uptime", "/apps", "/health",
                 "/disk_health", "/disks", "/verify_backup", "/notifications", "/updates", "/storage",
                 "/schedule"}

# Shown by /lock. Generated rather than written out, because a hardcoded list
# silently lies the moment SAFE_COMMANDS changes — and a wrong list in safe mode
# is exactly when you least want to be guessing what still works.
def _safe_command_list():
    hidden = {"/start", "/lock", "/unlock", "/disks"}   # aliases and the lock verbs themselves
    return ", ".join(sorted(SAFE_COMMANDS - hidden))


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
                     f"🔒 Safe mode ON. Still available: {_safe_command_list()}\n"
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


def set_config_value(key, value, path=None):
    """Change one key in config.env, leaving every other byte alone.

    `path` resolves to CONFIG_PATH at call time, not as a default argument. A
    default would snapshot the module global when this function is defined,
    which quietly ignores the GUARDIAN_CONFIG override the module documents.

    Rewrites the existing line in place if the key is there, appends it if not.
    Never reformats, never drops a comment, never reorders — config.env is
    hand-edited as often as it is written by this, and a settings command that
    quietly tidies someone's file is a settings command they stop trusting.

    The bot is the only writer. It can do this without any privilege at all:
    config.env lives inside ReadWritePaths and is owned by the service user. The
    privileged half (apply-timers.sh) deliberately only reads.

    Returns (True, "") or (False, reason).
    """
    path = path or CONFIG_PATH
    try:
        with open(path) as handle:
            lines = handle.readlines()
    except OSError as error:
        return False, str(error)

    replaced = False
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("#") or "=" not in stripped:
            continue
        if stripped.partition("=")[0].strip() == key:
            lines[index] = f"{key}={value}\n"
            replaced = True
    if not replaced:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append(f"{key}={value}\n")

    # Temp file in the same directory, then rename: a half-written config.env is
    # a bot that will not start after the next reboot.
    tmp = f"{path}.tmp.{os.getpid()}"
    try:
        with open(tmp, "w") as handle:
            handle.writelines(lines)
        os.chmod(tmp, os.stat(path).st_mode & 0o7777)
        os.replace(tmp, path)
    except OSError as error:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False, str(error)
    return True, ""


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


def run_privileged_script(script_name, *args, timeout=60):
    """Run a scripts/ helper as root via `sudo -n`.

    For the diagnostics that genuinely need root: smartctl talks to the raw
    device, the kernel journal is not world-readable, and the backup mirror is
    root-owned. `-n` never prompts, so a missing sudoers file fails immediately
    instead of hanging the bot waiting for a password nobody can type into a
    chat window.
    """
    script_path = os.path.join(SCRIPTS_DIR, script_name)
    if not os.path.isfile(script_path):
        return f"⚠️ Script not found: {script_name}"
    try:
        result = subprocess.run(
            ["sudo", "-n", script_path] + list(args),
            capture_output=True,
            text=True,
            timeout=timeout
        )
        stderr = result.stderr or ""
        # sudo itself refusing is worth distinguishing from the script failing:
        # /etc/sudoers.d/ is wiped on every boot and restamped by the pre-start
        # hook, so this is a known, recoverable state with a known fix.
        if result.returncode != 0 and ("sudo:" in stderr or "a password is required" in stderr):
            return ("⚠️ Could not run this as root.\n"
                    "/etc/sudoers.d/ is cleared on every boot and restamped by the "
                    "pre-start hook. If this keeps happening, run:\n"
                    "sudo bash reinstall-services.sh")
        output = result.stdout.strip() or stderr.strip()
        return output or "(no output)"
    except subprocess.TimeoutExpired:
        return f"⚠️ Command timed out after {timeout} seconds."
    except Exception as e:
        return f"⚠️ Error running {script_name}: {e}"


PRIV_DIR = "/usr/local/lib/umbrel-guardian"
APPLY_TIMERS = os.path.join(PRIV_DIR, "apply-timers.sh")
RESTORE_ALL = os.path.join(SCRIPTS_DIR, "restore_file.sh")
SYSTEMD_RUN = "/usr/bin/systemd-run"


def run_outside_sandbox(unit, argv, timeout=60):
    """Run a privileged command that has to WRITE somewhere this unit cannot.

    `sudo` is not enough on its own. umbrel-guardian-bot.service sets
    ProtectSystem=strict, which mounts the entire filesystem hierarchy read-only
    except for ReadWritePaths — and that is a mount namespace. Raising the uid
    does not leave it, so a root child of the bot still gets EROFS writing
    /etc/systemd/system or the umbrel data directory.

    This cost real time to find: /restore all stopped umbreld, failed every copy
    with "permission denied?", and started umbreld again, on a node whose
    permissions were perfect.

    systemd-run asks PID 1 to spawn the command instead. PID 1 is outside the
    sandbox, so the transient unit sees the real filesystem. --pipe hands it our
    stdio, so this stays synchronous and the caller reports a real result rather
    than "requested". --collect reaps the unit afterwards, including a failed
    one, so a fixed unit name can be reused.

    Every argv here is a fixed literal matched exactly by /etc/sudoers.d — no
    wildcard, so nothing a chat message says can reach the command line.
    """
    command = ["sudo", "-n", SYSTEMD_RUN, "--quiet", "--pipe", "--wait",
               "--collect", f"--unit={unit}"] + list(argv)
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return f"⚠️ Timed out after {timeout} seconds."
    except Exception as error:
        return f"⚠️ Could not start {unit}: {error}"

    stderr = result.stderr or ""
    if result.returncode != 0 and ("sudo:" in stderr or "a password is required" in stderr):
        return ("⚠️ Could not run this as root.\n"
                "/etc/sudoers.d/ is cleared on every boot and restamped by the "
                "pre-start hook. If this keeps happening, run:\n"
                "sudo bash reinstall-services.sh")
    return (result.stdout.strip() or stderr.strip()) or "(no output)"


def normalise_hhmm(value):
    """'2:00' -> '02:00'. None if it is not a 24-hour time at all.

    A single-digit hour is accepted rather than refused because install.sh
    stored the backup time unvalidated for its whole life, so real config.env
    files carry `BACKUP_TIME=2:00` — and systemd has been running them happily,
    since OnCalendar accepts a non-padded hour. Rejecting it made Guardian wrong
    about input that works.
    """
    match = re.match(r'^([0-9]|[01][0-9]|2[0-3]):([0-5][0-9])$', (value or "").strip())
    if not match:
        return None
    return "%02d:%s" % (int(match.group(1)), match.group(2))


def _systemctl_value(unit, prop):
    """One `systemctl show` property, or None if systemd cannot be asked.

    Unprivileged: `systemctl show` reads properties over D-Bus and needs no
    root, so this stays usable in safe mode where the setters are blocked.
    """
    try:
        result = subprocess.run(
            ["systemctl", "show", unit, "-p", prop, "--value"],
            capture_output=True, text=True, timeout=10
        )
    except Exception:
        return None
    return (result.stdout or "").strip()


def next_timer_fire(unit):
    """When systemd will next run a timer, or why it will not.

    Takes whatever form systemd hands back. `systemctl show` special-cases
    NextElapseUSecRealtime and prints a FORMATTED timestamp ("Wed 2026-09-24
    09:00:00 UTC") rather than the microseconds its name implies. Requiring
    digits threw that away and reported "not scheduled" for two healthy timers.
    Both forms are handled, because which one you get is a systemd-version
    detail not worth depending on.

    When there is genuinely nothing, name what was observed. An "unknown" that
    does not say why is the failure this project keeps having to fix.
    """
    value = _systemctl_value(unit, "NextElapseUSecRealtime")
    if value is None:
        return "cannot ask systemd"
    if value.isdigit():
        if int(value) > 0:
            return time.strftime("%Y-%m-%d %H:%M:%S %Z",
                                 time.localtime(int(value) // 1_000_000))
    elif value and value not in ("n/a", "infinity"):
        return value

    load = _systemctl_value(unit, "LoadState") or ""
    active = _systemctl_value(unit, "ActiveState") or "unknown"
    if load == "loaded":
        return f"none scheduled (timer is {active})"
    if not load:
        return "cannot ask systemd"
    return f"not installed ({load})"


# The five forms install.sh offers and apply-timers.sh accepts, keyed by what a
# person would type. One table, so the chat command cannot drift from the two
# other places that know these values.
HEALTH_INTERVALS = {
    "15m": "*:0/15",
    "30m": "*:0/30",
    "1h":  "hourly",
    "3h":  "0/3:00",
    "12h": "0/12:00",
}
HEALTH_INTERVAL_LABELS = {v: k for k, v in HEALTH_INTERVALS.items()}


HELP_TEXT = r"""🛡 *Umbrel Guardian*

*Commands:*
/status — System overview \(disk, RAM, CPU, uptime\)
/uptime — Show system uptime
/apps — App states \(ready / stopped / unknown\)
/health — Run a health check now
/restart \<app\_id\> — Restart a specific app
/restart unhealthy — Restart apps in unknown/failed state
/logs \<app\_id\> \[lines\] — Recent container logs \(default: 50\)
/backup — Trigger a manual backup now
/verify\_backup — Check the backup is restorable \(add `deep` for a full compare\)
/disk\_health — SMART, SD/eMMC wear and kernel I/O errors
/storage — Per\-app storage usage
/notifications — Pending umbrelOS notifications
/updates — umbrelOS version and available updates
/schedule — Show when checks and backups run
/interval \<15m\|30m\|1h\|3h\|12h\> — How often the health check runs
/backup\_time \<HH:MM\> — Daily backup time \(24h\)
/alerts \<hours\> — Repeat an unchanged alert this often \(0 \= never\)
/system\_reboot — Reboot the Pi \(2\-step confirm\)
/system\_shutdown — Power off the Pi \(2\-step confirm\)
/restart\_docker — Restart Docker daemon \(2\-step confirm\)
/restart\_umbrel — Restart umbreld \(2\-step confirm\)
/system\_cancel — Cancel a pending reboot/shutdown
/lock — Enable safe mode \(disable dangerous commands\)
/unlock \<PIN\> — Disable safe mode
/help — Show this message
"""


def _prime_system_command(cmd, token, chat_id):
    """Stage a system command and ask the user to confirm within the timeout."""
    spec = SYSTEM_COMMANDS[cmd]
    _pending_system_confirm[chat_id] = (cmd, time.time() + SYSTEM_CONFIRM_TIMEOUT)
    confirm_cmd = f"{cmd}_confirm"
    send_message(
        token, chat_id,
        f"{spec['warning']}\n\n"
        f"Reply {confirm_cmd} within {SYSTEM_CONFIRM_TIMEOUT} seconds to proceed.\n"
        f"Otherwise this request expires."
    )


def _execute_system_command(cmd, token, chat_id):
    """Execute a previously-primed system command (after confirmation)."""
    pending = _pending_system_confirm.get(chat_id)
    if not pending or pending[0] != cmd:
        send_message(token, chat_id,
                     f"❌ No pending {cmd} to confirm.\n"
                     f"Send {cmd} first, then {cmd}_confirm within {SYSTEM_CONFIRM_TIMEOUT}s.")
        return
    if pending[1] < time.time():
        _pending_system_confirm.pop(chat_id, None)
        send_message(token, chat_id,
                     f"⏱ Confirmation expired. Re-issue {cmd} to start over.")
        return
    _pending_system_confirm.pop(chat_id, None)

    spec = SYSTEM_COMMANDS[cmd]
    send_message(token, chat_id, spec["ack"])
    # /restart_docker takes 30-90s to stop+start all Umbrel containers;
    # shutdown/reboot/cancel return almost instantly. 180s covers all cases
    # comfortably and prevents spurious "timed out" messages while the
    # underlying systemctl is still doing real work.
    timeout_sec = 180
    try:
        # sudoers grants NOPASSWD for `system_control.sh <action>` exactly
        result = subprocess.run(
            ["sudo", "-n", _SYSTEM_CONTROL_SH, spec["action"]],
            capture_output=True, text=True, timeout=timeout_sec
        )
        if result.returncode != 0:
            msg = result.stderr.strip() or result.stdout.strip() or "(no output)"
            send_message(token, chat_id, f"❌ {cmd} failed (exit {result.returncode}):\n{msg}")
    except subprocess.TimeoutExpired:
        send_message(token, chat_id, f"⚠️ {cmd} timed out after {timeout_sec}s (action may still be running).")
    except Exception as e:
        send_message(token, chat_id, f"❌ {cmd} error: {e}")


def _sweep_pending_confirms(token):
    """Expire stale system-command confirmations and notify their users.

    Called once per poll-loop iteration. Without this, an expiry only fires
    when the user actually attempts the corresponding _confirm command —
    here we proactively tell them their request lapsed."""
    now = time.time()
    expired = []
    for cid, (cmd, expires_at) in list(_pending_system_confirm.items()):
        if now >= expires_at:
            _pending_system_confirm.pop(cid, None)
            expired.append((cid, cmd))
    for cid, cmd in expired:
        send_message(token, cid,
                     f"⏱ {cmd} confirmation expired — request was not confirmed within "
                     f"{SYSTEM_CONFIRM_TIMEOUT}s. Re-issue {cmd} if you still want to proceed.")


def _cancel_pending_shutdown(token, chat_id):
    """Cancel a pending shutdown/reboot via `shutdown -c`."""
    try:
        result = subprocess.run(
            ["sudo", "-n", _SYSTEM_CONTROL_SH, "cancel"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            send_message(token, chat_id, "✅ Pending shutdown/reboot cancelled.")
        else:
            # shutdown -c returns non-zero when there's nothing to cancel
            send_message(token, chat_id, "ℹ️ No pending shutdown/reboot to cancel.")
    except Exception as e:
        send_message(token, chat_id, f"❌ Cancel error: {e}")


def handle_command(text, token, chat_id, chat_ids, cfg):
    """Route a Telegram command to the appropriate script."""
    text = text.strip()
    lower = text.lower()

    # ── Safe mode gate ────────────────────────────────────────────────────────
    if handle_lock(text, token, chat_id, cfg):
        return
    if _locked and lower.split()[0] not in SAFE_COMMANDS:
        send_message(token, chat_id, "🔒 Safe mode is active. Use /unlock <PIN> to restore.")
        return

    # ── System control commands (must come BEFORE the /restart_<id> regex,
    #    otherwise /restart_docker / /restart_umbrel get rewritten and routed
    #    to restart_app.sh, which doesn't know about system services).
    if lower in SYSTEM_COMMANDS:
        _prime_system_command(lower, token, chat_id)
        return
    if lower.endswith("_confirm"):
        primary = lower[: -len("_confirm")]
        if primary in SYSTEM_COMMANDS:
            _execute_system_command(primary, token, chat_id)
            return
    if lower == "/system_cancel":
        _cancel_pending_shutdown(token, chat_id)
        return

    # Backward-compat: /restart_nextcloud → /restart nextcloud
    # (matches the old UmbrelGuard button style)
    m = re.match(r'^/restart_([a-zA-Z0-9_-]+)$', text, re.IGNORECASE)
    if m:
        text = f"/restart {m.group(1)}"
        lower = text.lower()

    # ── Command dispatch ──────────────────────────────────────────────────────

    if lower in ("/start", "/help"):
        send_message(token, chat_id, HELP_TEXT, parse_mode="MarkdownV2")

    elif lower == "/status":
        out = run_script("system_status.sh", timeout=150)
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
        out = run_script("health_check.sh", "--force", timeout=120)
        # health_check.sh sends alerts directly via telegram_send.sh,
        # so we only need to reply if there was no output (script handles notification)
        if "Script not found" in out or "Error running" in out:
            send_message(token, chat_id, out)

    elif lower == "/apps":
        out = run_script("apps_status.sh", timeout=150)
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
            out = run_script("restart_unhealthy.sh", timeout=360)
            broadcast(token, chat_ids, out)
        else:
            if not valid_app_id(arg):
                send_message(token, chat_id, "⚠️ Invalid app ID.")
                return
            send_message(token, chat_id, f"🔄 Restarting {arg}...")
            out = run_script("restart_app.sh", arg, timeout=240)
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
        # Everything here is about not saying "starting" unless a backup can
        # actually start. This command works by touching a trigger file that a
        # systemd .path unit watches (no sudo needed, works inside the
        # ProtectSystem=strict sandbox) — and a file write succeeds whether or
        # not anything is listening, so the write proves nothing on its own.
        #
        # On a node with no backup drive it proved exactly nothing: reinstall
        # only enables the .path unit when BACKUP_PATH is set, so the bot wrote
        # the file, nothing read it, and the user was left with "⏳ Starting
        # backup" and then silence, permanently. Silence is the worst available
        # answer — it is indistinguishable from a backup still running.
        if not cfg.get("BACKUP_PATH", "").strip():
            # Same wording as /verify_backup: a fresh install with no drive is a
            # normal state, not a fault.
            send_message(token, chat_id,
                         "ℹ️ Backups are not configured (BACKUP_PATH is empty in config.env).\n"
                         "   Re-run install.sh to set up a backup drive.")
            return

        # BACKUP_PATH is set, but the unit that watches the trigger still has to
        # be running. If it is not, the write below is a no-op and the user would
        # get the same silence, so check before promising anything.
        watcher = "umbrel-guardian-backup-trigger.path"
        try:
            watching = subprocess.run(
                ["systemctl", "is-active", "--quiet", watcher], timeout=10
            ).returncode == 0
        except Exception:
            watching = False
        if not watching:
            send_message(token, chat_id,
                         f"❌ Cannot start a backup: {watcher} is not running, so nothing\n"
                         "   would pick up the request.\n"
                         "   Fix: sudo bash ~/umbrel/umbrel-guardian/reinstall-services.sh\n"
                         "   Meanwhile a backup still works over SSH:\n"
                         "   sudo systemctl start umbrel-guardian-backup.service")
            return

        trigger = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            ".backup-trigger",
        )
        try:
            with open(trigger, "w") as f:
                f.write("")
        except OSError as e:
            send_message(token, chat_id, f"❌ Could not trigger backup: {e}")
            return
        # Only now is "starting" true. Sending it first meant the OSError branch
        # produced a contradictory pair of messages.
        send_message(token, chat_id, "⏳ Starting backup, this may take a while...")

    elif lower.startswith("/restore"):
        # Deliberately NOT in SAFE_COMMANDS: everything else the bot can do
        # over Telegram is read-only, and this one writes to the data
        # directory. /lock exists precisely to fence off the commands that can
        # change the node.
        if _locked:
            send_message(token, chat_id,
                         "🔒 Safe mode: /restore writes to your data directory. "
                         "Use /unlock <PIN> first.")
            return
        # Only two fixed verbs, so the sudoers grant stays two exact command
        # lines with no wildcard. A wildcard would let any argument reach a
        # root-run script, and per-file selection is not worth that: from a
        # phone the useful action is "fix what is broken", and anyone who wants
        # one specific file is already at a shell.
        parts = lower.split()
        if len(parts) == 1:
            send_message(token, chat_id,
                         run_privileged_script("restore_file.sh", "--list", timeout=120))
        elif len(parts) == 2 and parts[1] in ("all", "--all"):
            # Through systemd-run, not plain sudo: this one WRITES into the
            # umbrel data directory, which ProtectSystem=strict makes read-only
            # for us regardless of uid. See run_outside_sandbox.
            send_message(token, chat_id,
                         run_outside_sandbox("guardian-restore",
                                             [RESTORE_ALL, "--all"], timeout=240))
        else:
            send_message(token, chat_id,
                         "Usage:\n/restore — list what can be restored\n"
                         "/restore all — restore all of it\n\n"
                         "To restore one specific file, over SSH:\n"
                         "sudo ~/umbrel/umbrel-guardian/scripts/restore_file.sh <path>")

    elif lower == "/schedule":
        cfg_now = load_config(CONFIG_PATH)
        raw = cfg_now.get("HEALTH_INTERVAL", "").strip()
        health = HEALTH_INTERVAL_LABELS.get(raw, raw or "(unset)")
        # Displayed padded even when config.env holds a legacy "2:00", so the
        # chat is consistent without a write. apply-timers.sh normalises the same
        # value on its own side; the bot stays config.env's only writer.
        backup = normalise_hhmm(cfg_now.get("BACKUP_TIME", "")) \
            or (cfg_now.get("BACKUP_TIME", "").strip() or "(unset)")
        repeat = cfg_now.get("ALERT_REPEAT_HOURS", "24").strip()
        lines = [
            "🗓 Schedules",
            "━━━━━━━━━━━━━━━━━━",
            f"  Health check: every {health}",
        ]
        if cfg_now.get("BACKUP_PATH", "").strip():
            lines.append(f"  Backup: daily at {backup}")
        else:
            lines.append("  Backup: not configured (no BACKUP_PATH)")
        if repeat == "0":
            lines.append("  Repeat alerts: off — an unchanged problem is reported once")
        else:
            lines.append(f"  Repeat alerts: every {repeat}h while a problem persists")
        lines += [
            "",
            "  /interval 15m|30m|1h|3h|12h",
            "  /backup_time HH:MM",
            "  /alerts <hours>  (0 = never repeat)",
        ]
        # Ask systemd as well as config.env, because the two can disagree — a
        # timer edited by hand, or a config change whose apply step failed — and
        # when they do, that is the thing worth seeing. `systemctl show` is a
        # read over D-Bus and needs no privilege, which keeps /schedule safe to
        # leave in SAFE_COMMANDS: it reports, it never applies.
        lines.append("")
        lines.append(f"  Next health check: {next_timer_fire('umbrel-guardian-health.timer')}")
        if cfg_now.get("BACKUP_PATH", "").strip():
            lines.append(f"  Next backup: {next_timer_fire('umbrel-guardian-backup.timer')}")
        send_message(token, chat_id, "\n".join(lines))

    elif lower.startswith("/interval"):
        parts = text.split()
        if len(parts) != 2 or parts[1].lower() not in HEALTH_INTERVALS:
            send_message(token, chat_id,
                         "Usage: /interval 15m|30m|1h|3h|12h\n"
                         "Example: /interval 30m\n\n"
                         "This is how often the health check RUNS. How often it repeats "
                         "itself about a problem you already know about is /alerts.")
            return
        choice = parts[1].lower()
        # config.env first: it is the durable record, and reinstall-services.sh
        # re-applies it from there. If the systemd step fails the intent still
        # survives the next reinstall.
        written, why = set_config_value("HEALTH_INTERVAL", HEALTH_INTERVALS[choice])
        if not written:
            send_message(token, chat_id, f"⚠️ Could not write config.env: {why}")
            return
        out = run_outside_sandbox("guardian-apply-timers", [APPLY_TIMERS], timeout=60)
        broadcast(token, chat_ids, f"🗓 Health check interval → {choice}\n{out}")

    elif lower.startswith("/backup_time"):
        parts = text.split()
        when = normalise_hhmm(parts[1]) if len(parts) == 2 else None
        if when is None:
            send_message(token, chat_id,
                         "Usage: /backup_time HH:MM  (24-hour, system timezone)\n"
                         "Example: /backup_time 03:30\n\n"
                         "This reschedules the daily backup. It does not run one — "
                         "use /backup for that.")
            return
        cfg_now = load_config(CONFIG_PATH)
        if not cfg_now.get("BACKUP_PATH", "").strip():
            send_message(token, chat_id,
                         "ℹ️ Backups are not configured (BACKUP_PATH is empty in config.env), "
                         "so there is no backup timer to reschedule.")
            return
        # Stored padded, so config.env converges on one format no matter which
        # form was typed or what the installer left behind.
        written, why = set_config_value("BACKUP_TIME", when)
        if not written:
            send_message(token, chat_id, f"⚠️ Could not write config.env: {why}")
            return
        out = run_outside_sandbox("guardian-apply-timers", [APPLY_TIMERS], timeout=60)
        broadcast(token, chat_ids, f"🗓 Daily backup time → {when}\n{out}")

    elif lower.startswith("/alerts"):
        parts = text.split()
        if len(parts) != 2 or not parts[1].isdigit() or int(parts[1]) > 168:
            send_message(token, chat_id,
                         "Usage: /alerts <hours>  (0-168, 0 = never repeat)\n"
                         "Example: /alerts 24\n\n"
                         "A problem is reported the moment it appears or changes. "
                         "This is how long before it is mentioned again while it stays "
                         "exactly the same.")
            return
        hours = str(int(parts[1]))
        # Nothing to apply: health_check.sh sources config.env on every run, so
        # this takes effect at the next tick with no reload and no restart.
        written, why = set_config_value("ALERT_REPEAT_HOURS", hours)
        if not written:
            send_message(token, chat_id, f"⚠️ Could not write config.env: {why}")
            return
        if hours == "0":
            broadcast(token, chat_ids,
                      "🔕 Repeat alerts off. A problem is reported when it appears or "
                      "changes, and never repeated. /health still answers on demand.")
        else:
            broadcast(token, chat_ids,
                      f"🔔 Repeat alerts → every {hours}h while a problem persists.")

    elif lower in ("/disk_health", "/disks"):
        # 120s: SMART probes on a sick drive are exactly the slow case, and the
        # script bounds each sub-probe itself.
        send_message(token, chat_id, run_privileged_script("disk_health.sh", timeout=120))

    elif lower.startswith("/verify_backup"):
        parts = lower.split()
        want_deep = len(parts) > 1 and parts[1] == "deep"
        if want_deep and _locked:
            send_message(token, chat_id,
                         "🔒 Safe mode: the quick check is available, but the deep scan "
                         "starts a background job. Use /unlock <PIN> first.")
        elif want_deep:
            send_message(token, chat_id, run_privileged_script("verify_backup.sh", "--deep"))
        else:
            send_message(token, chat_id, run_privileged_script("verify_backup.sh"))

    elif lower == "/notifications":
        send_message(token, chat_id, run_script("umbrel_notifications.sh", "--list", timeout=150))

    elif lower == "/updates":
        send_message(token, chat_id, run_script("umbrel_update_check.sh", "--report", timeout=150))

    elif lower == "/storage":
        # Was already written and working, just never wired to anything.
        send_message(token, chat_id, run_script("storage_usage.sh", timeout=120))

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

    # Wait until the Telegram API is actually reachable before announcing.
    #
    # On a reboot/OTA the bot starts within ~15s of boot, often BEFORE DNS is
    # ready — `api.telegram.org` fails to resolve for a while. The old code
    # fired deleteWebhook + the "online" broadcast once, eagerly, and silently
    # dropped both on NameResolutionError. Now we loop on deleteWebhook (which
    # doubles as the connectivity probe AND the stale-state cleanup it already
    # performs) until it succeeds, then announce.
    #
    # HTTP errors (401/404) mean a bad token or a Telegram-side problem —
    # those are fatal, not transient, so we exit rather than loop forever.
    _wait = _BACKOFF_INITIAL
    while True:
        try:
            r = requests.post(
                f"https://api.telegram.org/bot{token}/deleteWebhook",
                data={"drop_pending_updates": True},
                timeout=10
            )
            r.raise_for_status()
            log.info("Webhook cleared, pending updates dropped — Telegram reachable")
            break
        except requests.exceptions.HTTPError as e:
            log.error(f"Telegram API rejected request ({e}). Check BOT_TOKEN — exiting.")
            sys.exit(1)
        except Exception as e:
            log.warning(f"Telegram not reachable yet ({e.__class__.__name__}); retrying in {_wait}s")
            time.sleep(_wait)
            _wait = min(_wait * 2, _BACKOFF_MAX)

    broadcast(token, chat_ids, "🛡 Umbrel Guardian is online. Send /help for commands.")

    # ── Main poll loop ────────────────────────────────────────────────────────

    # offset tracks which updates we've already processed.
    # It must be updated OUTSIDE the inner loop to persist across poll cycles.
    offset = 0
    backoff = _BACKOFF_INITIAL

    while True:
        # Short long-poll (10s) so the periodic sweep below (for expired system
        # command confirmations) runs ~every 10s, not every ~30s.
        updates = get_updates(token, offset, timeout=10)

        if updates is None:
            # API error — back off exponentially
            log.warning(f"API error — retrying in {backoff}s")
            time.sleep(backoff)
            backoff = min(backoff * 2, _BACKOFF_MAX)
            continue

        backoff = _BACKOFF_INITIAL  # reset on successful poll

        # Notify users whose system-command confirmation lapsed.
        # Worst-case delay is one long-poll cycle (~10s), well within tolerance for a 30s timer.
        _sweep_pending_confirms(token)

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

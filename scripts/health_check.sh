#!/usr/bin/env bash
# Proactive health check: runs on a timer and sends Telegram alerts
# if disk usage exceeds threshold or any app is in an unknown/failed state.
# (Healthy = ready or running; transient and stopped states are ignored.)
#
# Deduplication: alerts are only sent when the issue set *changes*,
# preventing Telegram spam every 30 minutes for persistent problems.
#
# Pass --force to always send the current status (used by /health command).
#
# Exit code: 1 if alerts were sent, 0 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$(dirname "$SCRIPT_DIR")/config.env"
SEND="$SCRIPT_DIR/telegram_send.sh"

source "$CONFIG"

THRESHOLD="${DISK_THRESHOLD:-90}"
STATE_FILE="/run/umbrel-guardian-health.last"
HOST="$(hostname)"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# Collect issues into an array (not sent immediately — deduplicated first)
ISSUES=()

# ── Disk check ─────────────────────────────────────────────────────────────
# Umbrel OS 1.5 on Pi uses /mnt/root/mnt/data as the actual data mount.
# Fall back to /mnt/data and then / for other setups.
if df -hP /mnt/root/mnt/data &>/dev/null; then
    DISK_USE=$(df -hP /mnt/root/mnt/data | awk 'NR==2 {print $5}' | tr -d '%')
    DISK_LABEL="/mnt/root/mnt/data"
elif df -hP /mnt/data &>/dev/null; then
    DISK_USE=$(df -hP /mnt/data | awk 'NR==2 {print $5}' | tr -d '%')
    DISK_LABEL="/mnt/data"
else
    DISK_USE=$(df -hP / | awk 'NR==2 {print $5}' | tr -d '%')
    DISK_LABEL="/"
fi

if [ "${DISK_USE:-0}" -gt "$THRESHOLD" ]; then
    # Report a 5% band rather than the live figure. The fingerprint below covers
    # this string, so "at 91%" → "at 92%" reads as a brand new problem and
    # re-alerts every 30 minutes for as long as the disk stays full — which is
    # precisely when you least want to be trained to ignore the alert.
    DISK_BAND=$(( DISK_USE / 5 * 5 ))
    ISSUES+=("⚠️ Disk ${DISK_LABEL} is over ${DISK_BAND}% full (threshold: ${THRESHOLD}%)")
fi

# ── App health check ────────────────────────────────────────────────────────
# Umbrel app state taxonomy (1.7.x):
#   ready, running                                           → healthy
#   starting, installing, updating, restarting,              → transient
#     stopping, uninstalling                                   (ignore — fluctuates)
#   stopped                                                  → intentional off (user choice)
#   unknown                                                  → real problem
# We only alert on "unknown" so transient states don't flap and stopped
# apps (which the user deliberately turned off) don't trigger alerts.
if command -v umbreld &>/dev/null; then
    # The app list reaches Python through the ENVIRONMENT, not a pipe.
    #
    # `python3 -` reads its program from stdin, so the heredoc below claims
    # stdin — silently overriding the pipe. sys.stdin.read() returned '' on
    # every single run, which means this check has never once reported an
    # unhealthy app since it was written. shellcheck SC2259 catches it.
    #
    # The heredoc stays (this script needs both quote styles internally, so
    # collapsing it into python3 -c would be a quoting minefield); only the data
    # path moves.
    APP_RAW=$(timeout 45 umbreld client apps.list.query 2>&1)
    APP_ISSUES=$(APP_RAW="$APP_RAW" python3 - <<'PYEOF'
import os, json

raw = os.environ.get("APP_RAW", "")
decoder = json.JSONDecoder()
apps = None
try:
    apps, _ = decoder.raw_decode(raw.lstrip())
except (json.JSONDecodeError, ValueError):
    idx = raw.find('[')
    if idx != -1:
        try:
            apps, _ = decoder.raw_decode(raw, idx)
        except (json.JSONDecodeError, ValueError):
            pass
if apps is None:
    sys.exit(0)

HEALTHY    = {"ready", "running"}
TRANSIENT  = {"starting", "installing", "updating", "restarting", "stopping", "uninstalling"}
INTENTIONAL = {"stopped"}

for app in apps:
    state = app.get("state", "unknown")
    if state in HEALTHY or state in TRANSIENT or state in INTENTIONAL:
        continue
    print(f"❌ {app['id']} is {state}")
PYEOF
    ) || true

    # Add each unhealthy app line to ISSUES array
    while IFS= read -r line; do
        [ -n "$line" ] && ISSUES+=("$line")
    done <<< "${APP_ISSUES:-}"
fi

# ── Disk health ──────────────────────────────────────────────────────────────
# Runs as root via sudo -n: smartctl needs the raw device and the kernel journal
# is not world-readable. Silent when that is unavailable — /etc/sudoers.d/ is
# wiped on every boot and restamped by the pre-start hook, so there is a window
# where this legitimately cannot run, and alerting on it would fire a spurious
# "monitoring is broken" after every reboot.
#
# disk_health.sh emits deterministic, bucketed lines precisely so they can join
# ISSUES without breaking the fingerprint below.
DISK_HEALTH="$SCRIPT_DIR/disk_health.sh"
if [ -x "$DISK_HEALTH" ]; then
    DISK_ISSUES=$(sudo -n "$DISK_HEALTH" --issues 2>/dev/null || true)
    while IFS= read -r line; do
        [ -n "$line" ] && ISSUES+=("$line")
    done <<< "${DISK_ISSUES:-}"
fi

# ── Backup integrity ─────────────────────────────────────────────────────────
# Corruption is silent. It produces no kernel error, no failed backup and no
# failed comparison — the disk writes garbage, rsync copies the garbage, and
# every check that only compares the two reports agreement. Nothing above this
# line would notice, which is why a node ran for days with five destroyed files
# in both its data directory and its backup while every check said fine.
#
# Same contract as disk_health.sh: deterministic lines, so identical findings
# produce an identical fingerprint and alert exactly once.
VERIFY_BACKUP="$SCRIPT_DIR/verify_backup.sh"
if [ -x "$VERIFY_BACKUP" ]; then
    INTEGRITY_ISSUES=$(sudo -n "$VERIFY_BACKUP" --integrity 2>/dev/null || true)
    while IFS= read -r line; do
        [ -n "$line" ] && ISSUES+=("$line")
    done <<< "${INTEGRITY_ISSUES:-}"
fi

# ── Deduplication ────────────────────────────────────────────────────────────
# Build a deterministic fingerprint of the current issues.
# Only send notifications when this fingerprint differs from last run.
ISSUE_COUNT="${#ISSUES[@]}"
# LC_ALL=C: collation is locale-dependent, and the sorted text feeds the hash.
# Under en_US.UTF-8 glibc orders "a-item A-item b-item _item" where C gives
# "A-item _item a-item b-item" — same issues, different fingerprint, spurious
# re-alert. Pinning the collation makes the fingerprint depend only on content.
STATE_TEXT="$(printf "%s\n" "${ISSUES[@]}" 2>/dev/null | LC_ALL=C sort)"
CURRENT_HASH="$(printf "%s" "$STATE_TEXT" | sha256sum | awk '{print $1}')"
LAST_HASH="$(cat "$STATE_FILE" 2>/dev/null || true)"

send_ok() {
    "$SEND" "✅ Health check OK on ${HOST}"
}

send_issues() {
    local msg="🚨 Health issues on ${HOST}:"
    for issue in "${ISSUES[@]}"; do
        msg="$msg
- $issue"
    done
    "$SEND" "$msg"
}

SENT=0

if [[ "$FORCE" -eq 1 ]]; then
    # Manual /health — always respond with current state
    if [ "$ISSUE_COUNT" -eq 0 ]; then
        send_ok
    else
        send_issues
    fi
    SENT=1
elif [[ "$CURRENT_HASH" != "$LAST_HASH" ]]; then
    # State changed — send notification
    if [ "$ISSUE_COUNT" -gt 0 ]; then
        send_issues
        SENT=1
    fi
    # Save new state (whether issues or all-clear, so we detect recovery)
    echo "$CURRENT_HASH" > "$STATE_FILE"
fi

# ── Side channels ────────────────────────────────────────────────────────────
# These report for themselves rather than joining ISSUES, deliberately. The
# fingerprint above describes a STATE — what is wrong right now — and has to
# stay stable for dedup to work. A notification or an update is an EVENT: it
# happens once. Folding events into the state would change the hash every time
# one arrived and re-announce every unrelated issue alongside it. Each keeps its
# own seen-set instead.
#
# Piggybacking the health timer rather than adding units: both want exactly this
# cadence and this user. Failures here never affect the health result.
for SIDE in umbrel_notifications.sh umbrel_update_check.sh; do
    if [ -x "$SCRIPT_DIR/$SIDE" ]; then
        "$SCRIPT_DIR/$SIDE" &>/dev/null || true
    fi
done

# Non-zero exit tells systemd that alerts were sent (visible in systemctl status)
exit $(( SENT > 0 ? 1 : 0 ))

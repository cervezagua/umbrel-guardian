#!/usr/bin/env bash
# Proactive health check: runs on a timer and sends Telegram alerts
# if disk usage exceeds threshold or any app is not in "ready" state.
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
    ISSUES+=("⚠️ Disk ${DISK_LABEL} at ${DISK_USE}% (threshold: ${THRESHOLD}%)")
fi

# ── App health check ────────────────────────────────────────────────────────
if command -v umbreld &>/dev/null; then
    APP_ISSUES=$(umbreld client apps.list.query 2>&1 | python3 - <<'PYEOF'
import sys, json

raw = sys.stdin.read()
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

for app in apps:
    state = app.get("state", "unknown")
    if state != "ready":
        print(f"❌ {app['id']} is {state}")
PYEOF
    ) || true

    # Add each unhealthy app line to ISSUES array
    while IFS= read -r line; do
        [ -n "$line" ] && ISSUES+=("$line")
    done <<< "${APP_ISSUES:-}"
fi

# ── Deduplication ────────────────────────────────────────────────────────────
# Build a deterministic fingerprint of the current issues.
# Only send notifications when this fingerprint differs from last run.
ISSUE_COUNT="${#ISSUES[@]}"
STATE_TEXT="$(printf "%s\n" "${ISSUES[@]}" 2>/dev/null | sort)"
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

# Non-zero exit tells systemd that alerts were sent (visible in systemctl status)
exit $(( SENT > 0 ? 1 : 0 ))

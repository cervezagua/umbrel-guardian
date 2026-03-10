#!/usr/bin/env bash
# Output a human-readable system status summary for Telegram.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$(dirname "$SCRIPT_DIR")/config.env"
source "$CONFIG"

UMBREL_DATA="${UMBREL_DIR:-/home/umbrel/umbrel}"

# Disk — Umbrel OS 1.5 on Pi uses /mnt/root/mnt/data, fall back to /mnt/data then /
if df -hP /mnt/root/mnt/data &>/dev/null; then
    DISK_LINE=$(df -hP /mnt/root/mnt/data | awk 'NR==2 {print $3"/"$2" ("$5" used)"}')
    DISK_LABEL="/mnt/root/mnt/data"
elif df -hP /mnt/data &>/dev/null; then
    DISK_LINE=$(df -hP /mnt/data | awk 'NR==2 {print $3"/"$2" ("$5" used)"}')
    DISK_LABEL="/mnt/data"
else
    DISK_LINE=$(df -hP / | awk 'NR==2 {print $3"/"$2" ("$5" used)"}')
    DISK_LABEL="/"
fi

RAM=$(free -h | awk '/Mem:/ {print $3"/"$2}')
CPU=$(uptime | awk -F'load average:' '{print $2}' | xargs)
UPTIME_STR=$(uptime -p 2>/dev/null || uptime)

# App count (non-fatal if umbreld is unavailable)
APP_COUNT="?"
if command -v umbreld &>/dev/null; then
    _RAW=$(umbreld client apps.list.query 2>&1) || true
    APP_COUNT=$(echo "$_RAW" | python3 -c "
import sys, json
raw = sys.stdin.read()
decoder = json.JSONDecoder()
try:
    apps, _ = decoder.raw_decode(raw.lstrip())
except (json.JSONDecodeError, ValueError):
    idx = raw.find('[')
    if idx == -1: sys.exit(1)
    apps, _ = decoder.raw_decode(raw, idx)
print(len(apps))
" 2>/dev/null) || APP_COUNT="?"
fi

echo "🖥 Umbrel System Status
━━━━━━━━━━━━━━━━━━
⏱ Uptime:   ${UPTIME_STR}
💾 Disk (${DISK_LABEL}): ${DISK_LINE}
🧠 RAM:      ${RAM}
⚡ CPU load: ${CPU}
📦 Apps:     ${APP_COUNT} installed"

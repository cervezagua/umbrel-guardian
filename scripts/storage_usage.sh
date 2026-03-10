#!/usr/bin/env bash
# Report disk usage breakdown under UMBREL_DIR.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$(dirname "$SCRIPT_DIR")/config.env"
source "$CONFIG"

UMBREL_DATA="${UMBREL_DIR:-/home/umbrel/umbrel}"

# Overall disk — Umbrel OS 1.5 on Pi uses /mnt/root/mnt/data
if df -hP /mnt/root/mnt/data &>/dev/null; then
    DISK_LINE=$(df -hP /mnt/root/mnt/data | awk 'NR==2 {print $3"/"$2" ("$5" used)"}')
    echo "💾 Storage Usage — /mnt/root/mnt/data: $DISK_LINE"
elif df -hP /mnt/data &>/dev/null; then
    DISK_LINE=$(df -hP /mnt/data | awk 'NR==2 {print $3"/"$2" ("$5" used)"}')
    echo "💾 Storage Usage — /mnt/data: $DISK_LINE"
else
    DISK_LINE=$(df -hP / | awk 'NR==2 {print $3"/"$2" ("$5" used)"}')
    echo "💾 Storage Usage — /: $DISK_LINE"
fi

echo "━━━━━━━━━━━━━━━━━━"
echo "Top dirs in $UMBREL_DATA:"
echo ""

# du with depth 1, sorted by size descending, top 10.
# Wrapped in timeout — on a Pi with 500GB+ of app data, du can take minutes
# scanning millions of files. The df summary above is instant and always shown.
DU_OUT=$(timeout 45 du -sh "${UMBREL_DATA}"/*/  2>/dev/null \
    | sort -rh \
    | head -10 \
    | awk '{printf "%-8s %s\n", $1, $2}')

if [ -n "$DU_OUT" ]; then
    echo "$DU_OUT"
else
    echo "(directory breakdown unavailable — scan timed out)"
fi

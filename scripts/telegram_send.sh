#!/usr/bin/env bash
# Send a Telegram message.
# Usage:
#   telegram_send.sh "your message"   ← pass as argument
#   echo "your message" | telegram_send.sh  ← pipe via stdin
#
# Supports CHAT_IDS (comma-separated) for multiple admins,
# with fallback to CHAT_ID for backward compatibility.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$(dirname "$SCRIPT_DIR")/config.env"

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: config.env not found at $CONFIG" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG"

if [ -z "${BOT_TOKEN:-}" ]; then
    echo "ERROR: BOT_TOKEN not set in config.env" >&2
    exit 1
fi

# Support CHAT_IDS (comma-separated) with fallback to CHAT_ID
IDS="${CHAT_IDS:-${CHAT_ID:-}}"
if [ -z "$IDS" ]; then
    echo "ERROR: CHAT_ID or CHAT_IDS not set in config.env" >&2
    exit 1
fi

# Accept message from argument or stdin
if [ -n "${1:-}" ]; then
    TEXT="$1"
else
    TEXT=$(cat)
fi

if [ -z "$TEXT" ]; then
    echo "ERROR: No message text provided." >&2
    exit 1
fi

# Send to each chat ID and verify the API response body
SEND_FAILED=0
IFS=',' read -ra ID_ARRAY <<< "$IDS"
for CHAT in "${ID_ARRAY[@]}"; do
    CHAT="${CHAT// /}"   # trim whitespace

    RESPONSE=$(curl -s \
        -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT}" \
        --data-urlencode "text=${TEXT}" \
        --data-urlencode "disable_web_page_preview=true")

    # Telegram returns HTTP 200 even for logical errors; check the JSON body
    if ! echo "$RESPONSE" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    sys.exit(0 if d.get('ok') else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
        echo "ERROR: Telegram API failure for chat ${CHAT}: $RESPONSE" >&2
        SEND_FAILED=1
    fi
done

exit $SEND_FAILED

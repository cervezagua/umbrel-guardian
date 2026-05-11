#!/usr/bin/env bash
# Restart a specific Umbrel app by its app ID.
# Usage: restart_app.sh <app_id>

set -uo pipefail

APP="${1:-}"

if [ -z "$APP" ]; then
    echo "⚠️ Usage: restart_app.sh <app_id>"
    exit 1
fi

if ! command -v umbreld &>/dev/null; then
    echo "⚠️ umbreld not found — cannot restart apps."
    exit 1
fi

# Verify the app exists before trying to restart.
# Capture all output (stdout + stderr) — umbreld may write JSON to either.
RAW=$(umbreld client apps.list.query 2>&1) || true
if ! echo "$RAW" | python3 -c "
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
    sys.exit(0)  # can't validate — let the restart attempt proceed

ids = [a['id'] for a in apps]
app = sys.argv[1]
if app not in ids:
    sys.exit(1)
" "$APP" 2>/dev/null; then
    echo "⚠️ Unknown app ID: $APP"
    echo "Use /apps to see valid app IDs."
    exit 1
fi

if umbreld client apps.restart.mutate --appId "$APP" &>/dev/null; then
    echo "✅ Restarted: $APP"
else
    echo "⚠️ Failed to restart $APP — check that the app ID is correct."
    exit 1
fi

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

# Verify the app exists and resolve it to its canonical id.
# Telegram-tappable shortcuts use underscores instead of dashes
# (e.g. /restart_adguard_home for app id "adguard-home"), so we also try
# the literal form with _ → - substitution as a fallback.
# Capture all output (stdout + stderr) — umbreld may write JSON to either.
RAW=$(umbreld client apps.list.query 2>&1) || true
RESOLVED=$(echo "$RAW" | python3 -c "
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

app = sys.argv[1]
if apps is None:
    # Can't validate — pass through and let the restart attempt handle it.
    print(app)
    sys.exit(0)

ids = [a['id'] for a in apps]
# Try literal first, then the _ → - substitution (Telegram-tappable form).
for candidate in (app, app.replace('_', '-')):
    if candidate in ids:
        print(candidate)
        sys.exit(0)
sys.exit(1)
" "$APP" 2>/dev/null) || true

if [ -z "$RESOLVED" ]; then
    echo "⚠️ Unknown app ID: $APP"
    echo "Use /apps to see valid app IDs."
    exit 1
fi

APP="$RESOLVED"

if umbreld client apps.restart.mutate --appId "$APP" &>/dev/null; then
    echo "✅ Restarted: $APP"
else
    echo "⚠️ Failed to restart $APP — check that the app ID is correct."
    exit 1
fi

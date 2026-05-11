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
# Resolution order:
#   1. Exact match against typed id
#   2. Exact match against id with _ → - substitution (Telegram-tappable form)
#   3. Prefix match: if exactly one installed app starts with the typed id (or
#      its dash-substituted form), use it. Lets `/restart adguard` → adguard-home.
#   4. If multiple prefix matches, report them all so the user can be specific.
# Capture all output (stdout + stderr) — umbreld may write JSON to either.
RAW=$(umbreld client apps.list.query 2>&1) || true
RESPONSE=$(echo "$RAW" | python3 -c "
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
    print(f'RESOLVED:{app}')
    sys.exit(0)

ids = [a['id'] for a in apps]

# 1 & 2: exact match (literal, then _ → -)
for candidate in (app, app.replace('_', '-')):
    if candidate in ids:
        print(f'RESOLVED:{candidate}')
        sys.exit(0)

# 3 & 4: prefix match (union of literal and dash-substituted)
needles = {app, app.replace('_', '-')}
matches = sorted({i for i in ids for n in needles if i.startswith(n)})

if len(matches) == 1:
    print(f'RESOLVED:{matches[0]}')
elif len(matches) > 1:
    print(f'AMBIGUOUS:{\",\".join(matches)}')
else:
    print('NONE')
" "$APP" 2>/dev/null) || true

case "$RESPONSE" in
    RESOLVED:*)
        APP="${RESPONSE#RESOLVED:}"
        ;;
    AMBIGUOUS:*)
        echo "⚠️ Ambiguous app ID: \"$APP\" matches multiple apps."
        echo "Did you mean one of these?"
        echo "${RESPONSE#AMBIGUOUS:}" | tr ',' '\n' | sed 's|^|  - /restart |'
        exit 1
        ;;
    *)
        echo "⚠️ Unknown app ID: $APP"
        echo "Use /apps to see valid app IDs."
        exit 1
        ;;
esac

if umbreld client apps.restart.mutate --appId "$APP" &>/dev/null; then
    echo "✅ Restarted: $APP"
else
    echo "⚠️ Failed to restart $APP — check that the app ID is correct."
    exit 1
fi

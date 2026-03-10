#!/usr/bin/env bash
# Restart all Umbrel apps that are not in "ready" state.

set -uo pipefail

if ! command -v umbreld &>/dev/null; then
    echo "⚠️ umbreld not found — cannot restart apps."
    exit 1
fi

# Capture all output (stdout + stderr) — umbreld may write JSON to either.
RAW=$(umbreld client apps.list.query 2>&1) || true

UNHEALTHY=$(echo "$RAW" | python3 -c "
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

for a in apps:
    if a.get('state') != 'ready':
        print(a['id'])
" 2>/dev/null) || true

if [ -z "$UNHEALTHY" ]; then
    echo "✅ All apps are healthy — nothing to restart."
    exit 0
fi

echo "🔄 Restart Results:"
while IFS= read -r APP_ID; do
    if umbreld client apps.restart.mutate --appId "$APP_ID" &>/dev/null; then
        echo "✅ Restarted: $APP_ID"
    else
        echo "⚠️ Failed:    $APP_ID"
    fi
done <<< "$UNHEALTHY"

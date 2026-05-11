#!/usr/bin/env bash
# Restart Umbrel apps that are in an unhealthy state (e.g. "unknown").
#
# State taxonomy (Umbrel 1.7.x):
#   ready, running                                           → healthy, skip
#   starting, installing, updating, restarting, stopping,    → transient, skip
#     uninstalling                                             (would race with umbreld)
#   stopped                                                  → user turned it off, skip
#   unknown                                                  → restart

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

HEALTHY     = {'ready', 'running'}
TRANSIENT   = {'starting', 'installing', 'updating', 'restarting', 'stopping', 'uninstalling'}
INTENTIONAL = {'stopped'}

for a in apps:
    state = a.get('state', 'unknown')
    if state in HEALTHY or state in TRANSIENT or state in INTENTIONAL:
        continue
    print(a['id'])
" 2>/dev/null) || true

if [ -z "$UNHEALTHY" ]; then
    echo "✅ No apps in unknown/failed state — nothing to restart."
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

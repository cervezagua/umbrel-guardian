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

# Per-app and overall budgets. The loop below used to be unbounded at 60s per
# app while the bot allowed the whole script 120s — so restarting two apps made
# the bot report a failure while the restarts were in fact proceeding. A script
# whose worst case exceeds its caller's patience will eventually be killed
# mid-sentence, and what it was killed during is invisible. Bounding it here
# means the caller's timeout is a backstop, not the normal exit path.
RESTART_TIMEOUT=120
OVERALL_BUDGET=300
START_TS=$(date +%s)

if ! command -v umbreld &>/dev/null; then
    echo "⚠️ umbreld not found — cannot restart apps."
    exit 1
fi

# Capture all output (stdout + stderr) — umbreld may write JSON to either.
RAW=$(timeout 45 umbreld client apps.list.query 2>&1) || true

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
    if state in HEALTHY or state in INTENTIONAL:
        continue
    # Transient states are not restarted — that would race umbreld's own
    # transition — but they ARE reported. An app that has been 'restarting'
    # for hours is no longer transient, and silently skipping it tells you
    # nothing was wrong when something plainly is.
    if state in TRANSIENT:
        print('SKIP\t%s\t%s' % (a['id'], state))
        continue
    print('FIX\t%s\t%s' % (a['id'], state))
" 2>/dev/null) || true

SKIPPED=$(printf '%s\n' "${UNHEALTHY:-}" | awk -F'\t' '$1=="SKIP"{print $2" ("$3")"}')
UNHEALTHY=$(printf '%s\n' "${UNHEALTHY:-}" | awk -F'\t' '$1=="FIX"{print $2}')

report_stuck() {
    [ -n "${SKIPPED:-}" ] || return 0
    echo ""
    echo "⏳ Mid-transition, not touched (restarting one would race umbreld):"
    printf '%s\n' "$SKIPPED" | sed 's|^|   - |'
    echo "   If any of these has been stuck for more than a few minutes, it is"
    echo "   not really mid-transition: /restart <app_id> forces it."
}

if [ -z "${UNHEALTHY:-}" ]; then
    echo "✅ No apps in unknown/failed state — nothing to restart."
    report_stuck
    exit 0
fi

echo "🔄 Restart Results:"
STOPPED_EARLY=""
while IFS= read -r APP_ID; do
    [ -n "${APP_ID:-}" ] || continue
    # Stop starting new work once another full-length restart could not finish
    # inside the budget, rather than being cut off partway through one.
    if [ $(( $(date +%s) - START_TS + RESTART_TIMEOUT )) -gt "$OVERALL_BUDGET" ]; then
        STOPPED_EARLY="$STOPPED_EARLY $APP_ID"
        continue
    fi
    OUT=$(timeout "$RESTART_TIMEOUT" umbreld client apps.restart.mutate --appId "$APP_ID" 2>&1)
    RC=$?
    if [ "$RC" -eq 0 ]; then
        echo "✅ Restarted: $APP_ID"
    elif [ "$RC" -eq 124 ]; then
        echo "⏳ Timed out:  $APP_ID (${RESTART_TIMEOUT}s; it may still be coming back)"
    else
        # Keep the reason. "Failed" with no cause is the message that sends you
        # looking in the wrong place.
        DETAIL=$(printf '%s' "${OUT:-}" | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-160)
        echo "⚠️ Failed:    $APP_ID${DETAIL:+ — $DETAIL}"
    fi
done <<< "$UNHEALTHY"

if [ -n "${STOPPED_EARLY:-}" ]; then
    echo ""
    echo "⏸ Stopped after ${OVERALL_BUDGET}s. Not attempted:${STOPPED_EARLY}"
    echo "   Run /restart unhealthy again to continue."
fi
report_stuck

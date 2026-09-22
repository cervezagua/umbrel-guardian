#!/usr/bin/env bash
# Relay umbrelOS's own notifications to Telegram.
#
# Usage:
#   umbrel_notifications.sh          ← send anything not seen before (timer path)
#   umbrel_notifications.sh --list   ← show everything currently pending, change nothing
#
# umbrelOS raises notifications for things Guardian cannot see for itself —
# its own backups failing, an app's storage being moved, cloud auth expiring —
# and they only appear if you happen to open the dashboard. This puts them where
# you already are.
#
# ── Read-only, deliberately ──────────────────────────────────────────────────
# umbreld exposes notifications.clear.mutate, and we never call it. Clearing
# removes the notice from the dashboard for everyone, so relaying it to Telegram
# would quietly destroy state someone else may be relying on. Re-sending is
# prevented by our own seen-set instead, which costs nothing and touches nobody.
#
# ── Shape of the data ────────────────────────────────────────────────────────
# notifications.get.query returns a JSON array of PLAIN STRINGS, newest first.
# No object, no timestamp, no severity — the id is the whole notification. Ids
# scoped to an account are prefixed "@account:<urlencoded-id>:", and the suffix
# can itself contain colons (cloud-auth:acct1), so the prefix is stripped with a
# single # expansion. Using ## would eat the useful half.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
if [ ! -r "$SCRIPT_DIR/lib-umbreld.sh" ]; then
    echo "⚠️ scripts/lib-umbreld.sh is missing — this is a partial install." >&2
    echo "   Re-run: sudo bash $(dirname "$SCRIPT_DIR")/reinstall-services.sh" >&2
    exit 1
fi
source "$SCRIPT_DIR/lib-umbreld.sh"
CONFIG="$(dirname "$SCRIPT_DIR")/config.env"
SEND="$SCRIPT_DIR/telegram_send.sh"
STATE_DIR="$(dirname "$SCRIPT_DIR")/.state"
SEEN_FILE="$STATE_DIR/notifications.seen"

# shellcheck source=/dev/null
[ -f "$CONFIG" ] && source "$CONFIG"

MODE="send"
[ "${1:-}" = "--list" ] && MODE="list"

# Overridable so the test harness can drive this without a live umbreld.
UMBRELD_BIN="${UMBRELD_BIN:-umbreld}"
# 45s, not the 10s that looks generous for a local query. `umbreld client` is
# Node and burns ~2.7s of CPU to answer; the bot's unit sets CPUQuota=20%, and
# cgroup limits apply to every process the bot spawns. Measured on a live node:
# 1.8s unconstrained, 19.25s under that quota — a 10x multiplier. A 10s timeout
# is therefore guaranteed to fail from the bot while passing every test run from
# a shell, which is exactly how this shipped.
UMBRELD_TIMEOUT=45
MAX_MESSAGES=5

guardian_umbreld_available || {
    [ "$MODE" = "list" ] && echo "ℹ️ umbreld not found — notification relay unavailable."
    exit 0
}

RAW=$(guardian_umbreld "$UMBRELD_TIMEOUT" notifications.get.query 2>&1)
RC=$?

# umbrelOS 1.7.x may not have the notifications module at all, and an upgrade
# can remove or rename a procedure at any time. Either way this is not a fault
# worth alerting on — it just means there is nothing to relay.
if [ "$RC" -ne 0 ] || [ -z "${RAW:-}" ]; then
    if [ "$MODE" = "list" ]; then
        if echo "${RAW:-}" | grep -qi "no procedure\|not found\|unknown"; then
            echo "ℹ️ This umbrelOS version has no notifications API — nothing to relay."
        else
            echo "⚠️ Could not read umbrelOS notifications (umbreld exit $RC)."
        fi
    fi
    # CRITICAL: return without touching SEEN_FILE. Truncating it on a transient
    # failure would make every pending notification look new on the next run and
    # re-send the entire backlog.
    exit 0
fi

# Same defensive JSON handling the other scripts use: umbreld interleaves log
# noise with its JSON, so locate the array rather than trusting the whole blob.
IDS=$(printf '%s' "$RAW" | python3 -c "
import sys, json
raw = sys.stdin.read()
decoder = json.JSONDecoder()
data = None
try:
    data, _ = decoder.raw_decode(raw.lstrip())
except (json.JSONDecodeError, ValueError):
    idx = raw.find('[')
    if idx != -1:
        try:
            data, _ = decoder.raw_decode(raw, idx)
        except (json.JSONDecodeError, ValueError):
            pass
if not isinstance(data, list):
    sys.exit(0)
for item in data:
    if isinstance(item, str) and item.strip():
        print(item)
" 2>/dev/null)

mkdir -p "$STATE_DIR" 2>/dev/null || true

# Map an id to something a human wants to read at 3am. Unknown ids pass through
# verbatim rather than being dropped: umbrelOS 2.0 adds new ones, and a
# notification we do not recognise is exactly the kind we should not swallow.
describe() {
    local id="$1"
    local bare="${id#@account:*:}"   # single # — the suffix may contain colons
    case "$bare" in
        onboarding-complete)          echo "" ;;   # noise, seen once per lifetime
        umbrelos-updated)             echo "🔄 umbrelOS was updated" ;;
        migrated-back-that-mac-up)    echo "🔄 Back That Mac Up data was migrated" ;;
        backups-failing:*)            echo "🚨 umbrelOS backups are failing (repository ${bare#backups-failing:})" ;;
        backups-failing)              echo "🚨 umbrelOS backups are failing" ;;
        app-storage-settings-changed:*) echo "ℹ️ Storage settings changed for ${bare#app-storage-settings-changed:}" ;;
        cloud-auth:*)                 echo "🔑 Cloud storage needs re-authentication" ;;
        *raid*scrub*|*RAID*)          echo "🚨 RAID scrub reported errors" ;;
        thunderbolt*)                 echo "⚠️ Thunderbolt device issue: $bare" ;;
        *)                            echo "🔔 umbrelOS: $bare" ;;
    esac
}

if [ "$MODE" = "list" ]; then
    if [ -z "${IDS:-}" ]; then
        echo "✅ No pending umbrelOS notifications."
        exit 0
    fi
    echo "🔔 umbrelOS Notifications"
    echo "━━━━━━━━━━━━━━━━━━"
    while IFS= read -r ID; do
        [ -n "$ID" ] || continue
        TEXT=$(describe "$ID")
        [ -n "$TEXT" ] && echo "  $TEXT" || echo "  ℹ️ ${ID#@account:*:}"
    done <<< "$IDS"
    exit 0
fi

# ── First run seeds silently ─────────────────────────────────────────────────
# A node that has been up for months carries a pile of notices it already showed
# you in the dashboard. Blasting all of them the first time this runs teaches
# you that the relay is noise, which is the opposite of the point. /notifications
# shows the backlog whenever you actually want it.
if [ ! -f "$SEEN_FILE" ]; then
    printf '%s\n' "${IDS:-}" > "$SEEN_FILE" 2>/dev/null || true
    exit 0
fi

NEW=()
while IFS= read -r ID; do
    [ -n "$ID" ] || continue
    grep -qxF "$ID" "$SEEN_FILE" 2>/dev/null && continue
    TEXT=$(describe "$ID")
    [ -n "$TEXT" ] && NEW+=("$TEXT")
done <<< "${IDS:-}"

# Record everything we saw — including ids we chose not to relay — so a noisy id
# is evaluated once and never again.
printf '%s\n' "${IDS:-}" > "$SEEN_FILE" 2>/dev/null || true

[ "${#NEW[@]}" -eq 0 ] && exit 0

COUNT="${#NEW[@]}"
SHOWN=$(( COUNT < MAX_MESSAGES ? COUNT : MAX_MESSAGES ))
MSG="🔔 umbrelOS notification"
[ "$COUNT" -gt 1 ] && MSG="🔔 ${COUNT} new umbrelOS notifications"
for (( i = 0; i < SHOWN; i++ )); do
    MSG="$MSG
${NEW[$i]}"
done
if [ "$COUNT" -gt "$SHOWN" ]; then
    MSG="$MSG
…and $(( COUNT - SHOWN )) more — see /notifications"
fi

[ -x "$SEND" ] && "$SEND" "$MSG"
exit 0

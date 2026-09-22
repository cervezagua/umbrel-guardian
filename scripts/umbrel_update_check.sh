#!/usr/bin/env bash
# Watch for umbrelOS updates, and verify Guardian survived the last one.
#
# Usage:
#   umbrel_update_check.sh            ← alert on a new version / a completed OTA (timer path)
#   umbrel_update_check.sh --report   ← print current state, change nothing
#
# ── Two jobs, two cadences, one script ───────────────────────────────────────
# Post-OTA detection is local and costs nothing, so it runs on every invocation:
# the sooner we notice an update landed, the sooner we can tell you whether
# Guardian came back with it. The "is an update available" question goes over
# the network, so it is throttled to a few times a day.
#
# The self-check matters more than the availability alert. Guardian lives on a
# system with A/B root partitions: an OTA replaces /etc wholesale, taking every
# systemd unit and the sudoers file with it. Recovery depends entirely on
# umbrelOS running custom-hooks/pre-start on the next boot. When that works you
# never notice; when it does not, Guardian is silently gone — no bot, no
# backups, no alerts, and nothing to tell you so, because the thing that would
# have told you is the thing that died. So after every version change we check
# our own installation and say plainly what came back.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
if [ ! -r "$SCRIPT_DIR/lib-umbreld.sh" ]; then
    echo "⚠️ scripts/lib-umbreld.sh is missing — this is a partial install." >&2
    echo "   Re-run: sudo bash $(dirname "$SCRIPT_DIR")/reinstall-services.sh" >&2
    exit 1
fi
source "$SCRIPT_DIR/lib-umbreld.sh"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="$INSTALL_DIR/config.env"
SEND="$SCRIPT_DIR/telegram_send.sh"
STATE_DIR="$INSTALL_DIR/.state"
VERSION_FILE="$STATE_DIR/os-version"
STAMP_FILE="$STATE_DIR/update-check.stamp"
SEEN_FILE="$STATE_DIR/update.seen"

# shellcheck source=/dev/null
[ -f "$CONFIG" ] && source "$CONFIG"

MODE="check"
[ "${1:-}" = "--report" ] && MODE="report"

UMBRELD_BIN="${UMBRELD_BIN:-umbreld}"
# 45s, not the 10s that looks generous for a local query. `umbreld client` is
# Node and burns ~2.7s of CPU to answer; the bot's unit sets CPUQuota=20%, and
# cgroup limits apply to every process the bot spawns. Measured on a live node:
# 1.8s unconstrained, 19.25s under that quota — a 10x multiplier. A 10s timeout
# is therefore guaranteed to fail from the bot while passing every test run from
# a shell, which is exactly how this shipped.
UMBRELD_TIMEOUT="$GUARDIAN_UMBRELD_TIMEOUT"
# How long between network update checks. Six hours is far more often than
# umbrelOS ships, and keeps the timer from making an outbound call every 30
# minutes for an answer that changes a few times a year.
CHECK_INTERVAL=$(( 6 * 3600 ))

mkdir -p "$STATE_DIR" 2>/dev/null || true

# Pull values out of umbreld's JSON. Same defensive decode as the other scripts:
# umbreld interleaves log lines with its output, so locate the payload rather
# than trusting the whole blob. With no key, prints a bare scalar (getReleaseChannel
# returns a plain JSON string); with keys, prints one line per key in order.
umbreld_json() {
    local query="$1"; shift
    local raw
    raw=$(guardian_umbreld "$UMBRELD_TIMEOUT" "$query" 2>/dev/null) || return 1
    [ -n "${raw:-}" ] || return 1
    printf '%s' "$raw" | python3 -c '
import sys, json
raw = sys.stdin.read()
keys = sys.argv[1:]
dec = json.JSONDecoder()
data = None
try:
    data, _ = dec.raw_decode(raw.lstrip())
except Exception:
    for ch in ("{", "["):
        i = raw.find(ch)
        if i != -1:
            try:
                data, _ = dec.raw_decode(raw, i)
                break
            except Exception:
                pass
if keys:
    for k in keys:
        v = data.get(k) if isinstance(data, dict) else None
        print("" if v is None else v)
elif data is not None and not isinstance(data, (dict, list)):
    print(data)
' "$@" 2>/dev/null
}

guardian_umbreld_available || {
    [ "$MODE" = "report" ] && echo "ℹ️ umbreld not found — update checks unavailable."
    exit 0
}

# system.version.query is a public procedure, so this works even where the
# private ones are refused.
CURRENT=$(umbreld_json "system.version.query" "version")
[ -n "${CURRENT:-}" ] || {
    [ "$MODE" = "report" ] && echo "⚠️ Could not read the umbrelOS version from umbreld."
    exit 0
}

# ── Post-OTA self-check ──────────────────────────────────────────────────────
# Runs every invocation: local, cheap, and the answer matters most right after
# an update.
PREVIOUS=$(cat "$VERSION_FILE" 2>/dev/null || true)

self_check() {
    local missing=() ok_count=0 total=0
    check() {
        total=$((total + 1))
        if eval "$2" &>/dev/null; then ok_count=$((ok_count + 1)); else missing+=("$1"); fi
    }
    check "bot service"            "[ -f /etc/systemd/system/umbrel-guardian-bot.service ]"
    check "bot running"            "systemctl is-active --quiet umbrel-guardian-bot.service"
    check "health timer"           "systemctl is-enabled --quiet umbrel-guardian-health.timer"
    check "backup timer"           "systemctl is-enabled --quiet umbrel-guardian-backup.timer"
    check "backup trigger path"    "systemctl is-enabled --quiet umbrel-guardian-backup-trigger.path"
    check "sudoers"                "[ -f /etc/sudoers.d/umbrel-guardian-system ]"
    check "pre-start hook"         "[ -x /home/umbrel/umbrel/custom-hooks/pre-start ]"
    check "scripts executable"     "[ -x $SCRIPT_DIR/backup.sh ]"
    check "config"                 "[ -f $CONFIG ]"
    check "state dir"              "[ -d $STATE_DIR ]"
    SELF_CHECK_TOTAL=$total
    SELF_CHECK_OK=$ok_count
    SELF_CHECK_MISSING="${missing[*]:-}"
}

if [ "$MODE" = "check" ] && [ -n "${PREVIOUS:-}" ] && [ "$PREVIOUS" != "$CURRENT" ]; then
    self_check
    MSG="🔄 umbrelOS updated: $PREVIOUS → $CURRENT
🛡 Guardian self-check: ${SELF_CHECK_OK}/${SELF_CHECK_TOTAL} components present"
    if [ -n "${SELF_CHECK_MISSING:-}" ]; then
        MSG="$MSG
❌ Missing: ${SELF_CHECK_MISSING}
Recover with: sudo bash $INSTALL_DIR/reinstall-services.sh"
    else
        MSG="$MSG
✅ Guardian came through the update intact."
    fi
    [ -x "$SEND" ] && "$SEND" "$MSG"
fi

# Record the version last, so a crash mid-run means we re-check next time
# rather than silently deciding we already handled this update.
[ "$MODE" = "check" ] && printf '%s\n' "$CURRENT" > "$VERSION_FILE" 2>/dev/null

# ── Update availability ──────────────────────────────────────────────────────
CHANNEL=$(umbreld_json "system.getReleaseChannel.query" || true)

should_check_network() {
    [ -f "$STAMP_FILE" ] || return 0
    local last now
    last=$(stat -c %Y "$STAMP_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    [ $(( now - last )) -ge "$CHECK_INTERVAL" ]
}

AVAILABLE=""; NEW_VERSION=""
if [ "$MODE" = "report" ] || should_check_network; then
    # One call, both fields — asking twice would double the network round trips
    # for a single question.
    UPDATE_INFO=$(umbreld_json "system.checkUpdate.query" "available" "version" || true)
    AVAILABLE=$(printf '%s\n' "${UPDATE_INFO:-}" | sed -n '1p')
    NEW_VERSION=$(printf '%s\n' "${UPDATE_INFO:-}" | sed -n '2p')
    [ "$MODE" = "check" ] && touch "$STAMP_FILE" 2>/dev/null
fi

if [ "$MODE" = "report" ]; then
    echo "🔄 umbrelOS Update Status"
    echo "━━━━━━━━━━━━━━━━━━"
    echo "  Installed: ${CURRENT}"
    echo "  Channel:   ${CHANNEL:-unknown}"
    if [ "${AVAILABLE:-}" = "True" ] || [ "${AVAILABLE:-}" = "true" ]; then
        echo "  ⬆️ Update available: ${NEW_VERSION:-unknown}"
        echo ""
        echo "  Guardian reinstalls itself after an update via the pre-start hook,"
        echo "  and will report whether that worked once the node comes back."
    else
        echo "  ✅ Up to date"
    fi
    if [ -f "$STAMP_FILE" ]; then
        AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$STAMP_FILE" 2>/dev/null || echo 0) ) / 3600 ))
        echo "  Last checked: ${AGE_H}h ago"
    fi
    exit 0
fi

# Alert once per version, not once per check. Without the seen-file this would
# repeat the same "update available" every six hours until you took it.
if [ "${AVAILABLE:-}" = "True" ] || [ "${AVAILABLE:-}" = "true" ]; then
    if ! grep -qxF "${NEW_VERSION:-unknown}" "$SEEN_FILE" 2>/dev/null; then
        printf '%s\n' "${NEW_VERSION:-unknown}" >> "$SEEN_FILE" 2>/dev/null || true
        [ -x "$SEND" ] && "$SEND" "⬆️ umbrelOS ${NEW_VERSION:-update} is available (you are on ${CURRENT})
Update from the umbrelOS dashboard when convenient.
Guardian reinstalls itself afterwards via the pre-start hook and will confirm it came back."
    fi
fi
exit 0

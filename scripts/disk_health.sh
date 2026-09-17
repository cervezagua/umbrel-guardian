#!/usr/bin/env bash
# Disk health probe: SMART attributes, SD/eMMC wear, and kernel I/O errors.
#
# Usage:
#   disk_health.sh            ← human-readable report (for /disk_health)
#   disk_health.sh --issues   ← one deterministic line per problem, for health_check.sh
#   disk_health.sh --reset    ← forget every latched problem (after a drive swap)
#
# Needs root: smartctl talks to the raw device and the kernel journal is not
# world-readable. health_check.sh runs as the umbrel user and invokes this via
# `sudo -n`, which /etc/sudoers.d/umbrel-guardian-system permits for exactly the
# two forms above.
#
# ── Why the counts are bucketed ──────────────────────────────────────────────
# health_check.sh deduplicates by hashing its sorted issue list and alerting
# only when that hash changes. Any number that drifts between runs therefore
# re-alerts forever: an error count that ticks 41 → 42 looks like a brand new
# problem every 30 minutes, and you learn to ignore the alerts.
#
# So we never emit a raw count. Counts collapse into order-of-magnitude buckets
# (0, 1+, 10+, 100+, 1000+) and the highest bucket ever seen for each key is
# latched in .state/disk-health.state. Crossing into a new bucket changes the
# text once — a real escalation worth interrupting you for — and everything in
# between is silent.
#
# The latch never decays, and reporting is driven by the union of what is live
# now and what has ever been latched. That matters because the journal window is
# finite: errors age out, and a drive whose last recorded failure was eight days
# ago is not a healthy drive. Letting the alert clear itself would be worse than
# not alerting at all. Recovery is deliberate: --reset, after you have actually
# replaced the hardware.
#
# ── Why the journal is read incrementally ────────────────────────────────────
# The obvious implementation rescans a time window on every run. Measured on the
# live node that costs 75 SECONDS: 1.8 GB of journal pulled off an SD card at
# roughly 25 MB/s. `journalctl --grep` does not help — measured at the same 75s,
# because it filters what is PRINTED, not what is read — and neither does a
# longer timeout. Doing that every 30 minutes means holding a card we already
# suspect of failing under continuous read load, forever, in order to ask
# whether it is failing.
#
# So each entry is read exactly once. A journal cursor in .state/ records where
# the last run stopped; --after-cursor seeks straight there (a binary search
# through the entry arrays, not a scan) and returns only what is new. Per-key
# totals accumulate in .state/disk-health.counts. The latch was always
# monotonic, so accumulating across runs is the semantics it already wanted.
#
# Two runs racing (the 30-minute timer and someone typing /disk_health) can
# both read the same delta, or one can overwrite the other's totals. Both are
# bounded by a single run's worth of entries and both are absorbed by the
# order-of-magnitude buckets, so this is left unlocked deliberately rather than
# carrying a lock through every path to prevent a miscount of ±1 in a bucket
# that spans a factor of ten.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$(dirname "$SCRIPT_DIR")/config.env"
STATE_DIR="$(dirname "$SCRIPT_DIR")/.state"
STATE_FILE="$STATE_DIR/disk-health.state"
COUNT_FILE="$STATE_DIR/disk-health.counts"
CURSOR_FILE="$STATE_DIR/disk-health.cursor"

# shellcheck source=/dev/null
[ -f "$CONFIG" ] && source "$CONFIG"

MODE="report"
case "${1:-}" in
    --issues) MODE="issues" ;;
    --reset)  MODE="reset" ;;
    "")       ;;
    *)        echo "Usage: $0 [--issues|--reset]" >&2; exit 2 ;;
esac

# Sub-probe timeouts. A wedged drive must not hold the health timer open: the
# unit allows 300s total and the bot waits 120s, so every external call is
# individually bounded rather than trusting the whole script to finish.
SMART_TIMEOUT=20
# 60s. An incremental read finishes in milliseconds; this budget exists for the
# one-off bootstrap below and for a journal that is slow to open. An earlier
# 10s budget on a full-window scan silently produced "no errors found" on a node
# whose journal contained four I/O errors — see the failure handling below,
# which is the part that made that silent rather than obvious.
JOURNAL_TIMEOUT=60
# How far back the FIRST run looks, in kernel log lines. Seeking to the tail and
# walking backwards is cheap; seeking to a timestamp and reading forward is the
# 75-second operation. Kernel messages are sparse on an idle node, so a couple of
# thousand lines typically reach back months — far enough to notice a card that
# is already failing when Guardian is installed.
BOOTSTRAP_LINES="${DISK_HEALTH_BOOTSTRAP_LINES:-2000}"

say() { [ "$MODE" = "report" ] && echo "$1"; return 0; }

# ── Root check ───────────────────────────────────────────────────────────────
# Silent in --issues mode. /etc/sudoers.d/ is wiped on every boot and restamped
# by the pre-start hook, so there is a window where sudo -n legitimately fails;
# alerting on it would fire a spurious "monitoring is broken" every reboot. A
# human running /disk_health gets the full explanation instead.
IS_ROOT=0
[ "$EUID" -eq 0 ] && IS_ROOT=1
if [ "$IS_ROOT" -eq 0 ] && [ "$MODE" = "issues" ]; then
    exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true

# ── --reset ──────────────────────────────────────────────────────────────────
# Clearing the latch is not enough. If the cursor were simply deleted, the next
# run would bootstrap from the tail and re-import the very errors you just
# replaced the hardware to get rid of, re-latching them within 30 minutes. So
# --reset PINS the cursor to now: tracking restarts from this moment, which is
# what "I have swapped the card" actually means.
# The cheapest question you can ask a journal: where does it currently end?
# One entry, no content, no scan — used both by --reset and as the escape hatch
# when a bootstrap proves too expensive to finish.
pin_cursor_to_now() {
    local pin
    pin=$(timeout "$JOURNAL_TIMEOUT" journalctl -k -n 1 --no-pager --show-cursor 2>/dev/null \
          | sed -n 's/^-- cursor: //p' | tail -n1)
    [ -n "${pin:-}" ] || return 1
    printf '%s\n' "$pin" > "$CURSOR_FILE" 2>/dev/null || return 1
    return 0
}

if [ "$MODE" = "reset" ]; then
    rm -f "$STATE_FILE" "$COUNT_FILE" "$CURSOR_FILE"
    if pin_cursor_to_now; then
        echo "✅ Disk health latches cleared. Kernel-log tracking restarts from now."
    else
        echo "✅ Disk health latches cleared."
        echo "ℹ️ Could not pin the journal position (need root, or journalctl is unavailable)."
        echo "   The next run will re-read recent history, which may re-latch old errors."
    fi
    exit 0
fi

# ── Bucket + latch ───────────────────────────────────────────────────────────
bucket() {
    local n="${1:-0}"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    if   [ "$n" -eq 0 ];    then echo 0
    elif [ "$n" -lt 10 ];   then echo 1
    elif [ "$n" -lt 100 ];  then echo 10
    elif [ "$n" -lt 1000 ]; then echo 100
    else                         echo 1000
    fi
}

stored_bucket() {
    [ -f "$STATE_FILE" ] || { echo 0; return; }
    local v
    v=$(awk -F= -v k="$1" '$1==k{print $2; exit}' "$STATE_FILE" 2>/dev/null)
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    echo "$v"
}

# Raise the latch if the live bucket is higher, then print whichever is greater.
# Printing the latch rather than the live value is what keeps the text stable
# while a count keeps climbing inside a bucket.
latch() {
    local key="$1" live="$2" stored
    stored=$(stored_bucket "$key")
    if [ "$live" -gt "$stored" ]; then
        # Temp file plus mv, so an interrupted write cannot truncate the latch
        # and silently forget a failing drive.
        local tmp="${STATE_FILE}.tmp.$$"
        { [ -f "$STATE_FILE" ] && grep -v "^${key}=" "$STATE_FILE" 2>/dev/null
          echo "${key}=${live}"; } > "$tmp" 2>/dev/null
        mv -f "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp"
        echo "$live"
    else
        echo "$stored"
    fi
}

label() { [ "${1:-0}" -eq 0 ] && echo "" || echo "$1+"; }

# Minimum bucket worth reporting. Occasional USB resets and a handful of CRC
# errors are normal on any bus; sector damage never is.
threshold() {
    case "$1" in
        usbreset:*|smart:crc:*) echo 10 ;;
        *)                      echo 1 ;;
    esac
}

describe() {
    local key="$1" lbl; lbl=$(label "$2")
    case "$key" in
        ioerr:*)         echo "🚨 ${key#ioerr:}: $lbl kernel I/O errors — the drive is failing reads or writes" ;;
        usbreset:*)      echo "⚠️ usb ${key#usbreset:}: $lbl bus resets — check the cable and the power supply" ;;
        medium)          echo "🚨 $lbl unrecoverable medium errors — a drive has bad sectors" ;;
        readonly)        echo "🚨 A filesystem was remounted read-only — the kernel gave up on writes" ;;
        smart:health:*)  echo "🚨 /dev/${key##*:}: SMART self-assessment FAILED — the drive predicts its own failure" ;;
        smart:realloc:*) echo "🚨 /dev/${key##*:}: $lbl reallocated sectors — the drive is going bad" ;;
        smart:pending:*) echo "🚨 /dev/${key##*:}: $lbl sectors pending reallocation — the drive is going bad" ;;
        smart:uncorr:*)  echo "🚨 /dev/${key##*:}: $lbl uncorrectable sectors — the drive is going bad" ;;
        smart:crc:*)     echo "⚠️ /dev/${key##*:}: $lbl interface CRC errors — suspect the cable, not the disk" ;;
        mmc:eolwarn:*)   echo "⚠️ ${key##*:}: eMMC pre-EOL warning — 80% of its reserve blocks are used" ;;
        mmc:eolurgent:*) echo "🚨 ${key##*:}: eMMC pre-EOL URGENT — replace this card" ;;
        mmc:life90:*)    echo "🚨 ${key##*:}: eMMC has used 90%+ of its rated write life" ;;
        mmc:life70:*)    echo "⚠️ ${key##*:}: eMMC has used 70%+ of its rated write life" ;;
        *)               echo "⚠️ $key ($lbl)" ;;
    esac
}

# Every probe feeds this one map, keyed exactly as the state file is, so the
# reporting pass below is uniform and the latch lines up by construction.
declare -A LIVE=()
record() { LIVE["$1"]="${2:-1}"; }

# ── Kernel log probe ─────────────────────────────────────────────────────────
# Piped straight into awk. Even an incremental read can return a burst of lines
# from a drive that is actively failing, and slurping that into a shell variable
# would balloon memory on a Pi for no reason.
#
# The window is NOT the current boot. `-b` looked tidy and was wrong — a node
# that logged I/O errors yesterday and has since rebooted reports a clean
# current boot while the card is exactly as damaged as it was. The cursor spans
# reboots, so history survives a power cycle the way the hardware does.
KERNEL_LOG_OK=0
declare -A DELTA=()
NEW_CURSOR=""

# Counts accumulated by every previous run. These are what get bucketed; a
# single incremental read only ever sees the last half hour, which would never
# reach a meaningful bucket on its own.
declare -A TOTAL=()
if [ -f "$COUNT_FILE" ]; then
    while IFS='=' read -r _k _v; do
        [ -n "${_k:-}" ] || continue
        [[ "${_v:-}" =~ ^[0-9]+$ ]] || continue
        TOTAL["$_k"]="$_v"
    done < "$COUNT_FILE"
fi

kernel_scan() {
    timeout "$JOURNAL_TIMEOUT" journalctl -k --no-pager --show-cursor "$@" 2>/dev/null | awk '
        # journalctl appends this as its final line under --show-cursor. Capture
        # it here rather than post-processing the stream, so the whole read stays
        # a single pass with nothing buffered.
        /^-- cursor: / { cursor = substr($0, 12); next }
        # "I/O error, dev mmcblk0, sector 30648088 op 0x0:(READ)"
        match($0, /I\/O error, dev [a-zA-Z0-9]+/) {
            d = substr($0, RSTART + 15, RLENGTH - 15); ioerr[d]++; next
        }
        # "Buffer I/O error on device sda1, logical block 42" → attribute to the disk
        match($0, /Buffer I\/O error on device [a-zA-Z0-9]+/) {
            d = substr($0, RSTART + 27, RLENGTH - 27); sub(/p?[0-9]+$/, "", d); ioerr[d]++; next
        }
        /critical medium error|Medium Error|Unrecovered read error/ { medium++; next }
        # "usb 2-1: reset SuperSpeed USB device number 3". Extract from the match,
        # never by splitting on ":" — the syslog timestamp is full of colons.
        /: reset (high-speed|full-speed|low-speed|SuperSpeed)/ {
            if (match($0, /usb [0-9]+-[0-9.]+/)) {
                d = substr($0, RSTART + 4, RLENGTH - 4); usbreset[d]++; next
            }
        }
        /[Rr]emounting filesystem read-only/ { ro++; next }
        END {
            for (d in ioerr)    print "ioerr:" d " " ioerr[d]
            for (d in usbreset) print "usbreset:" d " " usbreset[d]
            if (medium + 0 > 0) print "medium " (medium + 0)
            if (ro + 0 > 0)     print "readonly " (ro + 0)
            if (cursor != "")   print "__cursor__ " cursor
        }
    '
}

if [ "$IS_ROOT" -eq 1 ] && command -v journalctl &>/dev/null; then
    CURSOR=""
    [ -f "$CURSOR_FILE" ] && CURSOR=$(head -n1 "$CURSOR_FILE" 2>/dev/null || true)

    KERNEL_RC=0
    if [ -n "${CURSOR:-}" ]; then
        KERNEL_SUMMARY=$(kernel_scan --after-cursor "$CURSOR"); KERNEL_RC=$?
        # A cursor whose entry has since been vacuumed away is not a monitoring
        # failure, it is an expired bookmark. Fall back to a bootstrap rather
        # than reporting the disks as unmonitored. A timeout is NOT this case —
        # retrying it would just burn the budget twice.
        if [ "$KERNEL_RC" -ne 0 ] && [ "$KERNEL_RC" -ne 124 ]; then
            CURSOR=""
        fi
    fi
    if [ -z "${CURSOR:-}" ]; then
        KERNEL_SUMMARY=$(kernel_scan -n "$BOOTSTRAP_LINES"); KERNEL_RC=$?
        # If even the tail read cannot finish, do NOT just report a failure and
        # try again in 30 minutes — with no cursor to advance, that repeats
        # forever and is the very "scan the whole journal on every cycle"
        # behaviour this design exists to remove. Give up on the backlog, pin
        # the cursor here, and monitor forward from now. Partial monitoring
        # that works beats complete monitoring that never completes; saying so
        # out loud is what keeps it from being a silent all-clear.
        if [ "$KERNEL_RC" -ne 0 ] && pin_cursor_to_now; then
            BOOTSTRAP_GAVE_UP=1
        fi
    fi

    # Check whether the probe actually SUCCEEDED. This was previously set to 1
    # unconditionally, which meant a timed-out journal read was indistinguishable
    # from a healthy disk: empty output, nothing recorded, and a confident
    # "No disk problems detected" on a node that had logged I/O errors.
    #
    # A monitoring tool reporting all-clear because its probe failed is worse
    # than one that crashes — you would believe it. Never infer health from the
    # absence of evidence you failed to collect.
    if [ "$KERNEL_RC" -eq 0 ]; then
        KERNEL_LOG_OK=1
        if [ -n "${KERNEL_SUMMARY:-}" ]; then
            while read -r key count; do
                [ -n "${key:-}" ] || continue
                if [ "$key" = "__cursor__" ]; then NEW_CURSOR="${count:-}"; continue; fi
                DELTA["$key"]="${count:-1}"
                TOTAL["$key"]=$(( ${TOTAL["$key"]:-0} + ${count:-1} ))
            done <<< "$KERNEL_SUMMARY"
        fi

        # Persist the totals BEFORE advancing the cursor. Getting that order
        # wrong would drop a run's findings on the floor every time the state
        # directory was briefly unwritable: the cursor would say those entries
        # were already accounted for, and nothing would ever count them.
        COUNTS_SAVED=0
        if [ -n "${TOTAL[*]:-}" ]; then
            _tmp="${COUNT_FILE}.tmp.$$"
            if : > "$_tmp" 2>/dev/null; then
                for _k in ${TOTAL[@]+"${!TOTAL[@]}"}; do
                    printf '%s=%s\n' "$_k" "${TOTAL[$_k]}" >> "$_tmp"
                done
                mv -f "$_tmp" "$COUNT_FILE" 2>/dev/null && COUNTS_SAVED=1 || rm -f "$_tmp"
            fi
        else
            COUNTS_SAVED=1   # nothing to save is saved
        fi
        if [ -n "${NEW_CURSOR:-}" ] && [ "$COUNTS_SAVED" -eq 1 ]; then
            _tmp="${CURSOR_FILE}.tmp.$$"
            printf '%s\n' "$NEW_CURSOR" > "$_tmp" 2>/dev/null \
                && mv -f "$_tmp" "$CURSOR_FILE" 2>/dev/null || rm -f "$_tmp"
        fi
    else
        # Surfaced as a real issue, not a footnote. The text is fixed, so it
        # alerts once rather than every 30 minutes, and it says plainly that
        # disk monitoring is currently blind rather than that the disks are fine.
        KERNEL_PROBE_ERROR=$([ "$KERNEL_RC" -eq 124 ] \
            && echo "timed out after ${JOURNAL_TIMEOUT}s" \
            || echo "failed (exit $KERNEL_RC)")
    fi
fi

# ── SD / eMMC wear ───────────────────────────────────────────────────────────
# life_time is two hex values, each counting 10% of rated write endurance used
# (0x01 = 0-10%, 0x0B = exceeded). pre_eol_info: 0x01 normal, 0x02 warning (80%
# of reserve blocks consumed), 0x03 urgent.
#
# These are eMMC registers. Plain SD cards usually do not expose them, so their
# absence is normal and never reported as a problem — the kernel I/O error check
# above is what catches a dying SD card.
MMC_FOUND=0
MMC_DETAIL=""
for MMC_DIR in /sys/class/mmc_host/mmc*/mmc*:*/; do
    [ -d "$MMC_DIR" ] || continue
    MMC_NAME=$(basename "$MMC_DIR")
    EOL=$(cat "$MMC_DIR/pre_eol_info" 2>/dev/null || true)
    LIFE=$(cat "$MMC_DIR/life_time" 2>/dev/null || true)
    [ -z "${EOL:-}" ] && [ -z "${LIFE:-}" ] && continue
    MMC_FOUND=1
    MMC_DETAIL="${MMC_DETAIL}  ℹ️ $MMC_NAME: pre_eol=${EOL:-n/a} life_time=${LIFE:-n/a}"$'\n'

    case "${EOL:-}" in
        0x02) record "mmc:eolwarn:$MMC_NAME" ;;
        0x03) record "mmc:eolurgent:$MMC_NAME" ;;
    esac
    if [ -n "${LIFE:-}" ]; then
        # Take the worse of the two estimates.
        WORST=$(echo "$LIFE" | tr ' ' '\n' | sort -r | head -1)
        case "$WORST" in
            0x0A|0x0B) record "mmc:life90:$MMC_NAME" ;;
            0x08|0x09) record "mmc:life70:$MMC_NAME" ;;
        esac
    fi
done

# ── SMART ────────────────────────────────────────────────────────────────────
SMART_AVAILABLE=0
SMART_DETAIL=""
if command -v smartctl &>/dev/null && [ "$IS_ROOT" -eq 1 ]; then
    SMART_AVAILABLE=1
    for DISK in $(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
        case "$DISK" in mmcblk*|zram*|loop*|ram*) continue ;; esac   # no SMART on these
        DEV="/dev/$DISK"

        # -n standby: never spin up a sleeping drive just to ask how it feels.
        SMART_OUT=$(timeout "$SMART_TIMEOUT" smartctl -n standby -H -A "$DEV" 2>/dev/null)
        SMART_RC=$?
        # USB bridges often need the SAT translation layer spelled out.
        if [ "$SMART_RC" -ne 0 ] && echo "${SMART_OUT:-}" | grep -qi "unknown usb bridge\|unsupported"; then
            SMART_OUT=$(timeout "$SMART_TIMEOUT" smartctl -n standby -d sat -H -A "$DEV" 2>/dev/null)
            SMART_RC=$?
        fi

        # smartctl's exit status is a BITMASK, not a code — testing -eq 0 would
        # discard every result that carries any warning bit. Bit 1 (value 2) is
        # "could not open the device", which is also what -n standby returns for
        # a sleeping disk: nothing useful either way, so skip.
        if [ $(( SMART_RC & 2 )) -ne 0 ] || [ -z "${SMART_OUT:-}" ]; then
            SMART_DETAIL="${SMART_DETAIL}  ℹ️ $DEV: no SMART data (asleep, or not SMART-capable over USB)"$'\n'
            continue
        fi

        # Bit 3 (value 8) is the drive's own "I am failing" verdict.
        if [ $(( SMART_RC & 8 )) -ne 0 ]; then
            record "smart:health:$DISK"
        else
            SMART_DETAIL="${SMART_DETAIL}  ✅ $DEV: SMART self-assessment passed"$'\n'
        fi

        smart_attr() { echo "${SMART_OUT:-}" | awk -v id="$1" '$1==id {print $10; exit}'; }
        for PAIR in "realloc:5" "pending:197" "uncorr:198" "crc:199"; do
            NAME="${PAIR%%:*}"; ID="${PAIR#*:}"
            VAL=$(smart_attr "$ID")
            [[ "${VAL:-}" =~ ^[0-9]+$ ]] || continue
            [ "$VAL" -eq 0 ] && continue
            record "smart:$NAME:$DISK" "$VAL"
            SMART_DETAIL="${SMART_DETAIL}  ℹ️ $DEV: raw attribute $ID = $VAL"$'\n'
        done
    done
fi

# ── Report ───────────────────────────────────────────────────────────────────
# Walk the union of live keys and latched keys. A latched-only key is a problem
# whose live count has since reset — a rotated journal or a reboot — and it must
# keep being reported, or the alert would silently clear itself.
ALL_KEYS=$( { printf '%s\n' ${LIVE[@]+"${!LIVE[@]}"}
              printf '%s\n' ${TOTAL[@]+"${!TOTAL[@]}"}
              [ -f "$STATE_FILE" ] && cut -d= -f1 "$STATE_FILE" 2>/dev/null
            } | grep -v '^$' | LC_ALL=C sort -u )

say "🩺 Disk Health"
say "━━━━━━━━━━━━━━━━━━"

PROBLEMS=0

# Blindness is reported before findings, because it changes what the findings
# mean: "no problems detected" is only reassuring if the detector ran.
if [ -n "${BOOTSTRAP_GAVE_UP:-}" ]; then
    PROBLEMS=$((PROBLEMS + 1))
    LINE="⚠️ Could not read existing kernel log history (the journal is too large to scan in ${JOURNAL_TIMEOUT}s). Disk monitoring is live from now on, but anything logged before this moment was not counted."
    if [ "$MODE" = "issues" ]; then echo "$LINE"; else say "  $LINE"; fi
elif [ -n "${KERNEL_PROBE_ERROR:-}" ]; then
    PROBLEMS=$((PROBLEMS + 1))
    LINE="⚠️ Disk monitoring is degraded — the kernel log probe ${KERNEL_PROBE_ERROR}. Disk errors would not be seen."
    if [ "$MODE" = "issues" ]; then echo "$LINE"; else say "  $LINE"; fi
fi

if [ -n "$ALL_KEYS" ]; then
    while read -r KEY; do
        [ -n "$KEY" ] || continue
        # Two kinds of number live in this loop and they must not be confused.
        # SMART attributes and eMMC registers are GAUGES: the drive already
        # reports a lifetime total, so the value read this run is the whole
        # story and adding it to a previous reading would invent damage. Kernel
        # log lines are EVENTS, counted once each as they are seen, so their
        # meaning is the running total. LIVE holds the former, TOTAL the latter,
        # and the two key namespaces never overlap.
        GAUGE="${LIVE[$KEY]:-0}"
        COUNT="${TOTAL[$KEY]:-0}"
        [ "$GAUGE" -gt 0 ] && COUNT="$GAUGE"
        B=$(latch "$KEY" "$(bucket "$COUNT")")
        [ "$B" -lt "$(threshold "$KEY")" ] && continue
        PROBLEMS=$((PROBLEMS + 1))
        LINE=$(describe "$KEY" "$B")
        if [ "$MODE" = "issues" ]; then
            echo "$LINE"
        else
            # Exact numbers appear only here: the report is never hashed, so
            # precision is useful rather than a source of false alerts.
            NEW="${DELTA[$KEY]:-0}"
            if [ "$NEW" -gt 0 ]; then
                say "  $LINE (total $COUNT, $NEW new since the last check)"
            elif [ "$COUNT" -gt 0 ]; then
                say "  $LINE (total $COUNT, nothing new since the last check)"
            else
                say "  $LINE (latched by an earlier run)"
            fi
        fi
    done <<< "$ALL_KEYS"
fi

if [ "$MODE" = "report" ]; then
    if [ "$PROBLEMS" -eq 0 ]; then
        if [ "$KERNEL_LOG_OK" -eq 1 ]; then
            say "  ✅ No disk problems detected"
        else
            say "  ⚠️ No problems found, but the kernel log was not read — this is not an all-clear"
        fi
    fi
    say ""
    if [ "$IS_ROOT" -eq 0 ]; then
        say "  ⚠️ Not running as root — SMART and kernel-log checks were skipped."
        say "     The bot invokes this via sudo -n. If that is failing, the sudoers"
        say "     file may be missing: sudo bash reinstall-services.sh"
    else
        # Suppressed when we gave up on the backlog on purpose: that case has
        # already said its piece above, and "could not read the kernel journal"
        # would contradict the "monitoring is live from now on" it just printed.
        [ "$KERNEL_LOG_OK" -eq 1 ] || [ -n "${BOOTSTRAP_GAVE_UP:-}" ] \
            || say "  ⚠️ Could not read the kernel journal"
        if [ "$SMART_AVAILABLE" -eq 0 ]; then
            # Never an --issues line: a missing optional tool is not a failing
            # disk, and it would latch as a permanent alert. Guardian installs
            # no packages on your node.
            say "  ℹ️ smartctl not installed — SMART checks skipped."
            say "     To enable: sudo apt-get install smartmontools"
        else
            [ -n "$SMART_DETAIL" ] && printf '%s' "$SMART_DETAIL"
        fi
        if [ "$MMC_FOUND" -eq 1 ]; then
            printf '%s' "$MMC_DETAIL"
        else
            say "  ℹ️ No eMMC wear data (normal for SD cards)"
        fi
    fi
    say ""
    say "  Latched problems persist until you replace the hardware and run:"
    say "    sudo $SCRIPT_DIR/disk_health.sh --reset"
    say "  (which also restarts kernel-log counting from that moment)"
fi
exit 0

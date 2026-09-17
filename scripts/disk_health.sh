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
DMESG_FILE="$STATE_DIR/disk-health.dmesg"
HISTORY_FILE="$STATE_DIR/disk-health.history"

# shellcheck source=/dev/null
[ -f "$CONFIG" ] && source "$CONFIG"

MODE="report"
case "${1:-}" in
    --issues)          MODE="issues" ;;
    --reset)           MODE="reset" ;;
    --import-history)  MODE="import" ;;
    "")                ;;
    *)        echo "Usage: $0 [--issues|--reset|--import-history]" >&2; exit 2 ;;
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
DMESG_TIMEOUT=15
# The one-off attempt at journald history gets a SHORT budget, because on a node
# whose journal is slow it will never succeed and must not be paid for twice.
# The explicit --import-history gets a long one, because then a human asked.
JOURNAL_BOOTSTRAP_TIMEOUT=20
JOURNAL_IMPORT_TIMEOUT=600
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
# Clearing the latch is not enough. If the watermark were simply deleted, the
# next run would count everything still sitting in the ring buffer and re-latch
# the very errors you just replaced the hardware to get rid of. So --reset PINS
# the watermark to now: counting restarts from this moment, which is what "I
# have swapped the card" actually means.
#
# This reads the ring buffer, never journald. --reset must work on a node whose
# journal is unusable — that is precisely the node you are most likely to be
# replacing a card on.
dmesg_max_timestamp() {
    timeout "$DMESG_TIMEOUT" dmesg -k 2>/dev/null \
        | awk 'match($0, /^\[[ ]*[0-9.]+\]/) { t = substr($0, 2, RLENGTH - 2) + 0; if (t > m) m = t }
               END { printf "%.6f\n", m + 0 }'
}

pin_dmesg_watermark() {
    local wm
    wm=$(dmesg_max_timestamp)
    [[ "${wm:-}" =~ ^[0-9.]+$ ]] || return 1
    { echo "bootid=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
      echo "watermark=$wm"; } > "$DMESG_FILE" 2>/dev/null || return 1
    return 0
}

if [ "$MODE" = "reset" ]; then
    rm -f "$STATE_FILE" "$COUNT_FILE" "$DMESG_FILE"
    if pin_dmesg_watermark; then
        echo "✅ Disk health latches cleared. Kernel-log counting restarts from now."
    else
        echo "✅ Disk health latches cleared."
        echo "ℹ️ Could not read the kernel ring buffer (need root?)."
        echo "   The next run will count what is already in it, which may re-latch old errors."
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
# Source of truth: the kernel ring buffer, via dmesg. NOT journald.
#
# That is a correctness decision, not a performance one. journald's logs live on
# the disk being monitored, so a failing disk makes the monitor slow — the tool
# degrades exactly when the thing it watches gets worse, which is the one moment
# it has to work. Measured on the live node, with 1.8 GB of journal on an SD card
# throwing I/O errors:
#
#   journalctl -k --since "7 days ago"    75 s   (--grep does not help: it
#   journalctl -k --grep ... --since ...  75 s    filters output, not reads)
#   journalctl -k -n 1                   >60 s   ← even asking where it ENDS
#
# That last one is why the previous design failed in the field: its escape hatch
# for a slow journal was itself a journald call, so a run cost two full timeouts
# and never converged. Any fallback that lands back on the broken dependency is
# not a fallback.
#
# The ring buffer is in RAM. It costs nothing, it cannot be slowed down by a
# dying card, and on an idle node it holds far more than the 30 minutes between
# checks. What it does not hold is history from before the current boot — and
# that is what .state/ is for: the latch persists across reboots even though the
# buffer does not, so what we observe once we remember for good.
KERNEL_LOG_OK=0
declare -A DELTA=()

# Counts accumulated by every previous run. These are what get bucketed; one
# read only ever sees what is new, which would never reach a meaningful bucket
# on its own.
declare -A TOTAL=()
if [ -f "$COUNT_FILE" ]; then
    while IFS='=' read -r _k _v; do
        [ -n "${_k:-}" ] || continue
        [[ "${_v:-}" =~ ^[0-9]+$ ]] || continue
        TOTAL["$_k"]="$_v"
    done < "$COUNT_FILE"
fi

# One counting pass, shared by both sources. `wm` is a monotonic-clock
# watermark: lines at or below it were counted by an earlier run. dmesg stamps
# every line "[  123.456789]"; journalctl does not, so for a history import the
# timestamp rule simply never fires and everything is counted once.
count_stream() {
    awk -v wm="${1:--1}" '
        {
            if (match($0, /^\[[ ]*[0-9.]+\]/)) {
                t = substr($0, 2, RLENGTH - 2) + 0
                if (t > maxts) maxts = t
                if (t <= wm) next
            }
        }
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
        # never by splitting on ":" — the timestamp is full of colons.
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
            if (maxts + 0 > 0)  printf "__watermark__ %.6f\n", maxts
        }
    '
}

absorb() {   # stdin: "key count" lines → DELTA + TOTAL, and the new watermark
    local key count
    while read -r key count; do
        [ -n "${key:-}" ] || continue
        if [ "$key" = "__watermark__" ]; then NEW_WATERMARK="${count:-}"; continue; fi
        DELTA["$key"]=$(( ${DELTA["$key"]:-0} + ${count:-1} ))
        TOTAL["$key"]=$(( ${TOTAL["$key"]:-0} + ${count:-1} ))
    done
}

persist_counts() {
    local tmp="${COUNT_FILE}.tmp.$$" k
    [ -n "${TOTAL[*]:-}" ] || return 0
    : > "$tmp" 2>/dev/null || return 1
    for k in ${TOTAL[@]+"${!TOTAL[@]}"}; do
        printf '%s=%s\n' "$k" "${TOTAL[$k]}" >> "$tmp"
    done
    mv -f "$tmp" "$COUNT_FILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

NEW_WATERMARK=""

# ── One-off journald history import ──────────────────────────────────────────
# Worth trying once: a card can already be failing when Guardian is installed,
# and that evidence lives in journald across previous boots. Worth trying only
# ONCE, and on a short leash, because on a node where it is slow it will be slow
# forever. The outcome is recorded either way and never retried automatically —
# the failure mode being avoided is a 30-minute timer that spends two minutes
# every cycle re-discovering that the journal is unreadable.
# $1 = time budget, $2 = line limit ("all" reads the whole journal).
#
# The automatic attempt is bounded on both axes because it must not cost a
# slow node anything twice. An explicit --import-history is not: a human asked
# for it, granted it ten minutes, and wants everything that is there. Reading
# only the tail in that case quietly answers a narrower question than the one
# being asked, and reports it as if it were the whole answer.
import_history() {
    local budget="$1" limit="${2:-$BOOTSTRAP_LINES}" raw rc saved="${NEW_WATERMARK:-}"
    local -a args=(-k --no-pager)
    [ "$limit" = "all" ] || args+=(-n "$limit")
    raw=$(timeout "$budget" journalctl "${args[@]}" 2>/dev/null | count_stream -1)
    rc=$?
    if [ "$rc" -ne 0 ]; then return "$rc"; fi
    absorb <<< "${raw:-}"
    # journald lines carry no ring-buffer clock, so this import must not disturb
    # the watermark the dmesg read just established. Restoring it explicitly
    # rather than trusting that journalctl never emits a "[123.456]" prefix:
    # getting that wrong silently makes the ring buffer re-count itself forever,
    # which is how this was caught.
    NEW_WATERMARK="$saved"
    return 0
}

if [ "$MODE" = "import" ]; then
    if [ "$IS_ROOT" -eq 0 ]; then
        echo "⚠️ --import-history needs root: sudo $0 --import-history" >&2; exit 1
    fi
    echo "Reading kernel log history from journald (up to ${JOURNAL_IMPORT_TIMEOUT}s)…"
    if import_history "$JOURNAL_IMPORT_TIMEOUT" all; then
        persist_counts && echo "imported" > "$HISTORY_FILE" 2>/dev/null
        echo "✅ History imported. Run $0 to see the result."
    else
        echo "skipped:timeout" > "$HISTORY_FILE" 2>/dev/null
        echo "❌ journald did not answer within ${JOURNAL_IMPORT_TIMEOUT}s."
        echo "   Your journal is ${JOURNAL_IMPORT_TIMEOUT}s-unreadable, which on a node with"
        echo "   disk errors is itself a symptom. Consider: sudo journalctl --vacuum-size=200M"
    fi
    exit 0
fi

if [ "$IS_ROOT" -eq 1 ] && command -v dmesg &>/dev/null; then
    # Same boot → resume from the watermark. Different boot (or none recorded) →
    # the buffer was rebuilt from scratch, so everything in it is new.
    WATERMARK=-1
    BOOT_NOW=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
    if [ -f "$DMESG_FILE" ]; then
        BOOT_WAS=$(awk -F= '$1=="bootid"{print $2; exit}' "$DMESG_FILE" 2>/dev/null)
        if [ "${BOOT_WAS:-}" = "$BOOT_NOW" ]; then
            _w=$(awk -F= '$1=="watermark"{print $2; exit}' "$DMESG_FILE" 2>/dev/null)
            [[ "${_w:-}" =~ ^[0-9.]+$ ]] && WATERMARK="$_w"
        fi
    fi

    DMESG_OUT=$(timeout "$DMESG_TIMEOUT" dmesg -k 2>/dev/null | count_stream "$WATERMARK")
    DMESG_RC=$?
    if [ "$DMESG_RC" -eq 0 ]; then
        KERNEL_LOG_OK=1
        absorb <<< "${DMESG_OUT:-}"

        # On the very first run, also try journald once for pre-install history.
        if [ ! -f "$HISTORY_FILE" ] && command -v journalctl &>/dev/null; then
            if import_history "$JOURNAL_BOOTSTRAP_TIMEOUT"; then
                echo "imported" > "$HISTORY_FILE" 2>/dev/null
            else
                echo "skipped:timeout" > "$HISTORY_FILE" 2>/dev/null
                HISTORY_SKIPPED=1
            fi
        fi
        [ "$(cat "$HISTORY_FILE" 2>/dev/null)" = "skipped:timeout" ] && HISTORY_SKIPPED=1

        # Counts first, watermark second. The other order drops a run's findings
        # whenever the state directory is briefly unwritable: the watermark would
        # say those lines were already accounted for, and nothing would count them.
        if persist_counts && [[ "${NEW_WATERMARK:-}" =~ ^[0-9.]+$ ]]; then
            { echo "bootid=$BOOT_NOW"; echo "watermark=$NEW_WATERMARK"; } \
                > "$DMESG_FILE" 2>/dev/null || true
        fi
    else
        # Never inferred as health. A monitoring tool reporting all-clear because
        # its probe failed is worse than one that crashes — you would believe it.
        KERNEL_PROBE_ERROR=$([ "$DMESG_RC" -eq 124 ] \
            && echo "timed out after ${DMESG_TIMEOUT}s" \
            || echo "failed (exit $DMESG_RC)")
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
if [ -n "${KERNEL_PROBE_ERROR:-}" ]; then
    PROBLEMS=$((PROBLEMS + 1))
    LINE="⚠️ Disk monitoring is degraded — the kernel ring buffer ${KERNEL_PROBE_ERROR}. Disk errors would not be seen."
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
        [ "$KERNEL_LOG_OK" -eq 1 ] || say "  ⚠️ Could not read the kernel ring buffer"
        # Deliberately NOT an --issues line. Live monitoring is working; only
        # pre-install history is missing. Alerting on it would put a permanent
        # "something is wrong" in Telegram for a gap that cannot be closed by
        # anything happening now.
        if [ -n "${HISTORY_SKIPPED:-}" ]; then
            say "  ℹ️ Kernel log history from before this boot was not imported —"
            say "     journald did not answer in ${JOURNAL_BOOTSTRAP_TIMEOUT}s. Monitoring from"
            say "     the ring buffer is unaffected. To retry the import:"
            say "       sudo $SCRIPT_DIR/disk_health.sh --import-history"
        fi
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

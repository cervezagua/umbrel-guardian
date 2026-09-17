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

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$(dirname "$SCRIPT_DIR")/config.env"
STATE_DIR="$(dirname "$SCRIPT_DIR")/.state"
STATE_FILE="$STATE_DIR/disk-health.state"

# shellcheck source=/dev/null
[ -f "$CONFIG" ] && source "$CONFIG"

MODE="report"
case "${1:-}" in
    --issues) MODE="issues" ;;
    --reset)  rm -f "$STATE_FILE" && echo "✅ Disk health latches cleared."; exit 0 ;;
    "")       ;;
    *)        echo "Usage: $0 [--issues|--reset]" >&2; exit 2 ;;
esac

# Sub-probe timeouts. A wedged drive must not hold the health timer open: the
# unit allows 300s total and the bot waits 120s, so every external call is
# individually bounded rather than trusting the whole script to finish.
SMART_TIMEOUT=20
# 60s. Reading seven days of kernel journal is not a quick operation on a Pi,
# and under the bot's CPUQuota=20% it is roughly ten times slower again. A 10s
# budget here silently produced "no errors found" on a node whose journal
# contained four — see the failure handling below, which is the part that made
# that silent rather than obvious.
JOURNAL_TIMEOUT=60

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
# Piped straight into awk. On a node throwing repeated I/O errors the journal is
# large, and slurping it into a shell variable would balloon memory on a Pi for
# no reason.
# Window: recent history, NOT the current boot. `-b` looked tidy and was wrong —
# a node that logged I/O errors yesterday and has since rebooted reports a clean
# current boot while the card is exactly as damaged as it was. Time-bounding
# keeps the read cheap without pretending a power cycle fixed the hardware.
KERNEL_WINDOW="7 days ago"
KERNEL_LOG_OK=0
if [ "$IS_ROOT" -eq 1 ] && command -v journalctl &>/dev/null; then
    KERNEL_SUMMARY=$(timeout "$JOURNAL_TIMEOUT" journalctl -k --since "$KERNEL_WINDOW" --no-pager 2>/dev/null | awk '
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
        }
    ')
    # Check whether the probe actually SUCCEEDED. This was previously set to 1
    # unconditionally, which meant a timed-out journal read was indistinguishable
    # from a healthy disk: empty output, nothing recorded, and a confident
    # "No disk problems detected" on a node that had logged I/O errors.
    #
    # A monitoring tool reporting all-clear because its probe failed is worse
    # than one that crashes — you would believe it. Never infer health from the
    # absence of evidence you failed to collect.
    KERNEL_RC=$?
    if [ "$KERNEL_RC" -eq 0 ]; then
        KERNEL_LOG_OK=1
        if [ -n "${KERNEL_SUMMARY:-}" ]; then
            while read -r key count; do
                [ -n "${key:-}" ] && record "$key" "${count:-1}"
            done <<< "$KERNEL_SUMMARY"
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
              [ -f "$STATE_FILE" ] && cut -d= -f1 "$STATE_FILE" 2>/dev/null
            } | grep -v '^$' | sort -u )

say "🩺 Disk Health"
say "━━━━━━━━━━━━━━━━━━"

PROBLEMS=0

# Blindness is reported before findings, because it changes what the findings
# mean: "no problems detected" is only reassuring if the detector ran.
if [ -n "${KERNEL_PROBE_ERROR:-}" ]; then
    PROBLEMS=$((PROBLEMS + 1))
    LINE="⚠️ Disk monitoring is degraded — the kernel log probe ${KERNEL_PROBE_ERROR}. Disk errors would not be seen."
    if [ "$MODE" = "issues" ]; then echo "$LINE"; else say "  $LINE"; fi
fi

if [ -n "$ALL_KEYS" ]; then
    while read -r KEY; do
        [ -n "$KEY" ] || continue
        LIVE_COUNT="${LIVE[$KEY]:-0}"
        B=$(latch "$KEY" "$(bucket "$LIVE_COUNT")")
        [ "$B" -lt "$(threshold "$KEY")" ] && continue
        PROBLEMS=$((PROBLEMS + 1))
        LINE=$(describe "$KEY" "$B")
        if [ "$MODE" = "issues" ]; then
            echo "$LINE"
        else
            # Live count shown only here: the report is never hashed, so an
            # exact number is useful rather than a source of false alerts.
            if [ "$LIVE_COUNT" -gt 0 ]; then
                say "  $LINE (now: $LIVE_COUNT)"
            else
                say "  $LINE (latched; not seen since last boot)"
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
        [ "$KERNEL_LOG_OK" -eq 1 ] || say "  ⚠️ Could not read the kernel journal"
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
    say "  Latched problems persist until: sudo $SCRIPT_DIR/disk_health.sh --reset"
fi
exit 0

#!/usr/bin/env bash
# Proactive health check: runs on a timer and sends Telegram alerts
# if disk usage exceeds threshold or any app is in an unknown/failed state.
# (Healthy = ready or running; transient and stopped states are ignored.)
#
# Deduplication: an alert is sent when the issue set *changes*, and then once
# every ALERT_REPEAT_HOURS (default 24) while it stays the same, so a persistent
# problem neither spams the chat nor drops off it entirely.
#
# Pass --force to always send the current status (used by /health command).
#
# Exit code: 1 if alerts were sent, 0 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
if [ -r "$SCRIPT_DIR/lib-umbreld.sh" ]; then
    source "$SCRIPT_DIR/lib-umbreld.sh"
fi
CONFIG="$(dirname "$SCRIPT_DIR")/config.env"
SEND="$SCRIPT_DIR/telegram_send.sh"

source "$CONFIG"

THRESHOLD="${DISK_THRESHOLD:-90}"
STATE_DIR="$(dirname "$SCRIPT_DIR")/.state"
# The dedup fingerprint. It lived at /run/umbrel-guardian-health.last and that
# was wrong twice over.
#
# /run is tmpfs, so the hash died at every reboot and every outstanding issue
# was re-announced on the next tick — the exact failure reinstall-services.sh
# already warns about where it creates this directory. Worse, /run is
# root-owned and this script runs as the umbrel user with no RuntimeDirectory=,
# so the write never landed at all: the hash read back empty on every single
# run and deduplication has never once worked. It went unnoticed for as long as
# it did because an empty issue list short-circuits the send, so nothing
# repeated until the first problem that never clears — a failing SD card,
# reported hourly, forever.
#
# Two lines of defence now: the file lives beside every other latch, in a
# directory this user owns, and save_state() below says so in the journal if it
# still cannot write. A suppression mechanism that fails open in silence is
# indistinguishable from one that works.
STATE_FILE="$STATE_DIR/health.last"
HOST="$(hostname)"

# How long an unchanged, still-present problem stays quiet before one reminder.
# Pure change-detection would mean a real failure alerts once and is never
# mentioned again; hourly repetition means you stop reading the alerts. A daily
# nudge is the compromise. 0 disables reminders entirely.
ALERT_REPEAT_HOURS="${ALERT_REPEAT_HOURS:-24}"
[[ "$ALERT_REPEAT_HOURS" =~ ^[0-9]+$ ]] || ALERT_REPEAT_HOURS=24

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# Collect issues into an array (not sent immediately — deduplicated first)
ISSUES=()

# ── Disk check ─────────────────────────────────────────────────────────────
# Umbrel OS 1.5 on Pi uses /mnt/root/mnt/data as the actual data mount.
# Fall back to /mnt/data and then / for other setups.
if df -hP /mnt/root/mnt/data &>/dev/null; then
    DISK_USE=$(df -hP /mnt/root/mnt/data | awk 'NR==2 {print $5}' | tr -d '%')
    DISK_LABEL="/mnt/root/mnt/data"
elif df -hP /mnt/data &>/dev/null; then
    DISK_USE=$(df -hP /mnt/data | awk 'NR==2 {print $5}' | tr -d '%')
    DISK_LABEL="/mnt/data"
else
    DISK_USE=$(df -hP / | awk 'NR==2 {print $5}' | tr -d '%')
    DISK_LABEL="/"
fi

if [ "${DISK_USE:-0}" -gt "$THRESHOLD" ]; then
    # Report a 5% band rather than the live figure. The fingerprint below covers
    # this string, so "at 91%" → "at 92%" reads as a brand new problem and
    # re-alerts every 30 minutes for as long as the disk stays full — which is
    # precisely when you least want to be trained to ignore the alert.
    DISK_BAND=$(( DISK_USE / 5 * 5 ))
    ISSUES+=("⚠️ Disk ${DISK_LABEL} is over ${DISK_BAND}% full (threshold: ${THRESHOLD}%)")
fi

# ── App health check ────────────────────────────────────────────────────────
# Umbrel app state taxonomy (1.7.x):
#   ready, running                                           → healthy
#   starting, installing, updating, restarting,              → transient
#     stopping, uninstalling                                   (ignore — fluctuates)
#   stopped                                                  → intentional off (user choice)
#   unknown                                                  → real problem
# We only alert on "unknown" so transient states don't flap and stopped
# apps (which the user deliberately turned off) don't trigger alerts.
#
# ...with one exception, because "unknown" is also what a healthy app looks like
# before umbreld has got to it. umbreld keeps app state in memory only and
# initialises every app to "unknown" at startup, so for a while after a boot or
# an OS update the list reads unknown for apps that are simply not up yet. A
# live node upgrading 1.7.4 → 2.0.0 was told "❌ cloudflared is unknown" in the
# same minute as the update notice, about an app that was merely still starting.
#
# So inside a grace window after boot, "unknown" is treated as not-yet-known
# rather than broken. This defers the judgement, it does not suppress it: an app
# still unknown after the window is reported on the next tick. Nothing else is
# affected — a genuinely bad state that is not "unknown" still reports at once.
APP_GRACE_SECONDS="${GUARDIAN_APP_GRACE_SECONDS:-900}"
# Never defer for longer than this in total. umbreld has crash-looped on this
# hardware before ("restart counter is at 31"), and a window keyed to its start
# time would be reset by every loop — leaving the app check silent forever
# exactly when apps are most likely to be broken. Deferring is only ever worth
# it if it is bounded.
APP_GRACE_MAX="${GUARDIAN_APP_GRACE_MAX:-$(( APP_GRACE_SECONDS * 2 ))}"

UPTIME_SECONDS=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)
# An unreadable /proc/uptime must not silently enable the grace window forever;
# treat it as "long since booted" so the check keeps its teeth.
[ -n "${UPTIME_SECONDS:-}" ] || UPTIME_SECONDS=999999

# What resets app state to "unknown" is umbreld starting, NOT the machine
# booting. Keying this to uptime was wrong: a `systemctl restart umbrel` on a
# node that had been up for hours wiped umbreld's in-memory state while uptime
# stayed large, so the window never opened and a still-starting app was reported
# as broken. Guardian's own /restart_umbrel command triggers exactly that.
#
# ActiveEnterTimestampMonotonic is microseconds since boot, on the same clock as
# /proc/uptime, so the subtraction needs no wall-clock and survives NTP steps.
UMBRELD_AGE="$UPTIME_SECONDS"
SVC_MONO=$(systemctl show umbrel.service -p ActiveEnterTimestampMonotonic 2>/dev/null | cut -d= -f2)
if [[ "${SVC_MONO:-}" =~ ^[0-9]+$ ]] && [ "$SVC_MONO" -gt 0 ]; then
    _svc_age=$(( UPTIME_SECONDS - SVC_MONO / 1000000 ))
    # A negative age means the two clocks disagree; rather than trust it, fall
    # back to uptime, which is the stricter of the two.
    [ "$_svc_age" -ge 0 ] && UMBRELD_AGE="$_svc_age"
fi

if [ "$UMBRELD_AGE" -lt "$APP_GRACE_SECONDS" ]; then APP_GRACE=1; else APP_GRACE=0; fi

# Bound the total deferral, per APP_GRACE_MAX above.
#
# Unlike STATE_FILE (which lives in /run and is therefore always writable), this
# is under the install directory, and nothing in this script created it —
# reinstall-services.sh does. On a node where .state is missing, the redirection
# below fails and the shell reports it before the command's own 2>/dev/null can
# suppress anything, so the health timer's journal fills with "No such file or
# directory" every run. Create it, and brace-group the write so a read-only
# filesystem degrades quietly instead.
GRACE_SINCE_FILE="$STATE_DIR/app-grace-since"
mkdir -p "$STATE_DIR" 2>/dev/null || true
if [ "$APP_GRACE" -eq 1 ]; then
    NOW_EPOCH=$(date +%s)
    GRACE_SINCE=$(cat "$GRACE_SINCE_FILE" 2>/dev/null || true)
    if ! [[ "${GRACE_SINCE:-}" =~ ^[0-9]+$ ]]; then
        GRACE_SINCE="$NOW_EPOCH"
        { printf '%s\n' "$GRACE_SINCE" > "$GRACE_SINCE_FILE"; } 2>/dev/null || true
    fi
    if [ "$(( NOW_EPOCH - GRACE_SINCE ))" -ge "$APP_GRACE_MAX" ]; then APP_GRACE=0; fi
else
    # Out of the window: forget the start, so the next restart gets a full one.
    rm -f "$GRACE_SINCE_FILE" 2>/dev/null || true
fi

if command -v umbreld &>/dev/null; then
    # The app list reaches Python through the ENVIRONMENT, not a pipe.
    #
    # `python3 -` reads its program from stdin, so the heredoc below claims
    # stdin — silently overriding the pipe. sys.stdin.read() returned '' on
    # every single run, which means this check has never once reported an
    # unhealthy app since it was written. shellcheck SC2259 catches it.
    #
    # The heredoc stays (this script needs both quote styles internally, so
    # collapsing it into python3 -c would be a quoting minefield); only the data
    # path moves.
    APP_RAW=$(guardian_umbreld "$GUARDIAN_UMBRELD_TIMEOUT" apps.list.query 2>&1)
    APP_ISSUES=$(APP_RAW="$APP_RAW" APP_GRACE="$APP_GRACE" python3 - <<'PYEOF'
import os, json, sys

raw = os.environ.get("APP_RAW", "")
GRACE = os.environ.get("APP_GRACE") == "1"
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

HEALTHY    = {"ready", "running"}
TRANSIENT  = {"starting", "installing", "updating", "restarting", "stopping", "uninstalling"}
INTENTIONAL = {"stopped"}

for app in apps:
    state = app.get("state", "unknown")
    if state in HEALTHY or state in TRANSIENT or state in INTENTIONAL:
        continue
    # Shortly after boot this is "umbreld has not resolved it yet", not "broken".
    if state == "unknown" and GRACE:
        continue
    print(f"❌ {app['id']} is {state}")
PYEOF
    ) || true

    # Add each unhealthy app line to ISSUES array
    while IFS= read -r line; do
        [ -n "$line" ] && ISSUES+=("$line")
    done <<< "${APP_ISSUES:-}"
fi

# ── Disk health ──────────────────────────────────────────────────────────────
# Runs as root via sudo -n: smartctl needs the raw device and the kernel journal
# is not world-readable. Silent when that is unavailable — /etc/sudoers.d/ is
# wiped on every boot and restamped by the pre-start hook, so there is a window
# where this legitimately cannot run, and alerting on it would fire a spurious
# "monitoring is broken" after every reboot.
#
# disk_health.sh emits deterministic, bucketed lines precisely so they can join
# ISSUES without breaking the fingerprint below.
DISK_HEALTH="$SCRIPT_DIR/disk_health.sh"
if [ -x "$DISK_HEALTH" ]; then
    DISK_ISSUES=$(sudo -n "$DISK_HEALTH" --issues 2>/dev/null || true)
    while IFS= read -r line; do
        [ -n "$line" ] && ISSUES+=("$line")
    done <<< "${DISK_ISSUES:-}"
fi

# ── Unclean shutdown ─────────────────────────────────────────────────────────
# Written by the pre-start hook when the previous boot's shutdown marker was
# still present, meaning the machine lost power rather than shutting down.
#
# Worth interrupting someone for, because it is the most likely cause of the
# config corruption the integrity check below hunts for, it leaves no kernel
# error behind, and unlike failing hardware it is completely preventable. The
# file carries the boot id it was recorded for, so the warning describes the
# boot you are actually in and goes quiet after the next clean shutdown rather
# than accusing you indefinitely.
UNCLEAN_FILE="$STATE_DIR/unclean-shutdown"
if [ -f "$UNCLEAN_FILE" ]; then
    RECORDED_BOOT=$(head -n1 "$UNCLEAN_FILE" 2>/dev/null || true)
    CURRENT_BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
    if [ -n "${RECORDED_BOOT:-}" ] && [ "$RECORDED_BOOT" = "$CURRENT_BOOT" ]; then
        ISSUES+=("⚠️ The last shutdown was unclean (power loss or held button). This is the most common cause of corrupted config files — always use 'sudo shutdown -h now' or the dashboard.")
    fi
fi

# ── Backup integrity ─────────────────────────────────────────────────────────
# Corruption is silent. It produces no kernel error, no failed backup and no
# failed comparison — the disk writes garbage, rsync copies the garbage, and
# every check that only compares the two reports agreement. Nothing above this
# line would notice, which is why a node ran for days with five destroyed files
# in both its data directory and its backup while every check said fine.
#
# Same contract as disk_health.sh: deterministic lines, so identical findings
# produce an identical fingerprint and alert exactly once.
VERIFY_BACKUP="$SCRIPT_DIR/verify_backup.sh"
if [ -x "$VERIFY_BACKUP" ]; then
    INTEGRITY_ISSUES=$(sudo -n "$VERIFY_BACKUP" --integrity 2>/dev/null || true)
    while IFS= read -r line; do
        [ -n "$line" ] && ISSUES+=("$line")
    done <<< "${INTEGRITY_ISSUES:-}"
fi

# ── Deduplication ────────────────────────────────────────────────────────────
# Build a deterministic fingerprint of the current issues.
# Only send notifications when this fingerprint differs from last run.
ISSUE_COUNT="${#ISSUES[@]}"
# LC_ALL=C: collation is locale-dependent, and the sorted text feeds the hash.
# Under en_US.UTF-8 glibc orders "a-item A-item b-item _item" where C gives
# "A-item _item a-item b-item" — same issues, different fingerprint, spurious
# re-alert. Pinning the collation makes the fingerprint depend only on content.
STATE_TEXT="$(printf "%s\n" "${ISSUES[@]}" 2>/dev/null | LC_ALL=C sort)"
CURRENT_HASH="$(printf "%s" "$STATE_TEXT" | sha256sum | awk '{print $1}')"

# "<hash> <epoch-of-last-send>". One file, not two: the epoch is what makes the
# reminder possible, and keeping it here means testing the reminder is a matter
# of rewriting this number rather than faking a clock.
LAST_HASH=""
LAST_SENT=0
# Brace-grouped: a failed input redirection is reported by the shell BEFORE the
# command's own 2>/dev/null can suppress it, so on a node without the file yet
# the bare form fills the journal with "No such file or directory" every run.
{ read -r LAST_HASH LAST_SENT < "$STATE_FILE"; } 2>/dev/null || true
[[ "${LAST_SENT:-}" =~ ^[0-9]+$ ]] || LAST_SENT=0
NOW_EPOCH="$(date +%s)"

# Temp file plus mv, so an interrupted write cannot leave a truncated hash that
# matches nothing and re-alerts forever.
#
# The failure path is the point. This write failing silently is the whole bug
# being fixed here, so if it fails again it says so somewhere a person can find
# it: stderr reaches the journal via StandardError=journal in the unit.
save_state() {
    local tmp="${STATE_FILE}.tmp.$$"
    if { printf '%s %s\n' "$1" "$2" > "$tmp"; } 2>/dev/null &&
       mv -f "$tmp" "$STATE_FILE" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null
    echo "guardian: cannot write $STATE_FILE — alert deduplication is disabled," \
         "so every run with an outstanding issue will re-alert. Check that" \
         "$STATE_DIR exists and is writable by $(id -un)." >&2
    return 1
}

send_ok() {
    "$SEND" "✅ Health check OK on ${HOST}"
}

send_issues() {
    local msg="🚨 Health issues on ${HOST}:"
    for issue in "${ISSUES[@]}"; do
        msg="$msg
- $issue"
    done
    "$SEND" "$msg"
}

SENT=0

if [[ "$FORCE" -eq 1 ]]; then
    # Manual /health — always respond with current state.
    #
    # Deliberately does not touch the state file. Asking "how are things?" must
    # not reset the reminder clock, or checking in often enough would silence
    # the daily nudge about a problem you have not fixed.
    if [ "$ISSUE_COUNT" -eq 0 ]; then
        send_ok
    else
        send_issues
    fi
    SENT=1
elif [[ "$CURRENT_HASH" != "$LAST_HASH" ]]; then
    # The issue set changed — a new problem, a resolved one, or an escalation.
    # Always worth saying at once, which is why disk_health.sh buckets its
    # counts: a number that drifts would land here on every run.
    if [ "$ISSUE_COUNT" -gt 0 ]; then
        send_issues
        SENT=1
    fi
    # Save whether or not anything was sent, so recovery is detected too. The
    # epoch is 0 for an all-clear: nothing was announced, so there is nothing
    # to remind anyone about.
    save_state "$CURRENT_HASH" "$( [ "$SENT" -eq 1 ] && echo "$NOW_EPOCH" || echo 0 )"
elif [ "$ISSUE_COUNT" -gt 0 ] && [ "$ALERT_REPEAT_HOURS" -gt 0 ] &&
     [ "$(( NOW_EPOCH - LAST_SENT ))" -ge "$(( ALERT_REPEAT_HOURS * 3600 ))" ]; then
    # Unchanged and still broken. One reminder, then quiet again.
    send_issues
    SENT=1
    save_state "$CURRENT_HASH" "$NOW_EPOCH"
fi

# ── Side channels ────────────────────────────────────────────────────────────
# These report for themselves rather than joining ISSUES, deliberately. The
# fingerprint above describes a STATE — what is wrong right now — and has to
# stay stable for dedup to work. A notification or an update is an EVENT: it
# happens once. Folding events into the state would change the hash every time
# one arrived and re-announce every unrelated issue alongside it. Each keeps its
# own seen-set instead.
#
# Piggybacking the health timer rather than adding units: both want exactly this
# cadence and this user. Failures here never affect the health result.
for SIDE in umbrel_notifications.sh umbrel_update_check.sh; do
    if [ -x "$SCRIPT_DIR/$SIDE" ]; then
        "$SCRIPT_DIR/$SIDE" &>/dev/null || true
    fi
done

# Non-zero exit tells systemd that alerts were sent (visible in systemctl status)
exit $(( SENT > 0 ? 1 : 0 ))

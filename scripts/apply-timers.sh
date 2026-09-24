#!/usr/bin/env bash
# Apply the schedules in config.env to Guardian's systemd timers. Root-only.
#
# ── Why this exists ──────────────────────────────────────────────────────────
# Changing when the health check or the backup runs used to mean an SSH session
# and `sudo bash reinstall-services.sh`. The bot can write config.env by itself
# — it owns that file — but it cannot make systemd notice, because a timer lives
# in /etc/systemd/system and the bot cannot write there. Not because it lacks
# root: because umbrel-guardian-bot.service sets ProtectSystem=strict, which
# mounts the whole hierarchy read-only apart from the Guardian directory, and a
# mount namespace is not something `sudo` steps out of.
#
# So the bot reaches this script through `systemd-run`, which asks PID 1 to
# spawn it — outside that namespace, where /etc is writable for root.
#
# ── Why it takes no arguments ────────────────────────────────────────────────
# It reads the values from config.env instead, which means the sudoers grant
# carries no user input at all:
#
#     umbrel ALL=(root) NOPASSWD: /usr/bin/systemd-run … apply-timers.sh
#
# There is no wildcard to smuggle anything through, and nothing to validate at
# the sudo layer. config.env is writable by `umbrel`, so everything read from it
# IS validated here — see the whitelist below. That is defence in depth rather
# than a boundary: `umbrel` can already rewrite the other sudo-granted scripts
# under scripts/, which is a separate problem this file does not pretend to fix.
#
# ── Why it parses config.env instead of sourcing it ──────────────────────────
# `source` on a file the caller can write, in a script running as root, is
# arbitrary code execution as root. Two greps are not worth that.
#
# ── Why it edits one line instead of redeploying the unit ────────────────────
# reinstall-services.sh builds the timers from services/*.timer, which lives
# under /home/umbrel and is writable by `umbrel`. That is fine for a command a
# human runs; it is not fine for one reachable from a chat window, where it
# would let anyone who holds the bot token put an arbitrary ExecStart into a
# root unit. This rewrites the OnCalendar= line of the already-deployed unit and
# nothing else, with a value that has to match one of six fixed forms.
#
# Deployed to /usr/local/lib/umbrel-guardian/ as root:root 0755 by
# reinstall-services.sh, for the same reason umbreld-query.sh is.

set -uo pipefail

INSTALL_DIR="/home/umbrel/umbrel/umbrel-guardian"
CONFIG="$INSTALL_DIR/config.env"
SYSTEMD_DIR="/etc/systemd/system"
HEALTH_TIMER="$SYSTEMD_DIR/umbrel-guardian-health.timer"
BACKUP_TIMER="$SYSTEMD_DIR/umbrel-guardian-backup.timer"

refuse() { echo "refused: $1" >&2; exit 2; }

[ "$EUID" -eq 0 ] || refuse "must run as root"
[ "$#" -eq 0 ] || refuse "takes no arguments"
[ -r "$CONFIG" ] || refuse "$CONFIG is not readable"

# One KEY=value line, last occurrence wins, no quotes, no expansion, no eval.
config_value() {
    sed -n "s/^[[:space:]]*$1=\(.*\)$/\1/p" "$CONFIG" 2>/dev/null \
        | tail -1 | tr -d '"'"'"'\r'
}

HEALTH_INTERVAL="$(config_value HEALTH_INTERVAL)"
BACKUP_TIME="$(config_value BACKUP_TIME)"
BACKUP_PATH="$(config_value BACKUP_PATH)"

CHANGED=0
PROBLEMS=0
# Units whose OnCalendar this run actually rewrote. Only these get restarted,
# and only these get their catch-up suppressed — see restart_rescheduled().
RESCHEDULED=()

# The five forms install.sh offers, and nothing else. Kept as one list here and
# in install.sh so the menu and this script cannot drift into disagreeing about
# what a valid interval is.
health_interval_ok() {
    case "$1" in
        '*:0/15'|'*:0/30'|hourly|'0/3:00'|'0/12:00') return 0 ;;
        *) return 1 ;;
    esac
}

# A 24-hour time, zero-padded, or nothing.
#
# `H:MM` is accepted and padded rather than refused. install.sh took the backup
# time with no validation for its whole life, so `BACKUP_TIME=2:00` is sitting in
# real config.env files, and systemd has been happily running `OnCalendar=*-*-*
# 2:00:00` from it — non-padded hours are valid there. Refusing it made the
# validator wrong about working input: `/interval 3h` reported a backup-time
# error while doing something unrelated to backups.
normalise_hhmm() {
    local value="$1"
    [[ "$value" =~ ^([0-9]|[01][0-9]|2[0-3]):([0-5][0-9])$ ]] || return 1
    printf '%02d:%s\n' "$((10#${BASH_REMATCH[1]}))" "${BASH_REMATCH[2]}"
}

# Rewrite one directive in a unit that is already deployed. The value cannot
# contain a newline — every accepted form is checked above or below — so it
# cannot introduce a second directive.
set_oncalendar() {
    local unit="$1" value="$2"
    [ -f "$unit" ] || return 1
    grep -q '^OnCalendar=' "$unit" || return 1
    if [ "$(sed -n 's/^OnCalendar=//p' "$unit" | tail -1)" = "$value" ]; then
        return 2   # already correct; nothing to write and nothing to restart
    fi
    sed -i "s|^OnCalendar=.*|OnCalendar=$value|" "$unit" || return 1
    return 0
}

# systemd's own answer, rather than ours, so a mistake in the calendar spec
# shows up here instead of as a timer that silently never fires.
#
# Take whatever form systemd gives. `systemctl show` special-cases
# NextElapseUSecRealtime and prints a FORMATTED timestamp ("Wed 2026-09-24
# 09:00:00 UTC"), not the raw microseconds the property name suggests. Demanding
# digits threw the right answer away and reported "unknown" for two perfectly
# healthy timers. Both forms are handled now, because which one you get is a
# systemd-version detail and not worth depending on.
#
# And when there is genuinely nothing, say what was observed. "unknown" that
# does not name its cause is the failure this project keeps having to fix.
next_fire() {
    local unit="$1" value load active
    value="$(systemctl show "$unit" -p NextElapseUSecRealtime --value 2>/dev/null | tr -d '\r')"

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        if [ "$value" -gt 0 ]; then
            date -d "@$(( value / 1000000 ))" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null && return 0
        fi
    elif [ -n "$value" ] && [ "$value" != "n/a" ] && [ "$value" != "infinity" ]; then
        printf '%s\n' "$value"
        return 0
    fi

    load="$(systemctl show "$unit" -p LoadState --value 2>/dev/null)"
    active="$(systemctl show "$unit" -p ActiveState --value 2>/dev/null)"
    case "${load:-}" in
        loaded) echo "none scheduled (timer is ${active:-unknown})" ;;
        "")     echo "cannot ask systemd" ;;
        *)      echo "not installed (${load})" ;;
    esac
}

# ── Health check ─────────────────────────────────────────────────────────────
if [ -z "$HEALTH_INTERVAL" ]; then
    echo "ℹ️ HEALTH_INTERVAL is not set in config.env — health timer left as it is"
elif ! health_interval_ok "$HEALTH_INTERVAL"; then
    echo "❌ HEALTH_INTERVAL='$HEALTH_INTERVAL' is not one of the accepted forms"
    echo "   (*:0/15, *:0/30, hourly, 0/3:00, 0/12:00) — health timer not changed"
    PROBLEMS=$((PROBLEMS + 1))
elif [ ! -f "$HEALTH_TIMER" ]; then
    echo "❌ $HEALTH_TIMER is not installed — run: sudo bash $INSTALL_DIR/reinstall-services.sh"
    PROBLEMS=$((PROBLEMS + 1))
else
    set_oncalendar "$HEALTH_TIMER" "$HEALTH_INTERVAL"
    case $? in
        0) CHANGED=1; RESCHEDULED+=(umbrel-guardian-health.timer)
           echo "✅ Health check interval set to $HEALTH_INTERVAL" ;;
        2) echo "ℹ️ Health check interval already $HEALTH_INTERVAL" ;;
        *) echo "❌ Could not rewrite $HEALTH_TIMER"; PROBLEMS=$((PROBLEMS + 1)) ;;
    esac
fi

# ── Backup ───────────────────────────────────────────────────────────────────
# With no BACKUP_PATH the backup units are never deployed at all
# (reinstall-services.sh only installs them when it is set), so say that rather
# than reporting a schedule nothing will act on. A command that answers "done"
# when no backup will ever run is how /backup came to go silent for hours.
if [ -z "$BACKUP_PATH" ]; then
    echo "ℹ️ Backups are not configured (BACKUP_PATH is empty) — no backup timer to set"
elif [ -z "$BACKUP_TIME" ]; then
    echo "ℹ️ BACKUP_TIME is not set in config.env — backup timer left as it is"
elif ! BACKUP_TIME="$(normalise_hhmm "$BACKUP_TIME")"; then
    echo "❌ BACKUP_TIME='$(config_value BACKUP_TIME)' is not a 24-hour HH:MM — backup timer not changed"
    PROBLEMS=$((PROBLEMS + 1))
elif [ ! -f "$BACKUP_TIMER" ]; then
    echo "❌ $BACKUP_TIMER is not installed — run: sudo bash $INSTALL_DIR/reinstall-services.sh"
    PROBLEMS=$((PROBLEMS + 1))
else
    set_oncalendar "$BACKUP_TIMER" "*-*-* ${BACKUP_TIME}:00"
    case $? in
        0) CHANGED=1; RESCHEDULED+=(umbrel-guardian-backup.timer)
           echo "✅ Daily backup time set to $BACKUP_TIME" ;;
        2) echo "ℹ️ Daily backup time already $BACKUP_TIME" ;;
        *) echo "❌ Could not rewrite $BACKUP_TIMER"; PROBLEMS=$((PROBLEMS + 1)) ;;
    esac
fi

# ── Make systemd notice, without running anything ────────────────────────────
# Restart, not reload: a timer re-reads OnCalendar when it is restarted, and
# daemon-reload alone leaves the running timer on its old schedule.
#
# The stamp file is the part that is not obvious, and skipping it cost a live
# node an unrequested full backup. Every Guardian timer sets Persistent=true, so
# on start systemd compares /var/lib/systemd/timers/stamp-<unit> against the most
# recent occurrence of the calendar expression and fires AT ONCE if a run looks
# missed. Move a 02:00 backup to 05:00 at 08:14 and the 05:00 slot is suddenly in
# the past and unaccounted for, so the timer "catches up" — a full clone nobody
# asked for, onto a drive, on hardware that may be the reason you were changing
# the schedule in the first place.
#
# Asking for a different time is not asking to run now. Touch the stamp to the
# current moment before starting, so the new schedule begins from here. Only for
# a timer this run actually rewrote: an untouched timer keeps normal catch-up, so
# a node that was powered off through its backup window still catches up at boot.
STAMP_DIR=/var/lib/systemd/timers
restart_rescheduled() {
    # Two statements, not one `local`: a variable assigned in the same `local`
    # is not yet visible to the one beside it, so the stamp path would come out
    # as "stamp-" and both timers would collide on it.
    local unit="$1"
    local stamp="$STAMP_DIR/stamp-$unit"
    systemctl stop "$unit" 2>/dev/null || true
    if mkdir -p "$STAMP_DIR" 2>/dev/null && : > "$stamp" 2>/dev/null; then
        touch "$stamp" 2>/dev/null || true
    else
        # Worth saying: without the stamp the timer may fire the moment it
        # starts, and that is exactly the surprise this function exists to stop.
        echo "⚠️ Could not write $stamp — $unit may run once immediately"
    fi
    systemctl start "$unit" 2>/dev/null \
        || { echo "⚠️ Could not start $unit"; PROBLEMS=$((PROBLEMS + 1)); }
}

if [ "$CHANGED" -eq 1 ]; then
    systemctl daemon-reload 2>/dev/null || true
    for UNIT in ${RESCHEDULED[@]+"${RESCHEDULED[@]}"}; do
        [ -f "$SYSTEMD_DIR/$UNIT" ] || continue
        systemctl is-enabled --quiet "$UNIT" 2>/dev/null || continue
        restart_rescheduled "$UNIT"
    done
    echo "ℹ️ Rescheduled only — nothing was run now."
fi

# ── Report what systemd now believes ─────────────────────────────────────────
[ -f "$HEALTH_TIMER" ] && echo "⏱ Next health check: $(next_fire umbrel-guardian-health.timer)"
[ -f "$BACKUP_TIMER" ] && echo "⏱ Next backup: $(next_fire umbrel-guardian-backup.timer)"

exit $(( PROBLEMS > 0 ? 1 : 0 ))

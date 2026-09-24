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

# The five forms install.sh offers, and nothing else. Kept as one list here and
# in install.sh so the menu and this script cannot drift into disagreeing about
# what a valid interval is.
health_interval_ok() {
    case "$1" in
        '*:0/15'|'*:0/30'|hourly|'0/3:00'|'0/12:00') return 0 ;;
        *) return 1 ;;
    esac
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
# shows up as "unknown" here instead of as a timer that silently never fires.
next_fire() {
    local unit="$1" usec
    usec="$(systemctl show "$unit" -p NextElapseUSecRealtime --value 2>/dev/null)"
    if [[ "${usec:-}" =~ ^[0-9]+$ ]] && [ "$usec" -gt 0 ]; then
        date -d "@$(( usec / 1000000 ))" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null
    else
        echo "unknown"
    fi
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
        0) CHANGED=1; echo "✅ Health check interval set to $HEALTH_INTERVAL" ;;
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
elif ! [[ "$BACKUP_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "❌ BACKUP_TIME='$BACKUP_TIME' is not a 24-hour HH:MM — backup timer not changed"
    PROBLEMS=$((PROBLEMS + 1))
elif [ ! -f "$BACKUP_TIMER" ]; then
    echo "❌ $BACKUP_TIMER is not installed — run: sudo bash $INSTALL_DIR/reinstall-services.sh"
    PROBLEMS=$((PROBLEMS + 1))
else
    set_oncalendar "$BACKUP_TIMER" "*-*-* ${BACKUP_TIME}:00"
    case $? in
        0) CHANGED=1; echo "✅ Daily backup time set to $BACKUP_TIME" ;;
        2) echo "ℹ️ Daily backup time already $BACKUP_TIME" ;;
        *) echo "❌ Could not rewrite $BACKUP_TIMER"; PROBLEMS=$((PROBLEMS + 1)) ;;
    esac
fi

# ── Make systemd notice ──────────────────────────────────────────────────────
# Restart, not reload: a timer re-reads OnCalendar when it is restarted, and
# daemon-reload alone leaves the running timer on its old schedule.
if [ "$CHANGED" -eq 1 ]; then
    systemctl daemon-reload 2>/dev/null || true
    for UNIT in umbrel-guardian-health.timer umbrel-guardian-backup.timer; do
        [ -f "$SYSTEMD_DIR/$UNIT" ] || continue
        systemctl is-enabled --quiet "$UNIT" 2>/dev/null || continue
        systemctl restart "$UNIT" 2>/dev/null \
            || { echo "⚠️ Could not restart $UNIT"; PROBLEMS=$((PROBLEMS + 1)); }
    done
fi

# ── Report what systemd now believes ─────────────────────────────────────────
[ -f "$HEALTH_TIMER" ] && echo "⏱ Next health check: $(next_fire umbrel-guardian-health.timer)"
[ -f "$BACKUP_TIMER" ] && echo "⏱ Next backup: $(next_fire umbrel-guardian-backup.timer)"

exit $(( PROBLEMS > 0 ? 1 : 0 ))

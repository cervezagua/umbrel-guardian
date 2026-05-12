#!/usr/bin/env bash
# Umbrel Guardian — system control wrapper.
#
# Runs privileged operations (reboot, shutdown, restart Docker/umbrel)
# on behalf of the bot. The bot invokes this via sudo:
#
#     sudo -n /home/umbrel/umbrel/umbrel-guardian/scripts/system_control.sh <action>
#
# /etc/sudoers.d/umbrel-guardian-system grants NOPASSWD access for exact
# subcommands of this script — nothing else. The bot can only trigger
# the actions listed below.

set -uo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "system_control.sh must be run as root (invoke via sudo)" >&2
    exit 1
fi

ACTION="${1:-}"

case "$ACTION" in
    reboot)
        # +1 minute grace so the bot can reply and pending tasks can settle.
        exec /usr/sbin/shutdown -r +1 "Reboot scheduled via Umbrel Guardian"
        ;;
    shutdown)
        exec /usr/sbin/shutdown -h +1 "Shutdown scheduled via Umbrel Guardian"
        ;;
    cancel)
        exec /usr/sbin/shutdown -c
        ;;
    restart-docker)
        # Will briefly interrupt all containers (including umbreld).
        exec /bin/systemctl restart docker
        ;;
    restart-umbrel)
        # Restarts umbreld (Umbrel's orchestration daemon).
        exec /bin/systemctl restart umbrel
        ;;
    *)
        echo "Usage: $0 {reboot|shutdown|cancel|restart-docker|restart-umbrel}" >&2
        exit 2
        ;;
esac

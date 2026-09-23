#!/usr/bin/env bash
# Arms and disarms the clean-shutdown marker, and decides — once, at boot —
# whether the previous power-off was orderly.
#
# The decision lives here rather than in reinstall-services.sh for two reasons,
# both of which were live bugs.
#
# 1. The marker's presence is NOT evidence of an unclean shutdown. It is created
#    when the machine comes up and removed at orderly shutdown, so while the
#    system is running normally it is supposed to be there. reinstall-services.sh
#    tested `[ -e marker ]` and therefore reported a power loss on every manual
#    reinstall of a healthy running node — then stamped the alert with the
#    current boot id, so the health timer pushed it to Telegram. A false alarm on
#    the one warning built to catch what actually destroyed the user's config.
#
# 2. Nothing ordered the marker unit against the pre-start hook, so the marker
#    could be re-created before the hook ever looked at it — silently losing a
#    REAL detection. A race in both directions.
#
# So the marker records WHICH boot created it, and the unit that owns it does the
# comparison in its own ExecStart. A marker whose boot id differs from the
# running kernel's survived a boot transition without ExecStop — the plug was
# pulled. Same boot id means this boot armed it and all is well.
set -uo pipefail

STATE_DIR="${GUARDIAN_STATE_DIR:-/home/umbrel/umbrel/umbrel-guardian/.state}"
MARKER="$STATE_DIR/boot-in-progress"
UNCLEAN="$STATE_DIR/unclean-shutdown"
BOOT_ID_FILE="${GUARDIAN_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"

current_boot() { cat "$BOOT_ID_FILE" 2>/dev/null || echo unknown; }

case "${1:-}" in
--arm)
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    NOW="$(current_boot)"
    if [ -e "$MARKER" ]; then
        WAS="$(head -n1 "$MARKER" 2>/dev/null || true)"
        if [ -z "$WAS" ]; then
            # An empty marker is what the previous version's `touch` produced.
            # It carries no boot id, so it cannot answer the question either way.
            # Guessing here would mean either a false alarm or a lost detection,
            # and a monitor that cries wolf is worse than one that says nothing:
            # stay quiet, re-stamp, and be correct from the next boot on.
            echo "boot marker carries no boot id (pre-upgrade format) — cannot judge the last shutdown"
            # One-time migration, and it happens exactly once per node: after this
            # the marker carries a boot id and this branch is unreachable.
            #
            # The version that wrote empty markers decided "unclean" from the
            # marker's mere existence, which was true whenever the machine was
            # running — so it stamped the verdict on every single reinstall. Any
            # verdict sitting here alongside a legacy marker is therefore almost
            # certainly that false alarm, and because it carries the live boot id
            # it would re-alert every 30 minutes until the next clean shutdown.
            #
            # A real power loss stamps the same value, so this cannot tell them
            # apart. Clearing risks dropping one warning about a power-off the
            # operator already lived through; keeping it guarantees recurring
            # noise on the one alert that exists to be believed. Clear it, and
            # say so rather than doing it quietly.
            if [ -e "$UNCLEAN" ]; then
                rm -f "$UNCLEAN" 2>/dev/null || true
                echo "cleared a shutdown verdict left by the pre-upgrade check, which flagged every reinstall"
            fi
        elif [ "$WAS" != "$NOW" ]; then
            printf '%s\n' "$NOW" > "$UNCLEAN" 2>/dev/null || true
            echo "previous shutdown was unclean (marker from boot $WAS survived into $NOW)"
        else
            # Same boot: this boot already armed it. Re-arming is idempotent and
            # must NOT clear the verdict — an unclean shutdown detected earlier
            # in this same boot is still true, and clearing it here would erase a
            # real alert every time the unit was restarted.
            echo "already armed for this boot"
        fi
    else
        # No marker: ExecStop ran at the last shutdown, or this is a first
        # install. Either way the previous power-off was orderly.
        rm -f "$UNCLEAN" 2>/dev/null || true
        echo "previous shutdown was clean"
    fi
    printf '%s\n' "$NOW" > "$MARKER" 2>/dev/null || true
    ;;
--disarm)
    rm -f "$MARKER" 2>/dev/null || true
    ;;
*)
    echo "usage: boot-marker.sh --arm | --disarm" >&2
    exit 2
    ;;
esac

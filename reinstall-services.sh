#!/usr/bin/env bash
# Umbrel Guardian — Re-install systemd services from persistent storage.
#
# Umbrel OS uses A/B root partitions. On OTA updates the root filesystem
# is replaced, wiping /etc/systemd/system/. The Guardian install dir at
# /home/umbrel/umbrel/umbrel-guardian/ survives because /home is bind-mounted
# from the persistent data partition.
#
# Recovery on Umbrel 1.7.x is automatic via the official pre-start hook:
#   /opt/umbrel-custom-hooks/run-pre-start  (Umbrel-provided wrapper)
#     → /home/umbrel/umbrel/custom-hooks/pre-start  (deployed by this script)
#     → this script (reinstall-services.sh)
#
# Manual recovery: sudo bash /home/umbrel/umbrel/umbrel-guardian/reinstall-services.sh

set -euo pipefail

INSTALL_DIR="/home/umbrel/umbrel/umbrel-guardian"
SYSTEMD_DIR="/etc/systemd/system"
CONFIG="$INSTALL_DIR/config.env"
CUSTOM_HOOKS_DIR="/home/umbrel/umbrel/custom-hooks"

# ── Pre-flight checks ─────────────────────────────────────────────────────────

if [ "$EUID" -ne 0 ]; then
    echo "❌ This script must be run as root (it writes to /etc/systemd/system)."
    echo "   Try: sudo bash $0"
    exit 1
fi

if [ ! -f "$CONFIG" ]; then
    echo "❌ config.env not found at $CONFIG"
    echo "   Run install.sh first to set up Umbrel Guardian."
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG"

echo "🛡 Umbrel Guardian — Reinstalling systemd services..."

# ── Python virtualenv ────────────────────────────────────────────────────────
# The bot runs from a venv at $INSTALL_DIR/.venv/. That directory lives in
# /home (bind-mounted from the persistent data partition), so it survives
# rugpi A/B reboots and OTAs — no apt/pip dance needed on most boots.
#
# We only need to (re)create it when:
#   - It doesn't exist yet (fresh install)
#   - It exists but the import test fails (Python version bump invalidated it,
#     or pip install partially failed previously)
VENV="$INSTALL_DIR/.venv"
VENV_PY="$VENV/bin/python3"

ensure_venv() {
    # On Debian, `import venv` succeeds even when the ensurepip wheels
    # (shipped in python3.X-venv) are missing — so we can't reliably detect
    # via import. Just attempt creation; if it fails, install python3-venv
    # (which pulls in the version-specific python3.X-venv on Trixie+) and retry.

    echo "  🔧 Creating venv at $VENV..."
    rm -rf "$VENV"

    if ! sudo -u umbrel python3 -m venv "$VENV" &>/dev/null; then
        echo "  ⚠️  venv creation failed (likely python3-venv not installed) — installing..."
        rm -rf "$VENV"
        if ! apt-get install -y python3-venv &>/dev/null; then
            apt-get update &>/dev/null || true
            apt-get install -y python3-venv &>/dev/null || {
                echo "  ❌ Could not install python3-venv via apt."
                return 1
            }
        fi
        if ! sudo -u umbrel python3 -m venv "$VENV"; then
            echo "  ❌ venv creation still failing after python3-venv install — see above."
            return 1
        fi
    fi

    echo "  📦 Installing requirements into venv..."
    if ! sudo -u umbrel "$VENV/bin/pip" install --quiet --upgrade pip &>/dev/null; then
        # Network issue — pip can't reach PyPI. Try again with apt cache refreshed.
        apt-get update &>/dev/null || true
        sudo -u umbrel "$VENV/bin/pip" install --quiet --upgrade pip &>/dev/null || true
    fi
    if sudo -u umbrel "$VENV/bin/pip" install --quiet -r "$INSTALL_DIR/requirements.txt"; then
        echo "  ✅ Venv ready: $VENV"
        return 0
    fi
    echo "  ❌ pip install -r requirements.txt failed."
    return 1
}

if [ ! -x "$VENV_PY" ] || ! "$VENV_PY" -c "import requests" &>/dev/null; then
    ensure_venv || {
        echo "  ❌ Could not prepare Python environment. Bot service will fail."
        echo "     Manual recovery: cd $INSTALL_DIR && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
    }
fi

# ── Ensure scripts are executable ────────────────────────────────────────────
# Defense in depth: GitHub blobs preserve +x via mode 100755, but if anyone
# ever copies/syncs files in a way that strips bits (Windows checkout with
# core.fileMode=false, scp without -p, manual archive extract), this restores
# them so the bot does not fail with "Permission denied".
chmod +x "$INSTALL_DIR/scripts/"*.sh 2>/dev/null || true
chmod +x "$INSTALL_DIR/reinstall-services.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/uninstall.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/install.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/custom-hooks/pre-start" 2>/dev/null || true

# ── Persistent state directory ───────────────────────────────────────────────
# Alert latches and seen-sets live here rather than under /run. /run is tmpfs,
# so state there dies at every reboot and every monitor re-announces everything
# it already told you about — which teaches you to ignore the alerts. This path
# is inside the bot's ReadWritePaths (see umbrel-guardian-bot.service), so the
# bot can write it despite ProtectSystem=strict, and it is gitignored.
STATE_DIR="$INSTALL_DIR/.state"
mkdir -p "$STATE_DIR"
chown umbrel:umbrel "$STATE_DIR" 2>/dev/null || true
chmod 750 "$STATE_DIR" 2>/dev/null || true

# ── Ensure umbrel user is in docker group ────────────────────────────────────
# OTA updates rebuild /etc/group, removing umbrel from supplementary groups.
# Without docker membership, the bot (User=umbrel) cannot run `docker ps`,
# breaking /apps and /logs. usermod -aG is idempotent if already a member.
if getent group docker &>/dev/null; then
    if ! id -nG umbrel 2>/dev/null | grep -qw docker; then
        usermod -aG docker umbrel
        echo "  ✅ Added umbrel to docker group (bot service will be restarted)"
    fi
fi

# ── Was the last shutdown clean? ─────────────────────────────────────────────
# NOT decided here. It used to be, and it was wrong in both directions.
#
# The marker is created when the machine comes up and removed at orderly
# shutdown, so it is present for the entire time the system is running — that is
# its job. Testing `[ -e marker ]` from this script therefore reported a power
# loss on every manual reinstall of a perfectly healthy node, and stamped it with
# the live boot id so the health timer pushed the alert to Telegram. And in the
# other direction, nothing ordered the marker unit against this hook, so at real
# boot the marker could be re-created before this script ever read it, losing a
# genuine detection.
#
# The verdict now belongs to the unit that owns the marker: the marker records
# WHICH boot wrote it, and umbrel-guardian-cleanshutdown.service compares boot
# ids in its own ExecStart. See scripts/boot-marker.sh.
mkdir -p "$STATE_DIR" 2>/dev/null || true
chown -R umbrel:umbrel "$STATE_DIR" 2>/dev/null || true

# ── Cap the journal ──────────────────────────────────────────────────────────
# umbrelOS ships no journal limit, and on the node this was written for the
# journal reached 1.8 GB on the system SD card. That is not just wasted space:
# every kernel-log query had to read through it, which is what made disk
# monitoring take 75 seconds a run, and it is continuous write load on exactly
# the card whose wear we are trying to slow.
#
# /etc is restored from the image each boot, so the drop-in is rewritten every
# time, same as the sudoers and sysctl files above. journald only reads it at
# start — which already happened, long before this hook — so the live journal
# is vacuumed here too, and the drop-in makes it stick from the next boot on.
JOURNALD_CONF=/etc/systemd/journald.conf.d/90-umbrel-guardian.conf
JOURNAL_MAX="${JOURNAL_MAX_SIZE:-200M}"
if [[ "$JOURNAL_MAX" =~ ^[0-9]+[KMG]?$ ]]; then
    mkdir -p /etc/systemd/journald.conf.d 2>/dev/null || true
    cat > "$JOURNALD_CONF" <<JOURNAL_EOF
[Journal]
SystemMaxUse=$JOURNAL_MAX
JOURNAL_EOF
    # Only vacuum when actually over the cap. Vacuuming is slow on a large
    # journal and this hook shares a 5-minute budget with everything else, so
    # it is bounded and its failure is never fatal.
    # `[0-9.]+` matches a lone "." and journald's sentence ends with one, so
    # with `tail -1` this reported the size as "." — "Journal capped at 200M
    # (was .)" on a live node. Require a leading digit and take the FIRST match:
    # "Archived and active journals take up 1.8G in the file system."
    JOURNAL_NOW=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?[KMGTPE]?B?' | head -1 || true)
    if timeout 120 journalctl --vacuum-size="$JOURNAL_MAX" &>/dev/null; then
        echo "  ✅ Journal capped at $JOURNAL_MAX (was ${JOURNAL_NOW:-unknown})"
    else
        echo "  ⚠️ Journal vacuum did not finish; cap applies from next boot"
    fi
else
    echo "  ⚠️ JOURNAL_MAX_SIZE='$JOURNAL_MAX' is not a valid size — skipping journal cap"
fi

# ── Bump inotify watch limits (system-wide) ──────────────────────────────────
# Umbrel 1.7.x consumes more inotify watches than 1.5; default limits cause
# .path units (including umbrel-guardian-backup-trigger.path AND systemd's own
# systemd-ask-password-console.path) to fail with "inotify watch limit reached".
# OTA wipes /etc/sysctl.d/, so we re-deploy on each reinstall.
SYSCTL_CONF=/etc/sysctl.d/40-inotify-umbrel.conf
WANT_WATCHES=524288
WANT_INSTANCES=512

# Always rewrite the file rather than testing for it: it lives on the OS
# partition, so an OTA replaces it, and writing it is free.
cat > "$SYSCTL_CONF" <<SYSCTL_EOF
fs.inotify.max_user_watches=$WANT_WATCHES
fs.inotify.max_user_instances=$WANT_INSTANCES
SYSCTL_EOF

# Then assert the LIVE values, which is the part that actually matters.
# Testing for the file's existence was not enough. This script only runs from
# custom-hooks/pre-start when Guardian's units are missing, so on a boot that
# keeps /etc/systemd/system but resets the running sysctls, the config file is
# still sitting there while the kernel is back on its defaults — and the old
# `[ ! -f ]` guard short-circuited and never reapplied anything. The symptom is
# precisely what this block exists to prevent: systemd-ask-password-console.path
# fails with "inotify watch limit reached" and interactive sudo stops accepting
# passwords, which locks you out of the machine you need root on to fix it.
#
# Only ever raise. If something else set a higher limit, leave it alone.
INOTIFY_RAISED=0
for KEY in max_user_watches max_user_instances; do
    case "$KEY" in
        max_user_watches)   WANT=$WANT_WATCHES ;;
        max_user_instances) WANT=$WANT_INSTANCES ;;
    esac
    LIVE=$(sysctl -n "fs.inotify.$KEY" 2>/dev/null || true)
    [[ "$LIVE" =~ ^[0-9]+$ ]] || LIVE=0
    if [ "$LIVE" -lt "$WANT" ]; then
        sysctl -w "fs.inotify.$KEY=$WANT" &>/dev/null || true
        INOTIFY_RAISED=1
        echo "  ✅ inotify $KEY: $LIVE → $WANT"
    fi
done
if [ "$INOTIFY_RAISED" -eq 1 ]; then
    # The .path unit fails permanently once it cannot register its watch, so it
    # needs clearing before systemd will start it again.
    systemctl reset-failed umbrel-guardian-backup-trigger.path 2>/dev/null || true
else
    echo "  ✅ inotify limits already sufficient"
fi

# ── Clean up legacy bootstrap unit ───────────────────────────────────────────
# The old bootstrap pattern (umbrel-guardian-bootstrap.service in /etc/systemd/system)
# could not survive OTA — the service file itself got wiped. Replaced by the
# pre-start hook in /home/umbrel/umbrel/custom-hooks/ (persistent).
if [ -f "$SYSTEMD_DIR/umbrel-guardian-bootstrap.service" ]; then
    systemctl disable umbrel-guardian-bootstrap.service 2>/dev/null || true
    rm -f "$SYSTEMD_DIR/umbrel-guardian-bootstrap.service"
    echo "  🧹 Removed legacy bootstrap service"
fi

# ── Install unit files ───────────────────────────────────────────────────────

# Health check
cp "$INSTALL_DIR/services/umbrel-guardian-health.service" "$SYSTEMD_DIR/"

if [ -n "${HEALTH_INTERVAL:-}" ]; then
    sed "s|OnCalendar=.*|OnCalendar=${HEALTH_INTERVAL}|" \
        "$INSTALL_DIR/services/umbrel-guardian-health.timer" \
        > "$SYSTEMD_DIR/umbrel-guardian-health.timer"
else
    cp "$INSTALL_DIR/services/umbrel-guardian-health.timer" "$SYSTEMD_DIR/"
fi

# Bot
cp "$INSTALL_DIR/services/umbrel-guardian-bot.service" "$SYSTEMD_DIR/"

# Daily summary
cp "$INSTALL_DIR/services/umbrel-guardian-daily.service" "$SYSTEMD_DIR/"
cp "$INSTALL_DIR/services/umbrel-guardian-daily.timer"   "$SYSTEMD_DIR/"

# Backup (only if configured)
if [ -n "${BACKUP_PATH:-}" ]; then
    cp "$INSTALL_DIR/services/umbrel-guardian-backup.service" "$SYSTEMD_DIR/"

    BACKUP_TIME="${BACKUP_TIME:-02:00}"
    sed "s|OnCalendar=.*|OnCalendar=*-*-* ${BACKUP_TIME}:00|" \
        "$INSTALL_DIR/services/umbrel-guardian-backup.timer" \
        > "$SYSTEMD_DIR/umbrel-guardian-backup.timer"

    # Auto-mount: udev rule for hot-plug + systemd service for boot.
    # The mount script is the single source of truth for mount logic.
    # Both udev and the boot service call it at /usr/local/bin/.
    if [[ "${AUTO_MOUNT:-n}" =~ ^[Yy] ]]; then
        # Deploy mount script to fixed system path (udev needs a stable path)
        sed -e "s|@@BACKUP_PATH@@|${BACKUP_PATH}|g" \
            -e "s|@@INSTALL_DIR@@|${INSTALL_DIR}|g" \
            "$INSTALL_DIR/scripts/mount-backup.sh" \
            > /usr/local/bin/mount-umbrel-backup.sh
        chmod +x /usr/local/bin/mount-umbrel-backup.sh

        # Deploy udev rule for hot-plug auto-mount
        cp "$INSTALL_DIR/services/99-umbrel-backup.rules" /etc/udev/rules.d/
        chmod 644 /etc/udev/rules.d/99-umbrel-backup.rules
        udevadm control --reload-rules 2>/dev/null || true

        # Simplified systemd service (calls the deployed mount script)
        sed "s|@@BACKUP_PATH@@|${BACKUP_PATH}|g" \
            "$INSTALL_DIR/services/umbrel-guardian-mount-backup.service" \
            > "$SYSTEMD_DIR/umbrel-guardian-mount-backup.service"
    fi
fi

# ── Deploy sudoers for system control commands ───────────────────────────────
# Grants the umbrel user NOPASSWD for the exact subcommands of
# scripts/system_control.sh. The bot uses these to expose /system_reboot,
# /system_shutdown, /restart_docker, /restart_umbrel.
# /etc/sudoers.d/ is wiped on every boot, so we redeploy here.
SUDOERS_FILE="/etc/sudoers.d/umbrel-guardian-system"
TMP_SUDOERS=$(mktemp)
cat > "$TMP_SUDOERS" <<'SUDOERS_EOF'
# Umbrel Guardian — allow umbrel user to run system control commands without
# a password. Scope is strictly limited to the exact subcommands listed.
umbrel ALL=(root) NOPASSWD: /home/umbrel/umbrel/umbrel-guardian/scripts/system_control.sh reboot
umbrel ALL=(root) NOPASSWD: /home/umbrel/umbrel/umbrel-guardian/scripts/system_control.sh shutdown
umbrel ALL=(root) NOPASSWD: /home/umbrel/umbrel/umbrel-guardian/scripts/system_control.sh cancel
umbrel ALL=(root) NOPASSWD: /home/umbrel/umbrel/umbrel-guardian/scripts/system_control.sh restart-docker
umbrel ALL=(root) NOPASSWD: /home/umbrel/umbrel/umbrel-guardian/scripts/system_control.sh restart-umbrel

# Read-only diagnostics that need root: smartctl talks to the raw device, and
# the kernel journal is not world-readable. Neither script takes an argument
# that could widen what it touches.
umbrel ALL=(root) NOPASSWD: /home/umbrel/umbrel/umbrel-guardian/scripts/disk_health.sh
umbrel ALL=(root) NOPASSWD: /home/umbrel/umbrel/umbrel-guardian/scripts/disk_health.sh --issues
umbrel ALL=(root) NOPASSWD: /home/umbrel/umbrel/umbrel-guardian/scripts/verify_backup.sh
umbrel ALL=(root) NOPASSWD: /home/umbrel/umbrel/umbrel-guardian/scripts/verify_backup.sh --deep
umbrel ALL=(root) NOPASSWD: /home/umbrel/umbrel/umbrel-guardian/scripts/verify_backup.sh --integrity
umbrel ALL=(root) NOPASSWD: /home/umbrel/umbrel/umbrel-guardian/scripts/restore_file.sh --list
umbrel ALL=(root) NOPASSWD: /home/umbrel/umbrel/umbrel-guardian/scripts/restore_file.sh --all

# The umbreld gateway. Five read-only queries that take no arguments, and one
# mutation whose only wildcard is the app id — which the gateway itself
# validates against umbrelOS's id format before it reaches umbreld.
umbrel ALL=(root) NOPASSWD: /usr/local/lib/umbrel-guardian/umbreld-query.sh apps.list.query
umbrel ALL=(root) NOPASSWD: /usr/local/lib/umbrel-guardian/umbreld-query.sh notifications.get.query
umbrel ALL=(root) NOPASSWD: /usr/local/lib/umbrel-guardian/umbreld-query.sh system.version.query
umbrel ALL=(root) NOPASSWD: /usr/local/lib/umbrel-guardian/umbreld-query.sh system.checkUpdate.query
umbrel ALL=(root) NOPASSWD: /usr/local/lib/umbrel-guardian/umbreld-query.sh system.getReleaseChannel.query
umbrel ALL=(root) NOPASSWD: /usr/local/lib/umbrel-guardian/umbreld-query.sh apps.restart.mutate --appId *
SUDOERS_EOF
# Validate with visudo before installing — a broken sudoers file breaks all sudo.
if visudo -c -f "$TMP_SUDOERS" &>/dev/null; then
    install -m 0440 -o root -g root "$TMP_SUDOERS" "$SUDOERS_FILE"
    echo "  ✅ Deployed system-control sudoers → $SUDOERS_FILE"
else
    echo "  ❌ sudoers content failed visudo check — NOT deploying. System commands will not work."
    visudo -c -f "$TMP_SUDOERS" || true
fi
rm -f "$TMP_SUDOERS"

# ── Root-owned gateway to umbreld ────────────────────────────────────────────
# umbrelOS 2.0 made `umbreld client` root-only. Guardian's scripts run as
# `umbrel`, so without this every umbreld-backed command breaks on 2.0.
#
# It is deployed HERE, outside $INSTALL_DIR, on purpose. A sudo-granted script
# that its own caller can rewrite is not a privilege boundary — and everything
# under /home/umbrel is writable by `umbrel`. Root-owned and mode 0755, with no
# config, libraries or state beside it to subvert either.
PRIV_DIR=/usr/local/lib/umbrel-guardian
mkdir -p "$PRIV_DIR"
if [ -f "$INSTALL_DIR/scripts/umbreld-query.sh" ]; then
    install -o root -g root -m 0755 "$INSTALL_DIR/scripts/umbreld-query.sh" \
        "$PRIV_DIR/umbreld-query.sh"
    echo "  ✅ Deployed umbreld gateway → $PRIV_DIR/umbreld-query.sh"
else
    echo "  ⚠️ scripts/umbreld-query.sh missing — umbreld commands will not work on umbrelOS 2.0"
fi

# Clean up the LEGACY sudoers file from a prior design (different filename)
rm -f /etc/sudoers.d/umbrel-guardian 2>/dev/null || true

# Manual backup trigger — the bot touches .backup-trigger, this .path unit
# watches for it and starts umbrel-guardian-backup.service.  No sudo needed.
cp "$INSTALL_DIR/services/umbrel-guardian-backup-trigger.path" "$SYSTEMD_DIR/"

# Clean-shutdown marker. Its whole job is ExecStop; see the unit for why.
cp "$INSTALL_DIR/services/umbrel-guardian-cleanshutdown.service" "$SYSTEMD_DIR/"

# ── Deploy OTA-recovery hook (SSD-overlay path) ─────────────────────────────
# Umbrel 1.7.x's wrapper at /opt/umbrel-custom-hooks/run-pre-start looks for
# /home/umbrel/umbrel/custom-hooks/pre-start at boot. The path lives on the
# SSD overlay during normal operation, so this copy is for post-boot manual
# invocation and for situations where the SSD is mounted before the wrapper
# runs (e.g., systems without external storage).
if [ -f "$INSTALL_DIR/custom-hooks/pre-start" ]; then
    mkdir -p "$CUSTOM_HOOKS_DIR"
    cp "$INSTALL_DIR/custom-hooks/pre-start" "$CUSTOM_HOOKS_DIR/pre-start"
    chmod +x "$CUSTOM_HOOKS_DIR/pre-start"
    chown -R umbrel:umbrel "$CUSTOM_HOOKS_DIR"
    echo "  ✅ Deployed OTA-recovery hook → $CUSTOM_HOOKS_DIR/pre-start"
else
    echo "  ⚠️  custom-hooks/pre-start not found in install dir — OTA recovery disabled"
fi

# ── Deploy the hook to the SD-card layer (pre-mount path) ───────────────────
# On Umbrel 1.7.x, /home/umbrel/umbrel is bind-mounted from an external SSD
# (e.g. /dev/sda1) by umbrel-external-storage.service. That service runs in
# PARALLEL with umbrel-custom-pre-start.service, not before it — so when the
# wrapper checks /home/umbrel/umbrel/custom-hooks/pre-start, it usually sees
# the empty SD-card-side mount point, not the SSD's content.
#
# Fix: also drop our hook on the SD-card layer at the equivalent path. The
# wrapper finds it pre-mount, runs it, and the hook polls until the SSD
# mount completes (config.env appears) before invoking the recovery.
#
# This is only needed when /home and /home/umbrel/umbrel are on different
# devices. On systems where they share a partition (no external storage),
# the SSD-overlay deployment above is sufficient.
if [ -f "$INSTALL_DIR/custom-hooks/pre-start" ]; then
    HOME_SRC=$(findmnt -n -o SOURCE /home 2>/dev/null || true)
    UMBREL_SRC=$(findmnt -n -o SOURCE /home/umbrel/umbrel 2>/dev/null || true)
    HOME_DEV=$(echo "$HOME_SRC" | sed 's/\[.*\]//')
    UMBREL_DEV=$(echo "$UMBREL_SRC" | sed 's/\[.*\]//')
    HOME_SUBPATH=$(echo "$HOME_SRC" | grep -oP '\[\K[^]]+' || true)

    if [ -n "$HOME_DEV" ] && [ -b "$HOME_DEV" ] \
        && [ -n "$UMBREL_DEV" ] && [ "$HOME_DEV" != "$UMBREL_DEV" ]; then
        # Different devices — SD card overlay scenario. Mount the SD card
        # partition at a temporary location and drop the hook on its layer.
        SD_RAW=$(mktemp -d /tmp/guardian-sd-XXXXXX)
        if mount "$HOME_DEV" "$SD_RAW" 2>/dev/null; then
            # The SD-card-side equivalent of /home/foo is "$SD_RAW$HOME_SUBPATH/foo".
            SD_HOOK_PARENT="$SD_RAW${HOME_SUBPATH}/umbrel/umbrel"
            if [ -d "$SD_HOOK_PARENT" ]; then
                SD_HOOK_DIR="$SD_HOOK_PARENT/custom-hooks"
                mkdir -p "$SD_HOOK_DIR"
                cp "$INSTALL_DIR/custom-hooks/pre-start" "$SD_HOOK_DIR/pre-start"
                chmod +x "$SD_HOOK_DIR/pre-start"
                echo "  ✅ Deployed pre-mount hook → SD-card layer ($HOME_DEV)"
            else
                echo "  ⚠️  SD-card path $SD_HOOK_PARENT not found — skipping pre-mount hook"
            fi
            umount "$SD_RAW" 2>/dev/null || umount -l "$SD_RAW" 2>/dev/null || true
        else
            echo "  ⚠️  Could not mount $HOME_DEV for SD-card hook deployment"
        fi
        rmdir "$SD_RAW" 2>/dev/null || true
    else
        echo "  ℹ️  /home and /home/umbrel/umbrel on same device — pre-mount hook not needed"
    fi
fi

# ── Enable and start units ───────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable --now umbrel-guardian-health.timer
systemctl enable umbrel-guardian-bot.service
systemctl restart umbrel-guardian-bot.service  # restart so any group/code changes take effect
systemctl enable --now umbrel-guardian-daily.timer
systemctl enable --now umbrel-guardian-cleanshutdown.service
# `--now` does not re-run ExecStart on a unit that is already active, and this one
# is Type=oneshot RemainAfterExit=yes — so on a live node the marker logic above
# would not take effect until the next reboot. Arm it directly instead.
#
# Deliberately NOT `systemctl restart`: that runs ExecStop first, which removes
# the marker, and --arm would then read "no marker" as a clean previous shutdown
# and erase a verdict legitimately reached earlier in this same boot. Calling
# --arm on its own is idempotent and keeps a real alert intact.
if [ -x "$INSTALL_DIR/scripts/boot-marker.sh" ]; then
    ARM_OUT="$("$INSTALL_DIR/scripts/boot-marker.sh" --arm 2>&1 || true)"
    [ -n "$ARM_OUT" ] && echo "  ℹ️ Shutdown marker: $ARM_OUT"
    chown -R umbrel:umbrel "$STATE_DIR" 2>/dev/null || true
fi

if [ -n "${BACKUP_PATH:-}" ]; then
    systemctl enable --now umbrel-guardian-backup.timer
    # Clear a stale trigger BEFORE enabling the watcher. The .path unit uses
    # PathExists=, which fires the instant the path is there — so a leftover
    # trigger file means `enable --now` immediately starts an unrequested
    # backup. That file is exactly what a node with no BACKUP_PATH accumulates:
    # /backup used to write it with nothing watching, so the first reinstall
    # after configuring a drive would kick off a backup nobody asked for.
    # backup.sh removes the trigger itself on a normal run; this only catches
    # the ones no run ever consumed.
    rm -f "$INSTALL_DIR/.backup-trigger" 2>/dev/null || true
    systemctl enable --now umbrel-guardian-backup-trigger.path
    if [[ "${AUTO_MOUNT:-n}" =~ ^[Yy] ]]; then
        systemctl enable --now umbrel-guardian-mount-backup.service 2>/dev/null || true
    fi
fi

echo "✅ Systemd services reinstalled and enabled."

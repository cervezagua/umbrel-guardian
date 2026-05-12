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

# ── Bump inotify watch limits (system-wide) ──────────────────────────────────
# Umbrel 1.7.x consumes more inotify watches than 1.5; default limits cause
# .path units (including umbrel-guardian-backup-trigger.path AND systemd's own
# systemd-ask-password-console.path) to fail with "inotify watch limit reached".
# OTA wipes /etc/sysctl.d/, so we re-deploy on each reinstall.
SYSCTL_CONF=/etc/sysctl.d/40-inotify-umbrel.conf
if [ ! -f "$SYSCTL_CONF" ]; then
    cat > "$SYSCTL_CONF" <<'SYSCTL_EOF'
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512
SYSCTL_EOF
    sysctl --system &>/dev/null || true
    systemctl reset-failed umbrel-guardian-backup-trigger.path 2>/dev/null || true
    echo "  ✅ Bumped inotify limits via $SYSCTL_CONF"
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

# Clean up old sudoers entry if present (no longer needed — using .path unit now)
rm -f /etc/sudoers.d/umbrel-guardian 2>/dev/null || true

# Manual backup trigger — the bot touches .backup-trigger, this .path unit
# watches for it and starts umbrel-guardian-backup.service.  No sudo needed.
cp "$INSTALL_DIR/services/umbrel-guardian-backup-trigger.path" "$SYSTEMD_DIR/"

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

if [ -n "${BACKUP_PATH:-}" ]; then
    systemctl enable --now umbrel-guardian-backup.timer
    systemctl enable --now umbrel-guardian-backup-trigger.path
    if [[ "${AUTO_MOUNT:-n}" =~ ^[Yy] ]]; then
        systemctl enable --now umbrel-guardian-mount-backup.service 2>/dev/null || true
    fi
fi

echo "✅ Systemd services reinstalled and enabled."

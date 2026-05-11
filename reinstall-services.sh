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

# ── Python dependency check ──────────────────────────────────────────────────
# Umbrel OS major upgrades bump Python (e.g. 3.11 → 3.13 between 1.5 and 1.7.2),
# which loses prior pip-installed packages. Re-ensure `requests` is importable.
if ! python3 -c "import requests" &>/dev/null; then
    echo "  ⚠️  python3 requests module missing — installing..."
    if apt-get install -y python3-requests &>/dev/null; then
        echo "  ✅ Installed python3-requests via apt"
    elif python3 -m pip install --quiet --break-system-packages requests &>/dev/null; then
        echo "  ✅ Installed requests via pip (--break-system-packages)"
    else
        echo "  ❌ Could not install requests. Bot service will fail."
        echo "     Try manually: sudo apt install python3-requests"
    fi
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

# ── Deploy OTA-recovery hook ─────────────────────────────────────────────────
# Umbrel 1.7.x looks for /home/umbrel/umbrel/custom-hooks/pre-start at boot.
# That directory is bind-mounted from the persistent data partition, so the
# hook survives OTA. On each boot, the hook re-runs this script if Guardian's
# units are missing.
if [ -f "$INSTALL_DIR/custom-hooks/pre-start" ]; then
    mkdir -p "$CUSTOM_HOOKS_DIR"
    cp "$INSTALL_DIR/custom-hooks/pre-start" "$CUSTOM_HOOKS_DIR/pre-start"
    chmod +x "$CUSTOM_HOOKS_DIR/pre-start"
    chown -R umbrel:umbrel "$CUSTOM_HOOKS_DIR"
    echo "  ✅ Deployed OTA-recovery hook → $CUSTOM_HOOKS_DIR/pre-start"
else
    echo "  ⚠️  custom-hooks/pre-start not found in install dir — OTA recovery disabled"
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

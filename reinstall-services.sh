#!/usr/bin/env bash
# Umbrel Guardian — Re-install systemd services from persistent storage.
#
# Umbrel OS uses A/B root partitions. On OTA updates the root filesystem
# is replaced, wiping /etc/systemd/system/. The Guardian install dir at
# /home/umbrel/umbrel/umbrel-guardian/ survives because /home is bind-mounted
# from the persistent data partition.
#
# Run this after an OTA update to restore Guardian services:
#   sudo bash /home/umbrel/umbrel/umbrel-guardian/reinstall-services.sh
#
# Or call it from install.sh with --headless to skip prompts.

set -euo pipefail

INSTALL_DIR="/home/umbrel/umbrel/umbrel-guardian"
SYSTEMD_DIR="/etc/systemd/system"
CONFIG="$INSTALL_DIR/config.env"

if [ ! -f "$CONFIG" ]; then
    echo "❌ config.env not found at $CONFIG"
    echo "   Run install.sh first to set up Umbrel Guardian."
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG"

echo "🛡 Umbrel Guardian — Reinstalling systemd services..."

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
    sed "s|^After=.*|&\nConditionPathIsMountPoint=${BACKUP_PATH}|" \
        "$INSTALL_DIR/services/umbrel-guardian-backup.service" \
        > "$SYSTEMD_DIR/umbrel-guardian-backup.service"

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

# Bootstrap service — ensures Guardian survives future OTA updates too
cat > "$SYSTEMD_DIR/umbrel-guardian-bootstrap.service" <<'UNIT'
[Unit]
Description=Umbrel Guardian Bootstrap (re-install services after OTA update)
DefaultDependencies=no
Before=umbrel-guardian-bot.service umbrel-guardian-health.timer
After=local-fs.target
ConditionPathExists=/home/umbrel/umbrel/umbrel-guardian/config.env
ConditionPathExists=!/etc/systemd/system/umbrel-guardian-bot.service

[Service]
Type=oneshot
ExecStart=/bin/bash /home/umbrel/umbrel/umbrel-guardian/reinstall-services.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

# Clean up old sudoers entry if present (no longer needed — using .path unit now)
rm -f /etc/sudoers.d/umbrel-guardian 2>/dev/null || true

# Manual backup trigger — the bot touches .backup-trigger, this .path unit
# watches for it and starts umbrel-guardian-backup.service.  No sudo needed.
cp "$INSTALL_DIR/services/umbrel-guardian-backup-trigger.path" "$SYSTEMD_DIR/"

systemctl daemon-reload
systemctl enable umbrel-guardian-bootstrap.service  2>/dev/null || true
systemctl enable --now umbrel-guardian-health.timer
systemctl enable --now umbrel-guardian-bot.service
systemctl enable --now umbrel-guardian-daily.timer

if [ -n "${BACKUP_PATH:-}" ]; then
    systemctl enable --now umbrel-guardian-backup.timer
    systemctl enable --now umbrel-guardian-backup-trigger.path
    if [[ "${AUTO_MOUNT:-n}" =~ ^[Yy] ]]; then
        systemctl enable --now umbrel-guardian-mount-backup.service 2>/dev/null || true
    fi
fi

echo "✅ Systemd services reinstalled and enabled."

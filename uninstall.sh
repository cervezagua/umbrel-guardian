#!/usr/bin/env bash
# Umbrel Guardian — Uninstaller
set -euo pipefail

INSTALL_DIR="/home/umbrel/umbrel/umbrel-guardian"

echo "🛡 Umbrel Guardian — Uninstaller"
echo
read -rp "This will stop and remove Umbrel Guardian. Continue? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { echo "Aborted."; exit 0; }

echo "Stopping services..."
for svc in umbrel-guardian-bot umbrel-guardian-health.timer umbrel-guardian-daily.timer umbrel-guardian-backup.timer umbrel-guardian-backup-trigger.path umbrel-guardian-mount-backup umbrel-guardian-bootstrap; do
    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done

echo "Removing systemd unit files..."
rm -f /etc/systemd/system/umbrel-guardian-*.service
rm -f /etc/systemd/system/umbrel-guardian-*.timer
rm -f /etc/systemd/system/umbrel-guardian-*.path
systemctl daemon-reload

echo "Removing udev rule and mount script..."
rm -f /etc/udev/rules.d/99-umbrel-backup.rules
rm -f /usr/local/bin/mount-umbrel-backup.sh
udevadm control --reload-rules 2>/dev/null || true

echo "Removing sudoers entry..."
rm -f /etc/sudoers.d/umbrel-guardian

echo "Removing installation directory..."
rm -rf "$INSTALL_DIR"

echo
echo "✅ Umbrel Guardian has been removed."

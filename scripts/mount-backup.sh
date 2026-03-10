#!/usr/bin/env bash
# Mount the backup drive by filesystem label.
# Called by: udev rule (hot-plug), systemd boot service, backup.sh (safety net).
# Idempotent — exits cleanly if already mounted or no drive found.
#
# Placeholders @@BACKUP_PATH@@ and @@INSTALL_DIR@@ are patched by
# reinstall-services.sh when deploying to /usr/local/bin/.

set -uo pipefail

LABEL="umbrel-backup"
MOUNTPOINT="@@BACKUP_PATH@@"

# Find device by filesystem label
DEV=$(blkid -L "$LABEL" 2>/dev/null || true)
if [ -z "$DEV" ]; then
    logger -t umbrel-guardian "mount-backup: no device with label '$LABEL' — skipping"
    exit 0
fi

mkdir -p "$MOUNTPOINT"

if mountpoint -q "$MOUNTPOINT"; then
    logger -t umbrel-guardian "mount-backup: $MOUNTPOINT is already mounted"
    exit 0
fi

if mount "$DEV" "$MOUNTPOINT"; then
    chown umbrel:umbrel "$MOUNTPOINT"
    logger -t umbrel-guardian "mount-backup: mounted $DEV at $MOUNTPOINT"
else
    logger -t umbrel-guardian "mount-backup: FAILED to mount $DEV at $MOUNTPOINT"
    exit 1
fi

# Best-effort Telegram notification — skip during early boot when bot isn't up yet
SEND="@@INSTALL_DIR@@/scripts/telegram_send.sh"
if [ -x "$SEND" ] && [ -d /run/systemd/system ] && systemctl is-active --quiet umbrel-guardian-bot.service 2>/dev/null; then
    "$SEND" "🔌 Backup drive mounted at $MOUNTPOINT" || true
fi

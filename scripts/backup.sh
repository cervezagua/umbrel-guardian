#!/usr/bin/env bash
# Backup Umbrel app data to an external drive using rsync.
# Validates that the drive is mounted before starting.
# Uses atomic staging (.tmp) so a failed rsync leaves no orphaned directories.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$(dirname "$SCRIPT_DIR")/config.env"
SEND="$SCRIPT_DIR/telegram_send.sh"

source "$CONFIG"

# Remove trigger file so the systemd .path unit resets for the next manual /backup
rm -f "$(dirname "$SCRIPT_DIR")/.backup-trigger" 2>/dev/null || true

UMBREL_SRC="${UMBREL_DIR:-/home/umbrel/umbrel}"
DEST_BASE="${BACKUP_PATH:-}"
# Lock file must be under INSTALL_DIR — the bot service uses ProtectSystem=strict
# which makes /run read-only. The install dir is in ReadWritePaths.
LOCK="$(dirname "$SCRIPT_DIR")/.backup.lock"

# Safety net: attempt to mount the backup drive if not already mounted.
# The mount script is idempotent — exits cleanly if already mounted or no drive.
if [ -x /usr/local/bin/mount-umbrel-backup.sh ]; then
    /usr/local/bin/mount-umbrel-backup.sh || true
fi

# ── Validation ──────────────────────────────────────────────────────────────
if [ -z "$DEST_BASE" ]; then
    "$SEND" "⚠️ Backup skipped: BACKUP_PATH is not set in config.env"
    exit 1
fi

# Require an actual mount — reject plain directories to avoid
# accidentally filling the SD card / root filesystem.
if ! mountpoint -q "$DEST_BASE"; then
    "$SEND" "⚠️ Backup skipped: $DEST_BASE is not a mounted drive.
Plug in the backup drive and mount it first."
    exit 0
fi

# ── Overlap lock ────────────────────────────────────────────────────────────
# Prevents concurrent backup runs (e.g. manual /backup while timer is active)
exec 9>"$LOCK"
if ! flock -n 9; then
    "$SEND" "⚠️ Backup skipped: another backup is already running."
    exit 0
fi

# ── Run backup ──────────────────────────────────────────────────────────────
DATE=$(date +%Y-%m-%d_%H%M)
DEST="$DEST_BASE/umbrel-backup-$DATE"

# Determine what to back up based on config
SCOPE="${BACKUP_SCOPE:-essential}"

case "$SCOPE" in
    full)
        # Full clone — mirror the entire Umbrel directory, nothing excluded.
        # This is a true disk clone: large and slow, but fully restorable.
        # rsync --delete removes files on the destination that no longer exist at source.
        FULL_CLONE=true
        ;;
    *)
        # Essential: the three directories needed to restore apps and their settings.
        # Fast, small, sufficient for the vast majority of recovery scenarios.
        FULL_CLONE=false
        SOURCES=(
            "$UMBREL_SRC/app-data"
            "$UMBREL_SRC/db"
            "$UMBREL_SRC/secrets"
        )
        ;;
esac

START=$(date +%s)
RSYNC_EXIT=0
RSYNC_LOG="/tmp/umbrel-guardian-rsync.$$.log"

if [ "$FULL_CLONE" = true ]; then
    # Full mirror — rolling clone, no date-stamped subfolder.
    # Stage in a .tmp directory; rename only on success.
    DEST="$DEST_BASE/umbrel-full-clone"
    DEST_TMP="${DEST}.tmp"
    mkdir -p "$DEST_TMP"
    ionice -c2 -n7 nice -n 10 \
        rsync -a --delete "$UMBREL_SRC/" "$DEST_TMP/" >"$RSYNC_LOG" 2>&1 || RSYNC_EXIT=$?
    if [ "$RSYNC_EXIT" -eq 0 ]; then
        rm -rf "$DEST"
        mv "$DEST_TMP" "$DEST"
    else
        rm -rf "$DEST_TMP"
    fi
else
    # Essential — stage in a .tmp subdirectory; rename on success.
    DEST_TMP="${DEST}.tmp"
    mkdir -p "$DEST_TMP"
    ionice -c2 -n7 nice -n 10 \
        rsync -a --delete "${SOURCES[@]}" "$DEST_TMP/" >"$RSYNC_LOG" 2>&1 || RSYNC_EXIT=$?
    if [ "$RSYNC_EXIT" -eq 0 ]; then
        mv "$DEST_TMP" "$DEST"
    else
        rm -rf "$DEST_TMP"
    fi
fi

END=$(date +%s)
ELAPSED=$(( END - START ))

# ── Report failure and exit early if rsync failed ───────────────────────────
if [ "$RSYNC_EXIT" -ne 0 ]; then
    # Include last few lines of rsync output to help diagnose the failure
    RSYNC_ERR=$(tail -5 "$RSYNC_LOG" 2>/dev/null || echo "(no log)")
    rm -f "$RSYNC_LOG"
    "$SEND" "⚠️ Backup FAILED (rsync exit ${RSYNC_EXIT})
📁 Destination: $DEST_BASE
🗂 Scope: $SCOPE
⏱ Duration: ${ELAPSED}s
📋 rsync output:
${RSYNC_ERR}"
    exit 1
fi

rm -f "$RSYNC_LOG"

# Use df (instant) instead of du -sh (walks every file — 30+ min on 474GB over USB)
SIZE=$(df -h "$DEST" | awk 'NR==2{print $3}')

# ── Retention: keep only the N most recent essential backups ────────────────
# Full clone is a rolling mirror so it never accumulates — no cleanup needed.
if [ "$FULL_CLONE" = false ]; then
    KEEP="${BACKUP_KEEP:-3}"
    # List all essential backup dirs sorted newest-first, skip the first $KEEP
    mapfile -t OLD_BACKUPS < <(
        ls -dt "$DEST_BASE"/umbrel-backup-* 2>/dev/null | tail -n +$(( KEEP + 1 ))
    )
    DELETED=0
    for OLD in "${OLD_BACKUPS[@]}"; do
        rm -rf "$OLD"
        DELETED=$(( DELETED + 1 ))
    done
fi

# ── Build completion message ─────────────────────────────────────────────────
MSG="✅ Backup complete
📁 Location: $DEST
📦 Size: $SIZE
🗂 Scope: $SCOPE
⏱ Duration: ${ELAPSED}s"

if [ "$FULL_CLONE" = false ] && [ "${DELETED:-0}" -gt 0 ]; then
    MSG="$MSG
🗑 Pruned: ${DELETED} old backup(s) removed (keeping last ${KEEP})"
fi

"$SEND" "$MSG"

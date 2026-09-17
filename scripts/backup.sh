#!/usr/bin/env bash
# Backup Umbrel app data to an external drive using rsync.
# Validates that the drive is mounted before starting.
#
# Essential scope — date-stamped snapshots, staged in a .tmp directory and
#   renamed on success, so a failed run leaves no half-written snapshot behind.
#
# Full scope — a rolling mirror written in place, guarded by an .incomplete
#   marker file. Writing in place is what makes the clone incremental (rsync
#   only ships what changed) and keeps the drive requirement at 1x the source
#   instead of 2x. See the comment above the full-clone branch.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$(dirname "$SCRIPT_DIR")/config.env"
SEND="$SCRIPT_DIR/telegram_send.sh"

# shellcheck source=/dev/null
source "$CONFIG"
# Shared with verify_backup.sh — defines what is in scope and what is excluded.
#
# Hard-fail if it is missing. Without it the exclude list comes out EMPTY and the
# clone happily copies external/ — the backup drive umbrelOS may have mounted
# inside the source — into itself, while still reporting "Backup complete". A
# partial deploy is exactly how that happens, and a backup that looks successful
# and is not is worse than one that refuses to run.
if [ ! -r "$SCRIPT_DIR/lib-backup-scope.sh" ]; then
    "$SEND" "⚠️ Backup ABORTED: scripts/lib-backup-scope.sh is missing or unreadable.
It defines which paths are excluded — without it the clone could copy the backup
drive into itself. Guardian looks partially deployed.
Re-deploy: sudo bash $(dirname "$SCRIPT_DIR")/reinstall-services.sh"
    exit 1
fi
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib-backup-scope.sh"

# A truncated or half-written file sources without error but defines nothing,
# which fails the same silent way. Assert the contract, not just the file.
for _fn in guardian_full_clone_excludes guardian_db_excludes guardian_as_rsync_args; do
    if ! declare -F "$_fn" >/dev/null 2>&1; then
        "$SEND" "⚠️ Backup ABORTED: lib-backup-scope.sh loaded but $_fn is undefined.
The file looks truncated or corrupt. Re-deploy Guardian before backing up again."
        exit 1
    fi
done

# Remove trigger file so the systemd .path unit resets for the next manual /backup
rm -f "$(dirname "$SCRIPT_DIR")/.backup-trigger" 2>/dev/null || true

UMBREL_SRC="${UMBREL_DIR:-/home/umbrel/umbrel}"
DEST_BASE="${BACKUP_PATH:-}"
# Lock file must be under INSTALL_DIR — the bot service uses ProtectSystem=strict
# which makes /run read-only. The install dir is in ReadWritePaths.
LOCK="$(dirname "$SCRIPT_DIR")/.backup.lock"

# Full rsync output. Kept at LAST_LOG after a failure — the Telegram message can
# only carry an excerpt, and the real cause is often dozens of lines up.
# *.log is gitignored, so this never dirties the install dir.
RSYNC_LOG="/tmp/umbrel-guardian-rsync.$$.log"
LAST_LOG="$(dirname "$SCRIPT_DIR")/last-backup-rsync.log"

# Give up if the drive stops responding for this long, instead of hanging
# until the next backup window. Generous — a healthy drive never stalls 15 min.
RSYNC_TIMEOUT=900

# Format a byte count for humans: 4096 → 4.0K
human() {
    awk -v b="${1:-0}" 'BEGIN{
        split("B K M G T P", u, " "); i = 1
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        printf (i == 1 ? "%d%s" : "%.1f%s"), b, u[i]
    }'
}

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

# The destination must not live inside the source. rsync would copy the backup
# into itself, recursing until the drive fills and the receiver dies mid-write.
#
# This only catches BACKUP_PATH being configured inside UMBREL_DIR. It cannot
# see the same physical drive mounted a second time at a path inside the source
# — which is exactly what umbrelOS does, mounting external drives under
# UMBREL_DIR/external/. That case is handled by the mount excludes further down,
# not here.
case "${DEST_BASE%/}/" in
    "${UMBREL_SRC%/}"/*)
        "$SEND" "⚠️ Backup skipped: BACKUP_PATH ($DEST_BASE) is inside UMBREL_DIR ($UMBREL_SRC).
The backup would copy itself and fill the drive.
Point BACKUP_PATH at a separate drive."
        exit 1
        ;;
esac

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
        # Essential: what is actually needed to restore apps and their settings.
        # Fast, small, sufficient for the vast majority of recovery scenarios.
        #
        # umbrel.yaml is not optional despite its size. It is umbreld's store
        # (dataDirectory/umbrel.yaml) and holds the installed-app list, the owner
        # account with its password hash and TOTP secret, member accounts, widgets,
        # shortcuts and the wifi/hostname/static-IP settings. Without it a restore
        # comes back up as a node that believes no apps are installed and has no
        # user account — app-data on disk that nothing knows how to launch.
        #
        # db/ survives despite now holding almost nothing: db/umbrel-seed/seed is
        # what every app's passwords are derived from.
        #
        # Paths are existence-tested rather than hardcoded so one code path stays
        # correct across umbrelOS versions (members/ is 2.0-only, and rsync fails
        # the whole run on a missing source argument).
        FULL_CLONE=false
        SOURCES=()
        for CANDIDATE in app-data db secrets umbrel.yaml members; do
            [ -e "$UMBREL_SRC/$CANDIDATE" ] && SOURCES+=("$UMBREL_SRC/$CANDIDATE")
        done

        # home/ is the owner's Files and Photos data. Off by default: it can be
        # tens of GB, and essential keeps BACKUP_KEEP dated snapshots, so silently
        # including it would multiply both the runtime and the space this scope
        # was chosen to avoid. The full clone always covers it.
        if [ "${BACKUP_ESSENTIAL_INCLUDE_HOME:-n}" = "y" ] && [ -d "$UMBREL_SRC/home" ]; then
            SOURCES+=("$UMBREL_SRC/home")
        fi

        if [ "${#SOURCES[@]}" -eq 0 ]; then
            "$SEND" "⚠️ Backup skipped: none of the expected Umbrel data directories
exist under $UMBREL_SRC. Is UMBREL_DIR set correctly in config.env?"
            exit 1
        fi
        ;;
esac

# ── Pre-flight capacity check (full clone only) ─────────────────────────────
# A full clone that cannot possibly fit should fail in seconds, not two hours
# in when the drive fills and rsync's receiver dies with a broken pipe.
# df only, never du — du -s on a 500 GB tree over USB takes 30+ minutes.
# The source filesystem's used space is a safe upper bound for UMBREL_DIR.
if [ "$FULL_CLONE" = true ] && [ "${BACKUP_SKIP_SPACE_CHECK:-n}" != "y" ]; then
    SRC_USED_KB=$(df -Pk "$UMBREL_SRC" 2>/dev/null | awk 'NR==2{print $3}')
    DEST_SIZE_KB=$(df -Pk "$DEST_BASE" 2>/dev/null | awk 'NR==2{print $2}')
    if [[ "$SRC_USED_KB" =~ ^[0-9]+$ ]] && [[ "$DEST_SIZE_KB" =~ ^[0-9]+$ ]] &&
       [ "$DEST_SIZE_KB" -lt $(( SRC_USED_KB + SRC_USED_KB / 20 )) ]; then
        "$SEND" "⚠️ Backup skipped: the backup drive is too small for a full clone.
📁 Destination: $DEST_BASE
📦 Source data: $(human $(( SRC_USED_KB * 1024 )))
💽 Drive capacity: $(human $(( DEST_SIZE_KB * 1024 )))
Switch to BACKUP_SCOPE=essential, or fit a larger drive.
(To run anyway, set BACKUP_SKIP_SPACE_CHECK=y in config.env.)"
        exit 1
    fi
fi

START=$(date +%s)
RSYNC_EXIT=0
RESUMED=false

# --timeout turns a wedged drive into a clean failure.
# --stats gives us the bytes actually transferred for the completion message.
RSYNC_OPTS=( -a --timeout="$RSYNC_TIMEOUT" --stats )

# ── Full-clone excludes ─────────────────────────────────────────────────────
# Defined in lib-backup-scope.sh so verify_backup.sh reads the same list. If the
# two ever diverged, every path they disagreed on would surface as phantom drift
# and a perfectly good backup would be reported as broken.
mapfile -t RSYNC_EXCLUDES < <(
    guardian_full_clone_excludes "${BACKUP_EXCLUDE_CHURN:-y}" | guardian_as_rsync_args
)

# umbrel.db is umbreld's SQLite database, introduced after 1.7.x. A live copy of
# it alongside its -wal and -shm is not a consistent snapshot, so we exclude all
# of them from the transfer and write a proper snapshot afterwards instead. On a
# version that has no umbrel.db this adds nothing and nothing changes.
UMBREL_DB="$UMBREL_SRC/umbrel.db"
SNAPSHOT_DB=false
if [ "$FULL_CLONE" = true ] && [ -f "$UMBREL_DB" ]; then
    SNAPSHOT_DB=true
    mapfile -t -O "${#RSYNC_EXCLUDES[@]}" RSYNC_EXCLUDES < <(
        guardian_db_excludes "$UMBREL_SRC" | guardian_as_rsync_args
    )
fi

if [ "$FULL_CLONE" = true ]; then
    # Rolling mirror, written in place — no .tmp staging.
    #
    # Staging a full clone in a .tmp directory looks safer but breaks the clone
    # in two ways. It needs the drive to hold two complete copies at once (the
    # previous clone is only deleted after the new one finishes), and because
    # .tmp starts empty every run re-copies the entire tree from scratch —
    # discarding it all on failure, so a run that dies at hour two makes no
    # progress and the next night fails in exactly the same place.
    #
    # In place, rsync ships only what changed and a partial mirror is left for
    # the next run to finish. The .incomplete marker records that the mirror is
    # mid-update, since the directory itself no longer tells us.
    DEST="$DEST_BASE/umbrel-full-clone"
    MARKER="${DEST}.incomplete"
    mkdir -p "$DEST"

    [ -f "$MARKER" ] && RESUMED=true
    : > "$MARKER"

    # --delete-excluded, not just --delete. rsync protects excluded paths that
    # already exist on the destination, so without it a mirror made before these
    # excludes existed would keep its copy of external/, app-stores/ and kopia/
    # forever — stale data that a future restore would trust. This only ever
    # deletes from the backup drive; the source is opened read-only.
    ionice -c2 -n7 nice -n 10 \
        rsync "${RSYNC_OPTS[@]}" "${RSYNC_EXCLUDES[@]}" --delete-during --delete-excluded \
            "$UMBREL_SRC/" "$DEST/" >"$RSYNC_LOG" 2>&1 || RSYNC_EXIT=$?
else
    # Essential — stage in a .tmp subdirectory; rename on success.
    # Snapshots are small and date-stamped, so discarding a failed one and
    # starting over next run costs minutes, not hours.
    DEST_TMP="${DEST}.tmp"
    mkdir -p "$DEST_TMP"
    ionice -c2 -n7 nice -n 10 \
        rsync "${RSYNC_OPTS[@]}" --delete "${SOURCES[@]}" "$DEST_TMP/" >"$RSYNC_LOG" 2>&1 || RSYNC_EXIT=$?
fi

END=$(date +%s)
ELAPSED=$(( END - START ))

# ── Classify the rsync exit code ────────────────────────────────────────────
# Not every non-zero exit means the backup is unusable:
#   24 — source files vanished while rsync was reading them. Routine on a live
#        Umbrel: containers rewrite logs and databases during the copy.
#   23 — some files could not be transferred (usually permissions). The rest of
#        the backup is intact and worth keeping; surfaced as a warning.
RSYNC_WARN=""
case "$RSYNC_EXIT" in
    24)
        RSYNC_WARN="⚠️ Some files vanished mid-copy (apps were writing) — normal, backup kept"
        RSYNC_EXIT=0
        ;;
    23)
        RSYNC_WARN="⚠️ Some files could not be transferred — backup kept, see $LAST_LOG"
        cp -f "$RSYNC_LOG" "$LAST_LOG" 2>/dev/null || true
        RSYNC_EXIT=0
        ;;
esac

# ── Consistent umbrel.db snapshot ───────────────────────────────────────────
# Runs only when rsync succeeded, and before the .incomplete marker is cleared,
# so a mirror is never advertised as restorable with a missing or torn database.
# sqlite3's .backup uses the online backup API: it takes the same locks the
# database itself uses and produces a file that is consistent even though
# umbreld is still writing.
DB_WARN=""
if [ "$SNAPSHOT_DB" = true ] && [ "$RSYNC_EXIT" -eq 0 ]; then
    if command -v sqlite3 &>/dev/null &&
       sqlite3 "$UMBREL_DB" ".backup '$DEST/umbrel.db'" 2>>"$RSYNC_LOG"; then
        # Stale -wal/-shm beside a fresh snapshot would be read on restore and
        # could roll the database back to the previous state.
        rm -f "$DEST/umbrel.db-wal" "$DEST/umbrel.db-shm" "$DEST/umbrel.db-journal"
    else
        # Better a torn copy than no database at all — without it the restore has
        # nothing to promote. Say so plainly rather than failing the whole run.
        cp -f "$UMBREL_DB" "$DEST/umbrel.db" 2>>"$RSYNC_LOG" || true
        if command -v sqlite3 &>/dev/null; then
            DB_WARN="⚠️ umbrel.db snapshot failed — copied live instead, may be inconsistent"
        else
            DB_WARN="⚠️ sqlite3 not installed — umbrel.db copied live, may be inconsistent"
        fi
    fi
fi

# ── Promote or clean up staged data ─────────────────────────────────────────
if [ "$FULL_CLONE" = true ]; then
    # Marker stays on failure: the mirror is mid-update and must not be trusted
    # for a restore. The partial data stays too — that is what the next run
    # resumes from.
    [ "$RSYNC_EXIT" -eq 0 ] && rm -f "$MARKER"
elif [ "$RSYNC_EXIT" -eq 0 ]; then
    mv "$DEST_TMP" "$DEST"
else
    rm -rf "$DEST_TMP"
fi

# ── Report failure and exit early if rsync failed ───────────────────────────
if [ "$RSYNC_EXIT" -ne 0 ]; then
    cp -f "$RSYNC_LOG" "$LAST_LOG" 2>/dev/null || true

    # Lead with the FIRST error, not the last lines. A failed local rsync always
    # ends with the same socket-IO trailer (broken pipe / SIGUSR1), which says
    # only that the receiving process died — never why. The reason is printed
    # earlier, and a plain tail throws it away.
    CAUSE=$(grep -aiE 'no space left|input/output error|read-only file system|permission denied|cannot |failed to' \
        "$RSYNC_LOG" 2>/dev/null | head -3)
    [ -z "$CAUSE" ] && CAUSE=$(grep -a '^rsync' "$RSYNC_LOG" 2>/dev/null | head -3)
    # Nothing matched — fall back to the tail so an unrecognised failure
    # (a missing binary, a kernel message) still reaches the notification.
    [ -z "$CAUSE" ] && CAUSE=$(tail -3 "$RSYNC_LOG" 2>/dev/null)
    [ -z "$CAUSE" ] && CAUSE="(no rsync output)"

    FREE=$(df -Ph "$DEST_BASE" 2>/dev/null | awk 'NR==2{print $4" free of "$2}')

    case "$RSYNC_EXIT" in
        10|12)
            HINT="The receiving side died mid-transfer. Usual causes: the drive filled up, the USB drive dropped off the bus, or the kernel OOM-killed rsync. Check: dmesg | tail -40" ;;
        11)
            HINT="Could not write to the destination — drive full, mounted read-only, or failing." ;;
        30)
            HINT="The drive stopped responding for ${RSYNC_TIMEOUT}s — likely a USB link reset. Check: dmesg | tail -40" ;;
        *)
            HINT="" ;;
    esac

    MSG="⚠️ Backup FAILED (rsync exit ${RSYNC_EXIT})
📁 Destination: $DEST_BASE
🗂 Scope: $SCOPE
⏱ Duration: ${ELAPSED}s
💽 Drive: ${FREE:-unknown}
📋 First error:
${CAUSE}"

    [ -n "$HINT" ] && MSG="$MSG
💡 $HINT"

    if [ "$FULL_CLONE" = true ]; then
        MSG="$MSG
🔁 Partial mirror kept — the next run resumes from where this one stopped."
    fi

    MSG="$MSG
📄 Full log: $LAST_LOG"

    rm -f "$RSYNC_LOG"
    "$SEND" "$MSG"
    exit 1
fi

# Bytes actually shipped this run — for a rolling mirror this is the useful
# number, and it is near-zero when nothing changed.
XFER_BYTES=$(awk -F: '/^Total transferred file size:/{gsub(/[^0-9]/, "", $2); print $2; exit}' "$RSYNC_LOG" 2>/dev/null)
rm -f "$RSYNC_LOG"

# Use df (instant) instead of du -sh (walks every file — 30+ min on 474GB over USB)
USED=$(df -h "$DEST" | awk 'NR==2{print $3}')

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
💽 Drive used: $USED
🗂 Scope: $SCOPE
⏱ Duration: ${ELAPSED}s"

if [ -n "${XFER_BYTES:-}" ]; then
    MSG="$MSG
📦 Transferred: $(human "$XFER_BYTES")"
fi

if [ "$RESUMED" = true ]; then
    MSG="$MSG
🔁 Finished a mirror left partial by the previous run"
fi

if [ "$FULL_CLONE" = false ] && [ "${DELETED:-0}" -gt 0 ]; then
    MSG="$MSG
🗑 Pruned: ${DELETED} old backup(s) removed (keeping last ${KEEP})"
fi

if [ -n "$RSYNC_WARN" ]; then
    MSG="$MSG
$RSYNC_WARN"
fi

if [ -n "$DB_WARN" ]; then
    MSG="$MSG
$DB_WARN"
fi

"$SEND" "$MSG"

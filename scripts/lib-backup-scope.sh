#!/usr/bin/env bash
# Shared definition of WHAT gets backed up.
#
# Sourced by backup.sh (which does the copying) and verify_backup.sh (which
# checks the result). It exists so those two cannot disagree: if verify used its
# own copy of the exclude list, every path the two lists differed on would show
# up as phantom drift, and a backup that is actually fine would be reported as
# broken. One definition, two readers.
#
# Sourcing only defines functions — nothing here runs on its own or touches the
# filesystem.

# Excludes for the full clone, one per line on stdout.
#
# Every pattern is anchored with a leading slash so it matches only at the top
# of the transfer root. Without the anchor, "external" would also match an app's
# own app-data/<app>/external directory.
#
# Args: $1 = "y"/"n" for whether to include the churn excludes.
guardian_full_clone_excludes() {
    local include_churn="${1:-y}"

    # MOUNT POINTS — never optional, because this is a correctness property.
    #
    # umbrelOS mounts things *inside* the directory we are backing up:
    #   external/<Label>  every external USB drive (files.ts: '/External')
    #   network/          mounted NAS/SMB shares   (files.ts: '/Network')
    #   backups/          umbrelOS's own backup repo mount
    #
    # The external auto-mount is not gated on Raspberry Pi — the "not supported
    # on Pi" screen in the UI covers only choosing an external drive as a
    # *backup destination*. Files mounts any USB partition that is not already
    # mounted, deciding by whether the partition already has a mountpoint.
    # Guardian's udev rule usually wins that race, which is the only reason the
    # backup drive normally lands outside the source tree. umbrelOS mounts on a
    # D-Bus device event with no polling and no retry, so the race is not ours
    # to rely on: if it ever wins, the backup drive appears at external/<Label>
    # and a full clone copies the backup into itself until the drive fills.
    #
    # Backing up other people's drives and NAS shares would be wrong even if it
    # were safe, so these stay excluded regardless.
    echo "/external/"
    echo "/network/"
    echo "/backups/"

    # CHURN — mirrors umbrelOS's own .kopiaignore. Everything here is either a
    # regenerable cache, an incomplete staging copy, or per-device material that
    # a restore recreates anyway; copying it burns USB write cycles and backup
    # window for data that would be discarded on restore. Upstream additionally
    # notes that machines/*/media can contain password hashes and Windows
    # product keys.
    if [ "$include_churn" = "y" ]; then
        echo "/app-stores/"
        echo "/thumbnails/"
        echo "/file-index/"
        echo "/kopia/"
        echo "/.temporary-migration/"
        echo "/app-data/*/.data-moving-*"
        echo "/machine-images/"
        echo "/machines/*/operations"
        echo "/machines/*/media"
        echo "/lan-ingress/"
    fi
}

# The SQLite database, WAL and shared-memory files, excluded from the transfer
# so a consistent snapshot can be written separately. Upstream excludes exactly
# these from its own backups because they "cannot be copied independently while
# writes and checkpoints continue". Empty on versions with no umbrel.db.
guardian_db_excludes() {
    local src="$1"
    [ -f "$src/umbrel.db" ] || return 0
    echo "/umbrel.db"
    echo "/umbrel.db-wal"
    echo "/umbrel.db-shm"
    echo "/umbrel.db-journal"
}

# Turn the line-per-pattern output above into rsync --exclude= arguments.
# Usage: mapfile -t ARR < <(guardian_full_clone_excludes y | guardian_as_rsync_args)
guardian_as_rsync_args() {
    local pattern
    while IFS= read -r pattern; do
        [ -n "$pattern" ] && printf -- '--exclude=%s\n' "$pattern"
    done
}

# Files that must exist and be non-empty for a backup to actually restore.
#
# umbrel.yaml is umbreld's store: the installed-app list, the owner account and
# its password hash, member accounts, widgets, shortcuts and network settings.
# Without it a restore comes back as a node that believes no apps are installed
# and has no user account. db/umbrel-seed/seed is what every app's passwords are
# derived from. Both are small and easy to overlook, which is exactly why they
# are worth checking explicitly.
guardian_critical_paths() {
    echo "umbrel.yaml"
    echo "db/umbrel-seed/seed"
    echo "secrets"
    echo "app-data"
}

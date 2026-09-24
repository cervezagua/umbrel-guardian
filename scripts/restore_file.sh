#!/usr/bin/env bash
# Put a damaged config file back from the backup mirror.
#
# Usage:
#   restore_file.sh --list          ← what is damaged and recoverable
#   restore_file.sh <path>          ← restore one file, e.g. app-data/plex/settings.yml
#   restore_file.sh --all           ← restore everything recoverable
#
# ── Why this cannot restore an arbitrary path ────────────────────────────────
# It only ever restores a file the integrity checker has independently
# diagnosed as damaged on THIS NODE and intact in the mirror. The candidate
# list is computed; the argument selects from it and is validated in its own
# right. A restore tool that accepts any path can overwrite good data with old
# data, or be pointed outside the data directory entirely.
#
# An earlier version of this comment claimed selection alone made traversal
# impossible. It did not. Membership was tested with `grep -qxF "$TARGET"`,
# and grep -F treats a pattern containing newlines as SEVERAL patterns, any of
# which may match — so a two-line argument whose first line was a real
# candidate passed the check, and then every line got restored. A leading
# newline matched even an EMPTY candidate list, because the here-string
# supplies one empty line for the empty sub-pattern to match. Membership is an
# exact string comparison now, and paths are validated whatever list they came
# from, because a safety property that rests on one clever test is one edit
# away from not existing.
#
# ── Why the copy is not `cp` onto the destination ────────────────────────────
# cp writes THROUGH an existing destination symlink: it replaces the contents
# of whatever the link points at and leaves the link in place. Running as root
# against app-data/, which app containers are bind-mounted into, that turns a
# planted symlink into an arbitrary root-owned write. So symlinked destinations
# are refused outright, the copy lands on a temp file in the destination's own
# directory and is renamed into place, and ownership comes from the containing
# directory rather than from the mirror — a hostile source file should not get
# to choose who owns what replaces it.
#
# ── Why umbreld gets stopped ─────────────────────────────────────────────────
# umbrel.yaml is held open by umbreld, which rewrites it on shutdown. Restoring
# it underneath a running daemon means your good copy is overwritten by the
# broken in-memory state moments later. The correct sequence is stop, restore,
# start, and doing it wrong is exactly how an evening gets lost — so the script
# does it rather than explaining it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="$INSTALL_DIR/config.env"
CHECKER="$SCRIPT_DIR/lib-integrity.py"
BACKUP_DIR="$INSTALL_DIR/.state/restored"

# shellcheck source=/dev/null
[ -f "$CONFIG" ] && source "$CONFIG"

if [ ! -r "$SCRIPT_DIR/lib-backup-scope.sh" ]; then
    echo "⚠️ scripts/lib-backup-scope.sh is missing — cannot locate the mirror." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib-backup-scope.sh"

UMBREL_SRC="${UMBREL_DIR:-/home/umbrel/umbrel}"
DEST_BASE="${BACKUP_PATH:-}"
SCOPE="${BACKUP_SCOPE:-essential}"

# A plain relative path inside the data directory, and nothing else. Rejects
# absolute paths, "..", and anything outside a conservative character set —
# which also excludes the newline that defeated the old membership test.
safe_relpath() {
    local rel="$1" part
    [ -n "$rel" ] || return 1
    case "$rel" in /*) return 1 ;; esac
    [[ "$rel" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
    while IFS= read -r part; do
        [ "$part" = ".." ] && return 1
    done < <(printf '%s\n' "$rel" | tr '/' '\n')
    return 0
}

# Exact membership, one line at a time. grep -qxF looked equivalent and was not.
is_candidate() {
    local want="$1" line
    while IFS= read -r line; do
        [ -n "$line" ] && [ "$line" = "$want" ] && return 0
    done <<< "${CANDIDATES:-}"
    return 1
}

MODE="one"
TARGET=""
case "${1:-}" in
    --list) MODE="list" ;;
    --all)  MODE="all" ;;
    "")     echo "Usage: $0 [--list|--all|<path>]" >&2; exit 2 ;;
    -*)     echo "Usage: $0 [--list|--all|<path>]" >&2; exit 2 ;;
    *)      TARGET="$1" ;;
esac

if [ "$MODE" = "one" ] && ! safe_relpath "$TARGET"; then
    echo "❌ '$TARGET' is not a plain relative path inside the data directory." >&2
    exit 2
fi

if [ -z "$DEST_BASE" ]; then
    echo "ℹ️ Backups are not configured, so there is nothing to restore from."
    exit 1
fi
if ! mountpoint -q "$DEST_BASE" 2>/dev/null; then
    echo "❌ Backup drive is not mounted at $DEST_BASE — plug it in first."
    exit 1
fi

MIRROR=$(guardian_resolve_mirror "$DEST_BASE" "$SCOPE")
if [ -z "${MIRROR:-}" ] || [ ! -d "$MIRROR" ]; then
    echo "❌ No backup found under $DEST_BASE — nothing to restore from."
    exit 1
fi
if [ ! -r "$CHECKER" ]; then
    echo "⚠️ scripts/lib-integrity.py is missing — cannot tell what is damaged." >&2
    exit 1
fi

# ── Candidates ───────────────────────────────────────────────────────────────
# Only "source" verdicts: damaged here, good in the mirror. A "mirror" verdict
# means the node's copy is the good one and restoring would destroy it; "both"
# means neither copy is usable and the mirror has nothing to offer.
# Keep the whole diagnosis, not just the restorable subset. When someone asks
# for a file that cannot be restored, the reason is already in this output and
# telling them "nothing to do" instead would be both unhelpful and untrue.
DIAGNOSIS=$(timeout 60 python3 "$CHECKER" "$UMBREL_SRC" "$MIRROR" 2>/dev/null)
CANDIDATES=$(awk -F'\t' '$1=="BAD" && $3=="source" {print $2}' <<< "${DIAGNOSIS:-}")

verdict_for() { awk -F'\t' -v f="$1" '$1=="BAD" && $2==f {print $3; exit}' <<< "${DIAGNOSIS:-}"; }

if [ "$MODE" = "list" ]; then
    echo "🛟 Restorable from the backup"
    echo "━━━━━━━━━━━━━━━━━━"
    if [ -z "${CANDIDATES:-}" ]; then
        echo "  ✅ Nothing on this node is damaged-and-recoverable."
        echo "     (Files damaged in the BACKUP instead are listed by /verify_backup;"
        echo "      those need a new backup, not a restore.)"
        exit 0
    fi
    while IFS= read -r REL; do
        [ -n "$REL" ] && echo "  • $REL"
    done <<< "$CANDIDATES"
    echo ""
    echo "  Restore one:  $0 <path>"
    echo "  Restore all:  $0 --all"
    exit 0
fi

# A named target is answered on its own terms. Exiting 0 with "nothing to do"
# when someone asked for a specific file would report success for work that did
# not happen, and leave them believing a broken file was fixed.
if [ "$MODE" = "one" ]; then
    if ! is_candidate "$TARGET"; then
        case "$(verdict_for "$TARGET")" in
            mirror)
                echo "❌ '$TARGET' is damaged in the BACKUP, not on this node."
                echo "   This node has the good copy. Restoring would overwrite it with"
                echo "   the broken one. Run a backup instead to replace the bad copy." ;;
            source-nobackup)
                echo "❌ '$TARGET' is damaged on this node but is not in the backup at all."
                echo "   Nothing to restore from. If it is an app config, umbrelOS can"
                echo "   regenerate it from the app store template." ;;
            both)
                echo "❌ '$TARGET' is damaged on this node AND in the backup."
                echo "   There is no good copy to restore from. For an app config, umbrelOS"
                echo "   can regenerate it from the app store template." ;;
            *)
                echo "❌ '$TARGET' is not damaged, or is not a file this tool checks."
                echo "   Run '$0 --list' to see what can be restored." ;;
        esac
        exit 1
    fi
    CANDIDATES="$TARGET"
elif [ -z "${CANDIDATES:-}" ]; then
    echo "✅ Nothing is both damaged here and intact in the backup — nothing to do."
    exit 0
fi

# ── Can anything actually be written? ────────────────────────────────────────
# Asked BEFORE umbreld is stopped, and that ordering is the whole point.
#
# Invoked from the bot this script used to stop umbreld, fail every single write
# with EROFS, report "permission denied?", and start umbreld again — a restore
# that took the node's daemon down and restored nothing. The cause was never
# permissions: umbrel-guardian-bot.service sets ProtectSystem=strict, which
# mounts the entire hierarchy read-only apart from the Guardian directory, and
# that is a mount namespace, so sudo raises the uid but changes nothing about
# what is writable. (The bot now reaches this script through systemd-run, which
# PID 1 spawns outside that namespace.)
#
# A probe costs one mktemp per directory and turns an outage into a message.
can_write_dir() {
    local probe
    probe="$(mktemp "$1/.guardian-probe.XXXXXX" 2>&1)" || { INSTALL_ERR="$probe"; return 1; }
    rm -f "$probe"
    return 0
}

WRITABLE=0
INSTALL_ERR=""
while IFS= read -r REL; do
    [ -n "$REL" ] || continue
    _dir="$(dirname "$UMBREL_SRC/$REL")"
    [ -d "$_dir" ] || continue
    if can_write_dir "$_dir"; then WRITABLE=1; break; fi
done <<< "$CANDIDATES"

if [ "$WRITABLE" -eq 0 ]; then
    echo "❌ Nothing can be written under $UMBREL_SRC — stopping before anything is touched."
    [ -n "${INSTALL_ERR:-}" ] && echo "   The system said: ${INSTALL_ERR#mktemp: }"
    case "${INSTALL_ERR:-}" in
        *"Read-only file system"*)
            echo "   That is a read-only mount, not a permissions problem. A caller inside a"
            echo "   sandboxed systemd unit (ProtectSystem=strict) sees the filesystem this way"
            echo "   even as root; run this from a shell, or through systemd-run, as the bot does." ;;
        *"Permission denied"*)
            echo "   Run it as root: sudo $0 ${TARGET:---all}" ;;
    esac
    echo "   umbreld was NOT stopped and nothing was changed."
    exit 1
fi

# umbrel.yaml is rewritten by umbreld on shutdown, so restoring it under a live
# daemon means losing the good copy again minutes later.
NEEDS_UMBRELD_STOP=false
is_candidate "umbrel.yaml" && NEEDS_UMBRELD_STOP=true

UMBRELD_WAS_RUNNING=false
if [ "$NEEDS_UMBRELD_STOP" = true ]; then
    if [ "$EUID" -ne 0 ]; then
        echo "❌ Restoring umbrel.yaml means stopping umbreld first, which needs root."
        echo "   Run: sudo $0 ${TARGET:---all}"
        exit 1
    fi
    if systemctl is-active --quiet umbrel.service 2>/dev/null; then
        UMBRELD_WAS_RUNNING=true
        echo "⏸ Stopping umbreld so it cannot overwrite the restored file…"
        systemctl stop umbrel.service 2>/dev/null || true
    fi
fi

mkdir -p "$BACKUP_DIR" 2>/dev/null || true
RESTORED=0
FAILED=0
SRC_REAL="$(realpath -e "$UMBREL_SRC" 2>/dev/null || printf '%s' "$UMBREL_SRC")"

# Replace a file without ever writing through a link. Returns 2 when the
# destination, or any directory on the way to it, is a symlink or resolves
# outside the data directory.
# Failures here used to discard the operating system's own explanation and the
# caller reported "permission denied?" for every one of them. "Read-only file
# system" and "Permission denied" are different problems with different fixes,
# and guessing the wrong one sends someone to check ownership that was never
# wrong. The real message goes in INSTALL_ERR and the caller prints it.
install_file() {
    local src="$1" dst="$2" dir real tmp
    INSTALL_ERR=""
    dir="$(dirname "$dst")"
    [ -d "$dir" ] || { INSTALL_ERR="$dir does not exist"; return 1; }
    [ -L "$dst" ] && return 2
    # realpath resolves every component, so a symlinked PARENT is caught too.
    real="$(realpath -e "$dir" 2>/dev/null)" || { INSTALL_ERR="cannot resolve $dir"; return 1; }
    case "$real/" in
        "$SRC_REAL"/*) ;;
        *) return 2 ;;
    esac
    tmp="$(mktemp "$dir/.guardian-restore.XXXXXX" 2>&1)" || { INSTALL_ERR="${tmp#mktemp: }"; return 1; }
    # Deliberately not --preserve=ownership: the mirror copy is the thing that
    # may have been tampered with, and it does not get to decide who owns the
    # file that replaces the original.
    if ! INSTALL_ERR="$(cp --preserve=mode,timestamps "$src" "$tmp" 2>&1)"; then
        INSTALL_ERR="${INSTALL_ERR#cp: }"
        rm -f "$tmp"; return 1
    fi
    chown --reference="$dir" "$tmp" 2>/dev/null || true
    # rename(2) over the destination: atomic, and it cannot traverse a link.
    if ! INSTALL_ERR="$(mv -T "$tmp" "$dst" 2>&1)"; then
        INSTALL_ERR="${INSTALL_ERR#mv: }"
        rm -f "$tmp"; return 1
    fi
    INSTALL_ERR=""
    return 0
}

while IFS= read -r REL; do
    [ -n "$REL" ] || continue
    # Re-validated here as well as at the argument, so --all is protected no
    # matter how the candidate list was built.
    if ! safe_relpath "$REL"; then
        echo "❌ $REL: refused, not a plain path inside the data directory"
        FAILED=$((FAILED + 1)); continue
    fi
    SRC="$MIRROR/$REL"
    DST="$UMBREL_SRC/$REL"

    if [ ! -f "$SRC" ]; then
        echo "❌ $REL: not present in the backup after all — skipped"
        FAILED=$((FAILED + 1)); continue
    fi

    # Keep the broken copy. It costs a few kilobytes and it is the only
    # evidence of what went wrong if the restore turns out to be the wrong call.
    # -P so a symlinked original is preserved as a link rather than followed;
    # this keeps the evidence honest and avoids reading through it as root.
    if [ -e "$DST" ] || [ -L "$DST" ]; then
        KEEP="$BACKUP_DIR/$(echo "$REL" | tr '/' '_').$(date +%Y%m%d-%H%M%S).broken"
        cp -P --preserve=mode,timestamps "$DST" "$KEEP" 2>/dev/null || true
    fi

    install_file "$SRC" "$DST"
    case $? in
        0) ;;
        2) echo "❌ $REL: destination is a symlink or resolves outside $UMBREL_SRC — refused"
           echo "   A restore must not write through a link. Remove it and re-run."
           FAILED=$((FAILED + 1)); continue ;;
        *) echo "❌ $REL: could not write — ${INSTALL_ERR:-no reason reported} — skipped"
           case "${INSTALL_ERR:-}" in
               *"Read-only file system"*)
                   echo "   A read-only mount, not a permissions problem — see the probe note above." ;;
           esac
           FAILED=$((FAILED + 1)); continue ;;
    esac

    # Verify what actually landed. A copy that succeeded and produced an
    # unreadable file is worse than no restore at all, because it looks done.
    if python3 -c "import sys,yaml;yaml.safe_load(open(sys.argv[1],'rb').read().decode('utf-8'))" "$DST" 2>/dev/null; then
        echo "✅ $REL restored from the backup"
        RESTORED=$((RESTORED + 1))
    else
        echo "❌ $REL: the restored copy does not parse either — backup may be damaged too"
        FAILED=$((FAILED + 1))
    fi
done <<< "$CANDIDATES"

if [ "$UMBRELD_WAS_RUNNING" = true ]; then
    echo "▶️ Starting umbreld…"
    systemctl start umbrel.service 2>/dev/null || true
fi

echo ""
echo "Restored $RESTORED file(s), $FAILED failed."
[ "$RESTORED" -gt 0 ] && echo "Broken originals kept in $BACKUP_DIR"
[ "$FAILED" -eq 0 ]

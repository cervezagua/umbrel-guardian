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
# diagnosed as damaged on THIS NODE and intact in the mirror. That is not a
# convenience, it is the safety property: a restore tool that accepts any path
# is a tool that can overwrite good data with old data, and one that can be
# pointed outside the data directory entirely. Here the candidate list is
# computed, never taken from the caller — the argument only selects from it.
#
# So there is no path traversal to defend against, no way to "restore" a file
# that was never broken, and no way to copy from a mirror whose own copy is
# also garbage. Ask for something not on the list and it says so.
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

MODE="one"
TARGET=""
case "${1:-}" in
    --list) MODE="list" ;;
    --all)  MODE="all" ;;
    "")     echo "Usage: $0 [--list|--all|<path>]" >&2; exit 2 ;;
    -*)     echo "Usage: $0 [--list|--all|<path>]" >&2; exit 2 ;;
    *)      TARGET="$1" ;;
esac

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
    if ! grep -qxF "$TARGET" <<< "${CANDIDATES:-}"; then
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

# umbrel.yaml is rewritten by umbreld on shutdown, so restoring it under a live
# daemon means losing the good copy again minutes later.
NEEDS_UMBRELD_STOP=false
grep -qxF "umbrel.yaml" <<< "$CANDIDATES" && NEEDS_UMBRELD_STOP=true

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

while IFS= read -r REL; do
    [ -n "$REL" ] || continue
    SRC="$MIRROR/$REL"
    DST="$UMBREL_SRC/$REL"

    if [ ! -f "$SRC" ]; then
        echo "❌ $REL: not present in the backup after all — skipped"
        FAILED=$((FAILED + 1)); continue
    fi

    # Keep the broken copy. It costs a few kilobytes and it is the only
    # evidence of what went wrong if the restore turns out to be the wrong call.
    if [ -f "$DST" ]; then
        KEEP="$BACKUP_DIR/$(echo "$REL" | tr '/' '_').$(date +%Y%m%d-%H%M%S).broken"
        cp -a "$DST" "$KEEP" 2>/dev/null || true
    fi

    if ! cp -a "$SRC" "$DST" 2>/dev/null; then
        echo "❌ $REL: could not write (permission denied?) — skipped"
        FAILED=$((FAILED + 1)); continue
    fi

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

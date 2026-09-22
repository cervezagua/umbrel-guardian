#!/usr/bin/env bash
# Check that the backup on the drive is actually restorable.
#
# Usage:
#   verify_backup.sh             ← fast structural check, answers in under a second
#   verify_backup.sh --deep      ← start a full source-vs-mirror comparison in the background
#   verify_backup.sh --deep-run  ← the comparison itself (invoked by systemd-run; not for humans)
#
# A backup nobody has ever checked is a hope, not a backup. The cheap checks
# here catch the failure modes that actually happen: a run that died midway, a
# drive that silently unmounted, a mirror missing the one small file without
# which a restore produces a node that knows about no apps.
#
# ── Two script classes in one file ───────────────────────────────────────────
# The fast path is a stdout script: the bot runs it and relays what it prints.
# --deep-run is a self-sending script: it runs detached with no one waiting, so
# it reports through telegram_send.sh itself. They live together because both
# need identical scope and mirror-path resolution, and if that logic were
# duplicated the two halves could disagree about which directory they are even
# talking about.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$(dirname "$SCRIPT_DIR")/config.env"
SEND="$SCRIPT_DIR/telegram_send.sh"
STATE_DIR="$(dirname "$SCRIPT_DIR")/.state"
DEEP_RESULT="$STATE_DIR/last-verify-deep"
DEEP_UNIT="umbrel-guardian-verify-deep"

# shellcheck source=/dev/null
[ -f "$CONFIG" ] && source "$CONFIG"
# Same contract as backup.sh: without the shared scope definition this script
# cannot tell real drift from excluded paths, so it must not pretend to.
if [ ! -r "$SCRIPT_DIR/lib-backup-scope.sh" ]; then
    echo "❌ scripts/lib-backup-scope.sh is missing — Guardian looks partially deployed."
    echo "   Cannot verify the backup without knowing what is in scope."
    echo "   Re-deploy: sudo bash $(dirname "$SCRIPT_DIR")/reinstall-services.sh"
    exit 1
fi
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib-backup-scope.sh"

MODE="fast"
case "${1:-}" in
    --deep)      MODE="deep-start" ;;
    --deep-run)  MODE="deep-run" ;;
    --integrity) MODE="integrity" ;;
    "")         ;;
    *)          echo "Usage: $0 [--deep]" >&2; exit 2 ;;
esac

UMBREL_SRC="${UMBREL_DIR:-/home/umbrel/umbrel}"
DEST_BASE="${BACKUP_PATH:-}"
SCOPE="${BACKUP_SCOPE:-essential}"

# ── Backups not configured ───────────────────────────────────────────────────
# A fresh install with no drive is a normal state, not a fault. Say so plainly
# instead of emitting errors about a path that was never meant to exist.
if [ -z "$DEST_BASE" ]; then
    # --integrity feeds health_check.sh, whose contract is one deterministic
    # line per PROBLEM. Human prose here would be appended to its issue list
    # verbatim — turning "you have no backup drive" into a permanent two-line
    # Telegram alert on every node that never configured one. This mode answers
    # one question, "is anything corrupt", and having nothing to inspect is not
    # a corruption finding. Mount and configuration state belong to the checks
    # that already own them.
    [ "$MODE" = "integrity" ] && exit 0
    echo "ℹ️ Backups are not configured (BACKUP_PATH is empty in config.env)."
    echo "   Re-run install.sh to set up a backup drive."
    exit 0
fi

if ! mountpoint -q "$DEST_BASE" 2>/dev/null; then
    [ "$MODE" = "integrity" ] && exit 0
    echo "❌ Backup drive is NOT mounted at $DEST_BASE"
    echo "   Nothing is being backed up. Plug the drive in, or run:"
    echo "   sudo /usr/local/bin/mount-umbrel-backup.sh"
    exit 1
fi

# ── Locate the mirror ────────────────────────────────────────────────────────
MIRROR=$(guardian_resolve_mirror "$DEST_BASE" "$SCOPE")
if [ "$SCOPE" = "full" ]; then
    MARKER="$MIRROR.incomplete"
    WHAT="full clone"
else
    MARKER=""
    WHAT="latest essential snapshot"
fi

if [ -z "${MIRROR:-}" ] || [ ! -d "$MIRROR" ]; then
    echo "❌ No $WHAT found on $DEST_BASE"
    echo "   The drive is mounted but holds no backup. Run one: sudo systemctl start umbrel-guardian-backup.service"
    exit 1
fi

# ── Deep scan: launch ────────────────────────────────────────────────────────
if [ "$MODE" = "deep-start" ]; then
    if [ "$EUID" -ne 0 ]; then
        echo "⚠️ The deep scan needs root. The bot invokes it via sudo -n."
        exit 1
    fi
    # `is-active --quiet` alone is not enough: a Type=oneshot unit sits in
    # "activating" for its whole run and only reaches "active" at the end, so
    # the obvious check misses a scan that is currently running and the launch
    # below then fails with "unit already exists".
    DEEP_STATE=$(systemctl is-active "$DEEP_UNIT" 2>/dev/null || true)
    case "${DEEP_STATE:-}" in
        active|activating|reloading)
            echo "⏳ A deep scan is already running. Its result will arrive when it finishes."
            exit 0 ;;
    esac
    # Detached as a transient unit so it outlives the bot's script budget.
    #
    # --no-block is load-bearing, not a tweak. systemd-run returns when the unit
    # has finished STARTING, and for Type=oneshot "started" means the process
    # has already exited — so without it this call blocks for the entire scan.
    # That defeats the only reason the unit exists, and it showed up as the
    # completion message arriving in Telegram BEFORE the "started in the
    # background" line that was supposed to precede it.
    if systemd-run --no-block --unit="$DEEP_UNIT" \
        --description="Umbrel Guardian deep backup verification" \
        --property=Type=oneshot --property=TimeoutStartSec=3600 \
        --setenv=UMBREL_GUARDIAN_DEEP=1 \
        "$SCRIPT_DIR/verify_backup.sh" --deep-run &>/dev/null; then
        echo "🔍 Deep verification started in the background."
        echo "   Comparing every file in $UMBREL_SRC against the $WHAT."
        echo "   The result arrives via Telegram when it finishes."
    else
        echo "⚠️ Could not start the deep scan (systemd-run failed)."
        echo "   Run it in the foreground instead: sudo $SCRIPT_DIR/verify_backup.sh --deep-run"
    fi
    exit 0
fi

# ── Deep scan: the comparison ────────────────────────────────────────────────
if [ "$MODE" = "deep-run" ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    START=$(date +%s)

    # The same excludes backup.sh uses, from the shared library. Using a
    # different list here would report every disagreement as drift and call a
    # healthy backup broken.
    if [ "$SCOPE" = "full" ]; then
        mapfile -t EXCLUDES < <(
            { guardian_full_clone_excludes "${BACKUP_EXCLUDE_CHURN:-y}"
              guardian_db_excludes "$UMBREL_SRC"; } | guardian_as_rsync_args
        )
        SRC_ARG="$UMBREL_SRC/"
    else
        EXCLUDES=()
        SRC_ARG="$UMBREL_SRC/"
    fi

    # -n dry run, -i itemize. Counts only: a file list from a 500 GB tree would
    # be useless in a chat message and expensive to build.
    SUMMARY=$(ionice -c3 nice -n 19 \
        rsync -ain --delete ${EXCLUDES[@]+"${EXCLUDES[@]}"} "$SRC_ARG" "$MIRROR/" 2>/dev/null | awk '
            /^\*deleting/ { del++; next }
            /^[<>]/       { xfer++; next }
            /^\./         { attr++; next }
            END { printf "%d %d %d", xfer + 0, del + 0, attr + 0 }
        ')
    RC=$?
    ELAPSED=$(( $(date +%s) - START ))
    read -r XFER DEL ATTR <<< "${SUMMARY:-0 0 0}"

    if [ "$RC" -ne 0 ] || [ -z "${SUMMARY:-}" ]; then
        MSG="⚠️ Deep verification could not complete (rsync exit $RC after ${ELAPSED}s)."
    elif [ "$SCOPE" != "full" ]; then
        # An essential snapshot is frozen at the moment it was taken, so drift
        # against a live source is expected and says nothing about its health.
        # Reporting a raw number without this caveat would look like a fault.
        MSG="🔍 Deep verification complete (${ELAPSED}s)
📁 $MIRROR
📊 Differs from the live source in $XFER file(s)
ℹ️ Drift is normal here — this is a frozen snapshot, and the node has kept working since it was taken."
    elif [ "$XFER" -eq 0 ] && [ "$DEL" -eq 0 ]; then
        MSG="✅ Deep verification passed (${ELAPSED}s)
📁 $MIRROR
Every in-scope file matches the source."
    else
        MSG="🔍 Deep verification complete (${ELAPSED}s)
📁 $MIRROR
📊 $XFER file(s) would be re-copied, $DEL would be deleted, $ATTR attribute-only
ℹ️ Some drift is expected — the node keeps writing while the mirror sits still. Large numbers after a fresh backup are not."
    fi

    printf '%s\n' "$MSG" > "$DEEP_RESULT" 2>/dev/null || true
    [ -x "$SEND" ] && "$SEND" "$MSG"
    exit 0
fi

# ── Integrity ────────────────────────────────────────────────────────────────
# See lib-integrity.py for why this parses rather than compares. In short: the
# deep scan compares the mirror against the source, so when the source is
# corrupt and the backup faithfully copied that corruption, the comparison
# reports agreement. It called a backup restorable while five files inside it
# were garbage.
#
# One python process for every file, never one per file: interpreter startup
# costs ~19s inside the bot's CPUQuota before any work happens.
INTEGRITY_TIMEOUT=45
INTEGRITY_CHECKER="$SCRIPT_DIR/lib-integrity.py"

# Which side is damaged decides the remedy, so each verdict gets its own
# sentence. A message that only says "corrupt" leaves the reader to work out
# which copy to trust, which is the part that is actually hard at 3am.
integrity_line() {
    case "$2" in
        source) echo "🚨 $1 is damaged on this node — the backup copy is good, restore it" ;;
        mirror) echo "🚨 $1 is damaged in the BACKUP — the node is fine, run a backup to replace it" ;;
        both)   echo "🚨 $1 is damaged on the node AND in the backup — rebuild it from the app store" ;;
    esac
}

if [ "$MODE" = "integrity" ]; then
    # Deterministic output for health_check.sh: identical wording every run, so
    # its dedup hash changes only when the situation does. No counts, no paths
    # that vary, no parser messages that might differ between versions.
    if [ ! -r "$INTEGRITY_CHECKER" ]; then
        # Silent: a missing file here means a partial deploy, and alerting on it
        # every 30 minutes would train you to ignore the channel. /verify_backup
        # says so loudly, where a human is asking.
        exit 0
    fi
    OUT=$(timeout "$INTEGRITY_TIMEOUT" python3 "$INTEGRITY_CHECKER" "$UMBREL_SRC" "$MIRROR" 2>/dev/null)
    RC=$?
    if [ "$RC" -ne 0 ]; then
        # Never silently clean. A checker that failed has found nothing, and
        # reporting nothing as "no corruption" is the lie this whole file exists
        # to avoid.
        if [ "$RC" -eq 124 ]; then
            echo "⚠️ Backup integrity check timed out after ${INTEGRITY_TIMEOUT}s — corruption would not be seen."
        else
            echo "⚠️ Backup integrity check failed (exit $RC) — corruption would not be seen."
        fi
        exit 1
    fi
    printf '%s\n' "${OUT:-}" | while IFS=$'\t' read -r KIND REL VERDICT _; do
        [ "$KIND" = "BAD" ] || continue
        integrity_line "$REL" "$VERDICT"
    done
    exit 0
fi

# ── Fast path ────────────────────────────────────────────────────────────────
# Everything below is stat-level work on a handful of known paths. No directory
# walking: the whole point is an answer in under a second, so it stays inside
# the bot's script timeout even with a 500 GB mirror on a slow USB bus.
PROBLEMS=0
echo "🔍 Backup Verification"
echo "━━━━━━━━━━━━━━━━━━"
echo "📁 $MIRROR"
echo "🗂 Scope: $SCOPE"

# Mid-update marker — the one check that says "do not restore from this".
if [ -n "$MARKER" ] && [ -f "$MARKER" ]; then
    echo "❌ MID-UPDATE: $(basename "$MARKER") is present"
    echo "   The last backup did not finish. This mirror is inconsistent and must"
    echo "   not be restored from until a run completes."
    PROBLEMS=$((PROBLEMS + 1))
fi

# Critical files. Present-but-empty is the nastier failure: it looks fine in a
# directory listing and restores a node with no account.
while read -r REL; do
    TARGET="$MIRROR/$REL"
    if [ ! -e "$TARGET" ]; then
        echo "❌ Missing: $REL"
        PROBLEMS=$((PROBLEMS + 1))
    elif [ -f "$TARGET" ] && [ ! -s "$TARGET" ]; then
        echo "❌ Empty: $REL (present but zero bytes — it will not restore)"
        PROBLEMS=$((PROBLEMS + 1))
    elif [ -d "$TARGET" ] && [ -z "$(ls -A "$TARGET" 2>/dev/null)" ]; then
        echo "❌ Empty directory: $REL"
        PROBLEMS=$((PROBLEMS + 1))
    fi
done < <(guardian_critical_paths)

# Integrity. The checks above prove the files EXIST and are non-empty; this
# proves they can still be read. A file can be the right size, the right age and
# entirely unusable — that is precisely the failure that got past every earlier
# version of this script.
if [ -r "$INTEGRITY_CHECKER" ]; then
    INTEGRITY_RAW=$(timeout "$INTEGRITY_TIMEOUT" python3 "$INTEGRITY_CHECKER" "$UMBREL_SRC" "$MIRROR" 2>/dev/null)
    INTEGRITY_RC=$?
    if [ "$INTEGRITY_RC" -ne 0 ]; then
        echo "⚠️ Integrity check did not complete ($([ "$INTEGRITY_RC" -eq 124 ] \
            && echo "timed out after ${INTEGRITY_TIMEOUT}s" || echo "exit $INTEGRITY_RC"))"
        echo "   Corrupt files would NOT have been detected."
        PROBLEMS=$((PROBLEMS + 1))
    elif [ -n "${INTEGRITY_RAW:-}" ]; then
        while IFS=$'\t' read -r KIND REL VERDICT SRC_ST MIR_ST DETAIL; do
            case "$KIND" in
                BAD)
                    integrity_line "$REL" "$VERDICT"
                    [ -n "${DETAIL:-}" ] && echo "   ($SRC_ST on node, $MIR_ST in backup: $DETAIL)"
                    PROBLEMS=$((PROBLEMS + 1)) ;;
                PROBE)
                    echo "⚠️ Could not check $REL — $VERDICT" ;;
            esac
        done <<< "$INTEGRITY_RAW"
    else
        echo "✅ Config files parse cleanly on both sides"
    fi
else
    echo "⚠️ Integrity checker missing (scripts/lib-integrity.py) — corruption not checked"
    PROBLEMS=$((PROBLEMS + 1))
fi

# Age. Prefer a stamp written by the backup itself; fall back to asking systemd
# when the last run of the unit finished, which needs no cooperation from
# backup.sh. The mirror's own mtime is useless here — rsync -a copies the
# source's timestamps, so it reflects the source, not the backup.
AGE_SRC=""
STAMP="$DEST_BASE/.umbrel-guardian-last-backup"
LAST_EPOCH=""
if [ -f "$STAMP" ]; then
    LAST_EPOCH=$(stat -c %Y "$STAMP" 2>/dev/null)
    AGE_SRC="stamp file"
else
    LAST_RUN=$(systemctl show umbrel-guardian-backup.service -p ExecMainExitTimestamp --value 2>/dev/null)
    if [ -n "${LAST_RUN:-}" ]; then
        LAST_EPOCH=$(date -d "$LAST_RUN" +%s 2>/dev/null)
        AGE_SRC="systemd"
    fi
fi

if [[ "${LAST_EPOCH:-}" =~ ^[0-9]+$ ]]; then
    AGE_H=$(( ( $(date +%s) - LAST_EPOCH ) / 3600 ))
    if [ "$AGE_H" -gt 48 ]; then
        echo "⚠️ Last backup was ${AGE_H}h ago (via $AGE_SRC) — the timer may not be running"
        PROBLEMS=$((PROBLEMS + 1))
    else
        echo "⏱ Last backup: ${AGE_H}h ago"
    fi
else
    # Reaching here means neither the stamp nor systemd knows. Say which, so
    # the next step is obvious rather than a mystery.
    echo "⏱ Last backup: unknown — no stamp on the drive and no record from systemd."
    echo "   A backup written by this version of Guardian leaves a stamp; an older"
    echo "   one, or a mirror copied from elsewhere, will not have one until the"
    echo "   next run completes."
fi

# A read-only remount is how a failing drive presents itself: everything looks
# mounted and present, and every future backup silently fails to write.
#
# But the test is only meaningful outside the bot's sandbox. umbrel-guardian-bot
# .service sets ProtectSystem=strict, which remounts the whole filesystem
# read-only for the service and everything it spawns — sudo included, because
# sudo does not escape a mount namespace. Run from the bot, this write would
# fail on a perfectly healthy drive and report a fault that is not there.
#
# /etc is the canary: root can write it normally, and cannot under strict.
# Overridable so the behaviour can be exercised without a systemd sandbox.
RW_CANARY="${GUARDIAN_RW_CANARY:-/etc}"
if [ -w "$RW_CANARY" ]; then
    if ! touch "$DEST_BASE/.guardian-write-test" 2>/dev/null; then
        echo "❌ Backup drive is not writable — mounted read-only, or the filesystem has faulted"
        PROBLEMS=$((PROBLEMS + 1))
    else
        rm -f "$DEST_BASE/.guardian-write-test" 2>/dev/null || true
    fi
else
    # Not a problem, and not silence either — say which check did not run.
    echo "ℹ️ Writability not checked (running inside the bot's read-only sandbox)"
fi

DRIVE=$(df -Ph "$DEST_BASE" 2>/dev/null | awk 'NR==2{print $4" free of "$2}')
echo "💽 Drive: ${DRIVE:-unknown}"

# Surface the last deep scan if one has ever run, so the fast path is not
# silently narrower than the user remembers asking for.
if [ -f "$DEEP_RESULT" ]; then
    DEEP_AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$DEEP_RESULT" 2>/dev/null || echo 0) ) / 3600 ))
    echo "🔍 Last deep scan: ${DEEP_AGE_H}h ago"
fi

echo "━━━━━━━━━━━━━━━━━━"
if [ "$PROBLEMS" -eq 0 ]; then
    echo "✅ Backup looks restorable"
    echo "   For a full file-by-file comparison: /verify_backup deep"
    exit 0
fi
echo "❌ $PROBLEMS problem(s) found — this backup may not restore"
exit 1

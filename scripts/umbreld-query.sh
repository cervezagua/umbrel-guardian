#!/usr/bin/env bash
# Root-only gateway to `umbreld client`, limited to the procedures Guardian uses.
#
# ── Why this exists ──────────────────────────────────────────────────────────
# umbrelOS 2.0 made the CLI root-only. From modules/cli-client.ts:
#
#     This credential deliberately lives below a 0700 auth directory as a 0600
#     file. The production CLI is therefore root-only; loosening the file mode
#     would turn local shell access into full umbreld API access.
#
# Every Guardian script that asks umbreld anything runs as the `umbrel` user,
# so on 2.0 all of them break: /apps, /status, /health, /restart, /notifications
# and /updates. The lazy fix is a sudoers grant for each script, which hands
# `umbrel` exactly the "full umbreld API access" that comment is guarding —
# through the side door, with Guardian holding it open.
#
# So the grant is for this file instead, and this file allows six procedures
# and nothing else. The result is TIGHTER than 1.7.4, where `umbrel` could
# already run `umbreld client <anything>` unaided.
#
# ── Why it must not live with the other scripts ──────────────────────────────
# A sudo-granted script that its caller can rewrite is not a privilege
# boundary. This is deployed to /usr/local/lib/umbrel-guardian/ as root:root
# 0755 by reinstall-services.sh, outside anything `umbrel` can write, and it
# deliberately has no dependencies — no config, no libraries, no state — so
# there is nothing alongside it to subvert either.
#
# It is intentionally boring. Read the whitelist, check the arguments, exec.

set -uo pipefail

refuse() {
    echo "refused: $1" >&2
    exit 2
}

PROC="${1:-}"
[ -n "$PROC" ] || refuse "no procedure given"
shift

case "$PROC" in
    # Read-only queries. None of them takes an argument, so any argument at all
    # means the caller is doing something this wrapper was not built for.
    apps.list.query|notifications.get.query|system.version.query|\
    system.checkUpdate.query|system.getReleaseChannel.query)
        [ "$#" -eq 0 ] || refuse "$PROC takes no arguments"
        exec umbreld client "$PROC"
        ;;

    # The one mutation Guardian performs. Restricted to a single flag and an
    # app id matching umbrelOS's own format, so the wildcard the sudoers rule
    # needs for the id cannot smuggle a second procedure or a shell fragment.
    apps.restart.mutate)
        [ "$#" -eq 2 ] && [ "$1" = "--appId" ] || refuse "usage: apps.restart.mutate --appId <id>"
        [[ "$2" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]] || refuse "invalid app id"
        exec umbreld client apps.restart.mutate --appId "$2"
        ;;

    # Notably absent: notifications.clear.mutate, which would remove a notice
    # from the shared dashboard for everyone. Guardian never needs it, so it
    # is not reachable from here.
    *)
        refuse "'$PROC' is not an allowed procedure"
        ;;
esac

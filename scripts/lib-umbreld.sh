#!/usr/bin/env bash
# One definition of how Guardian talks to umbreld. Sourced, not run.
#
# umbrelOS 2.0 made `umbreld client` root-only, so the call goes through a
# root-owned wrapper that whitelists the procedures we use (see
# scripts/umbreld-query.sh). When that wrapper is not installed — a partial
# deploy, or a 1.7.x node where the CLI needs no credential — it falls back to
# calling umbreld directly, which is also the path the test suites stub.
#
# Having this in one place matters: seven scripts ask umbreld things, and seven
# independent opinions about how to reach it is how five of them keep working
# after an upgrade and two do not.

GUARDIAN_UMBRELD_WRAPPER="${GUARDIAN_UMBRELD_WRAPPER:-/usr/local/lib/umbrel-guardian/umbreld-query.sh}"

# guardian_umbreld <timeout-seconds> <procedure> [args...]
# stdout is umbreld's output; stderr is merged in by callers that want it.
guardian_umbreld() {
    local seconds="$1"; shift
    if [ -x "$GUARDIAN_UMBRELD_WRAPPER" ]; then
        # Already root (the health timer's disk probes, a shell) — no point
        # paying for sudo, and it would need a tty rule we do not want.
        if [ "${EUID:-$(id -u)}" -eq 0 ]; then
            timeout "$seconds" "$GUARDIAN_UMBRELD_WRAPPER" "$@"
        else
            timeout "$seconds" sudo -n "$GUARDIAN_UMBRELD_WRAPPER" "$@"
        fi
    else
        timeout "$seconds" "${UMBRELD_BIN:-umbreld}" client "$@"
    fi
}

# True when umbreld can be reached at all, by either route.
guardian_umbreld_available() {
    [ -x "$GUARDIAN_UMBRELD_WRAPPER" ] || command -v "${UMBRELD_BIN:-umbreld}" &>/dev/null
}

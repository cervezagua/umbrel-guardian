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

# 90s, and that is not paranoia. Measured on a Raspberry Pi 4 running umbrelOS
# 2.0.0, one `system.version.query`:
#
#   unconstrained                19.2 s
#   inside CPUQuota=20%         110.0 s
#   inside MemoryMax=128M        10.1 s
#
# That third row is one query in a throwaway scope and does NOT mean the memory
# limit was harmless: the live bot's cgroup later reported memory.events max=605
# — 605 times it reached the 128M ceiling and the kernel had to reclaim to stay
# under it. Nothing was ever OOM-killed, but the limit was binding constantly.
# See the unit file for what replaced it.
#
# The 19.2 s baseline is the surprise. The same call on 1.7.4 took 1.8 s. 2.0's
# CLI opens a WebSocket and mints a ticket via user.createWebSocketTicket before
# every query, so there are several round trips where there used to be one —
# roughly a tenfold cost increase with no code change on our side. The old 45 s
# budget was sized against 1.7.4 and every umbreld-backed command timed out on
# 2.0 at exactly 42-46 s.
#
# One number, in one place, so the next version's surprise is a one-line change.
GUARDIAN_UMBRELD_TIMEOUT="${GUARDIAN_UMBRELD_TIMEOUT:-90}"

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

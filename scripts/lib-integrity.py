#!/usr/bin/env python3
"""Parse umbrelOS's critical config files and report which copies are damaged.

Comparing a backup against its source cannot see corruption. rsync faithfully
copies a file whose contents have been destroyed, and afterwards both sides
agree — so a comparison reports success while the backup holds garbage. That is
not hypothetical: on the node this was written for, /verify_backup reported
"looks restorable" while five docker-compose.yml files inside it were null bytes.

So this does not compare. It PARSES each file on both sides independently, and
reports which side is damaged, because that changes the remedy entirely:

    source bad, mirror good   the node is damaged; restore the file
    source good, mirror bad   the backup cannot restore it; take a new backup
    both bad                  neither copy is usable; rebuild from the app store

Byte-level heuristics were tried first and are not enough. A scan for NUL bytes
passed a file that was full of other non-printable garbage, and the app it
belonged to stayed broken while the check called it clean. Parsing is the only
test that answers the question actually being asked: can umbreld read this?

Usage:  lib-integrity.py <source-dir> <mirror-dir>
Output: tab-separated records on stdout, one per problem, sorted by path.
            BAD    <rel> <verdict> <source-state> <mirror-state> <detail>
            PROBE  <rel> <why>          ← could not check, NOT a clean result
"""

import glob
import os
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - environment-dependent
    print("PROBE\tpyyaml\tnot installed, so nothing could be parsed")
    sys.exit(0)

# States that mean "this copy will not restore". Anything else is either fine
# or a probe failure, and the two must never be merged — see read().
BAD = {"corrupt", "empty", "incomplete"}


def read(path):
    """Return (state, detail).

    A permission or I/O error is reported as 'unreadable', never as damage.
    Conflating the two sends someone chasing a file that is perfectly fine —
    which happened during the incident that prompted this, when a root-owned
    AdGuard config read as corrupt purely because the scan ran unprivileged.
    """
    # os.path.exists() swallows permission errors and answers False, which
    # would report an unreadable file as a missing one — the precise
    # conflation this function exists to avoid. stat() raises instead, so the
    # two stay distinguishable.
    try:
        size = os.path.getsize(path)
    except FileNotFoundError:
        return "missing", ""
    except PermissionError:
        return "unreadable", "permission denied"
    except OSError as error:
        return "unreadable", error.strerror or "stat error"

    if size == 0:
        return "empty", ""

    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except PermissionError:
        return "unreadable", "permission denied"
    except OSError as error:
        return "unreadable", error.strerror or "read error"

    try:
        return "ok", yaml.safe_load(raw.decode("utf-8"))
    except UnicodeDecodeError:
        return "corrupt", "contains non-text data"
    except yaml.YAMLError as error:
        return "corrupt", str(error).split("\n")[0][:70]


def has(data, dotted):
    """True when a dotted key exists and holds something."""
    current = data
    for part in dotted.split("."):
        if not isinstance(current, dict) or part not in current:
            return False
        current = current[part]
    return current not in (None, "", [], {})


def inspect(root, rel, required):
    """State of one file on one side, including structural emptiness.

    A file can parse perfectly and still have lost the branch that matters.
    umbrel.yaml surviving as valid YAML with its entire user block gone is
    exactly how an account disappears without anything looking wrong.
    """
    state, payload = read(os.path.join(root, rel))
    if state == "ok" and required:
        absent = [key for key in required if not has(payload, key)]
        if absent:
            return "incomplete", "missing " + ", ".join(absent)
    return state, payload if isinstance(payload, str) else ""


def targets(source, mirror):
    """Every file worth parsing, from both sides.

    Mirror-only entries are included deliberately: an app uninstalled from the
    node should not make its backed-up copy invisible to the check.
    """
    found = {"umbrel.yaml": ("user.hashedPassword", "apps")}
    for root in (source, mirror):
        for app_dir in glob.glob(os.path.join(root, "app-data", "*")):
            app = os.path.basename(app_dir)
            for name in ("settings.yml", "docker-compose.yml"):
                found.setdefault(os.path.join("app-data", app, name), None)
    return sorted(found.items())


def main():
    if len(sys.argv) != 3:
        print("usage: lib-integrity.py <source-dir> <mirror-dir>", file=sys.stderr)
        return 2
    source, mirror = sys.argv[1], sys.argv[2]

    for rel, required in targets(source, mirror):
        src_state, src_detail = inspect(source, rel, required)
        mir_state, mir_detail = inspect(mirror, rel, required)

        if "unreadable" in (src_state, mir_state):
            print("PROBE\t%s\tcould not be read" % rel)
            continue

        src_bad = src_state in BAD
        mir_bad = mir_state in BAD
        if not src_bad and not mir_bad:
            continue

        verdict = "both" if src_bad and mir_bad else ("source" if src_bad else "mirror")
        detail = src_detail or mir_detail or ""
        print("BAD\t%s\t%s\t%s\t%s\t%s" % (rel, verdict, src_state, mir_state, detail))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""filter_deltas.py --- project the compat map to one version's audit surface.

Prints the symbols a per-version audit agent must scrutinise for its target
version --- the class-1/2 (existence / signature) surface:

  * ABSENT-in-<ver>  : classes / members present in some supported version but NOT
                       in <ver>. If the toolkit calls one of these WITHOUT a guard,
                       it breaks on <ver>. (The dominant class-1 risk.)
  * DRIFT            : members whose signature drifts across versions (virtual-drift
                       = only if overridden; breaking-callable = always a concern;
                       preserved = backward-compatible, listed for completeness).

With no --version, prints a global summary of every delta bucket.

Usage:
  python filter_deltas.py --version 4.2      # what's missing/changed in 4.2
  python filter_deltas.py --version 4.7 --kind method
  python filter_deltas.py                    # global summary
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAP = os.path.join(os.path.dirname(HERE), "compat-map.json")
VERSIONS = ["4.2", "4.3", "4.4", "4.5", "4.6", "4.7"]


def main():
    version = None
    kind = None
    if "--version" in sys.argv:
        version = sys.argv[sys.argv.index("--version") + 1]
    if "--kind" in sys.argv:
        kind = sys.argv[sys.argv.index("--kind") + 1]
    cmap = json.load(open(MAP, encoding="utf-8"))

    if not version:
        c = cmap["meta"]["counts"]
        print("Global delta summary:")
        print(json.dumps(c, indent=2))
        print("\nEditor builds:")
        print(json.dumps(cmap["meta"]["editor_builds"], indent=2))
        return

    if version not in VERSIONS:
        sys.exit(f"unknown version {version}; expected one of {VERSIONS}")
    vi = VERSIONS.index(version)

    absent_classes = [n for n, r in cmap["classes"].items() if r["present"][vi] != "Y"]
    print(f"== {version}: ABSENT classes ({len(absent_classes)}) ==")
    for n in absent_classes:
        print(f"  {n}  present={cmap['classes'][n]['present']}")

    absent_members, drifts = [], []
    for sym, r in cmap["member_deltas"].items():
        if kind and r["kind"] != kind:
            continue
        if r["present"][vi] != "Y":
            # absent in this version but present elsewhere; skip if its whole class
            # is absent here (already reported at class level)
            owner = sym.rsplit(".", 1)[0]
            oc = cmap["classes"].get(owner)
            if oc and oc["present"][vi] != "Y":
                continue
            absent_members.append((sym, r))
        elif r.get("drift"):
            drifts.append((sym, r))

    print(f"\n== {version}: ABSENT members on classes that DO exist here ({len(absent_members)}) ==")
    for sym, r in absent_members:
        print(f"  {sym}  present={r['present']}  note={r['note']}  sig={r.get('sig','')}")

    print(f"\n== signature DRIFT touching {version} ({len(drifts)}) ==")
    for sym, r in drifts:
        print(f"  {sym}  drift={r.get('drift')}  present={r['present']}  note={r['note']}")


if __name__ == "__main__":
    main()

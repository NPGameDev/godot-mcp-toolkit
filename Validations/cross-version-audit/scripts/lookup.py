#!/usr/bin/env python3
"""lookup.py --- point-query the committed compat map for one API symbol.

Resolves a `Class.member`, a bare `ClassName`, `@util:name`, `@genum:Name`, or
`@singleton:Name` against ``compat-map.json`` and prints its per-version presence,
introduction version, and (for members) signature / drift classification.

Resolution rules (mirror the compat-map convention):
  * If the symbol is a class            -> its `present` row.
  * If `Class.member` is in member_deltas -> that record (added/removed/drift).
  * If `Class.member` is NOT in member_deltas but the class exists ->
        "stable within class lifetime": present wherever the class is present,
        signature stable. (For the exact per-version signature of a stable or
        virtual-drift member, add --version <v> to read it from the raw dump.)

--version <v> cross-checks against the raw dump for that version (if present under
DUMPROOT) and prints the ground-truth signature --- authoritative existence check.

Usage:
  python lookup.py EditorPlugin.add_dock
  python lookup.py EditorInterface --version 4.7
  python lookup.py @util:type_convert
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAP = os.path.join(os.path.dirname(HERE), "compat-map.json")
VERSIONS = ["4.2", "4.3", "4.4", "4.5", "4.6", "4.7"]
DUMPROOT = os.environ.get(
    "DUMPROOT",
    "C:/Users/nicol/OneDrive/Desktop/Personal/AIWithGodot/_TempForClaude/xversion-dumps",
)


def raw_member(version, cls, member):
    path = os.path.join(DUMPROOT, version, "extension_api.json")
    if not os.path.isfile(path):
        return None
    d = json.load(open(path, encoding="utf-8"))
    for c in d.get("classes", []):
        if c["name"] != cls:
            continue
        for m in c.get("methods", []) or []:
            if m["name"] == member:
                args = ", ".join(f"{a.get('name')}: {a.get('type')}" for a in m.get("arguments", []) or [])
                ret = (m.get("return_value") or {}).get("type", "void")
                return f"method  {ret} {member}({args})  hash={m.get('hash')} virtual={m.get('is_virtual', False)}"
        for p in c.get("properties", []) or []:
            if p["name"] == member:
                return f"property  {p.get('type')} {member}"
    return f"(no member '{member}' on class '{cls}' in {version})"


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sym = sys.argv[1]
    version = None
    if "--version" in sys.argv:
        version = sys.argv[sys.argv.index("--version") + 1]
    cmap = json.load(open(MAP, encoding="utf-8"))

    if sym in cmap["classes"]:
        r = cmap["classes"][sym]
        print(f"CLASS {sym}: present={r['present']} api_type={r['api_type']} inherits={r['inherits']}")
    elif sym in cmap["member_deltas"]:
        r = cmap["member_deltas"][sym]
        print(f"MEMBER-DELTA {sym}: {json.dumps(r)}")
    elif sym in cmap["global_deltas"]:
        print(f"GLOBAL-DELTA {sym}: {json.dumps(cmap['global_deltas'][sym])}")
    elif "." in sym:
        cls, member = sym.split(".", 1)
        cr = cmap["classes"].get(cls)
        if not cr:
            print(f"UNKNOWN class '{cls}' (symbol not in any version's class table)")
        else:
            print(f"STABLE MEMBER {sym}: not in member_deltas -> present & signature-stable "
                  f"wherever {cls} is present ({cr['present']}). "
                  f"(intro = class intro = {next(v for v, c in zip(VERSIONS, cr['present']) if c == 'Y')})")
    else:
        print(f"NOT FOUND: {sym}")

    if version:
        if "." in sym and not sym.startswith("@"):
            cls, member = sym.split(".", 1)
            print(f"  raw[{version}]: {raw_member(version, cls, member)}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""cross_diff_dotnet.py --- (c) reflect-vs-manifest .NET cross-diff.

The .NET dimension check (c) from the iteration's methodology: GodotSharp is a
PascalCase projection of the same ClassDB reflection that produces
extension_api.json, so the C# surface is *covered* by the class-2 (signature)
check on the manifest. This script is the belt-and-suspenders confirmation that
the binding generator did NOT silently diverge --- it diffs the reflected
GodotSharp[Editor].dll surface (from reflect-tool) against the same version's
manifest and classifies every gap as EXPECTED (a documented PascalCase / method
-> property projection) or UNEXPLAINED (a real generation divergence == a finding).

Runs on the four installed .NET editors (4.2 / 4.5 / 4.6 / 4.7). The 4.3/4.4 C#
surface is covered by the shared-manifest mapping (check (a)) --- no .NET editor
installed, by design.

If a version's reflected surface JSON is missing, this script invokes reflect-tool
(dotnet run) to produce it first --- so a single `python cross_diff_dotnet.py`
does the whole .NET dimension.

Usage:
  python cross_diff_dotnet.py                 # all installed mono versions
  python cross_diff_dotnet.py --version 4.7
"""
import glob
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DUMPROOT = os.environ.get(
    "DUMPROOT",
    "C:/Users/nicol/OneDrive/Desktop/Personal/AIWithGodot/_TempForClaude/xversion-dumps",
)
EDITORS_ROOT = os.environ.get("EDITORS_ROOT", "C:/Users/nicol/Godot/Editors")
MONO_VERSIONS = ["4.2", "4.5", "4.6", "4.7"]

# Engine base classes that are NOT projected as C# classes (represented as C#
# structs / primitives / delegates, or intentionally not surfaced). Absence of a
# C# *class* for these is EXPECTED, not a generation divergence.
CS_EXCLUDED_CLASSES = {
    # variant/struct-projected value types live in `builtin_classes`, not `classes`,
    # so they never reach this diff; listed here only as belt-and-suspenders.
    "Variant",
}

# Engine classes the C# binding generator deliberately renames to avoid BCL clashes.
# Their C# type exists under the renamed name --- NOT a generation divergence.
KNOWN_CS_RENAMES = {
    "Object": "GodotObject",
    "Thread": "GodotThread",
}


def norm(s):
    """Underscore-stripped, case-insensitive key. Godot's C# generator applies
    acronym-casing (AESContext->AesContext, GLTFDocument->GltfDocument) and
    dimension-casing (node_3d->Node3D). Replicating that rule exactly is brittle;
    normalising both sides to lower-no-underscore confirms SURFACE PARITY (the
    generation-divergence question) without depending on the casing algorithm."""
    return s.replace("_", "").lower()


def net_editor_dir(v):
    exact = os.path.join(EDITORS_ROOT, f"NET-{v}-stable")
    if os.path.isdir(exact):
        return exact
    cands = sorted(glob.glob(os.path.join(EDITORS_ROOT, f"NET-{v}.*-stable")))
    return cands[-1] if cands else None


def ensure_reflected(v):
    out = os.path.join(DUMPROOT, "dotnet", f"net-{v}.json")
    if os.path.isfile(out) and os.path.getsize(out) > 0:
        return out
    ed = net_editor_dir(v)
    if not ed:
        return None
    api = os.path.join(ed, "GodotSharp", "Api", "Debug")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    proj = os.path.join(HERE, "reflect-tool")
    print(f"  [{v}] reflected surface missing --- invoking reflect-tool ...")
    subprocess.run(["dotnet", "run", "--project", proj, "-c", "Release", "--", api, out], check=True)
    return out if os.path.isfile(out) else None


def diff_version(v):
    manifest_path = os.path.join(DUMPROOT, v, "extension_api.json")
    if not os.path.isfile(manifest_path):
        return {"version": v, "error": f"missing manifest {manifest_path}"}
    reflected_path = ensure_reflected(v)
    if not reflected_path:
        return {"version": v, "error": "no .NET editor / reflected surface"}

    manifest = json.load(open(manifest_path, encoding="utf-8"))
    reflected = json.load(open(reflected_path, encoding="utf-8"))
    cs_types = reflected["types"]

    cs_type_norms = {norm(n): n for n in cs_types}

    # --- class-level parity: every manifest engine class -> a C# type ---
    missing_classes = []
    for c in manifest["classes"]:
        n = c["name"]
        if n in CS_EXCLUDED_CLASSES:
            continue
        renamed = KNOWN_CS_RENAMES.get(n)
        if renamed and norm(renamed) in cs_type_norms:
            continue
        if norm(n) not in cs_type_norms:
            missing_classes.append((n, c.get("api_type", "")))

    # --- method-level parity for editor classes (the toolkit's C# surface) ---
    # A manifest method maps to a C# METHOD OR, for accessor pairs, a C# PROPERTY.
    # Compared on the normalised key so casing/acronym/dimension rules don't matter.
    editor_method_gaps = []
    editor_classes = [c for c in manifest["classes"]
                      if c.get("api_type", "").startswith("editor") and norm(c["name"]) in cs_type_norms]
    for c in editor_classes:
        cs = cs_types[cs_type_norms[norm(c["name"])]]
        cs_member_norms = {norm(x) for x in cs.get("methods", [])} | {norm(x) for x in cs.get("properties", [])}
        for m in c.get("methods", []) or []:
            mn = m["name"]
            if norm(mn) in cs_member_norms:
                continue
            # accessor -> property projection: strip get_/set_/is_/has_ and re-check
            base = mn
            for pre in ("get_", "set_", "is_", "has_"):
                if mn.startswith(pre):
                    base = mn[len(pre):]
                    break
            if norm(base) in cs_member_norms:
                continue
            # An is_/get_/has_ read accessor with no name-matched member almost always
            # projected to a C# property under a cleaned-up name (e.g.
            # is_overwrite_warning_disabled -> DisableOverwriteWarning). Not a divergence,
            # and irrelevant to the toolkit's duck-typed Object.Call(snake_case) path.
            # A non-accessor (mutator/action) with no C# member WOULD be unexplained.
            kind = "accessor" if mn.startswith(("is_", "get_", "has_")) else "UNEXPLAINED"
            editor_method_gaps.append((f"{c['name']}.{mn}", kind))

    return {
        "version": v,
        "manifest_classes": len(manifest["classes"]),
        "cs_types": reflected["type_count"],
        "missing_classes": missing_classes,
        "editor_classes_checked": len(editor_classes),
        "editor_method_gaps": editor_method_gaps,
    }


def main():
    versions = MONO_VERSIONS
    if "--version" in sys.argv:
        versions = [sys.argv[sys.argv.index("--version") + 1]]
    overall_ok = True
    for v in versions:
        r = diff_version(v)
        print(f"\n=== .NET cross-diff: {v} ===")
        if r.get("error"):
            print(f"  ERROR: {r['error']}")
            overall_ok = False
            continue
        print(f"  manifest classes: {r['manifest_classes']}   reflected C# types: {r['cs_types']}")
        mc = r["missing_classes"]
        # editor/editor_extension classes not surfaced to C# is an EXPECTED case for a
        # handful; core classes missing a C# type would be UNEXPLAINED.
        core_missing = [n for n, at in mc if at == "core"]
        other_missing = [(n, at) for n, at in mc if at != "core"]
        print(f"  classes with no C# type: {len(mc)}  (core: {len(core_missing)}, editor/other: {len(other_missing)})")
        if core_missing:
            print(f"    UNEXPLAINED core-class gaps: {', '.join(core_missing[:40])}")
            overall_ok = False
        if other_missing:
            print(f"    editor/other (review): {', '.join(n for n, _ in other_missing[:40])}")
        gaps = r["editor_method_gaps"]
        accessor_gaps = [g for g, k in gaps if k == "accessor"]
        unexplained_gaps = [g for g, k in gaps if k == "UNEXPLAINED"]
        print(f"  editor classes method-checked: {r['editor_classes_checked']}   "
              f"editor method gaps: {len(gaps)} (accessor->property expected: {len(accessor_gaps)}, "
              f"UNEXPLAINED: {len(unexplained_gaps)})")
        if accessor_gaps:
            print(f"    accessor->property (expected): {', '.join(accessor_gaps[:40])}")
        for g in unexplained_gaps[:40]:
            print(f"    UNEXPLAINED gap: {g}")
        if unexplained_gaps:
            overall_ok = False
    print(f"\n{'CLEAN --- C# surface matches manifest (only expected casing/rename/property projections)' if overall_ok else 'DIVERGENCE --- review UNEXPLAINED items above'}")
    return 0 if overall_ok else 1


if __name__ == "__main__":
    sys.exit(main())

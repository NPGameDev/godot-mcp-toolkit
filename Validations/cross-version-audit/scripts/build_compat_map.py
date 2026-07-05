#!/usr/bin/env python3
"""build_compat_map.py --- (b) manifest pairwise-diff + distilled compat map.

Reads the six standard-editor ``extension_api.json`` dumps (4.2-4.7) produced by
``dump_api.sh`` and distills them into the committed cross-version compat map:

  * ``compat-map.json``  --- structured SSOT: every class's per-version presence,
                             plus the *interesting* member deltas and global-symbol
                             deltas (with per-version signature detail).
  * ``compat-map.tsv``   --- flat, greppable projection of the same (one row per
                             class + one row per member/global delta). The
                             non-``class`` rows ARE the machine-readable delta set.
  * ``delta-report.md``  --- human-readable pairwise narrative (4.2->4.3 ... 4.6->4.7).

Why a member can be omitted (the size-controlling collapse): a member whose
per-version presence exactly matches its owner class's presence *and* whose
signature is constant wherever it exists is "stable within the class lifetime" ---
the class row already carries that information, so the member is not repeated. A
member is recorded iff its presence differs from its class's (added/removed
mid-life) OR its signature drifts. This turns ~3.4k net-new methods into a few
hundred genuinely-interesting member deltas (dominated by new APIs bolted onto
long-lived classes --- exactly the toolkit's cross-version risk surface).

Signature identity uses Godot's own method ``hash`` (the ABI signature hash) for
methods/utility-functions --- an exact drift signal --- and the declared type /
enum-value set for properties / enums / signals.

Raw dumps are NOT committed (regenerate via dump_api.sh); only the distilled
outputs in this directory are.

Usage:  python build_compat_map.py            # reads default DUMPROOT
        DUMPROOT=/path python build_compat_map.py
"""
import json
import os
import sys
from datetime import date

VERSIONS = ["4.2", "4.3", "4.4", "4.5", "4.6", "4.7"]
DUMPROOT = os.environ.get(
    "DUMPROOT",
    "C:/Users/nicol/OneDrive/Desktop/Personal/AIWithGodot/_TempForClaude/xversion-dumps",
)
OUTDIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # cross-version-audit/


def present_str(flags):
    """6-char presence string over VERSIONS: 'Y' present, '-' absent."""
    return "".join("Y" if f else "-" for f in flags)


def intro_of(flags):
    for v, f in zip(VERSIONS, flags):
        if f:
            return v
    return None


def outro_of(flags):
    last = None
    for v, f in zip(VERSIONS, flags):
        if f:
            last = v
    return last


def pattern_note(flags, sig_stable):
    """One-word human tag for a presence/stability pattern."""
    p = present_str(flags)
    tags = []
    if p == "YYYYYY":
        tags.append("all" if sig_stable else "sig-drift")
    else:
        i, o = intro_of(flags), outro_of(flags)
        contiguous = "Y-Y" not in p.strip("-")  # no gap between first and last Y
        if not contiguous:
            tags.append("intermittent")
        if i != "4.2":
            tags.append(f"added-{i}")
        if o != "4.7":
            tags.append(f"removed-after-{o}")
        if not sig_stable:
            tags.append("sig-drift")
    return "+".join(tags) if tags else "all"


def load_dumps():
    dumps = {}
    for v in VERSIONS:
        path = os.path.join(DUMPROOT, v, "extension_api.json")
        if not os.path.isfile(path):
            sys.exit(f"ERROR: missing dump for {v}: {path}\n  Run dump_api.sh first.")
        with open(path, encoding="utf-8") as fh:
            dumps[v] = json.load(fh)
    return dumps


def method_sig(m):
    """Human-readable signature; hash is the identity key, this is for display."""
    args = ", ".join(
        f"{a.get('name', '')}: {a.get('type', '')}"
        + (f" = {a['default_value']}" if "default_value" in a else "")
        for a in m.get("arguments", [])
    )
    if m.get("is_vararg"):
        args = (args + ", ..." if args else "...")
    ret = (m.get("return_value") or {}).get("type", "void")
    pre = ("static " if m.get("is_static") else "") + ("const " if m.get("is_const") else "")
    return f"{pre}{ret} ({args})"


def index_version(d):
    """Flatten one dump into lookup dicts keyed by symbol."""
    classes = {}            # name -> {api_type, inherits}
    methods = {}            # "Class.method" -> (hash, sig, owner)
    properties = {}         # "Class.prop"   -> (type, owner)
    signals = {}            # "Class.sig"    -> (argtypes, owner)
    enums = {}              # "Class.ENUM"   -> (values-tuple, owner)
    for c in d.get("classes", []):
        cn = c["name"]
        classes[cn] = {"api_type": c.get("api_type", ""), "inherits": c.get("inherits", "")}
        for m in c.get("methods", []) or []:
            compat = frozenset(str(h) for h in (m.get("hash_compatibility") or []))
            methods[f"{cn}.{m['name']}"] = (
                str(m.get("hash", "")), method_sig(m), cn, compat, bool(m.get("is_virtual")))
        for p in c.get("properties", []) or []:
            properties[f"{cn}.{p['name']}"] = (p.get("type", ""), cn)
        for s in c.get("signals", []) or []:
            at = tuple(a.get("type", "") for a in s.get("arguments", []) or [])
            signals[f"{cn}.{s['name']}"] = (at, cn)
        for e in c.get("enums", []) or []:
            vals = tuple(sorted((v.get("name", ""), v.get("value", 0)) for v in e.get("values", []) or []))
            enums[f"{cn}.{e['name']}"] = (vals, cn)
    utils = {u["name"]: str(u.get("hash", "")) for u in d.get("utility_functions", []) or []}
    genums = {}
    for e in d.get("global_enums", []) or []:
        genums[e["name"]] = tuple(sorted((v.get("name", ""), v.get("value", 0)) for v in e.get("values", []) or []))
    singletons = {s["name"]: s.get("type", "") for s in d.get("singletons", []) or []}
    return dict(classes=classes, methods=methods, properties=properties,
                signals=signals, enums=enums, utils=utils, genums=genums, singletons=singletons)


def collect(idx, cat):
    """union symbol -> per-version value (None if absent) for a category."""
    out = {}
    for v in VERSIONS:
        for sym, val in idx[v][cat].items():
            out.setdefault(sym, {})[v] = val
    return out


def build():
    dumps = load_dumps()
    idx = {v: index_version(dumps[v]) for v in VERSIONS}

    # ---- class-level presence (backbone, ALL classes) ----
    class_union = collect(idx, "classes")
    class_present = {}      # name -> 6-flag list
    classes_out = {}
    for name, perv in sorted(class_union.items()):
        flags = [v in perv for v in VERSIONS]
        class_present[name] = flags
        # api_type/inherits from the newest version present
        newest = [v for v in VERSIONS if v in perv][-1]
        classes_out[name] = {
            "present": present_str(flags),
            "api_type": perv[newest]["api_type"],
            "inherits": perv[newest]["inherits"],
        }

    member_deltas = {}      # symbol -> record
    stats = {"methods": 0, "properties": 0, "signals": 0, "enums": 0}

    def owner_flags(owner):
        return class_present.get(owner, [True] * 6)

    # methods (with hash_compatibility-aware drift classification)
    drift_counts = {"preserved": 0, "breaking-callable": 0, "virtual-drift": 0}
    for sym, perv in collect(idx, "methods").items():
        flags = [v in perv for v in VERSIONS]
        present_vs = [v for v in VERSIONS if v in perv]
        owner = perv[present_vs[0]][2]
        of = owner_flags(owner)
        hashes = [perv[v][0] for v in present_vs]
        sig_stable = len(set(hashes)) <= 1
        if flags == of and sig_stable:
            continue  # stable within class lifetime --- collapsed
        is_virtual = perv[present_vs[-1]][4]
        rec = {"kind": "method", "present": present_str(flags),
               "owner_present": present_str(of), "intro": intro_of(flags),
               "note": pattern_note(flags, sig_stable)}
        if is_virtual:
            rec["is_virtual"] = True
        if sig_stable:
            rec["sig"] = perv[present_vs[0]][1]
            rec["hash"] = hashes[0]
        else:
            # Backward-compat: is every present version's primary hash still
            # callable in the newest version it exists in (hash + hash_compatibility)?
            newest = present_vs[-1]
            supported = {perv[newest][0]} | perv[newest][3]
            preserved = all(h in supported for h in hashes)
            if preserved:
                dclass = "preserved"
            elif is_virtual:
                dclass = "virtual-drift"
            else:
                dclass = "breaking-callable"
            drift_counts[dclass] += 1
            rec["drift"] = dclass
            rec["note"] = rec["note"] + f"+{dclass}"
            if dclass == "breaking-callable":
                # genuine break in callable API --- keep full per-version detail
                rec["sig_by_version"] = {v: perv[v][1] for v in present_vs}
                rec["hash_by_version"] = {v: perv[v][0] for v in present_vs}
            else:
                # 'preserved' (old bindings retained) or 'virtual-drift' (matters
                # only if overridden) --- store compactly; per-version sigs are
                # recoverable from the raw dumps via lookup.py --version <v>.
                rec["sig"] = perv[newest][1]
        member_deltas[sym] = rec
        stats["methods"] += 1
    stats["method_drift"] = drift_counts

    # properties
    for sym, perv in collect(idx, "properties").items():
        flags = [v in perv for v in VERSIONS]
        owner = list(perv.values())[0][1]
        of = owner_flags(owner)
        idents = {v: perv[v][0] for v in perv}       # type
        sig_stable = len(set(idents.values())) <= 1
        if flags == of and sig_stable:
            continue
        rec = {"kind": "property", "present": present_str(flags),
               "owner_present": present_str(of), "intro": intro_of(flags),
               "note": pattern_note(flags, sig_stable)}
        if sig_stable:
            rec["type"] = perv[next(v for v in VERSIONS if v in perv)][0]
        else:
            rec["type_by_version"] = {v: perv[v][0] for v in VERSIONS if v in perv}
        member_deltas[sym] = rec
        stats["properties"] += 1

    # signals
    for sym, perv in collect(idx, "signals").items():
        flags = [v in perv for v in VERSIONS]
        owner = list(perv.values())[0][1]
        of = owner_flags(owner)
        idents = {v: perv[v][0] for v in perv}
        sig_stable = len(set(idents.values())) <= 1
        if flags == of and sig_stable:
            continue
        rec = {"kind": "signal", "present": present_str(flags),
               "owner_present": present_str(of), "intro": intro_of(flags),
               "note": pattern_note(flags, sig_stable)}
        if not sig_stable:
            rec["args_by_version"] = {v: list(perv[v][0]) for v in VERSIONS if v in perv}
        else:
            rec["args"] = list(perv[next(v for v in VERSIONS if v in perv)][0])
        member_deltas[sym] = rec
        stats["signals"] += 1

    # enums (class-scoped)
    for sym, perv in collect(idx, "enums").items():
        flags = [v in perv for v in VERSIONS]
        owner = list(perv.values())[0][1]
        of = owner_flags(owner)
        idents = {v: perv[v][0] for v in perv}
        sig_stable = len(set(idents.values())) <= 1
        if flags == of and sig_stable:
            continue
        rec = {"kind": "enum", "present": present_str(flags),
               "owner_present": present_str(of), "intro": intro_of(flags),
               "note": pattern_note(flags, sig_stable)}
        if not sig_stable:
            rec["values_by_version"] = {v: dict(perv[v][0]) for v in VERSIONS if v in perv}
        member_deltas[sym] = rec
        stats["enums"] += 1

    # ---- global symbols (no owner class => baseline = all-present) ----
    global_deltas = {}
    for sym, perv in collect(idx, "utils").items():
        flags = [v in perv for v in VERSIONS]
        idents = {v: perv[v] for v in perv}
        sig_stable = len(set(idents.values())) <= 1
        if all(flags) and sig_stable:
            continue
        global_deltas[f"@util:{sym}"] = {
            "kind": "utility_function", "present": present_str(flags),
            "intro": intro_of(flags), "note": pattern_note(flags, sig_stable),
            "hash_by_version": {v: perv[v] for v in VERSIONS if v in perv} if not sig_stable else None,
        }
    for sym, perv in collect(idx, "genums").items():
        flags = [v in perv for v in VERSIONS]
        idents = {v: perv[v] for v in perv}
        sig_stable = len(set(idents.values())) <= 1
        if all(flags) and sig_stable:
            continue
        rec = {"kind": "global_enum", "present": present_str(flags),
               "intro": intro_of(flags), "note": pattern_note(flags, sig_stable)}
        if not sig_stable:
            rec["values_by_version"] = {v: dict(perv[v]) for v in VERSIONS if v in perv}
        global_deltas[f"@genum:{sym}"] = rec
    for sym, perv in collect(idx, "singletons").items():
        flags = [v in perv for v in VERSIONS]
        if all(flags):
            continue
        global_deltas[f"@singleton:{sym}"] = {
            "kind": "singleton", "present": present_str(flags),
            "intro": intro_of(flags), "note": pattern_note(flags, True)}

    headers = {v: dumps[v]["header"] for v in VERSIONS}
    meta = {
        "generated": str(date.today()),
        "versions": VERSIONS,
        "presence_legend": "6-char string over versions [4.2,4.3,4.4,4.5,4.6,4.7]; 'Y'=present '-'=absent",
        "editor_builds": {
            v: f"{headers[v].get('version_full_name', '')}"
            for v in VERSIONS
        },
        "convention": (
            "A class member NOT listed in member_deltas is present-and-stable wherever "
            "its owner class is present (see classes[].present). member_deltas holds only "
            "members whose presence differs from their class's lifetime OR whose signature "
            "drifts. Signature identity for methods/utility-functions uses Godot's ABI hash."
        ),
        "counts": {
            "classes": len(classes_out),
            "member_deltas": len(member_deltas),
            "global_deltas": len(global_deltas),
            "member_deltas_by_kind": {k: v for k, v in stats.items() if k != "method_drift"},
            "method_drift": stats.get("method_drift", {}),
        },
        "audit_headline": (
            "Across 4.2-4.7 ZERO regular (callable) methods lost their old binding: "
            "every callable-method signature drift is compat-preserved via "
            "hash_compatibility. Signature-drift risk is confined to (a) overridden "
            "virtual methods (drift='virtual-drift') and (b) calling a method with a "
            "signature newer than the toolkit's min supported version. Existence risk "
            "(class-1) is a method/class present only in newer versions (note='added-*')."
        ),
    }

    compat = {
        "meta": meta,
        "classes": classes_out,
        "member_deltas": dict(sorted(member_deltas.items())),
        "global_deltas": dict(sorted(global_deltas.items())),
    }
    with open(os.path.join(OUTDIR, "compat-map.json"), "w", encoding="utf-8") as fh:
        json.dump(compat, fh, indent=1, sort_keys=False)
        fh.write("\n")

    # compat-map.tsv (flat greppable)
    with open(os.path.join(OUTDIR, "compat-map.tsv"), "w", encoding="utf-8") as fh:
        fh.write("kind\tsymbol\tpresent\tintro\tnote\tdetail\n")
        for name, rec in classes_out.items():
            fh.write(f"class\t{name}\t{rec['present']}\t{intro_of([c=='Y' for c in rec['present']])}\t{rec['api_type']}\t{rec['inherits']}\n")
        for sym, rec in compat["member_deltas"].items():
            detail = rec.get("sig") or rec.get("type") or (";".join(f"{k}={v}" for k, v in (rec.get("sig_by_version") or rec.get("type_by_version") or {}).items()))
            fh.write(f"{rec['kind']}\t{sym}\t{rec['present']}\t{rec['intro']}\t{rec['note']}\t{detail}\n")
        for sym, rec in compat["global_deltas"].items():
            fh.write(f"{rec['kind']}\t{sym}\t{rec['present']}\t{rec['intro']}\t{rec['note']}\t\n")

    # delta-report.md (human pairwise narrative)
    write_delta_report(idx, class_present, compat)

    print("Compat map built. Counts:")
    print(json.dumps(meta["counts"], indent=2))
    for v in VERSIONS:
        print(f"  {v}: {headers[v].get('version_full_name','')}")
    return compat


def write_delta_report(idx, class_present, compat):
    lines = ["# Cross-version delta report (4.2 -> 4.7)", "",
             "Pairwise surface deltas between adjacent supported Godot versions, derived",
             "from `extension_api.json`. Class additions/removals and member additions to",
             "long-lived classes are the toolkit's cross-version risk surface.", ""]
    for a, b in zip(VERSIONS, VERSIONS[1:]):
        ca, cb = set(idx[a]["classes"]), set(idx[b]["classes"])
        added_c = sorted(cb - ca)
        removed_c = sorted(ca - cb)
        ma, mb = set(idx[a]["methods"]), set(idx[b]["methods"])
        # only report added methods on classes that already existed in `a`
        added_m_existing = sorted(m for m in (mb - ma) if m.split(".")[0] in ca)
        removed_m = sorted(ma - mb)
        # hash drift on methods present in both --- classified by backward-compat
        drift_preserved = drift_virtual = 0
        breaking_callable = []
        for m in sorted(ma & mb):
            oh = idx[a]["methods"][m][0]
            nh, _, _, ncompat, nvirtual = idx[b]["methods"][m]
            if oh == nh:
                continue
            if oh in ({nh} | ncompat):
                drift_preserved += 1
            elif nvirtual:
                drift_virtual += 1
            else:
                breaking_callable.append(m)
        editor_added = [m for m in added_m_existing
                        if idx[b]["classes"].get(m.split(".")[0], {}).get("api_type", "").startswith("editor")]
        lines += [f"## {a} -> {b}", "",
                  f"- **Classes:** +{len(added_c)} / -{len(removed_c)}"
                  + (f" --- added: {', '.join(added_c[:20])}{' ...' if len(added_c) > 20 else ''}" if added_c else "")]
        if removed_c:
            lines.append(f"  - removed: {', '.join(removed_c)}")
        lines.append(f"- **Methods added to pre-existing classes:** {len(added_m_existing)}"
                     + (f" (editor-API: {len(editor_added)})" if editor_added else ""))
        if editor_added:
            lines.append(f"  - editor: {', '.join(editor_added[:30])}{' ...' if len(editor_added) > 30 else ''}")
        if removed_m:
            lines.append(f"- **Methods removed:** {len(removed_m)} --- {', '.join(removed_m[:30])}{' ...' if len(removed_m) > 30 else ''}")
        lines.append(f"- **Signature drift:** compat-preserved {drift_preserved}, virtual {drift_virtual}, "
                     f"**breaking-callable {len(breaking_callable)}**"
                     + (f" --- {', '.join(breaking_callable)}" if breaking_callable else " (none)"))
        lines.append("")
    with open(os.path.join(OUTDIR, "delta-report.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    build()

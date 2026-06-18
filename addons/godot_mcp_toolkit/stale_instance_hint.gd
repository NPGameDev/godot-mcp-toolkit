@tool
extends RefCounted
## Pure decision + message helpers for the stale-live-instance method-call hazard
## (41m-bis-bis). On Godot < 4.4 a live instance already running a script does NOT
## see edits to that script — newly-added members AND changed method bodies — until
## the editor relaunches: editor.refresh, re-attaching the script, and even a
## brand-new node all keep the OLD code. 4.4+ hot-reloads promptly, so no hint there.
##
## Empirically characterised across 4.2.0 / 4.3.0 / 4.4.1 / 4.5.0 / 4.6.2 (boundary
## 4.3 -> 4.4) — see Insights/stale-live-instance-method-hazard.md and the server
## flow test/flows/02_hot_reload_reachability.ts. Scenario D proved a fresh node is
## ALSO stale on 4.2 AND 4.3, so both collapse to one recovery (relaunch) — there is
## no 4.2-vs-4.3 split.
##
## SPLIT (mirrors unfocused_backup.gd): every function here is PURE and headless —
## the decision predicates take the version `major`/`minor` as data, so run_unit_tests.gd
## exercises both branches across major/minor pairs (4.2-4.6 + a 5.0 guard) without
## an editor. The
## editor-coupled callers read the running version / on-disk source and feed these:
##   - script_commands.gd  : proactive hint on script.write of an existing .gd
##   - node_commands.gd    : reactive hint on node.call_method -> INVALID_METHOD
##
## Godot 4.x is the supported world; the gate is `major == 4 and minor < 4`, so the
## 4.0-4.3 hot-reload hazard is matched while 4.4+ AND any future 5.x correctly skip
## it. The editor-coupled callers feed both `major` and `minor` (not minor alone) from
## `Engine.get_version_info()`.

const _RECOVERY := (
	"On Godot %s, a live instance already running this script keeps the OLD code: "
	+ "changed method bodies AND newly-added members stay invisible to it. "
	+ "editor.refresh, re-attaching the script, and even creating a fresh node do NOT "
	+ "pick up the edit on Godot < 4.4 — relaunch the editor (or disable then re-enable "
	+ "the plugin) before calling the changed or added members."
)

const _WRITE_PREFIX := (
	"Validate scripts with script_check or lsp_diagnostics (errors also surface in "
	+ "editor_get_console). Then note: "
)


## Proactive trigger: an EXISTING .gd was re-written AND it compiled OK AND the
## editor is Godot < 4.4. (Create / 4.4+ / compile-fail / non-.gd -> no hint.)
static func should_warn_on_write(existed: bool, compiled_ok: bool, extension: String, major: int, minor: int) -> bool:
	return existed and compiled_ok and extension == "gd" and major == 4 and minor < 4


## Reactive trigger: node.call_method hit INVALID_METHOD (has_method false) on a
## .gd-scripted node whose ON-DISK source DEFINES the method and COMPILES, on Godot
## < 4.4 -> the live instance is stale (not a typo). Method absent on disk -> typo,
## no hint. Disk doesn't compile -> the real fix is the compile error (Option B), no
## stale hint. 4.4+ -> has_method would already be true, so this never fires.
static func should_hint_on_call(
	has_method: bool, disk_has_method: bool, disk_compiles: bool, is_gd: bool, major: int, minor: int
) -> bool:
	return (not has_method) and disk_has_method and disk_compiles and is_gd and major == 4 and minor < 4


## The shared recovery guidance (single < 4.4 form — 4.2 and 4.3 BOTH need relaunch;
## a fresh node helps on neither). `ver_label` is the detected "major.minor" so the
## message names the real running version.
static func recovery_message(ver_label: String) -> String:
	return _RECOVERY % ver_label


## Composed hint for a successful script.write (Q3 ordering: validation guidance
## leads, the situational stale nudge takes the recency slot).
static func write_hint(ver_label: String) -> String:
	return _WRITE_PREFIX + recovery_message(ver_label)


## True if `source` parses/compiles as GDScript. SAFE in-process parse via
## GDScript.new().reload() — NOT ResourceLoader.load(CACHE_MODE_IGNORE), which
## corrupts already-loaded scripts on every version (P-056). class_name is blanked
## first to avoid a global-class double-registration false positive (P-053).
static func source_compiles(source: String) -> bool:
	var lines := source.split("\n")
	for i in lines.size():
		if lines[i].strip_edges().begins_with("class_name "):
			lines[i] = ""
			break
	var script := GDScript.new()
	script.source_code = "\n".join(lines)
	return script.reload(false) == OK


## True if `source` defines `func <method>` (line scan on the raw text — no compile,
## no regex flags). Matches `func name(`, `static func name (`, and indented
## inner-class methods; ignores `func` appearing inside strings/comments because the
## stripped line must START with `func ` / `static func `.
static func source_has_method(source: String, method: String) -> bool:
	if method.is_empty():
		return false
	for raw_line in source.split("\n"):
		var line := raw_line.strip_edges()
		if not (line.begins_with("func ") or line.begins_with("static func ")):
			continue
		var after := line.substr(line.find("func ") + 5).strip_edges()
		var paren := after.find("(")
		if paren == -1:
			continue
		if after.substr(0, paren).strip_edges() == method:
			return true
	return false

@tool
extends RefCounted
## Pure decision + message helpers for the stale-live-instance method-call hazard.
## A toolkit write reloads the script the editor has cached, but a file changed outside
## the toolkit is not: on Godot < 4.4 a live instance already running that script does
## NOT see the edit — newly-added members AND changed method bodies — and editor_refresh
## doesn't change that. node_set_script reloads a script whose file changed, so setting
## the script again recovers, on a fresh node or the same one. 4.4+ hot-reloads promptly
## on a display editor, so no hint there — but a HEADLESS 4.4+ editor never
## re-instantiates the live node, so the stale hint fires there too, with its own
## headless-specific wording. On Godot 4.2.0 and 4.2.1 the toolkit reloads nothing in
## place (an in-place reload there can crash the editor), so a toolkit write leaves the
## live instance stale too, and only a relaunch recovers: those versions get the
## relaunch wording, on the write and on the call.
##
## Empirically characterised across 4.2.0 / 4.3.0 / 4.4.1 / 4.5.0 / 4.6.2 (boundary
## 4.3 -> 4.4); 4.2 and 4.3 behave alike, so there is no 4.2-vs-4.3 split.
##
## SPLIT (mirrors unfocused_backup.gd): every function here is PURE and headless —
## the decision predicate takes the version `major`/`minor` plus the `headless` flag as
## data, so run_unit_tests.gd exercises every branch across major/minor/headless
## combinations (4.2-4.6 + a 5.0 guard) without an editor. The editor-coupled caller
## reads the running version and the on-disk source and feeds these when
## node.call_method hits INVALID_METHOD.
##
## Godot 4.x is the supported world; the gate is `major == 4 and (minor < 4 or headless)`,
## so the 4.0-4.3 hot-reload hazard is always matched, the 4.4+ hazard is matched only
## when headless, and any future 5.x correctly skips it. The editor-coupled callers feed
## `major`, `minor`, and the headless flag from `Engine.get_version_info()` /
## `DisplayServer`.

# Direct preload, not through core/modules.gd: the aggregator preloads this file.
const GDScriptSource := preload("res://addons/godot_mcp_toolkit/core/gdscript_source.gd")

const _RECOVERY := (
	"On Godot %s, a live instance already running this script keeps the OLD code: "
	+ "changed method bodies AND newly-added members stay invisible to it, and "
	+ "editor_refresh does NOT pick up the edit on Godot < 4.4. Set the script again "
	+ "with node_set_script, which reloads it from disk, before calling the changed or "
	+ "added members (or relaunch the editor)."
)

# Godot 4.4+ headless: a display editor hot-reloads live instances promptly, but a
# headless editor never re-instantiates them — a distinct hazard from the < 4.4
# engine-cache staleness, so it carries its own guidance (recovery is setting the
# script again or relaunching, never editor_refresh).
const _RECOVERY_HEADLESS := (
	"On Godot %s, the live instance running this script is stale — "
	+ "headless editors don't re-instantiate live nodes on reload — set the script "
	+ "again with node_set_script or relaunch a display editor; the edit is on disk, "
	+ "confirm with script_check."
)

# Godot 4.2.0 and 4.2.1, where node_set_script does not reload the script either.
const _RECOVERY_RELAUNCH := (
	"On Godot %s, a live instance already running this script keeps the OLD code: "
	+ "changed method bodies AND newly-added members stay invisible to it. "
	+ "editor_refresh, setting the script again, and even creating a fresh node do NOT "
	+ "pick up the edit on Godot 4.2.0 and 4.2.1 — relaunch the editor (or disable then "
	+ "re-enable the plugin) before calling the changed or added members."
)

const _WRITE_PREFIX := (
	"Validate scripts with script_check or lsp_diagnostics (errors also surface in "
	+ "editor_get_console). Then note: "
)


## Reactive trigger: node.call_method hit INVALID_METHOD (has_method false) on a
## .gd-scripted node whose ON-DISK source DEFINES the method and COMPILES, and the live
## instance is stale. Two stale regimes: Godot < 4.4 in any mode (the editor never
## hot-reloads a live instance), OR Godot 4.4+ when [param headless] (a display editor
## hot-reloads — has_method would already be true — but a headless editor never
## re-instantiates the reloaded node). Method absent on disk -> typo, no hint. Disk
## doesn't compile -> the real fix is the compile error (Option B), no stale hint. 4.4+
## with a display -> not stale, so this never fires.
static func should_hint_on_call(
	has_method: bool, disk_has_method: bool, disk_compiles: bool, is_gd: bool,
	major: int, minor: int, headless: bool = false,
) -> bool:
	if not ((not has_method) and disk_has_method and disk_compiles and is_gd and major == 4):
		return false
	return minor < 4 or headless


## The recovery guidance, tailored to the stale regime. [param ver_label] is the detected
## "major.minor" so the message names the real running version. When [param headless] and
## the engine is 4.4+ ([param minor] >= 4), returns the headless re-instantiation form;
## otherwise the < 4.4 engine-cache form (4.2 and 4.3 alike), which is also what the
## defaults give. [param set_script_reloads] is false where node_set_script does not
## reload a changed script (Godot 4.2.0 and 4.2.1), which gets the relaunch form.
static func recovery_message(
		ver_label: String, minor: int = -1, headless: bool = false, set_script_reloads: bool = true,
) -> String:
	if headless and minor >= 4:
		return _RECOVERY_HEADLESS % ver_label
	if not set_script_reloads:
		return _RECOVERY_RELAUNCH % ver_label
	return _RECOVERY % ver_label


## The hint for a script_write or script_edit of an existing .gd that compiled on an
## engine where the toolkit does not reload it (Godot 4.2.0 and 4.2.1). Validation
## guidance leads; the stale nudge takes the recency slot.
static func write_hint(ver_label: String) -> String:
	return _WRITE_PREFIX + recovery_message(ver_label, -1, false, false)


## True if `source`, the file at `file_path`, parses/compiles as GDScript and its
## class_name clashes with nothing. SAFE in-process parse via GDScript.new().reload()
## — NOT ResourceLoader.load(CACHE_MODE_IGNORE), which corrupts already-loaded
## scripts on every version. The compiles run with error printing off (see
## `GDScriptSource.judge()`); an empty `file_path` stands for source with no file.
static func source_compiles(source: String, file_path: String = "") -> bool:
	return bool(GDScriptSource.judge(source, file_path)["valid"])


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

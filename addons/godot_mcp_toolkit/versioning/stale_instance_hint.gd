@tool
extends RefCounted
## Pure decision + message helpers for the stale-live-instance method-call hazard.
## On Godot < 4.4 a live instance already running a script does NOT see edits to that
## script — newly-added members AND changed method bodies — until the editor relaunches:
## editor.refresh, re-attaching the script, and even a brand-new node all keep the OLD
## code. 4.4+ hot-reloads promptly on a display editor, so no hint there — but a HEADLESS
## 4.4+ editor never re-instantiates the live node, so the stale hint fires there too,
## with its own headless-specific wording.
##
## Empirically characterised across 4.2.0 / 4.3.0 / 4.4.1 / 4.5.0 / 4.6.2 (boundary
## 4.3 -> 4.4). The characterisation also proved a fresh node is
## ALSO stale on 4.2 AND 4.3, so both collapse to one recovery (relaunch) — there is
## no 4.2-vs-4.3 split.
##
## SPLIT (mirrors unfocused_backup.gd): every function here is PURE and headless —
## the decision predicates take the version `major`/`minor` plus the `headless` flag as
## data, so run_unit_tests.gd exercises every branch across major/minor/headless
## combinations (4.2-4.6 + a 5.0 guard) without an editor. The
## editor-coupled callers read the running version / on-disk source and feed these:
##   - script_commands.gd  : proactive hint on script.write of an existing .gd
##   - node_commands.gd    : reactive hint on node.call_method -> INVALID_METHOD
##
## Godot 4.x is the supported world; the gate is `major == 4 and (minor < 4 or headless)`,
## so the 4.0-4.3 hot-reload hazard is always matched, the 4.4+ hazard is matched only
## when headless, and any future 5.x correctly skips it. The editor-coupled callers feed
## `major`, `minor`, and the headless flag from `Engine.get_version_info()` /
## `DisplayServer`.

const _RECOVERY := (
	"On Godot %s, a live instance already running this script keeps the OLD code: "
	+ "changed method bodies AND newly-added members stay invisible to it. "
	+ "editor.refresh, re-attaching the script, and even creating a fresh node do NOT "
	+ "pick up the edit on Godot < 4.4 — relaunch the editor (or disable then re-enable "
	+ "the plugin) before calling the changed or added members."
)

# Godot 4.4+ headless: a display editor hot-reloads live instances promptly, but a
# headless editor never re-instantiates them — a distinct hazard from the < 4.4
# engine-cache staleness, so it carries its own guidance (recovery is re-create or
# relaunch, never editor.refresh).
const _RECOVERY_HEADLESS := (
	"On Godot %s, the live instance running this script is stale — "
	+ "headless editors don't re-instantiate live nodes on reload — re-create the node "
	+ "or relaunch a display editor; the edit is on disk, confirm with script_check."
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
## otherwise the < 4.4 engine-cache form (4.2 and 4.3 BOTH need relaunch; a fresh node
## helps on neither). The defaults keep the single-arg < 4.4 callers (write_hint) intact.
static func recovery_message(ver_label: String, minor: int = -1, headless: bool = false) -> String:
	if headless and minor >= 4:
		return _RECOVERY_HEADLESS % ver_label
	return _RECOVERY % ver_label


## Composed hint for a successful script.write (deliberate ordering: validation
## guidance leads, the situational stale nudge takes the recency slot).
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

@tool
extends Node

const PORT := 6505
const BIND := "127.0.0.1"
const JSONRPC_VERSION := "2.0"
# iter 13: throttle re-listen retries to avoid log spam when the port is
# briefly held by another process (e.g. a second editor instance, a stale
# debugger). 60 frames ≈ 1s at 60fps; the bridge's reconnect backoff sits
# on the same order so we don't pile retries on top of the bridge's.
const _RELISTEN_FRAME_INTERVAL := 60
# iter 13c: poll TCPServer/WebSocket peers every Nth frame instead of every
# frame. Godot 4.4.1 has a race between our per-frame poll and the main-loop
# work triggered by FileSystem-dock interactions; shrinking our collision
# window ~4x (15Hz vs 60Hz) drops the reproducibility threshold enough that
# incidental clicks stop crashing the editor in smoke + dogfood usage.
# Tune lower if latency regresses noticeably; 4 frames ≈ 67ms at 60fps.
# (Trial with interval=2 + `call_deferred` dispatch crashed at run 4 of 20
# in dirty-stress testing — the deferral didn't materially help and the
# interval reduction halved the protective margin. Reverted to interval=4.)
const _POLL_FRAME_INTERVAL := 4

var _tcp_server: TCPServer = null
var _peers: Array[WebSocketPeer] = []
var _relisten_countdown := 0
# Tracks the current run of consecutive _try_listen() failures so we can log
# the first one (with a hint), stay silent during retries, and announce the
# recovery with the attempt count. Reset on every successful listen.
var _consecutive_failures := 0
# iter 13c: counter for _POLL_FRAME_INTERVAL frame-skip.
var _poll_frame_counter := 0


func start() -> void:
	# Initial listen attempt. _process picks up the retry slack on failure
	# (iter 13) — start() never blocks plugin enable on a transient bind
	# error; it just kicks off the loop.
	_relisten_countdown = 0
	_try_listen()


func stop() -> void:
	for peer in _peers:
		if peer != null:
			peer.close(1000)
	_peers.clear()
	if _tcp_server != null:
		_tcp_server.stop()
		_tcp_server = null
	_relisten_countdown = 0
	_consecutive_failures = 0
	print("[MCPServer] stopped")


# iter 13: idempotent re-listen. Called from start() and from _process when
# the TCPServer falls out of the listening state (port stolen, manual stop,
# etc.). Frame-throttled via _relisten_countdown so failures don't spam.
func _try_listen() -> void:
	if _relisten_countdown > 0:
		_relisten_countdown -= 1
		return
	if _tcp_server == null:
		_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(PORT, BIND)
	if err == OK:
		if _consecutive_failures > 0:
			print("[MCPServer] listening on %s:%d (recovered after %d failed attempts)" % [BIND, PORT, _consecutive_failures])
		else:
			print("[MCPServer] listening on %s:%d" % [BIND, PORT])
		_consecutive_failures = 0
		_relisten_countdown = 0
		return
	_consecutive_failures += 1
	# Log only the FIRST failure of a streak — silent retries afterward
	# until either success (recovery message above) or the user intervenes.
	# Avoids the iter-13 pattern of one push_warning per second for the
	# entire duration a zombie process holds the port.
	if _consecutive_failures == 1:
		# err 22 = ERR_ALREADY_IN_USE — usually a zombie Godot process from a
		# prior crash still holding the port. Surface that so the user doesn't
		# have to look up Godot error codes; a stale process check in Task
		# Manager / netstat is the typical fix.
		var hint := ""
		if err == ERR_ALREADY_IN_USE:
			hint = " (ERR_ALREADY_IN_USE — likely a stale Godot/MCP process holding the port; will retry silently every ~1s, watch for the listening / recovered message)"
		push_warning("[MCPServer] bind %s:%d failed (err %d)%s" % [BIND, PORT, err, hint])
	# Discard the (potentially-stuck) TCPServer instance so the next retry
	# allocates a fresh one. Without this, certain Godot-internal latch
	# states keep returning ERR_ALREADY_IN_USE even after the actual port
	# is freed — exactly the regression that made iter-13's retry loop
	# need a manual plugin disable+re-enable to recover (the disable path
	# happens to do the same fresh-allocate via stop() + null + start()).
	_tcp_server.stop()
	_tcp_server = null
	_relisten_countdown = _RELISTEN_FRAME_INTERVAL


func _process(_delta: float) -> void:
	# iter 13c: frame-skip to poll at ~15Hz. Race with editor main-loop work
	# on FS dock interactions (Godot 4.4.1) is dramatically less reproducible
	# when we're not fighting for main-thread cycles every frame. Re-listen
	# retries still respect _RELISTEN_FRAME_INTERVAL below, so a missed
	# listen-check here just delays recovery by a few frames at worst.
	_poll_frame_counter += 1
	if _poll_frame_counter < _POLL_FRAME_INTERVAL:
		return
	_poll_frame_counter = 0

	# iter 13: keep the listener up across editor cycles. If start() failed
	# transiently or the port dropped, retry here on the throttle.
	if _tcp_server == null or not _tcp_server.is_listening():
		_try_listen()
		return

	while _tcp_server.is_connection_available():
		var stream := _tcp_server.take_connection()
		var peer := WebSocketPeer.new()
		var accept_err := peer.accept_stream(stream)
		if accept_err != OK:
			push_warning("[MCPServer] accept_stream failed (%d)" % accept_err)
			continue
		_peers.append(peer)

	var closed_peers: Array[WebSocketPeer] = []
	for peer in _peers:
		peer.poll()
		var state := peer.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			closed_peers.append(peer)
			continue
		if state != WebSocketPeer.STATE_OPEN:
			continue
		while peer.get_available_packet_count() > 0:
			var text := peer.get_packet().get_string_from_utf8()
			_handle_message(peer, text)

	for peer in closed_peers:
		_peers.erase(peer)


func _handle_message(peer: WebSocketPeer, text: String) -> void:
	var parser := JSON.new()
	var parse_err := parser.parse(text)
	if parse_err != OK:
		_send_error(peer, null, -32700, "Parse error: %s" % parser.get_error_message())
		return

	var msg = parser.data
	if typeof(msg) != TYPE_DICTIONARY:
		_send_error(peer, null, -32600, "Invalid Request: top-level must be an object")
		return

	var id = msg.get("id", null)
	# Godot's JSON parser returns every number as float; coerce whole-float ids
	# back to int so {"id": 1} round-trips as {"id": 1}, not {"id": 1.0}.
	if typeof(id) == TYPE_FLOAT and int(id) == id:
		id = int(id)
	var method := str(msg.get("method", ""))
	var params = msg.get("params", null)

	if method.is_empty():
		_send_error(peer, id, -32600, "Invalid Request: missing method")
		return

	match method:
		"echo":
			_send_result(peer, id, params)
		"scene.get_tree":
			_cmd_scene_get_tree(peer, id)
		"scene.create_node":
			_cmd_scene_create_node(peer, id, params)
		"scene.delete_node":
			_cmd_scene_delete_node(peer, id, params)
		"node.set_property":
			_cmd_node_set_property(peer, id, params)
		"node.get_property":
			_cmd_node_get_property(peer, id, params)
		"script.read":
			_cmd_script_read(peer, id, params)
		"script.write":
			_cmd_script_write(peer, id, params)
		"editor.get_errors":
			_cmd_editor_get_errors(peer, id)
		"editor.save_scene":
			_cmd_editor_save_scene(peer, id, params)
		"editor.screenshot":
			_cmd_editor_screenshot(peer, id, params)
		"editor.reload_scripts":
			_cmd_editor_reload_scripts(peer, id)
		"scene.open":
			_cmd_scene_open(peer, id, params)
		"project.get_settings":
			_cmd_project_get_settings(peer, id, params)
		"signal.list":
			_cmd_signal_list(peer, id, params)
		"signal.connect":
			_cmd_signal_connect(peer, id, params)
		"signal.disconnect":
			_cmd_signal_disconnect(peer, id, params)
		"signal.emit":
			_cmd_signal_emit(peer, id, params)
		"resource.load":
			_cmd_resource_load(peer, id, params)
		"node.get_property_list":
			_cmd_node_get_property_list(peer, id, params)
		"scene.diff":
			_cmd_scene_diff(peer, id, params)
		_:
			_send_error(peer, id, -32601, "Method not found: %s" % method)


func _send_result(peer: WebSocketPeer, id, result) -> void:
	var response := {
		"jsonrpc": JSONRPC_VERSION,
		"id": id,
		"result": result,
	}
	peer.send_text(JSON.stringify(response))


func _send_error(peer: WebSocketPeer, id, code: int, message: String) -> void:
	var response := {
		"jsonrpc": JSONRPC_VERSION,
		"id": id,
		"error": {
			"code": code,
			"message": message,
		},
	}
	peer.send_text(JSON.stringify(response))


# ---- Scene / node command helpers (iter 03) -------------------------------
#
# Domain errors flow back inside the JSON-RPC `result` payload as
# { code: "UPPER_SNAKE", error: "human message" } — distinct from the
# envelope `error` field used for transport-level failures (parse,
# method-not-found, etc.). The TS bridge (iter 05+) maps these to MCP
# isError=true responses per I1.


func _get_edited_root() -> Node:
	return EditorInterface.get_edited_scene_root()


# I1 error contract (iter 14). Canonical list of MCP tool-error codes —
# UPPER_SNAKE_CASE. Must stay in sync with src/types.ts `ErrorCode` union
# (server-repo) and the reference table in CLAUDE.md. Iter 16 (SOLID
# split) hoists this and `mcp_error` into a shared module; duplicated
# with mcp_runtime_server.gd for now to keep each file self-contained.
# ALREADY_EXISTS is listed for completeness even though I3 treats it as a
# non-error success payload (it travels in a happy-path dict, NOT through
# mcp_error). INVALID_PARAMS is JSON-RPC params-shape (e.g. missing
# required field); INVALID_CLASS is ClassDB rejection; INVALID_PATH is
# semantic path refusal (e.g. deleting scene root) distinct from
# PATH_DENIED (prefix / sandbox refusal — full form in iter 18).
const MCP_ERROR_CODES := [
	"ALREADY_EXISTS",
	"CONNECT_FAILED",
	"DISCONNECTED",
	"EXECUTE_FAILED",
	"FEATURE_DISABLED",
	"FILE_TOO_LARGE",
	"GAME_NOT_RUNNING",
	"INTERNAL",
	"INVALID_CLASS",
	"INVALID_PARAMS",
	"INVALID_PATH",
	"LOAD_FAILED",
	"NO_SCENE",
	"NOT_FOUND",
	"PARSE_ERROR",
	"PATH_DENIED",
	"READ_FAILED",
	"SAVE_FAILED",
	"TIMEOUT",
	"WRITE_FAILED",
]


# mcp_error — canonical failure envelope for tool responses (I1). Returned
# inside the JSON-RPC `result` payload (NOT the envelope `error` field —
# that's for transport-level failures). The TS bridge (server-repo)
# translates `success: false` into an MCP `isError: true` response.
static func mcp_error(code: String, message: String) -> Dictionary:
	return {"success": false, "error": message, "code": code}


# Returned paths are *relative to the edited scene root* — keeps responses
# compact (no editor-internal /@EditorNode@.../@SubViewport@.../... leak) and
# round-trips cleanly because Node.get_node_or_null() accepts relative paths.
# The root itself serialises as "." per NodePath convention.
func _path_in_scene(scene_root: Node, node: Node) -> String:
	return str(scene_root.get_path_to(node))


func _cmd_scene_get_tree(peer: WebSocketPeer, id) -> void:
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
		return
	# TODO(iter-18): wrap this tree in an <untrusted kind="scene_tree" source="godot"> envelope at the response layer.
	_send_result(peer, id, _walk_tree(root, root))


func _walk_tree(node: Node, scene_root: Node) -> Dictionary:
	var children: Array = []
	for child in node.get_children():
		children.append(_walk_tree(child, scene_root))
	return {
		"name": String(node.name),
		"class": node.get_class(),
		"path": _path_in_scene(scene_root, node),
		"children": children,
	}


func _cmd_scene_create_node(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
		return

	var cls := str(params.get("class_name", ""))
	var parent_path := str(params.get("parent", ""))
	# TODO(iter-18): filter `parent_path` through FileGuard.resolve_safe.
	var requested_name := str(params.get("name", cls))

	if cls.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing class_name"))
		return
	if not ClassDB.class_exists(cls):
		_send_result(peer, id, mcp_error("INVALID_CLASS", "unknown class: %s" % cls))
		return
	if not ClassDB.can_instantiate(cls):
		_send_result(peer, id, mcp_error("INVALID_CLASS", "class is not instantiable (abstract, virtual, or editor-only): %s" % cls))
		return
	if not ClassDB.is_parent_class(cls, "Node"):
		_send_result(peer, id, mcp_error("INVALID_CLASS", "not a Node subclass: %s" % cls))
		return

	var parent_node := root.get_node_or_null(parent_path) if not parent_path.is_empty() else root
	if parent_node == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "parent not found: %s" % parent_path))
		return

	# I3 idempotency: same-name child already present -> return it, don't duplicate.
	var existing := parent_node.get_node_or_null(NodePath(requested_name))
	if existing != null:
		_send_result(peer, id, {"path": _path_in_scene(root, existing), "code": "ALREADY_EXISTS"})
		return

	var instance = ClassDB.instantiate(cls)
	if instance == null or not (instance is Node):
		_send_result(peer, id, mcp_error("INVALID_CLASS", "instantiate failed: %s" % cls))
		return

	instance.name = requested_name
	parent_node.add_child(instance)
	instance.set_owner(root)
	_send_result(peer, id, {"path": _path_in_scene(root, instance)})


func _cmd_scene_delete_node(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
		return

	var path := str(params.get("path", ""))
	# TODO(iter-18): filter `path` through FileGuard.resolve_safe.
	if path.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing path"))
		return

	var node := root.get_node_or_null(path)
	if node == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "node not found: %s" % path))
		return
	if node == root:
		_send_result(peer, id, mcp_error("INVALID_PATH", "cannot delete edited scene root"))
		return

	# Editor-safe deletion via UndoRedo. Pattern matches godot-mcp-pro and
	# godotiq: the node is detached from the tree by the action, but
	# add_undo_reference(node) keeps a reference alive in the undo history,
	# so the editor's SceneTreeDock / Inspector never see a dangling pointer.
	# Plain queue_free() or synchronous free() on an editor-owned node is a
	# SIGSEGV hazard on Godot 4.4.1 Windows when any FileAccess write follows.
	var parent := node.get_parent()
	if parent == null:
		_send_result(peer, id, mcp_error("INTERNAL", "node has no parent: %s" % path))
		return
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("MCP: delete %s" % path)
	undo_redo.add_do_method(parent, "remove_child", node)
	undo_redo.add_undo_method(parent, "add_child", node)
	undo_redo.add_undo_method(node, "set_owner", root)
	undo_redo.add_undo_reference(node)
	undo_redo.commit_action()
	_send_result(peer, id, {"ok": true, "path": path})


func _cmd_node_set_property(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
		return

	var path := str(params.get("path", ""))
	var property := str(params.get("property", ""))
	var raw_value = params.get("value", null)
	# TODO(iter-18): filter `path` through FileGuard.resolve_safe.

	if path.is_empty() or property.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing path or property"))
		return

	var node := root.get_node_or_null(path)
	if node == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "node not found: %s" % path))
		return

	var coerced = _coerce_value(raw_value)
	node.set(property, coerced)
	_send_result(peer, id, {"ok": true})


func _cmd_node_get_property(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
		return

	var path := str(params.get("path", ""))
	var property := str(params.get("property", ""))
	# TODO(iter-18): filter `path` through FileGuard.resolve_safe.

	if path.is_empty() or property.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing path or property"))
		return

	var node := root.get_node_or_null(path)
	if node == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "node not found: %s" % path))
		return

	_send_result(peer, id, {"value": _serialize_value(node.get(property))})


func _coerce_value(v):
	# Dict-wrapped engine types: {type:"Vector2",x:..,y:..} -> Vector2(..).
	# Plain JSON primitives pass through unchanged.
	if typeof(v) != TYPE_DICTIONARY:
		return v
	match str(v.get("type", "")):
		"Vector2":
			return Vector2(float(v.get("x", 0.0)), float(v.get("y", 0.0)))
		"Vector3":
			return Vector3(float(v.get("x", 0.0)), float(v.get("y", 0.0)), float(v.get("z", 0.0)))
		"Color":
			return Color(float(v.get("r", 0.0)), float(v.get("g", 0.0)), float(v.get("b", 0.0)), float(v.get("a", 1.0)))
		_:
			return v


func _serialize_value(v):
	# JSON-native scalars pass through. Engine types (Vector2, Color, NodePath, ...)
	# get the lossless var_to_str string form so the TS side can round-trip via str_to_var.
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return v
		_:
			return var_to_str(v)


# ---- Script / editor command helpers (iter 04) ----------------------------


func _cmd_script_read(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	# TODO(iter-18): replace this prefix check with FileGuard.resolve_safe(path).
	if not path.begins_with("res://"):
		_send_result(peer, id, mcp_error("PATH_DENIED", "path must start with res://: %s" % path))
		return
	if not FileAccess.file_exists(path):
		_send_result(peer, id, mcp_error("NOT_FOUND", "file not found: %s" % path))
		return
	var content := FileAccess.get_file_as_string(path)
	var open_err := FileAccess.get_open_error()
	if open_err != OK:
		_send_result(peer, id, mcp_error("READ_FAILED", "FileAccess error %d reading %s" % [open_err, path]))
		return
	# TODO(iter-18): wrap content in <untrusted kind="script_content" source="<path>"> envelope.
	_send_result(peer, id, {"content": content})


func _cmd_script_write(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	# TODO(iter-18): replace this prefix check with FileGuard.resolve_safe(path).
	if not path.begins_with("res://"):
		_send_result(peer, id, mcp_error("PATH_DENIED", "path must start with res://: %s" % path))
		return
	if not params.has("content"):
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing content"))
		return
	var content := str(params.get("content", ""))
	# I5: never wrap user-destination content — `content` is written to disk verbatim.

	# Capture prior state so the UndoRedo undo path is correct. If the file
	# exists we read-and-restore; if it's new, undo deletes. FileAccess reads
	# can fail — surface that instead of silently losing undo coverage.
	var existed := FileAccess.file_exists(path)
	var prior_content := ""
	if existed:
		prior_content = FileAccess.get_file_as_string(path)
		var read_err := FileAccess.get_open_error()
		if read_err != OK:
			_send_result(peer, id, mcp_error("READ_FAILED", "could not read prior content of %s (err %d)" % [path, read_err]))
			return

	# Attempt the write up-front so failures surface as WRITE_FAILED instead of
	# silently landing as a push_warning during UndoRedo's deferred commit.
	var write_err := _write_file_raw(path, content)
	if write_err != OK:
		_send_result(peer, id, mcp_error("WRITE_FAILED", "could not open %s for write (err %d)" % [path, write_err]))
		return

	# Wire the already-performed write into the editor's UndoRedo history so
	# Ctrl-Z restores prior state (or deletes, for new files). `do_method` is
	# a no-op replay of the write we just committed; `undo_method` reverses it.
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("MCP script_write: %s" % path)
	undo_redo.add_do_method(self, "_write_file_silent", path, content)
	if existed:
		undo_redo.add_undo_method(self, "_write_file_silent", path, prior_content)
	else:
		undo_redo.add_undo_method(self, "_delete_file_silent", path)
	# execute=false so UndoRedo doesn't double-apply the do_method we already ran.
	undo_redo.commit_action(false)

	var bytes_written := content.to_utf8_buffer().size()
	_send_result(peer, id, {"ok": true, "bytes": bytes_written, "undoable": true})


func _write_file_raw(path: String, content: String) -> int:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(content)
	file.close()
	return OK


func _write_file_silent(path: String, content: String) -> void:
	var err := _write_file_raw(path, content)
	if err != OK:
		push_warning("[MCPServer] UndoRedo write of %s failed (err %d)" % [path, err])


func _delete_file_silent(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var err := DirAccess.remove_absolute(path)
	if err != OK:
		push_warning("[MCPServer] UndoRedo delete of %s failed (err %d)" % [path, err])


func _cmd_editor_get_errors(peer: WebSocketPeer, id) -> void:
	# Iter 10 split: runtime log capture is now the `debugger.get_log` command
	# on the Mode B (port 9090) runtime autoload — that's the right place for
	# game-side print/push_warning/push_error output. Editor-time script parse
	# errors (shown in the bottom-panel Output dock before play) still need a
	# dedicated editor-side hook; left as a stub until a proper
	# EditorInterface.get_script_editor() signal path is wired.
	_send_result(peer, id, {
		"errors": [],
		"stub": true,
		"note": "editor-time error capture TBD; runtime logs via debugger_get_log (Mode B, iter 10)",
	})


func _cmd_editor_save_scene(peer: WebSocketPeer, id, params) -> void:
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
		return
	var save_path := ""
	if typeof(params) == TYPE_DICTIONARY:
		save_path = str(params.get("path", ""))
	if save_path.is_empty():
		var err := EditorInterface.save_scene()
		if err != OK:
			_send_result(peer, id, mcp_error("SAVE_FAILED", "EditorInterface.save_scene returned %d" % err))
			return
	else:
		# TODO(iter-18): validate save_path through FileGuard.resolve_safe.
		if not save_path.begins_with("res://"):
			_send_result(peer, id, mcp_error("PATH_DENIED", "save path must start with res://: %s" % save_path))
			return
		EditorInterface.save_scene_as(save_path)
		# save_scene_as returns void in 4.4; verify by existence.
		if not FileAccess.file_exists(save_path):
			_send_result(peer, id, mcp_error("SAVE_FAILED", "save_scene_as did not produce %s" % save_path))
			return
	_send_result(peer, id, {"ok": true, "path": root.scene_file_path})


func _cmd_editor_screenshot(peer: WebSocketPeer, id, params) -> void:
	# Return PNG bytes inline as base64 — pattern from godot-mcp-pro / godotiq.
	# Avoids cross-process user:// path resolution and FS races: the TS bridge
	# never touches disk for this tool.
	#
	# Optional `save_path` persists the PNG to res:// for later reference
	# (e.g. commit-to-repo workflows). Inline bytes are ALWAYS returned —
	# save_path is additive, not a mode switch.
	var save_path := ""
	if typeof(params) == TYPE_DICTIONARY:
		save_path = str(params.get("save_path", ""))

	var viewport: SubViewport = EditorInterface.get_editor_viewport_2d()
	if viewport == null:
		viewport = EditorInterface.get_editor_viewport_3d(0)
	if viewport == null:
		_send_result(peer, id, mcp_error("INTERNAL", "no editor viewport available"))
		return
	var image := viewport.get_texture().get_image()
	if image == null:
		_send_result(peer, id, mcp_error("INTERNAL", "viewport texture unavailable (nothing rendered yet?)"))
		return

	var png_bytes := image.save_png_to_buffer()
	if png_bytes.is_empty():
		_send_result(peer, id, mcp_error("INTERNAL", "save_png_to_buffer returned empty"))
		return

	var persisted_path := ""
	if not save_path.is_empty():
		# TODO(iter-18): replace this res://-only prefix check with
		# FileGuard.resolve_safe(save_path). FileGuard also needs to handle the
		# res:// vs user:// distinction explicitly — today user:// is rejected
		# here even though it's a legitimate destination for disposable
		# screenshots, because we haven't yet defined the policy. See
		# project_delete_node_crash.md for the related editor-safety notes and
		# iter-07 follow-up work.
		if not save_path.begins_with("res://"):
			_send_result(peer, id, mcp_error("PATH_DENIED", "save_path must start with res://: %s" % save_path))
			return
		if not save_path.ends_with(".png"):
			_send_result(peer, id, mcp_error("INVALID_PARAMS", "save_path must end with .png: %s" % save_path))
			return
		var dir_path := save_path.get_base_dir()
		if not dir_path.is_empty():
			var dir_err := DirAccess.make_dir_recursive_absolute(dir_path)
			if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
				_send_result(peer, id, mcp_error("INTERNAL", "could not create %s (err %d)" % [dir_path, dir_err]))
				return
		var save_err := image.save_png(save_path)
		if save_err != OK:
			_send_result(peer, id, mcp_error("INTERNAL", "save_png failed (err %d) for %s" % [save_err, save_path]))
			return
		persisted_path = save_path

	var response := {
		"image_base64": Marshalls.raw_to_base64(png_bytes),
		"mime_type": "image/png",
		"width": image.get_width(),
		"height": image.get_height(),
		"bytes": png_bytes.size(),
	}
	if not persisted_path.is_empty():
		response["path"] = persisted_path
	_send_result(peer, id, response)


# ---- Tier 1 commands (iter 09) --------------------------------------------


func _cmd_editor_reload_scripts(peer: WebSocketPeer, id) -> void:
	# Godot 4.4 has no EditorInterface.reload_scripts() static despite what
	# older docs suggest (iter-09 plan was drafted against that assumption).
	# Portable flow: (1) rescan res:// so the FS cache sees on-disk changes,
	# (2) call Script.reload(true) on each script currently open in the
	# editor so the script editor + Inspector pick up new content. "true"
	# preserves runtime state when possible (matches godot-mcp-pro's
	# _reload_script helper).
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.scan()
	var reloaded := 0
	var script_editor := EditorInterface.get_script_editor()
	if script_editor != null:
		for open_script in script_editor.get_open_scripts():
			if open_script is Script:
				open_script.reload(true)
				reloaded += 1
	_send_result(peer, id, {"ok": true, "reloaded": reloaded})


func _cmd_scene_open(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	# TODO(iter-18): replace this prefix check with FileGuard.resolve_safe(path).
	if not path.begins_with("res://"):
		_send_result(peer, id, mcp_error("PATH_DENIED", "path must start with res://: %s" % path))
		return
	if not FileAccess.file_exists(path):
		_send_result(peer, id, mcp_error("NOT_FOUND", "scene not found: %s" % path))
		return
	EditorInterface.open_scene_from_path(path)
	_send_result(peer, id, {"ok": true, "path": path})


# MVP secret-key filter. `key` is over-eager (matches input keybinding names
# with "keycode" etc.) but that's the right default for "lean out of sight
# rather than risk exfil". Proper scrubbing lands in iter 20.
const _SECRET_KEY_REGEX := "(?i)password|token|secret|key"


func _cmd_project_get_settings(peer: WebSocketPeer, id, params) -> void:
	var prefix := ""
	if typeof(params) == TYPE_DICTIONARY:
		prefix = str(params.get("prefix", ""))

	var re := RegEx.new()
	var compile_err := re.compile(_SECRET_KEY_REGEX)
	if compile_err != OK:
		_send_result(peer, id, mcp_error("INTERNAL", "secret regex failed to compile (err %d)" % compile_err))
		return

	var settings := {}
	var filtered_secrets := 0
	for prop in ProjectSettings.get_property_list():
		var name := str(prop.get("name", ""))
		# Empty names and non-path-like Object meta entries are noise.
		if name.is_empty() or not name.contains("/"):
			continue
		if not prefix.is_empty() and not name.begins_with(prefix):
			continue
		if re.search(name) != null:
			filtered_secrets += 1
			continue
		settings[name] = _serialize_value(ProjectSettings.get_setting(name))

	_send_result(peer, id, {
		"settings": settings,
		"count": settings.size(),
		"filtered_secret_count": filtered_secrets,
	})


# ---- Tier 3 commands (iter 11) --------------------------------------------


# Shared resolver: "." / "" → edited scene root, otherwise NodePath lookup from root.
# Returns null (+ signals caller to emit NOT_FOUND) if the node can't be found.
func _resolve_scene_node(path: String):
	var root := _get_edited_root()
	if root == null:
		return null
	if path.is_empty() or path == ".":
		return root
	return root.get_node_or_null(path)


func _cmd_signal_list(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
		return
	var path := str(params.get("path", ""))
	var node = _resolve_scene_node(path)
	if node == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "node not found: %s" % path))
		return
	_send_result(peer, id, {"path": path, "signals": _signal_list_of(node)})


func _signal_list_of(node: Object) -> Array:
	# Flattens get_signal_list() into JSON-friendly shape. `args` inside each
	# signal dict is itself an Array of property-info dicts; we keep name +
	# type (a TYPE_* int, TS consumer decodes).
	var out: Array = []
	for sig in node.get_signal_list():
		var args: Array = []
		for arg in sig.get("args", []):
			args.append({
				"name": str(arg.get("name", "")),
				"type": int(arg.get("type", 0)),
			})
		out.append({
			"name": str(sig.get("name", "")),
			"args": args,
		})
	return out


# Resolves {source_path, signal, target_path, method} to concrete nodes +
# validates the signal + method exist. Returns a typed result dict that
# callers pattern-match on `error`/`code` vs the happy-path fields.
func _resolve_signal_pair(params) -> Dictionary:
	if typeof(params) != TYPE_DICTIONARY:
		return {"code": "INVALID_PARAMS", "error": "params must be an object"}
	var source_path := str(params.get("source_path", ""))
	var signal_name := str(params.get("signal", ""))
	var target_path := str(params.get("target_path", ""))
	var method_name := str(params.get("method", ""))
	if source_path.is_empty() or signal_name.is_empty() or target_path.is_empty() or method_name.is_empty():
		return {"code": "INVALID_PARAMS", "error": "source_path, signal, target_path, method are all required"}
	var root := _get_edited_root()
	if root == null:
		return {"code": "NO_SCENE", "error": "no edited scene"}
	var source = _resolve_scene_node(source_path)
	if source == null:
		return {"code": "NOT_FOUND", "error": "source node not found: %s" % source_path}
	var target = _resolve_scene_node(target_path)
	if target == null:
		return {"code": "NOT_FOUND", "error": "target node not found: %s" % target_path}
	if not source.has_signal(signal_name):
		return {"code": "INVALID_PARAMS", "error": "signal %s not on %s" % [signal_name, source_path]}
	if not target.has_method(method_name):
		return {"code": "INVALID_PARAMS", "error": "method %s not on %s" % [method_name, target_path]}
	return {
		"source": source,
		"target": target,
		"source_path": source_path,
		"target_path": target_path,
		"signal_name": signal_name,
		"method_name": method_name,
		"callable": Callable(target, method_name),
	}


func _cmd_signal_connect(peer: WebSocketPeer, id, params) -> void:
	var r := _resolve_signal_pair(params)
	if r.has("error"):
		_send_result(peer, id, mcp_error(str(r["code"]), str(r["error"])))
		return
	var source = r["source"]
	var callable: Callable = r["callable"]
	var signal_name: String = str(r["signal_name"])
	var source_path: String = str(r["source_path"])
	var target_path: String = str(r["target_path"])
	var method_name: String = str(r["method_name"])
	# I3 idempotency: same (signal, callable) already connected → return
	# ALREADY_EXISTS as a non-error success instead of re-registering.
	if source.is_connected(signal_name, callable):
		_send_result(peer, id, {
			"code": "ALREADY_EXISTS",
			"source_path": source_path,
			"signal": signal_name,
			"target_path": target_path,
			"method": method_name,
		})
		return
	# Route through UndoRedo so the editor's signal-inspector picks this up
	# and Ctrl-Z reverses it. execute=true (default) runs the do_method now.
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("MCP: connect %s.%s -> %s.%s" % [source_path, signal_name, target_path, method_name])
	undo_redo.add_do_method(source, "connect", signal_name, callable)
	undo_redo.add_undo_method(source, "disconnect", signal_name, callable)
	undo_redo.commit_action()
	_send_result(peer, id, {"ok": true})


func _cmd_signal_disconnect(peer: WebSocketPeer, id, params) -> void:
	var r := _resolve_signal_pair(params)
	if r.has("error"):
		_send_result(peer, id, mcp_error(str(r["code"]), str(r["error"])))
		return
	var source = r["source"]
	var callable: Callable = r["callable"]
	var signal_name: String = str(r["signal_name"])
	var source_path: String = str(r["source_path"])
	var target_path: String = str(r["target_path"])
	var method_name: String = str(r["method_name"])
	if not source.is_connected(signal_name, callable):
		_send_result(peer, id, mcp_error("NOT_FOUND", "no connection to disconnect"))
		return
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("MCP: disconnect %s.%s -> %s.%s" % [source_path, signal_name, target_path, method_name])
	undo_redo.add_do_method(source, "disconnect", signal_name, callable)
	undo_redo.add_undo_method(source, "connect", signal_name, callable)
	undo_redo.commit_action()
	_send_result(peer, id, {"ok": true})


func _cmd_signal_emit(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
		return
	var path := str(params.get("path", ""))
	var signal_name := str(params.get("signal", ""))
	if signal_name.is_empty():
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing signal"))
		return
	var node = _resolve_scene_node(path)
	if node == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "node not found: %s" % path))
		return
	if not node.has_signal(signal_name):
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "signal %s not on %s" % [signal_name, path]))
		return
	var raw_args = params.get("args", [])
	if typeof(raw_args) != TYPE_ARRAY:
		raw_args = []
	var coerced: Array = [signal_name]
	for a in raw_args:
		coerced.append(_coerce_value(a))
	node.callv("emit_signal", coerced)
	_send_result(peer, id, {"ok": true})


const _RESOURCE_SKIP_PROPERTIES: Array[String] = ["image", "mesh_arrays", "surface_arrays", "_data"]


func _cmd_resource_load(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var path := str(params.get("path", ""))
	# TODO(iter-18): replace with FileGuard.resolve_safe(path).
	if not path.begins_with("res://"):
		_send_result(peer, id, mcp_error("PATH_DENIED", "path must start with res://: %s" % path))
		return
	if not ResourceLoader.exists(path):
		_send_result(peer, id, mcp_error("NOT_FOUND", "resource not found: %s" % path))
		return
	var resource := ResourceLoader.load(path)
	if resource == null:
		_send_result(peer, id, mcp_error("LOAD_FAILED", "ResourceLoader returned null for %s" % path))
		return
	var cls := resource.get_class()
	var props := {}
	for prop in resource.get_property_list():
		var usage: int = int(prop.get("usage", 0))
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		var pname := str(prop.get("name", ""))
		if pname.is_empty() or pname.begins_with("_"):
			continue
		# Heavy binary fields explicitly skipped — response caps in iter 20
		# formalise the limits, but the common offenders are worth pruning
		# now so tool calls stay usable.
		if pname in _RESOURCE_SKIP_PROPERTIES:
			continue
		props[pname] = _serialize_value(resource.get(pname))
	var metadata := {}
	if resource is Texture2D:
		metadata["width"] = resource.get_width()
		metadata["height"] = resource.get_height()
	_send_result(peer, id, {
		"class": cls,
		"path": path,
		"properties": props,
		"metadata": metadata,
	})


# scene.diff (iter 12): line-based JSON diff between a caller-supplied
# `before` snapshot (typically captured via scene.get_tree before mutating)
# and either an explicit `after` snapshot or the current edited tree.
# MVP heuristic: pretty-print both with sort_keys=true, take the symmetric
# difference of lines, label removed lines `- ` and added lines `+ `. A
# proper structural tree-diff (keyed by node path with property-level
# annotations) is post-MVP.
func _cmd_scene_diff(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	if not params.has("before"):
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "missing before"))
		return
	var before = params.get("before")
	var after = params.get("after", null)
	if after == null:
		var root := _get_edited_root()
		if root == null:
			_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
			return
		after = _walk_tree(root, root)
	# sort_keys=true so dict-key reordering doesn't show up as a diff.
	var before_str := JSON.stringify(before, "  ", true)
	var after_str := JSON.stringify(after, "  ", true)
	if before_str == after_str:
		_send_result(peer, id, {"changed": false, "diff": "", "added": 0, "removed": 0})
		return
	var before_lines := before_str.split("\n", false)
	var after_lines := after_str.split("\n", false)
	var before_set := {}
	for l in before_lines:
		before_set[l] = true
	var after_set := {}
	for l in after_lines:
		after_set[l] = true
	var diff_parts := PackedStringArray()
	var removed := 0
	for l in before_lines:
		if not after_set.has(l):
			diff_parts.append("- " + l)
			removed += 1
	var added := 0
	for l in after_lines:
		if not before_set.has(l):
			diff_parts.append("+ " + l)
			added += 1
	_send_result(peer, id, {
		"changed": true,
		"diff": "\n".join(diff_parts),
		"added": added,
		"removed": removed,
	})


func _cmd_node_get_property_list(peer: WebSocketPeer, id, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		_send_result(peer, id, mcp_error("INVALID_PARAMS", "params must be an object"))
		return
	var root := _get_edited_root()
	if root == null:
		_send_result(peer, id, mcp_error("NO_SCENE", "no edited scene"))
		return
	var path := str(params.get("path", ""))
	var node = _resolve_scene_node(path)
	if node == null:
		_send_result(peer, id, mcp_error("NOT_FOUND", "node not found: %s" % path))
		return
	var props: Array = []
	for prop in node.get_property_list():
		var usage: int = int(prop.get("usage", 0))
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		var pname := str(prop.get("name", ""))
		if pname.is_empty() or pname.begins_with("_"):
			continue
		props.append({
			"name": pname,
			"type": int(prop.get("type", 0)),
			"hint": int(prop.get("hint", 0)),
			"hint_string": str(prop.get("hint_string", "")),
		})
	_send_result(peer, id, {
		"path": path,
		"class": node.get_class(),
		"properties": props,
		"count": props.size(),
	})

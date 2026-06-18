@tool
extends Node
## UndoRedo apply/revert methods, invoked by name on undo/redo — possibly long
## after the originating command has returned.
##
## These live on a persistent, server-owned Node (reached via server.undo_helpers)
## because EditorUndoRedoManager.add_do_method / add_undo_method take an
## (object, method) pair and route undo by that object's editor context — unlike
## the base UndoRedo class, which takes a Callable. MCPToolkitUndoRedoAction
## unpacks each Callable into (object, method) to feed the editor-manager form, so
## the bound object must be a real, named method host. Because the call is
## deferred, that host must outlive the command — hence this dedicated Node.
##
## NOT a pre-Callable workaround. Do NOT inline these into command files or bind
## them on an ad-hoc / transient instance: a freed host means a broken undo.


func _write_file_silent(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[MCPServer] UndoRedo write of %s failed (err %d)" % [path, FileAccess.get_open_error()])
		return
	file.store_string(content)
	file.close()


func _delete_file_silent(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var error := DirAccess.remove_absolute(path)
	if error != OK:
		push_warning("[MCPServer] UndoRedo delete of %s failed (err %d)" % [path, error])


func _set_owner_recursive(node: Node, owner: Node) -> void:
	node.set_owner(owner)
	for child in node.get_children():
		_set_owner_recursive(child, owner)


func _animation_remove_key_at(animation: Animation, track_index: int, time: float) -> void:
	var key_index := animation.track_find_key(track_index, time, Animation.FIND_MODE_EXACT)
	if key_index != -1:
		animation.track_remove_key(track_index, key_index)


func _animation_insert_key_silent(animation: Animation, track_index: int, time: float, value) -> void:
	animation.track_insert_key(track_index, time, value)


func _sm_remove_transition_by_endpoints(sm: AnimationNodeStateMachine, from: String, to: String) -> void:
	for i in range(sm.get_transition_count()):
		if str(sm.get_transition_from(i)) == from and str(sm.get_transition_to(i)) == to:
			sm.remove_transition_by_index(i)
			return


func _tilemap_apply_batch(node: Node, layer: int, cells: Array) -> void:
	var is_layer := node.is_class("TileMapLayer")  # dynamic — avoids parse error on < 4.3
	for cell in cells:
		var coord := Vector2i(int(cell["x"]), int(cell["y"]))
		var source_id := int(cell["source_id"])
		var atlas := Vector2i(int(cell["atlas_x"]), int(cell["atlas_y"]))
		var alternative := int(cell.get("alternative_tile", 0))
		if is_layer:
			node.set_cell(coord, source_id, atlas, alternative)
		else:
			(node as TileMap).set_cell(layer, coord, source_id, atlas, alternative)


## Set a compound-path property (colon-chain or slash) on a node.
## Used by UndoRedo for compound path undo/redo — navigates sub-resources
## the same way set_property_compound does, but without coercion or readback.
func compound_set(node: Object, property_name: String, value: Variant) -> void:
	if ":" not in property_name:
		node.set(property_name, value)
		return
	var parts := property_name.split(":")
	# Single-colon: try slash-path first.
	if parts.size() == 2:
		var slash_path := parts[0] + "/" + parts[1]
		node.set(slash_path, value)
		if node.get(slash_path) != null:
			return
	# Navigate to sub-resource and set directly.
	var target: Object = node
	for i in range(parts.size() - 1):
		var sub = target.get(parts[i])
		if sub == null or not (sub is Object):
			return
		target = sub
	var final_prop := parts[-1]
	if final_prop.begins_with("shader_parameter/") and target is ShaderMaterial:
		(target as ShaderMaterial).set_shader_parameter(
			final_prop.trim_prefix("shader_parameter/"), value)
	else:
		target.set(final_prop, value)


func _tilemap_restore_batch(node: Node, layer: int, before_state: Array) -> void:
	var is_layer := node.is_class("TileMapLayer")  # dynamic — avoids parse error on < 4.3
	for state in before_state:
		var coord: Vector2i = state["coord"]
		var source_id := int(state["source_id"])
		var atlas: Vector2i = state["atlas"]
		var alternative := int(state["alternative_tile"])
		if is_layer:
			node.set_cell(coord, source_id, atlas, alternative)
		else:
			(node as TileMap).set_cell(layer, coord, source_id, atlas, alternative)

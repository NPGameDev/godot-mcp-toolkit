@tool
class_name MCPToolkitUndoRedoAction
extends RefCounted
## Lightweight UndoRedo builder for MCP toolkit tools and extensions.
##
## Wraps EditorUndoRedoManager with automatic headless-safe no-op,
## "MCP: " action prefix, and a fluent builder API.
##
## Recommended pattern — apply the mutation first, then record for undo:
##   node.set(&"position", new_pos)
##   MCPToolkitUndoRedoAction.begin("set position", node) \
##       .do_property(node, &"position", new_pos) \
##       .undo_property(node, &"position", old_pos) \
##       .commit_recorded()
##
## C# extensions: use registry.create_undo_action() instead of begin().

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")

## EditorUndoRedoManager — used for create_action / commit_action.
var _mgr = null  # untyped for headless compat
## Internal UndoRedo for the target history — used for add_do/undo_*
## operations.  EditorUndoRedoManager.add_do_method uses the old
## (Object, StringName, …) vararg API; the internal UndoRedo accepts
## a single Callable, which the builder exposes.
var _ur = null  # UndoRedo or null
var _active: bool = false
var _committed: bool = false


## Static factory — creates an action and returns the builder.
## Returns a no-op instance in headless context (no editor plugin).
## [param description]: human-readable action name (auto-prefixed with "MCP: ").
## [param context_object]: optional scene-owning node (tells Godot which scene
##   the undo action belongs to — important for multi-tab editing).
static func begin(description: String, context_object: Object = null) -> MCPToolkitUndoRedoAction:
	var action := MCPToolkitUndoRedoAction.new()
	var mgr = _Hub.get_undo_redo()
	if mgr != null:
		mgr.create_action("MCP: " + description, 0, context_object)
		action._mgr = mgr
		# Resolve internal UndoRedo for Callable-based method registration.
		# EditorUndoRedoManager.add_do_method uses vararg (Object, StringName, …)
		# but UndoRedo.add_do_method takes a single Callable — we need the latter.
		var hist_id := 0  # GLOBAL_HISTORY
		if context_object != null:
			var obj_hist = mgr.get_object_history_id(context_object)
			if obj_hist != -99:  # != INVALID_HISTORY
				hist_id = obj_hist
		action._ur = mgr.get_history_undo_redo(hist_id)
		action._active = action._ur != null
	return action


## Returns true when EditorUndoRedoManager is available and the action
## has been created but not yet committed. Use to skip expensive state
## capture in headless contexts.
func is_active() -> bool:
	return _active


# -- Properties ---------------------------------------------------------------

func do_property(obj: Object, property: StringName, value: Variant) -> MCPToolkitUndoRedoAction:
	if _active:
		_ur.add_do_property(obj, property, value)
	return self


func undo_property(obj: Object, property: StringName, value: Variant) -> MCPToolkitUndoRedoAction:
	if _active:
		_ur.add_undo_property(obj, property, value)
	return self


# -- Methods (Callable) -------------------------------------------------------

## Register a method call for the do-side. Use .bind() for arguments:
##   action.do_method(node.add_child.bind(child))
func do_method(callable: Callable) -> MCPToolkitUndoRedoAction:
	if _active:
		_ur.add_do_method(callable)
	return self


## Register a method call for the undo-side. Use .bind() for arguments:
##   action.undo_method(parent.remove_child.bind(child))
func undo_method(callable: Callable) -> MCPToolkitUndoRedoAction:
	if _active:
		_ur.add_undo_method(callable)
	return self


# -- References ----------------------------------------------------------------

## Keep [param ref] alive for redo. Use for newly created objects that would
## otherwise be freed when undone (e.g., a new node removed by undo).
func do_reference(ref: Object) -> MCPToolkitUndoRedoAction:
	if _active:
		_ur.add_do_reference(ref)
	return self


## Keep [param ref] alive for undo. Use for old objects being replaced that
## would otherwise be freed (e.g., a resource overwritten by the do-side).
func undo_reference(ref: Object) -> MCPToolkitUndoRedoAction:
	if _active:
		_ur.add_undo_reference(ref)
	return self


# -- Commit --------------------------------------------------------------------

## Commit the action — UndoRedo executes the do-side now.
## Use for batching scenarios where the mutation should be driven by UndoRedo.
func commit() -> void:
	if _committed:
		push_warning("[MCPToolkitUndoRedoAction] Action already committed — ignoring duplicate commit() call")
		return
	_committed = true
	if _active:
		_mgr.commit_action()
		_active = false


## Commit as recorded — mutation already applied, just record for undo/redo.
## This is the recommended default for MCP tools: apply the mutation first,
## then call commit_recorded() so Ctrl+Z/Y works.
func commit_recorded() -> void:
	if _committed:
		push_warning("[MCPToolkitUndoRedoAction] Action already committed — ignoring duplicate commit_recorded() call")
		return
	_committed = true
	if _active:
		_mgr.commit_action(false)
		_active = false

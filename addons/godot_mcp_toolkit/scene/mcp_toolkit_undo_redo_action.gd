@tool
class_name MCPToolkitUndoRedoAction
extends RefCounted
## Fluent UndoRedo builder for MCP toolkit tools and extensions.
##
## Wraps [code]EditorUndoRedoManager[/code] with an automatic headless-safe no-op,
## an [code]"MCP: "[/code] action-name prefix, and a chainable builder API. Start
## with [method begin], record the do-side and undo-side with the
## [method do_property] / [method undo_property] (and [method do_method] /
## [method undo_method], [method do_reference] / [method undo_reference]) pairs,
## then close with [method commit_recorded] or [method commit]. Every builder
## method is a no-op when [method is_active] is [code]false[/code] (headless), so
## the same code runs safely with no editor.[br]
## [br]
## Recommended pattern — apply the mutation first, then record it for undo with
## [method commit_recorded]:
## [codeblock]
## node.set(&"position", new_pos)
## MCPToolkitUndoRedoAction.begin("set position", node) \
##     .do_property(node, &"position", new_pos) \
##     .undo_property(node, &"position", old_pos) \
##     .commit_recorded()
## [/codeblock]
## C# extensions cannot call this GDScript static — use
## [method MCPToolkitCommandRegistry.create_undo_action] instead of [method begin].

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")

## EditorUndoRedoManager — used for all operations (create, add, commit).
## Routing to the correct internal history is handled by the manager itself.
var _mgr = null  # untyped for headless compat
var _active: bool = false
var _committed: bool = false


## Creates an undo action and returns the builder to chain from. [param description]
## is the human-readable action name (auto-prefixed with [code]"MCP: "[/code]);
## [param context_object] is the optional scene-owning node, which tells Godot which
## scene's history the action belongs to (important for multi-tab editing). Returns
## a builder bound to [code]EditorUndoRedoManager[/code], or a no-op builder in a
## headless context (no editor plugin) — see [method is_active].
static func begin(description: String, context_object: Object = null) -> MCPToolkitUndoRedoAction:
	var action := MCPToolkitUndoRedoAction.new()
	var mgr = Modules.EditorAccess.get_undo_redo()
	if mgr != null:
		mgr.create_action("MCP: " + description, 0, context_object)
		action._mgr = mgr
		action._active = true
	return action


## Returns [code]true[/code] when [code]EditorUndoRedoManager[/code] is available
## and the action has been created but not yet committed. Use it to skip expensive
## state capture in a headless context, where every builder method is a no-op.
func is_active() -> bool:
	return _active


# -- Properties ---------------------------------------------------------------

## Records the do-side (redo) value: sets [param property] on [param obj] to
## [param value] when the action is applied. Pair it with [method undo_property]
## carrying the old value. Returns [code]self[/code] for chaining.
func do_property(obj: Object, property: StringName, value: Variant) -> MCPToolkitUndoRedoAction:
	if _active:
		_mgr.add_do_property(obj, property, value)
	return self


## Records the undo-side value: restores [param property] on [param obj] to
## [param value] when the action is undone. Pass the value the property held
## before the mutation. Returns [code]self[/code] for chaining.
func undo_property(obj: Object, property: StringName, value: Variant) -> MCPToolkitUndoRedoAction:
	if _active:
		_mgr.add_undo_property(obj, property, value)
	return self


# -- Methods (Callable) -------------------------------------------------------

## Records [param callable] to run on the do-side (redo). Bind any arguments onto
## the [Callable] with [code].bind()[/code]. Returns [code]self[/code] for chaining.
## [codeblock]
## action.do_method(node.add_child.bind(child))
## [/codeblock]
func do_method(callable: Callable) -> MCPToolkitUndoRedoAction:
	if _active:
		var args: Array = [callable.get_object(), callable.get_method()]
		args.append_array(callable.get_bound_arguments())
		_mgr.callv(&"add_do_method", args)
	return self


## Records [param callable] to run on the undo-side. Bind any arguments onto the
## [Callable] with [code].bind()[/code]. Returns [code]self[/code] for chaining.
## [codeblock]
## action.undo_method(parent.remove_child.bind(child))
## [/codeblock]
func undo_method(callable: Callable) -> MCPToolkitUndoRedoAction:
	if _active:
		var args: Array = [callable.get_object(), callable.get_method()]
		args.append_array(callable.get_bound_arguments())
		_mgr.callv(&"add_undo_method", args)
	return self


# -- References ----------------------------------------------------------------

## Keeps [param ref] alive for redo. Use it for a newly created object that would
## otherwise be freed while undone (e.g. a new node that undo removes from the
## tree). Returns [code]self[/code] for chaining.
func do_reference(ref: Object) -> MCPToolkitUndoRedoAction:
	if _active:
		_mgr.add_do_reference(ref)
	return self


## Keeps [param ref] alive for undo. Use it for an old object being replaced that
## would otherwise be freed (e.g. a resource the do-side overwrites). Returns
## [code]self[/code] for chaining.
func undo_reference(ref: Object) -> MCPToolkitUndoRedoAction:
	if _active:
		_mgr.add_undo_reference(ref)
	return self


# -- Commit --------------------------------------------------------------------

## Commits the action, having UndoRedo execute the do-side now. Use this when the
## mutation should be driven by UndoRedo itself (rather than applied first). Calling
## it (or [method commit_recorded]) twice warns and is ignored. Compare
## [method commit_recorded], the recommended default.
func commit() -> void:
	if _committed:
		push_warning("[MCPToolkitUndoRedoAction] Action already committed - ignoring duplicate commit() call")
		return
	_committed = true
	if _active:
		_mgr.commit_action()
		_active = false


## Commits the action as already-recorded: the mutation has been applied directly,
## so this only registers the do/undo steps without re-executing the do-side. This
## is the recommended default for MCP tools — apply the mutation first, then call
## this so Ctrl+Z / Ctrl+Y work. Calling it (or [method commit]) twice warns and is
## ignored.
func commit_recorded() -> void:
	if _committed:
		push_warning("[MCPToolkitUndoRedoAction] Action already committed - ignoring duplicate commit_recorded() call")
		return
	_committed = true
	if _active:
		_mgr.commit_action(false)
		_active = false

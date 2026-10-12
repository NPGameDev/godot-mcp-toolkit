@tool
extends RefCounted
## Safe-scene-ops public API, ToolContext cancellation and scene-instancing unit
## tests. Exercises the scene/ subsystem's headless-safe surface (is_dispatching /
## check_save pure dict logic), the cooperative-cancellation context, and how a
## scene.instantiate instance packs into its owner scene.

const _SafeSceneOps := preload("res://addons/godot_mcp_toolkit/scene/mcp_toolkit_safe_scene_ops.gd")
const _SceneCommands := preload("res://addons/godot_mcp_toolkit/commands/scene_commands.gd")
const _INSTANCED_SCENE_FIXTURE := "user://scene_instantiate_fixture.tscn"


static func run(testing) -> void:
	_test_safe_scene_ops(testing)
	_test_tool_context(testing)
	_test_instance_saves_as_instance(testing)


# --- MCPToolkitSafeSceneOps public API -------------------------------------
# is_dispatching() is the pure, headless-testable surface. wait_for_scan_idle /
# save_scene / queue_save touch EditorInterface (null in this --script runner),
# so they are covered by the smoke suite + the editor-required dispatch
# integration / A-B validation that exercise editor_save_scene end to end.

static func _test_safe_scene_ops(testing) -> void:
	testing.begin("MCPToolkitSafeSceneOps (public API)")
	testing.ok(not _SafeSceneOps.is_dispatching(), "is_dispatching → false by default")
	_SafeSceneOps._in_dispatch = true
	testing.ok(_SafeSceneOps.is_dispatching(), "is_dispatching → true when _in_dispatch set")
	_SafeSceneOps._in_dispatch = false
	testing.ok(not _SafeSceneOps.is_dispatching(), "is_dispatching → false after reset")

	# C# reaches the safe-save API through the registry facade (like
	# create_undo_action), so verify the registry bridge forwards to SafeSceneOps.
	# (queue_save fires the editor-coupled save → integration-tested; check_save
	# is pure dict logic → testable here.)
	var _reg := MCPToolkitCommandRegistry.new()
	testing.ok(_reg.check_save("nope").get("unknown", false),
			"registry.check_save bridge → forwards to SafeSceneOps")

	# check_save — pure dict logic; seed _save_results directly to bypass the
	# editor-coupled save in queue_save/_run_queued_save.
	_SafeSceneOps._save_results = {}
	testing.ok(_SafeSceneOps.check_save("nope").get("unknown", false),
			"check_save(unknown id) → unknown:true")
	_SafeSceneOps._save_results["s1"] = {"done": false}
	testing.ok(not _SafeSceneOps.check_save("s1").get("done", true),
			"pending save → done:false")
	_SafeSceneOps._save_results["s1"] = {"done": true, "success": true}
	testing.ok(_SafeSceneOps.check_save("s1").get("success", false),
			"completed save → success:true")
	_SafeSceneOps.check_save("s1", true)  # clear a done save
	testing.ok(_SafeSceneOps.check_save("s1").get("unknown", false),
			"check_save(clear) on done → record removed")
	_SafeSceneOps._save_results["s2"] = {"done": false}
	_SafeSceneOps.check_save("s2", true)  # clear a pending save → no-op
	testing.ok(_SafeSceneOps._save_results.has("s2"),
			"check_save(clear) on pending → kept")
	_SafeSceneOps._save_results = {}  # reset the shared static
	print("")


# --- ToolContext cancellation (~3 assertions) ------------------------------

static func _test_tool_context(testing) -> void:
	testing.begin("ToolContext cancellation")

	# 1. fresh → is_cancelled false
	var context := MCPToolkitToolContext.new()
	testing.ok(not context.is_cancelled(), "fresh context → is_cancelled false")

	# 2. cancel → is_cancelled true
	context.cancel()
	testing.ok(context.is_cancelled(), "after cancel → is_cancelled true")

	# 3. cancelled signal fires synchronously
	var signal_context := MCPToolkitToolContext.new()
	var fired := [false]
	signal_context.cancelled.connect(func(): fired[0] = true)
	signal_context.cancel()
	testing.ok(fired[0], "cancel → cancelled signal fires")

	print("")


# --- scene.instantiate: an instance saves like an editor drop ----------------
# An instanced sub-scene must save as an instance: no type= and none of the
# sub-scene root's script, properties or groups copied into the owner scene, or
# later changes to that root never reach it. The oracle is the packed owner scene's
# SceneState, the data the engine writes to the .tscn. The single-instance path
# needs the editor's edited scene root, which this runner lacks, so this drives the
# batch path: it takes the root as an argument and instances through the same
# helper. Writes a user:// temp file and removes it afterward.

static func _test_instance_saves_as_instance(testing) -> void:
	testing.begin("scene.instantiate instance saves like an editor drop")
	var packed := _save_scripted_sub_scene(testing)
	var owner_root := Node.new()
	owner_root.name = "Outer"
	var response := _SceneCommands._batch_instantiate(
			null, owner_root, owner_root, packed, _INSTANCED_SCENE_FIXTURE, ".",
			[{"name": "BatchPod"}])
	testing.eq(response.get("count"), 1, "batch instantiate creates one instance")

	var owner_scene := PackedScene.new()
	testing.eq(owner_scene.pack(owner_root), OK, "owner scene packs")
	var state := owner_scene.get_state()
	testing.eq(state.get_node_count(), 2, "owner scene holds its root and the instance")
	testing.eq(state.get_node_type(1), &"",
			"instance stores no type= (the sub-scene root's class is not copied)")
	testing.eq(state.get_node_property_count(1), 0,
			"instance stores no root property (the sub-scene root's script is not copied)")
	testing.eq(state.get_node_groups(1).size(), 0,
			"instance stores no group (the sub-scene root's group is not copied)")
	testing.ok(state.get_node_instance(1) != null,
			"instance stores instance= (it saves as an instance of the sub-scene)")

	owner_root.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_INSTANCED_SCENE_FIXTURE))
	print("")


## Saves a sub-scene whose Node3D root carries a script and a group, the parts an
## owner scene must not copy, to a user:// temp file. Returns it loaded back from
## disk, which gives its instances the scene path an instance is saved by.
static func _save_scripted_sub_scene(testing) -> PackedScene:
	var root_script := GDScript.new()
	root_script.source_code = "extends Node3D\n"
	testing.eq(root_script.reload(), OK, "sub-scene root script compiles")
	var sub_root := Node3D.new()
	sub_root.name = "Pod"
	sub_root.set_script(root_script)
	sub_root.add_to_group(&"pods", true)
	var sub_scene := PackedScene.new()
	testing.eq(sub_scene.pack(sub_root), OK, "sub-scene packs")
	sub_root.free()
	testing.eq(ResourceSaver.save(sub_scene, _INSTANCED_SCENE_FIXTURE), OK, "sub-scene saved")
	return ResourceLoader.load(_INSTANCED_SCENE_FIXTURE) as PackedScene

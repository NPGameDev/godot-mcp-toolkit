@tool
extends RefCounted
## Safe-scene-ops public API, ToolContext cancellation and scene-instancing unit
## tests. Exercises the scene/ subsystem's headless-safe surface (is_dispatching /
## check_save pure dict logic), the cooperative-cancellation context, and how a
## scene.instantiate instance packs into its owner scene.

const _SafeSceneOps := preload("res://addons/godot_mcp_toolkit/scene/mcp_toolkit_safe_scene_ops.gd")
const _SceneCommands := preload("res://addons/godot_mcp_toolkit/commands/scene_commands.gd")
const _INSTANCED_SCENE_FIXTURE := "user://scene_instantiate_fixture.tscn"
const _BINARY_SCENE_FIXTURE := "user://scene_instantiate_fixture.scn"
const _NON_SCENE_FIXTURE := "user://scene_instantiate_fixture.tres"
const _NON_SCENE_BINARY_FIXTURE := "user://scene_instantiate_fixture.res"
const _TEXT_SCENE_FIXTURE := "user://scene_instantiate_text_fixture.tscn"
const _UNLOADABLE_MODEL_FIXTURE := "user://scene_instantiate_unloadable_model.glb"


static func run(testing) -> void:
	_test_safe_scene_ops(testing)
	_test_tool_context(testing)
	_test_instance_saves_as_instance(testing)
	_test_instantiate_takes_any_packed_scene(testing)
	_test_instantiate_load_barrier(testing)
	_test_instantiate_model_recovery_messages(testing)
	_test_create_node_typed_array_property(testing)


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


# --- scene.instantiate: any file that loads as a PackedScene -----------------
# The editor drops in any file that loads as a PackedScene: a .tscn, a binary .scn,
# or a 3D model imported as a scene (.glb, .fbx...). This runner can't import a
# model, so a .scn stands in for one: a PackedScene whose path isn't .tscn. A
# resource that isn't a scene is still refused. Writes user:// temp files and
# removes them afterward.

static func _test_instantiate_takes_any_packed_scene(testing) -> void:
	testing.begin("scene.instantiate takes any file that loads as a PackedScene")
	var scene_root := Node3D.new()
	scene_root.name = "Model"
	var scene := PackedScene.new()
	testing.eq(scene.pack(scene_root), OK, "binary scene packs")
	scene_root.free()
	testing.eq(ResourceSaver.save(scene, _BINARY_SCENE_FIXTURE), OK, "binary scene saved")
	var loaded := _SceneCommands._load_instanceable_scene(_BINARY_SCENE_FIXTURE)
	testing.eq(loaded.get("failure", {}).get("error"), null, ".scn is not refused")
	testing.ok(loaded.get("packed") is PackedScene, ".scn loads as a PackedScene")

	testing.eq(ResourceSaver.save(Resource.new(), _NON_SCENE_FIXTURE), OK, "plain resource saved")
	var refused := _SceneCommands._load_instanceable_scene(_NON_SCENE_FIXTURE)
	testing.eq(refused.get("failure", {}).get("code"), "INVALID_PATH",
			".tres that isn't a scene is refused with INVALID_PATH")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(_BINARY_SCENE_FIXTURE))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_NON_SCENE_FIXTURE))
	print("")


# --- scene.instantiate: the load decides, not the extension ------------------
# A .res can hold any resource, so its extension passes the scene check; loading
# it is what refuses a non-scene. A mesh-imported model takes the same road: .obj
# is on the scene-extension list whichever importer the file uses. The .tscn case
# guards the path every existing caller takes. Writes user:// temp files and
# removes them afterward.

static func _test_instantiate_load_barrier(testing) -> void:
	testing.begin("scene.instantiate refuses a file that doesn't load as a PackedScene")
	testing.eq(ResourceSaver.save(Resource.new(), _NON_SCENE_BINARY_FIXTURE), OK, "plain binary resource saved")
	var refused := _SceneCommands._load_instanceable_scene(_NON_SCENE_BINARY_FIXTURE)
	testing.eq(refused.get("failure", {}).get("code"), "INVALID_CLASS",
			".res holding a plain Resource is refused with INVALID_CLASS")

	var scene_root := Node2D.new()
	scene_root.name = "Prop"
	var scene := PackedScene.new()
	testing.eq(scene.pack(scene_root), OK, "text scene packs")
	scene_root.free()
	testing.eq(ResourceSaver.save(scene, _TEXT_SCENE_FIXTURE), OK, "text scene saved")
	var loaded := _SceneCommands._load_instanceable_scene(_TEXT_SCENE_FIXTURE)
	testing.ok(bool(loaded.get("ok", false)), ".tscn still loads")
	testing.ok(loaded.get("packed") is PackedScene, ".tscn loads as a PackedScene")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(_NON_SCENE_BINARY_FIXTURE))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_TEXT_SCENE_FIXTURE))
	print("")


# --- scene.instantiate: recovery a model's failure names ---------------------
# This runner registers no scene importer, so a .glb never reaches these helpers
# through _load_instanceable_scene here; they are called directly. A model can't
# be made with scene.create, and one with no .import sidecar needs a rescan.

static func _test_instantiate_model_recovery_messages(testing) -> void:
	testing.begin("scene.instantiate failures name the recovery a model needs")
	var missing_model := _SceneCommands._missing_scene_failure("user://no_such_model.glb")
	testing.eq(missing_model.get("code"), "NOT_FOUND", "missing model → NOT_FOUND")
	testing.ok(not str(missing_model.get("error", "")).contains("scene.create"),
			"missing model doesn't advise scene.create")
	testing.ok(str(missing_model.get("error", "")).contains("editor_refresh"),
			"missing model names editor_refresh")
	var missing_scene := _SceneCommands._missing_scene_failure("user://no_such_scene.tscn")
	testing.ok(str(missing_scene.get("error", "")).contains("scene.create"),
			"missing .tscn still advises scene.create")

	var unimported := _SceneCommands._unloadable_scene_failure("user://no_sidecar_model.glb")
	testing.eq(unimported.get("code"), "LOAD_FAILED", "model with no sidecar → LOAD_FAILED")
	testing.ok(str(unimported.get("error", "")).contains(".import sidecar"),
			"model with no sidecar names the missing sidecar")
	testing.ok(str(unimported.get("error", "")).contains("editor_refresh"),
			"model with no sidecar names editor_refresh")
	var broken_scene := _SceneCommands._unloadable_scene_failure("user://broken_scene.tscn")
	testing.ok(not str(broken_scene.get("error", "")).contains("editor_refresh"),
			"broken .tscn doesn't advise editor_refresh")

	# A sidecar with no imported output behind it, as after a failed import.
	var sidecar := FileAccess.open(_UNLOADABLE_MODEL_FIXTURE + ".import", FileAccess.WRITE)
	sidecar.store_string("[remap]\n")
	sidecar.close()
	var failed_import := _SceneCommands._unloadable_scene_failure(_UNLOADABLE_MODEL_FIXTURE)
	testing.ok(str(failed_import.get("error", "")).contains("editor_refresh"),
			"model whose import failed names editor_refresh")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_UNLOADABLE_MODEL_FIXTURE + ".import"))
	print("")


# --- scene.create_node: an inline array onto an Array[T] export ---------------
# scene.create_node creates a script-class node with the script's new(), a live
# instance, whose set() refuses an untyped array for an Array[T] member. The handler
# needs the editor's edited scene root, which this runner lacks, so this drives the
# two steps it runs on its inline properties: prepare (coerce and fit), then write
# (set and read back). New helpers, so this is green-only.

static func _test_create_node_typed_array_property(testing) -> void:
	testing.begin("scene.create_node stores a typed array on an Array[String] export")
	var node_script := GDScript.new()
	node_script.source_code = "extends Node\n@export var tags: Array[String] = []\n"
	testing.eq(node_script.reload(), OK, "typed-array node script compiles")
	var instance: Node = node_script.new()

	var prepared := _SceneCommands._prepare_inline_properties(instance, {"tags": ["a", "b"]})
	testing.eq((prepared["failed"] as Array).size(), 0, "prepare → no failure")
	var written := _SceneCommands._write_inline_properties(instance, prepared["simple"])
	testing.eq((written["failed"] as Array).size(), 0, "write → no failure")
	testing.eq((written["landed"] as Array).size(), 1, "write → the property landed")
	testing.eq((written["warnings"] as Array).size(), 0, "write → no warning")
	var stored: Variant = instance.get("tags")
	testing.ok(stored is Array and (stored as Array).is_typed()
			and (stored as Array).get_typed_builtin() == TYPE_STRING,
			"tags → stored as an Array[String]")
	testing.eq(stored, ["a", "b"], "tags → stores [\"a\", \"b\"]")

	instance.free()
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

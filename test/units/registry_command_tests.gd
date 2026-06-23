@tool
extends RefCounted
## Command-registry flag unit tests: the transport command_registry.gd
## is_read_only / mutation / serialization flags and metadata fallbacks.


static func run(testing) -> void:
	_test_registry(testing)


# --- Registry (~20 assertions) --------------------------------------------
static func _test_registry(testing) -> void:
	testing.begin("Registry")
	var registry := MCPToolkitCommandRegistry.new()

	# 1. mark_read_only → is_read_only true
	registry.add("t.ro", testing.noop, MCPToolkitCommandOptions.new().mark_read_only())
	testing.ok(registry.is_read_only("t.ro"), "mark_read_only → is_read_only true")

	# 2. default → is_read_only false
	registry.add("t.def", testing.noop, MCPToolkitCommandOptions.new())
	testing.ok(not registry.is_read_only("t.def"), "default → is_read_only false")

	# 3. mark_scene_independent → is_active_scene_required false
	registry.add("t.si", testing.noop, MCPToolkitCommandOptions.new().mark_scene_independent())
	testing.ok(not registry.is_active_scene_required("t.si"),
			"mark_scene_independent → is_active_scene_required false")

	# 4. default → is_active_scene_required true
	testing.ok(registry.is_active_scene_required("t.def"),
			"default → is_active_scene_required true")

	# 5. mark_exclusive_execution → is_exclusive_execution true
	registry.add("t.excl", testing.noop, MCPToolkitCommandOptions.new().mark_exclusive_execution())
	testing.ok(registry.is_exclusive_execution("t.excl"),
			"mark_exclusive_execution → is_exclusive_execution true")

	# 6. mark_cancellable → is_cancellable true
	registry.add("t.canc", testing.noop, MCPToolkitCommandOptions.new().mark_cancellable())
	testing.ok(registry.is_cancellable("t.canc"), "mark_cancellable → is_cancellable true")

	# 7-8. needs_serialization: read-only bypasses, default serialises
	testing.ok(not registry.needs_serialization("t.ro"),
			"needs_serialization for read-only → false")
	testing.ok(registry.needs_serialization("t.def"),
			"needs_serialization for non-read-only → true")

	# 8a-8c. Concern 030 routing regression — game.start / game.stop are
	# session-lifecycle mutators marked exclusive-execution and NOT read-only
	# (needs_serialization = is_exclusive_execution OR not read_only, exclusive
	# checked first). The exclusive flag is the sole serialization driver, so:
	#   - exclusive + non-read-only mutator (game.start/stop shape) → serialises.
	registry.add("t.exclmut",
			testing.noop, MCPToolkitCommandOptions.new().mark_exclusive_execution())
	testing.ok(registry.needs_serialization("t.exclmut"),
			"exclusive + non-read-only mutator → needs_serialization true")
	testing.ok(not registry.is_read_only("t.exclmut"),
			"game.start/stop shape → not read-only")
	#   - the latent landmine these tools dodge: had a mutator been marked
	#     read-only, dropping the exclusive flag would let it bypass the lock
	#     (not read_only → false). A read-only-ONLY command serialises FALSE,
	#     which is why a mutator must never carry read-only.
	registry.add("t.romut", testing.noop, MCPToolkitCommandOptions.new().mark_read_only())
	testing.ok(not registry.needs_serialization("t.romut"),
			"read-only-only command bypasses the lock — a mutator must not be "
			+ "read-only")

	# 9. remove → has_command false
	registry.add("t.rm", testing.noop, MCPToolkitCommandOptions.new())
	registry.remove("t.rm")
	testing.ok(not registry.has_command("t.rm"), "remove → has_command false")

	# 10. clear → get_all_methods empty
	var cleared_registry := MCPToolkitCommandRegistry.new()
	cleared_registry.add("t.a", testing.noop, MCPToolkitCommandOptions.new())
	cleared_registry.add("t.b", testing.noop, MCPToolkitCommandOptions.new())
	cleared_registry.clear()
	testing.eq(cleared_registry.get_all_methods().size(), 0, "clear → get_all_methods empty")

	# 11. mark_extension → get_extension_methods includes it
	registry.add("t.ext", testing.noop, MCPToolkitCommandOptions.new())
	registry.mark_extension("t.ext")
	testing.ok(registry.get_extension_methods().has("t.ext"),
			"mark_extension → in get_extension_methods")

	# 12. get_command_metadata contains description
	registry.add("t.desc", testing.noop,
			MCPToolkitCommandOptions.new().with_description("Hello"))
	testing.eq(registry.get_command_metadata("t.desc").get("description", ""), "Hello",
			"get_command_metadata → correct description")

	# 13. duplicate registration — overwrites cleanly, latest wins
	registry.add("t.dup", testing.noop, MCPToolkitCommandOptions.new())
	registry.add("t.dup", testing.noop, MCPToolkitCommandOptions.new().mark_read_only())
	testing.ok(registry.has_command("t.dup"), "duplicate → still registered")
	testing.ok(registry.is_read_only("t.dup"), "duplicate → latest options win")

	# 14. non-existent command — safe fallback
	testing.ok(not registry.has_command("t.nope"), "non-existent → has_command false")
	testing.eq(registry.get_command_metadata("t.nope"), {},
			"non-existent → metadata empty dict")
	testing.ok(registry.needs_serialization("t.nope"),
			"non-existent → needs_serialization true (safe default)")

	print("")

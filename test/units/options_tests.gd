@tool
extends RefCounted
## Options/annotation builder unit tests: MCPToolkitCommandOptions marks +
## timeouts + version gating, extension options, annotation mapping, timeout clamping.


static func run(testing) -> void:
	_test_options_builder(testing)
	_test_extension_options(testing)
	_test_annotation_mapping(testing)
	_test_timeout_clamping(testing)


# --- Options builder (~14 assertions) -------------------------------------
static func _test_options_builder(testing) -> void:
	testing.begin("Options builder")

	# 1-5. Boolean marks
	testing.ok(MCPToolkitCommandOptions.new().mark_read_only().to_dict()["is_read_only"],
			"mark_read_only → to_dict is_read_only true")
	testing.ok(MCPToolkitCommandOptions.new().mark_destructive().to_dict()["is_destructive"],
			"mark_destructive → to_dict is_destructive true")
	testing.ok(MCPToolkitCommandOptions.new().mark_idempotent().to_dict()["is_idempotent"],
			"mark_idempotent → to_dict is_idempotent true")
	testing.ok(MCPToolkitCommandOptions.new().mark_exclusive_execution().to_dict() \
			.get("exclusive_execution", false),
			"mark_exclusive_execution → to_dict exclusive_execution true")
	testing.ok(MCPToolkitCommandOptions.new().mark_cancellable().to_dict()["is_cancellable"],
			"mark_cancellable → to_dict is_cancellable true")

	# 6. with_timeout_ms
	testing.eq(MCPToolkitCommandOptions.new().with_timeout_ms(5000).to_dict()["timeout_ms"],
			5000, "with_timeout_ms(5000) → 5000")

	# 7. chained builder returns same reference
	var opts := MCPToolkitCommandOptions.new()
	testing.ok(opts.mark_read_only().mark_idempotent() == opts,
			"chained builder returns same reference")

	# 8. with_group sets name, description, keywords
	var group: Dictionary = MCPToolkitCommandOptions.new() \
			.with_group("grp", "Desc", ["kw"]).to_dict().get("group", {})
	testing.eq(group.get("name", ""), "grp", "with_group → name")
	testing.eq(group.get("description", ""), "Desc", "with_group → description")
	testing.ok(group.get("keywords", []).has("kw"), "with_group → keywords")

	# 9-10. Version gating
	testing.eq(MCPToolkitCommandOptions.new().with_min_godot_version("4.5") \
			.to_dict().get("min_godot_version", ""), "4.5",
			"with_min_godot_version → '4.5'")
	testing.eq(MCPToolkitCommandOptions.new().with_max_godot_version("4.4") \
			.to_dict().get("max_godot_version", ""), "4.4",
			"with_max_godot_version → '4.4'")

	# 11. chained version bounds
	var version_dict: Dictionary = MCPToolkitCommandOptions.new() \
			.with_min_godot_version("4.3") \
			.with_max_godot_version("4.5").to_dict()
	testing.ok(version_dict.has("min_godot_version") and version_dict.has("max_godot_version"),
			"chained version bounds → both present")

	# 12. invalid version string — stored despite push_warning
	testing.eq(MCPToolkitCommandOptions.new().with_min_godot_version("bad") \
			.to_dict().get("min_godot_version", ""), "bad",
			"invalid version stored (push_warning fires)")

	print("")


# --- Extension options (~4 assertions) ------------------------------------
static func _test_extension_options(testing) -> void:
	testing.begin("Extension options")

	# 1. constructor sets description
	var extension_dict: Dictionary = MCPToolkitExtensionOptions.new("My tool").to_dict()
	testing.eq(extension_dict["description"], "My tool", "constructor sets description")

	# 2. inherits builder methods (chaining returns same ref)
	var ext := MCPToolkitExtensionOptions.new("Ext")
	testing.ok(ext.mark_read_only().mark_idempotent() == ext,
			"inherits builder methods (chaining works)")

	# 3. default annotations — safe fallback
	var fresh: Dictionary = MCPToolkitExtensionOptions.new("Fresh").to_dict()
	testing.ok(not fresh["is_read_only"], "default → not read-only")
	testing.ok(not fresh["is_destructive"], "default → not destructive")

	print("")


# --- Annotation mapping (~6 assertions) -----------------------------------
static func _test_annotation_mapping(testing) -> void:
	testing.begin("Annotation mapping")
	var registry := MCPToolkitCommandRegistry.new()

	# 1. mark_read_only → readOnlyHint true
	registry.add("a.ro", testing.noop, MCPToolkitCommandOptions.new().mark_read_only())
	testing.ok(registry.get_command_metadata("a.ro")["annotations"]["readOnlyHint"],
			"mark_read_only → readOnlyHint true")

	# 2. mark_destructive → destructiveHint true
	registry.add("a.ds", testing.noop, MCPToolkitCommandOptions.new().mark_destructive())
	testing.ok(registry.get_command_metadata("a.ds")["annotations"]["destructiveHint"],
			"mark_destructive → destructiveHint true")

	# 3. mark_idempotent → idempotentHint true
	registry.add("a.id", testing.noop, MCPToolkitCommandOptions.new().mark_idempotent())
	testing.ok(registry.get_command_metadata("a.id")["annotations"]["idempotentHint"],
			"mark_idempotent → idempotentHint true")

	# 4. no marks → all hints false
	registry.add("a.plain", testing.noop, MCPToolkitCommandOptions.new())
	var ann: Dictionary = registry.get_command_metadata("a.plain").get("annotations", {})
	testing.ok(not ann.get("readOnlyHint", false), "no marks → readOnlyHint false")
	testing.ok(not ann.get("destructiveHint", false), "no marks → destructiveHint false")
	testing.ok(not ann.get("idempotentHint", false), "no marks → idempotentHint false")

	print("")


# --- Timeout clamping (~5 assertions) -------------------------------------
static func _test_timeout_clamping(testing) -> void:
	testing.begin("Timeout clamping")
	var registry := MCPToolkitCommandRegistry.new()

	# 1. no timeout → default 30000 (metadata omits key)
	registry.add("to.def", testing.noop, MCPToolkitCommandOptions.new())
	testing.ok(not registry.get_command_metadata("to.def").has("timeout_ms"),
			"no timeout → default 30000 (omitted from metadata)")

	# 2. below min → clamped to 1000
	registry.add("to.lo", testing.noop, MCPToolkitCommandOptions.new().with_timeout_ms(500))
	testing.eq(registry.get_command_metadata("to.lo").get("timeout_ms", -1), 1000,
			"timeout 500 → clamped to 1000")

	# 3. above max → clamped to 300000
	registry.add("to.hi", testing.noop, MCPToolkitCommandOptions.new().with_timeout_ms(500000))
	testing.eq(registry.get_command_metadata("to.hi").get("timeout_ms", -1), 300000,
			"timeout 500000 → clamped to 300000")

	# 4. in range → unchanged
	registry.add("to.ok", testing.noop, MCPToolkitCommandOptions.new().with_timeout_ms(5000))
	testing.eq(registry.get_command_metadata("to.ok").get("timeout_ms", -1), 5000,
			"timeout 5000 → unchanged")

	# 5. zero → default (same as no timeout)
	registry.add("to.z", testing.noop, MCPToolkitCommandOptions.new().with_timeout_ms(0))
	testing.ok(not registry.get_command_metadata("to.z").has("timeout_ms"),
			"timeout 0 → default (omitted from metadata)")

	print("")

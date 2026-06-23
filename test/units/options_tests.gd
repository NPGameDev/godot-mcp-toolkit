@tool
extends RefCounted
## Options/annotation builder unit tests: MCPToolkitCommandOptions marks +
## timeouts + version gating, extension options, annotation mapping, timeout clamping.


static func run(h) -> void:
	_test_options_builder(h)
	_test_extension_options(h)
	_test_annotation_mapping(h)
	_test_timeout_clamping(h)


# --- Options builder (~14 assertions) -------------------------------------
static func _test_options_builder(h) -> void:
	h.begin("Options builder")

	# 1-5. Boolean marks
	h.ok(MCPToolkitCommandOptions.new().mark_read_only().to_dict()["is_read_only"],
			"mark_read_only → to_dict is_read_only true")
	h.ok(MCPToolkitCommandOptions.new().mark_destructive().to_dict()["is_destructive"],
			"mark_destructive → to_dict is_destructive true")
	h.ok(MCPToolkitCommandOptions.new().mark_idempotent().to_dict()["is_idempotent"],
			"mark_idempotent → to_dict is_idempotent true")
	h.ok(MCPToolkitCommandOptions.new().mark_exclusive_execution().to_dict() \
			.get("exclusive_execution", false),
			"mark_exclusive_execution → to_dict exclusive_execution true")
	h.ok(MCPToolkitCommandOptions.new().mark_cancellable().to_dict()["is_cancellable"],
			"mark_cancellable → to_dict is_cancellable true")

	# 6. with_timeout_ms
	h.eq(MCPToolkitCommandOptions.new().with_timeout_ms(5000).to_dict()["timeout_ms"],
			5000, "with_timeout_ms(5000) → 5000")

	# 7. chained builder returns same reference
	var opts := MCPToolkitCommandOptions.new()
	h.ok(opts.mark_read_only().mark_idempotent() == opts,
			"chained builder returns same reference")

	# 8. with_group sets name, description, keywords
	var g: Dictionary = MCPToolkitCommandOptions.new() \
			.with_group("grp", "Desc", ["kw"]).to_dict().get("group", {})
	h.eq(g.get("name", ""), "grp", "with_group → name")
	h.eq(g.get("description", ""), "Desc", "with_group → description")
	h.ok(g.get("keywords", []).has("kw"), "with_group → keywords")

	# 9-10. Version gating
	h.eq(MCPToolkitCommandOptions.new().with_min_godot_version("4.5") \
			.to_dict().get("min_godot_version", ""), "4.5",
			"with_min_godot_version → '4.5'")
	h.eq(MCPToolkitCommandOptions.new().with_max_godot_version("4.4") \
			.to_dict().get("max_godot_version", ""), "4.4",
			"with_max_godot_version → '4.4'")

	# 11. chained version bounds
	var vd: Dictionary = MCPToolkitCommandOptions.new() \
			.with_min_godot_version("4.3") \
			.with_max_godot_version("4.5").to_dict()
	h.ok(vd.has("min_godot_version") and vd.has("max_godot_version"),
			"chained version bounds → both present")

	# 12. invalid version string — stored despite push_warning
	h.eq(MCPToolkitCommandOptions.new().with_min_godot_version("bad") \
			.to_dict().get("min_godot_version", ""), "bad",
			"invalid version stored (push_warning fires)")

	print("")


# --- Extension options (~4 assertions) ------------------------------------
static func _test_extension_options(h) -> void:
	h.begin("Extension options")

	# 1. constructor sets description
	var d: Dictionary = MCPToolkitExtensionOptions.new("My tool").to_dict()
	h.eq(d["description"], "My tool", "constructor sets description")

	# 2. inherits builder methods (chaining returns same ref)
	var ext := MCPToolkitExtensionOptions.new("Ext")
	h.ok(ext.mark_read_only().mark_idempotent() == ext,
			"inherits builder methods (chaining works)")

	# 3. default annotations — safe fallback
	var fresh: Dictionary = MCPToolkitExtensionOptions.new("Fresh").to_dict()
	h.ok(not fresh["is_read_only"], "default → not read-only")
	h.ok(not fresh["is_destructive"], "default → not destructive")

	print("")


# --- Annotation mapping (~6 assertions) -----------------------------------
static func _test_annotation_mapping(h) -> void:
	h.begin("Annotation mapping")
	var reg := MCPToolkitCommandRegistry.new()

	# 1. mark_read_only → readOnlyHint true
	reg.add("a.ro", h.noop, MCPToolkitCommandOptions.new().mark_read_only())
	h.ok(reg.get_command_metadata("a.ro")["annotations"]["readOnlyHint"],
			"mark_read_only → readOnlyHint true")

	# 2. mark_destructive → destructiveHint true
	reg.add("a.ds", h.noop, MCPToolkitCommandOptions.new().mark_destructive())
	h.ok(reg.get_command_metadata("a.ds")["annotations"]["destructiveHint"],
			"mark_destructive → destructiveHint true")

	# 3. mark_idempotent → idempotentHint true
	reg.add("a.id", h.noop, MCPToolkitCommandOptions.new().mark_idempotent())
	h.ok(reg.get_command_metadata("a.id")["annotations"]["idempotentHint"],
			"mark_idempotent → idempotentHint true")

	# 4. no marks → all hints false
	reg.add("a.plain", h.noop, MCPToolkitCommandOptions.new())
	var ann: Dictionary = reg.get_command_metadata("a.plain").get("annotations", {})
	h.ok(not ann.get("readOnlyHint", false), "no marks → readOnlyHint false")
	h.ok(not ann.get("destructiveHint", false), "no marks → destructiveHint false")
	h.ok(not ann.get("idempotentHint", false), "no marks → idempotentHint false")

	print("")


# --- Timeout clamping (~5 assertions) -------------------------------------
static func _test_timeout_clamping(h) -> void:
	h.begin("Timeout clamping")
	var reg := MCPToolkitCommandRegistry.new()

	# 1. no timeout → default 30000 (metadata omits key)
	reg.add("to.def", h.noop, MCPToolkitCommandOptions.new())
	h.ok(not reg.get_command_metadata("to.def").has("timeout_ms"),
			"no timeout → default 30000 (omitted from metadata)")

	# 2. below min → clamped to 1000
	reg.add("to.lo", h.noop, MCPToolkitCommandOptions.new().with_timeout_ms(500))
	h.eq(reg.get_command_metadata("to.lo").get("timeout_ms", -1), 1000,
			"timeout 500 → clamped to 1000")

	# 3. above max → clamped to 300000
	reg.add("to.hi", h.noop, MCPToolkitCommandOptions.new().with_timeout_ms(500000))
	h.eq(reg.get_command_metadata("to.hi").get("timeout_ms", -1), 300000,
			"timeout 500000 → clamped to 300000")

	# 4. in range → unchanged
	reg.add("to.ok", h.noop, MCPToolkitCommandOptions.new().with_timeout_ms(5000))
	h.eq(reg.get_command_metadata("to.ok").get("timeout_ms", -1), 5000,
			"timeout 5000 → unchanged")

	# 5. zero → default (same as no timeout)
	reg.add("to.z", h.noop, MCPToolkitCommandOptions.new().with_timeout_ms(0))
	h.ok(not reg.get_command_metadata("to.z").has("timeout_ms"),
			"timeout 0 → default (omitted from metadata)")

	print("")

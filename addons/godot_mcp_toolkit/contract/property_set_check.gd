@tool
extends RefCounted
## Pure, headless-testable detector for a silently-dropped property write.
##
## Godot's [method Object.set] is void and discards a Variant it cannot assign to
## the target property (a wrong type), so a write can "succeed" while the value
## never lands — a false success that sends an LLM caller chasing a value that was
## never stored. This module brackets a set with before/after readbacks and reports
## the drop. It is the single SSOT shared by every property-set path: the editor
## node/scene handlers (via [code]commands/editor_helpers.gd[/code]) and the runtime
## autoload's [code]runtime.set_property[/code] (via a direct preload).
##
## Runtime-clean by construction — it names only value types, [String] formatting,
## and [@GlobalScope] functions ([method @GlobalScope.type_string],
## [method @GlobalScope.is_equal_approx]), never an editor class, and preloads
## nothing. An editor symbol anywhere in this static graph would parse-fail the
## runtime autoload in an unstripped export (godotengine/godot#91713), and the
## runtime server preloads this file; keep it editor-free.


## Classify a property write as clean / accepted-but-adjusted / silently dropped.
## Godot's [method Object.set] is void: it silently discards a wrong-type Variant
## (a false success), but it also silently RESHAPES a convertible one (float 7.9 →
## int 7, "Foo/" → "Foo", a normalized direction) — accepted, yet the stored value
## differs from what was asked. Bracket a set with before/after readbacks and this
## returns a tri-state so the caller can succeed-clean, succeed-with-a-warning, or
## fail. Shared by the editor node/scene paths and the runtime autoload.
## [br]
##   [param before]  the property's value BEFORE the set (its type is the oracle)
##   [param after]   the property's value AFTER the set (read from the same place)
##   [param coerced] the value that was assigned (already Coerce-d from JSON)
##   [param path]    property path, for the message
## [br]
## Returns a tri-state Dictionary:
##   [code]{"status": "ok"}[/code] — stored ≈ requested (exact set, int→float where
##       5.0 == 5, set-to-same); clean success.
##   [code]{"status": "adjusted", "warning": String}[/code] — the write was ACCEPTED
##       but the engine reshaped it (truncate/sanitize/clamp/normalize) so the stored
##       value ≠ the request; success + a warning naming property/requested/stored.
##   [code]{"status": "dropped", "error": String}[/code] — a silent wrong-type drop
##       (cross-family, value unchanged, ≠ request) → the caller emits SET_FAILED.
static func describe_set_drop(
	before: Variant, after: Variant, coerced: Variant, path: String,
) -> Dictionary:
	# Reported no error but nothing is there: the property is not on this object. The
	# hint leads with the most common build-flow cause — a script-defined property set
	# before its script is attached — then the mistyped-name and dedicated-API cases.
	if after == null and coerced != null:
		return {"status": "dropped", "error":
			"set() on '%s' reported no error but readback is null. " % path
			+ "The property is not present on this object — most often it is defined "
			+ "by a script not attached to this node yet (attach the script first, "
			+ "then set its properties), a mistyped property name, or a property that "
			+ "needs a dedicated API (e.g. set_shader_parameter, add_animation_library)."}
	# Stored value equals the request → clean success (exact, int→float 5.0==5, set-to-same).
	if _values_loosely_equal(after, coerced):
		return {"status": "ok"}
	# Stored value ≠ requested. The convertible-family gate is the SINGLE arbiter of
	# reshape-vs-drop on BOTH the changed- and unchanged-value paths:
	#   • same family → the engine legitimately reshaped an in-family value
	#     (truncate 7.9→7, sanitize "Foo/"→"Foo", normalize a direction) → ADJUSTED.
	#   • cross family → the engine did NOT store a real value. It either kept the old
	#     one (a plain drop, after == before) OR — for a bound setter like position /
	#     modulate — Variant-converted the wrong type to a ZERO and stored that,
	#     DESTROYING the prior value (after ≠ before). BOTH are discards, not reshapes.
	#     Gating on the family (not on after == before) is what catches this
	#     destructive-zero case that a non-zero prior exposes.
	if before != null and _same_convertible_family(typeof(coerced), typeof(before)):
		return {"status": "adjusted", "warning": _adjusted_warning(after, coerced, path)}
	# Cross-family → the write did not land as a real value (kept-old or zeroed).
	return {"status": "dropped", "error":
		"property '%s' rejected the value: expected type %s, got %s (%s). "
		% [path, type_string(typeof(before)), type_string(typeof(coerced)),
			_brief_set_value(coerced)]
		+ "Godot's set() silently discards a wrong-type value. Pass a value of the "
		+ "expected type — for struct types use the tagged form "
		+ "(e.g. {\"type\":\"Vector2\",\"x\":0,\"y\":0})."}


## Warning text for an accepted-but-adjusted write, naming what was stored vs asked.
static func _adjusted_warning(after: Variant, coerced: Variant, path: String) -> String:
	return ("note: '%s' stored %s but you requested %s — the engine adjusted the value to fit %s."
		% [path, _brief_set_value(after), _brief_set_value(coerced), type_string(typeof(after))])


## True when assigning type [param t_coerced] onto a property of type
## [param t_before] stays within one convertible family Godot's set() accepts and
## reshapes in place: the exact same type (a value type may normalize/transform on
## set), both numeric (bool/int/float — the engine truncates float→int etc.), or
## both stringy (String/StringName/NodePath — normalized/sanitized). OBJECT is
## excluded — Resource assignment has no in-family reshape, so a wrong-subtype drop
## must reach the identity backstop rather than being trusted here.
static func _same_convertible_family(t_coerced: int, t_before: int) -> bool:
	if t_coerced == TYPE_OBJECT or t_before == TYPE_OBJECT:
		return false
	if t_coerced == t_before:
		return true
	if _is_numeric_type(t_coerced) and _is_numeric_type(t_before):
		return true
	if _is_stringy_type(t_coerced) and _is_stringy_type(t_before):
		return true
	# Integer/float vector variants convert too (Vector2 7.9 → Vector2i 7), mirroring
	# _values_loosely_equal so a truncate-onto-current here reads as adjusted, not dropped.
	if (t_coerced == TYPE_VECTOR2 or t_coerced == TYPE_VECTOR2I) \
			and (t_before == TYPE_VECTOR2 or t_before == TYPE_VECTOR2I):
		return true
	if (t_coerced == TYPE_VECTOR3 or t_coerced == TYPE_VECTOR3I) \
			and (t_before == TYPE_VECTOR3 or t_before == TYPE_VECTOR3I):
		return true
	return false


## True when [param t] is a numeric Variant type. bool counts — the engine assigns
## it as 0/1 in a numeric slot, so a bool↔int/float write is a real conversion.
static func _is_numeric_type(t: int) -> bool:
	return t == TYPE_BOOL or t == TYPE_INT or t == TYPE_FLOAT


## True when [param t] is a string-like Variant type. String, StringName and
## NodePath are mutually assignable in the engine (set() converts between them).
static func _is_stringy_type(t: int) -> bool:
	return t == TYPE_STRING or t == TYPE_STRING_NAME or t == TYPE_NODE_PATH


## Cross-type-tolerant value equality used to judge whether a write landed. Same
## type → exact [code]==[/code]. Within the numeric family (bool/int/float) and the
## string family (String/StringName/NodePath) values compare across the family, and
## integer/float vector variants (Vector2i↔Vector2, Vector3i↔Vector3) compare
## approximately — each mirrors a conversion Godot's set() performs. Anything else
## across types is unequal.
static func _values_loosely_equal(a: Variant, b: Variant) -> bool:
	var ta := typeof(a)
	var tb := typeof(b)
	if ta == tb:
		return a == b
	if _is_numeric_type(ta) and _is_numeric_type(tb):
		return is_equal_approx(float(a), float(b))
	if _is_stringy_type(ta) and _is_stringy_type(tb):
		return str(a) == str(b)
	if (ta == TYPE_VECTOR2 or ta == TYPE_VECTOR2I) \
			and (tb == TYPE_VECTOR2 or tb == TYPE_VECTOR2I):
		var v2a: Vector2 = type_convert(a, TYPE_VECTOR2)
		var v2b: Vector2 = type_convert(b, TYPE_VECTOR2)
		return v2a.is_equal_approx(v2b)
	if (ta == TYPE_VECTOR3 or ta == TYPE_VECTOR3I) \
			and (tb == TYPE_VECTOR3 or tb == TYPE_VECTOR3I):
		var v3a: Vector3 = type_convert(a, TYPE_VECTOR3)
		var v3b: Vector3 = type_convert(b, TYPE_VECTOR3)
		return v3a.is_equal_approx(v3b)
	return false


## Short, safe rendering of a value for an error message (truncated at 60 chars).
static func _brief_set_value(value: Variant) -> String:
	var s := var_to_str(value)
	if s.length() > 60:
		return s.left(57) + "..."
	return s

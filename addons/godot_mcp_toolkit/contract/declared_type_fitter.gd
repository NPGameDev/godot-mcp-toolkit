@tool
extends RefCounted
## Fits a JSON value to the type a property declares, before a property write sets it.
##
## JSON numbers always decode as float and JSON arrays always decode untyped, and
## [method Object.set] handles such a value differently on each kind of instance. A
## live script instance converts a float for an [code]int[/code] member, but refuses
## an untyped array for an [code]Array[T][/code] member and keeps the old value
## without an error. The editor runs a script that is not [code]@tool[/code] as a
## placeholder instance, whose set() stores either value as given, so the scene or
## resource file saves [code]4.0[/code] or an untyped array. [method fit] converts the
## value to the declared type first, so a live and a placeholder instance store the
## same value; [method fit] names the cases it leaves as given.
##
## Runtime-clean: it names no editor class and preloads only export-clean scripts,
## because the runtime server preloads it. An editor symbol anywhere in this static
## graph would parse-fail the runtime autoload in an unstripped export
## (godotengine/godot#91713); keep it editor-free.

const PropertySetCheck := preload("res://addons/godot_mcp_toolkit/contract/property_set_check.gd")

## Usage flags of the inspector header entries a property list interleaves with
## its properties.
const _PROPERTY_HEADER_USAGE := (
		PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP | PROPERTY_USAGE_CATEGORY)

## For each element type, the other types an element may have and still convert
## when the engine fills a typed array: the engine's strict conversions
## (Variant::can_convert_strict). Arrays and packed arrays, which convert into each
## other, and the Strings a [Color] takes without an error are left to
## [method _fits_typed_array].
const _STRICT_CONVERSIONS := {
	TYPE_BOOL: [TYPE_INT, TYPE_FLOAT],
	TYPE_INT: [TYPE_BOOL, TYPE_FLOAT],
	TYPE_FLOAT: [TYPE_BOOL, TYPE_INT],
	TYPE_STRING: [TYPE_NODE_PATH, TYPE_STRING_NAME],
	TYPE_VECTOR2: [TYPE_VECTOR2I],
	TYPE_VECTOR2I: [TYPE_VECTOR2],
	TYPE_RECT2: [TYPE_RECT2I],
	TYPE_RECT2I: [TYPE_RECT2],
	TYPE_TRANSFORM2D: [TYPE_TRANSFORM3D],
	TYPE_VECTOR3: [TYPE_VECTOR3I],
	TYPE_VECTOR3I: [TYPE_VECTOR3],
	TYPE_VECTOR4: [TYPE_VECTOR4I],
	TYPE_VECTOR4I: [TYPE_VECTOR4],
	TYPE_QUATERNION: [TYPE_BASIS],
	TYPE_BASIS: [TYPE_QUATERNION],
	TYPE_TRANSFORM3D: [TYPE_TRANSFORM2D, TYPE_QUATERNION, TYPE_BASIS, TYPE_PROJECTION],
	TYPE_PROJECTION: [TYPE_TRANSFORM3D],
	TYPE_COLOR: [TYPE_STRING, TYPE_INT],
	TYPE_RID: [TYPE_OBJECT],
	TYPE_STRING_NAME: [TYPE_STRING],
	TYPE_NODE_PATH: [TYPE_STRING],
}


## Fits [param value] to the type [param target]'s property list declares for
## [param property], before the caller sets it.
##
## A float written to an [code]int[/code] property becomes an int, truncated toward
## zero as the engine truncates it. An untyped [Array] written to a typed array
## property becomes an array of its element type, built the way the text resource
## loader builds one. Each element is checked first, so one that does not fit is
## reported here instead of as an engine error, and a float element of an
## [code]Array[int][/code] is truncated as a scalar is.
## [br][br]
## The declaration decides whether an array is converted, not the current value: a
## property declared as a Variant or a plain [Array] takes [param value] as given,
## even when it holds a typed array. The element type comes from the typed array the
## property holds, which carries the element's class and script; when it holds no
## typed array, as a placeholder that loaded an untyped one from a file does, a
## built-in element type comes from the declaration's hint string instead. A typed
## array that matches already, any other value, and a property missing from the list
## pass through too.
## [br][br]
## An array of objects onto a property that holds no typed array passes through
## untyped: the hint string names the element's class only by name. So does an
## array onto a typed var of an enum, whose hint string names the enum
## ([code]"Class.Enum"[/code]), not a built-in type; an exported enum array declares
## [code]int[/code] and converts.
## [br][br]
## Returns [code]{"value": <the value to set>, "warning": String, "error": String}[/code].
## [code]warning[/code] is empty unless a fraction was dropped; it then names
## [param property] and what changed, in one warning for a whole array.
## [code]error[/code] is empty unless an array element does not fit the element
## type; [code]value[/code] is then [param value] as given and the caller leaves the
## property unchanged.
static func fit(target: Object, property: String, value: Variant) -> Dictionary:
	var entry := property_entry(target, property)
	if _declares_typed_array(entry):
		return _fit_to_typed_array(_element_template(target.get(property), entry), property, value)
	var conversion := _coerce_to_declared_type(value, int(entry.get("type", TYPE_NIL)))
	var warning := ""
	if conversion["truncated"]:
		warning = PropertySetCheck.adjusted_warning(conversion["value"], value, property)
	return {"value": conversion["value"], "warning": warning, "error": ""}


## The entry [param target]'s property list holds for [param property], or an empty
## Dictionary when it has none.
##
## Inspector group, subgroup and category headers are skipped: an
## [code]@export_group("speed")[/code] listed ahead of [code]var speed: int[/code]
## shares its name but declares no type, and a key that names only a header is not
## a property.
static func property_entry(target: Object, property: String) -> Dictionary:
	for entry in target.get_property_list():
		if entry["name"] == property \
				and (int(entry.get("usage", 0)) & _PROPERTY_HEADER_USAGE) == 0:
			return entry
	return {}


## True when the property-list [param entry] declares a typed array. A typed
## [code]var[/code], or an entry a script lists itself, carries
## [constant @GlobalScope.PROPERTY_HINT_ARRAY_TYPE]; an [code]@export[/code] of a typed
## array carries [constant @GlobalScope.PROPERTY_HINT_TYPE_STRING] instead.
static func _declares_typed_array(entry: Dictionary) -> bool:
	if int(entry.get("type", TYPE_NIL)) != TYPE_ARRAY:
		return false
	var hint := int(entry.get("hint", PROPERTY_HINT_NONE))
	return hint == PROPERTY_HINT_ARRAY_TYPE or hint == PROPERTY_HINT_TYPE_STRING


## The array whose element type a write to a typed array property takes:
## [param current], the value the property holds, when it is a typed array; else an
## empty array of the built-in element type the property-list [param entry]
## declares; else [param current] as it is.
static func _element_template(current: Variant, entry: Dictionary) -> Variant:
	if current is Array and (current as Array).is_typed():
		return current
	var element_type := _declared_builtin_element_type(entry)
	if element_type == TYPE_NIL:
		return current
	return Array([], element_type, &"", null)


## The built-in element type a typed array [param entry] declares in its hint string,
## or [constant @GlobalScope.TYPE_NIL] for an object element or a hint string that
## names no built-in type. [constant @GlobalScope.PROPERTY_HINT_TYPE_STRING] leads
## with the type's number ([code]"4:"[/code], [code]"2/2:Low,High"[/code]);
## [constant @GlobalScope.PROPERTY_HINT_ARRAY_TYPE] holds the type's name
## ([code]"String"[/code]).
static func _declared_builtin_element_type(entry: Dictionary) -> int:
	var hint := int(entry.get("hint", PROPERTY_HINT_NONE))
	var hint_string := str(entry.get("hint_string", ""))
	var element_type := TYPE_NIL
	if hint == PROPERTY_HINT_TYPE_STRING:
		var type_number := hint_string.get_slice(":", 0).get_slice("/", 0)
		if type_number.is_valid_int():
			element_type = type_number.to_int()
	elif hint == PROPERTY_HINT_ARRAY_TYPE:
		element_type = _builtin_type_named(hint_string)
	if element_type <= TYPE_NIL or element_type >= TYPE_MAX or element_type == TYPE_OBJECT:
		return TYPE_NIL
	return element_type


## The built-in type whose name is [param type_name], as
## [method @GlobalScope.type_string] spells it, or [constant @GlobalScope.TYPE_NIL]
## when no built-in type has that name.
static func _builtin_type_named(type_name: String) -> int:
	for variant_type in range(TYPE_NIL + 1, TYPE_MAX):
		if type_string(variant_type) == type_name:
			return variant_type
	return TYPE_NIL


## Fits [param value] to the element type of [param current], the typed array
## [method _element_template] picks. An array the property holds carries the
## element's class and script, which the declaration's hint string names only by
## class name.
##
## Returns the [method fit] shape. A [param current] that is not a typed array, a
## [param value] that is not an [Array], and an array typed like [param current]
## pass through.
static func _fit_to_typed_array(current: Variant, property: String, value: Variant) -> Dictionary:
	if not (value is Array and current is Array):
		return {"value": value, "warning": "", "error": ""}
	var requested: Array = value
	var template: Array = current
	if not template.is_typed() or requested.is_same_typed(template):
		return {"value": value, "warning": "", "error": ""}
	var element_type := template.get_typed_builtin()
	var elements: Array = []
	var truncated_indices := PackedStringArray()
	for index in requested.size():
		var element: Variant = requested[index]
		if not _fits_typed_array(element, template):
			return {"value": value, "warning": "", "error":
				"property '%s': the element at index %d (%s) doesn't fit the typed array"
					% [property, index, type_string(typeof(element))]}
		var conversion := _coerce_to_declared_type(element, element_type)
		if conversion["truncated"]:
			truncated_indices.append(str(index))
		elements.append(conversion["value"])
	var typed := Array(elements, element_type,
			template.get_typed_class_name(), template.get_typed_script())
	# A conversion the element check passed can still fail inside the engine; the
	# typed array then comes back short.
	if typed.size() != elements.size():
		return {"value": value, "warning": "",
			"error": "property '%s': an element doesn't fit the typed array" % property}
	var warning := ""
	if not truncated_indices.is_empty():
		var index_word := "index" if truncated_indices.size() == 1 else "indices"
		warning = ("note: '%s' elements at %s %s were adjusted to fit %s; the fraction was dropped."
			% [property, index_word, ", ".join(truncated_indices), type_string(element_type)])
	return {"value": typed, "warning": warning, "error": ""}


## Fits a JSON number to the [code]int[/code] a property declares; any other value
## passes through unchanged.
##
## When [param declared_type] (the [code]type[/code] entry of
## [method Object.get_property_list]) is [constant @GlobalScope.TYPE_INT] and
## [param value] is a float, the value becomes an int, truncated toward zero as the
## engine's own conversion truncates it.
## [br][br]
## Returns [code]{"value": <the value to set>, "truncated": bool}[/code].
## [code]truncated[/code] is true when the stored int differs from the requested
## float, so the caller can warn that the value changed.
static func _coerce_to_declared_type(value: Variant, declared_type: int) -> Dictionary:
	if declared_type != TYPE_INT or typeof(value) != TYPE_FLOAT:
		return {"value": value, "truncated": false}
	var requested: float = value
	var stored := int(requested)
	# Exact compare: a whole float within int64 range survives the round trip
	# through int unchanged, while a tolerance that scales with the value would
	# hide a dropped fraction on large numbers.
	return {"value": stored, "truncated": float(stored) != requested}


## True when [param element] can go into an array typed like [param template]
## without an engine error, by the rule the engine applies when it fills a typed
## array from an untyped one: an object array takes null or an instance of its
## class and script; any other typed array takes its own type or one that converts
## strictly into it. A [Color] array takes a String only when it names a colour:
## the engine turns any other String into [code]Color(0, 0, 0, 0)[/code] and prints
## an error.
static func _fits_typed_array(element: Variant, template: Array) -> bool:
	var element_type := typeof(element)
	var target_type := template.get_typed_builtin()
	if target_type != TYPE_OBJECT:
		if element_type == target_type:
			return true
		if (element_type == TYPE_ARRAY and _is_packed_array_type(target_type)) \
				or (target_type == TYPE_ARRAY and _is_packed_array_type(element_type)):
			return true
		if target_type == TYPE_COLOR and element_type == TYPE_STRING:
			return _names_a_colour(element)
		var sources: Array = _STRICT_CONVERSIONS.get(target_type, [])
		return element_type in sources
	if element_type == TYPE_NIL:
		return true
	if element_type != TYPE_OBJECT or not is_instance_valid(element):
		return false
	var object: Object = element
	if not ClassDB.is_parent_class(object.get_class(), template.get_typed_class_name()):
		return false
	var required_script: Script = template.get_typed_script()
	var script: Script = object.get_script()
	if required_script == null:
		return true
	while script != null:
		if script == required_script:
			return true
		script = script.get_base_script()
	return false


## True when [param text] is an HTML colour code or a colour name, the Strings the
## engine converts to a [Color] without an error. [method Color.from_string] prints
## nothing and returns its default for any other String, so the String names a
## colour when two different defaults give the same result.
static func _names_a_colour(text: String) -> bool:
	return Color.from_string(text, Color.BLACK) == Color.from_string(text, Color.WHITE)


## True for the packed array types, which close the [enum Variant.Type] list on
## every supported version, so a packed type a later engine adds is included.
static func _is_packed_array_type(variant_type: int) -> bool:
	return variant_type >= TYPE_PACKED_BYTE_ARRAY and variant_type < TYPE_MAX

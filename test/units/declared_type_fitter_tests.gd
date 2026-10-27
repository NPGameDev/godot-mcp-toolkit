@tool
extends RefCounted
## DeclaredTypeFitter on its own: fit's int fraction, its typed-array conversion for
## each kind of element type, the warning and error it returns and the values it
## passes through, and the type declared_type reads. These pin the fitter's API; the
## behaviour pins for the property writers that call it live with each writer's
## tests. The typed_array_*.gd and placeholder_like_*.gd fixtures supply the
## declared properties.

const DeclaredTypeFitter := preload("res://addons/godot_mcp_toolkit/contract/declared_type_fitter.gd")
const PlaceholderLikeResource := preload("res://test/fixtures/placeholder_like_resource.gd")
const PlaceholderLikeGroupedResource := preload("res://test/fixtures/placeholder_like_grouped_resource.gd")
const TypedArrayResource := preload("res://test/fixtures/typed_array_resource.gd")
const TypedArrayScriptedResource := preload("res://test/fixtures/typed_array_scripted_resource.gd")
const TypedArrayElement := preload("res://test/fixtures/typed_array_element.gd")

## A script with an untyped array, a Variant and a typed array that is not exported,
## for the declarations the fixtures do not cover.
const _HOLDER_SOURCE := (
		"extends RefCounted\n"
		+ "var items: Array = []\n"
		+ "var anything = null\n"
		+ "var plain_tags: Array[String] = []\n")

## A stand-in for a placeholder whose typed-array exports declare their element type
## the way an [code]@export[/code] does, in a type-string hint, and store each value
## as given, as placeholder_like_resource.gd does.
const _PLACEHOLDER_EXPORTS_SOURCE := (
		"extends RefCounted\n"
		+ "var _values := {}\n"
		+ "func _get_property_list() -> Array[Dictionary]:\n"
		+ "\treturn [\n"
		+ "\t\t{'name': 'scores', 'type': TYPE_ARRAY, 'hint': PROPERTY_HINT_TYPE_STRING,\n"
		+ "\t\t\t'hint_string': str(TYPE_INT) + ':', 'usage': PROPERTY_USAGE_DEFAULT},\n"
		+ "\t\t{'name': 'textures', 'type': TYPE_ARRAY, 'hint': PROPERTY_HINT_TYPE_STRING,\n"
		+ "\t\t\t'hint_string': '%d/%d:Texture2D' % [TYPE_OBJECT, PROPERTY_HINT_RESOURCE_TYPE],\n"
		+ "\t\t\t'usage': PROPERTY_USAGE_DEFAULT},\n"
		+ "\t\t{'name': 'levels', 'type': TYPE_ARRAY, 'hint': PROPERTY_HINT_TYPE_STRING,\n"
		+ "\t\t\t'hint_string': '%d/%d:Low,High' % [TYPE_INT, PROPERTY_HINT_ENUM],\n"
		+ "\t\t\t'usage': PROPERTY_USAGE_DEFAULT},\n"
		+ "\t]\n"
		+ "func _set(property: StringName, value: Variant) -> bool:\n"
		+ "\tif property in [&'scores', &'textures', &'levels']:\n"
		+ "\t\t_values[property] = value\n"
		+ "\t\treturn true\n"
		+ "\treturn false\n"
		+ "func _get(property: StringName) -> Variant:\n"
		+ "\treturn _values.get(property)\n")


static func run(testing) -> void:
	_test_int_fraction(testing)
	_test_typed_array_element_types(testing)
	_test_truncation_warning(testing)
	_test_mismatched_element(testing)
	_test_pass_throughs(testing)
	_test_untyped_held_array(testing)
	_test_fit_to_typed_array(testing)
	_test_declared_type(testing)


static func _test_int_fraction(testing) -> void:
	testing.begin("DeclaredTypeFitter.fit: a float onto an int property (new API, green-only)")
	var resource: Resource = PlaceholderLikeResource.new()

	var fraction := DeclaredTypeFitter.fit(resource, "price", 4.5)
	testing.eq(typeof(fraction["value"]), TYPE_INT, "4.5 → an int")
	testing.eq(fraction["value"], 4, "4.5 → 4, truncated toward zero")
	testing.ok(str(fraction["warning"]).contains("'price'"), "a dropped fraction → a warning naming the property")
	testing.eq(fraction["error"], "", "a dropped fraction → no error")

	var whole := DeclaredTypeFitter.fit(resource, "price", 4.0)
	testing.eq(typeof(whole["value"]), TYPE_INT, "4.0 → an int")
	testing.eq(whole["value"], 4, "4.0 → 4")
	testing.eq(whole["warning"], "", "an integral float → no warning")

	var on_float := DeclaredTypeFitter.fit(resource, "weight", 4.5)
	testing.eq(typeof(on_float["value"]), TYPE_FLOAT, "a float property keeps the float")
	testing.eq(on_float["warning"], "", "a float property → no warning")
	print("")


static func _test_typed_array_element_types(testing) -> void:
	testing.begin("DeclaredTypeFitter.fit: an untyped array onto Array[T] (new API, green-only)")
	var tags := DeclaredTypeFitter.fit(TypedArrayResource.new(), "tags", ["a", &"b"])
	_expect_typed(testing, tags["value"], TYPE_STRING, "Array[String] (an @export)")
	testing.eq(tags["value"], ["a", "b"], "Array[String] holds the elements")
	testing.eq(typeof((tags["value"] as Array)[1]), TYPE_STRING, "a StringName element → a String")
	testing.eq(tags["error"], "", "Array[String] → no error")

	var scores := DeclaredTypeFitter.fit(TypedArrayScriptedResource.new(), "scores", [1, 2.0])
	_expect_typed(testing, scores["value"], TYPE_INT, "Array[int]")
	testing.eq(scores["value"], [1, 2], "Array[int] holds the elements")
	testing.eq(scores["warning"], "", "an integral float element → no warning")

	var texture := PlaceholderTexture2D.new()
	var textures := DeclaredTypeFitter.fit(TypedArrayResource.new(), "textures", [texture, null])
	_expect_typed(testing, textures["value"], TYPE_OBJECT, "Array[Texture2D]")
	testing.eq((textures["value"] as Array).get_typed_class_name(), &"Texture2D",
			"Array[<native class>] keeps the class")
	testing.eq((textures["value"] as Array).size(), 2, "a null element fits an object array")

	var element: Resource = TypedArrayElement.new()
	var elements := DeclaredTypeFitter.fit(TypedArrayScriptedResource.new(), "elements", [element])
	_expect_typed(testing, elements["value"], TYPE_OBJECT, "Array[<script class>]")
	testing.ok((elements["value"] as Array).get_typed_script() == TypedArrayElement,
			"Array[<script class>] keeps the script")

	var placeholder := DeclaredTypeFitter.fit(PlaceholderLikeResource.new(), "tags", ["x"])
	_expect_typed(testing, placeholder["value"], TYPE_STRING,
			"Array[String] a script lists in _get_property_list")

	var holder := _new_holder(testing)
	var plain := DeclaredTypeFitter.fit(holder, "plain_tags", ["y"])
	_expect_typed(testing, plain["value"], TYPE_STRING, "Array[String] on a var that is not exported")
	print("")


static func _test_truncation_warning(testing) -> void:
	testing.begin("DeclaredTypeFitter.fit: fractions in an Array[int] (new API, green-only)")
	var fit := DeclaredTypeFitter.fit(TypedArrayScriptedResource.new(), "scores", [1.5, 2.0, 3.5])
	testing.eq(fit["value"], [1, 2, 3], "each fraction is dropped")
	testing.eq(fit["error"], "", "a lossy element → no error")
	var warning := str(fit["warning"])
	testing.ok(warning.contains("indices 0, 2"), "one warning lists every truncated index")
	testing.ok(warning.contains("'scores'") and warning.contains("int"),
			"the warning names the property and the element type")
	print("")


static func _test_mismatched_element(testing) -> void:
	testing.begin("DeclaredTypeFitter.fit: an element that does not fit (new API, green-only)")
	var requested: Array = ["a", {}]
	var fit := DeclaredTypeFitter.fit(TypedArrayResource.new(), "tags", requested)
	testing.ok(str(fit["error"]).contains("'tags'"), "a mismatch → the error names the property")
	testing.ok(str(fit["error"]).contains("index 1"), "a mismatch → the error names the index")
	testing.eq(fit["warning"], "", "a mismatch → no warning")
	testing.ok(is_same(fit["value"], requested), "a mismatch → the value is returned as given")
	print("")


static func _test_pass_throughs(testing) -> void:
	testing.begin("DeclaredTypeFitter.fit: values and properties it leaves alone (new API, green-only)")
	var resource: Resource = TypedArrayScriptedResource.new()
	var scalar := DeclaredTypeFitter.fit(resource, "scores", 4)
	testing.eq(scalar["value"], 4, "a value that is not an array passes through")
	testing.eq(scalar["error"], "", "a value that is not an array → no error")

	var already: Array[int] = [7]
	var matching := DeclaredTypeFitter.fit(resource, "scores", already)
	testing.ok(is_same(matching["value"], already), "an array typed like the property passes through")

	var holder := _new_holder(testing)
	var untyped := DeclaredTypeFitter.fit(holder, "items", [1.5])
	testing.ok(not (untyped["value"] as Array).is_typed(), "a plain Array property → the array stays untyped")
	testing.eq(untyped["value"], [1.5], "a plain Array property → the value as given")

	var held: Array[int] = [1]
	holder.set("anything", held)
	var variant := DeclaredTypeFitter.fit(holder, "anything", ["a"])
	testing.ok(not (variant["value"] as Array).is_typed(),
			"a Variant property holding an Array[int] → the array stays untyped")
	testing.eq(variant["value"], ["a"], "a Variant property → the value as given")
	testing.eq(variant["error"], "", "a Variant property → no error")

	var empty := DeclaredTypeFitter.fit(TypedArrayResource.new(), "tags", [])
	_expect_typed(testing, empty["value"], TYPE_STRING, "an empty array onto Array[String]")
	testing.eq((empty["value"] as Array).size(), 0, "an empty array stays empty")
	testing.eq(empty["warning"], "", "an empty array → no warning")
	testing.eq(empty["error"], "", "an empty array → no error")

	var unknown := DeclaredTypeFitter.fit(resource, "missing", [1.5])
	testing.eq(unknown["value"], [1.5], "a property missing from the list → the value as given")
	testing.eq(unknown["error"], "", "a property missing from the list → no error")
	print("")


static func _test_untyped_held_array(testing) -> void:
	testing.begin("DeclaredTypeFitter.fit: Array[T] declared, an untyped array held (new API, green-only)")
	var resource: Resource = PlaceholderLikeResource.new()
	resource.set("tags", [])
	testing.ok(not (resource.get("tags") as Array).is_typed(), "the placeholder holds an untyped tags array")
	var tags := DeclaredTypeFitter.fit(resource, "tags", ["a", "b"])
	_expect_typed(testing, tags["value"], TYPE_STRING, "Array[String] by its element type's name")
	testing.eq(tags["value"], ["a", "b"], "Array[String] holds the elements")
	testing.eq(tags["error"], "", "Array[String] → no error")

	var exports := _new_placeholder_exports(testing)
	exports.set("scores", [])
	exports.set("textures", [])
	var scores := DeclaredTypeFitter.fit(exports, "scores", [1.5, 2.0])
	_expect_typed(testing, scores["value"], TYPE_INT, "Array[int] by its element type's number")
	testing.eq(scores["value"], [1, 2], "Array[int] holds the elements")
	testing.ok(str(scores["warning"]).contains("index 0 "), "a dropped fraction → the warning names its index")
	var mismatch := DeclaredTypeFitter.fit(exports, "scores", ["x"])
	testing.ok(str(mismatch["error"]).contains("index 0"), "a mismatch → the error names the index")
	exports.set("levels", [])
	var levels := DeclaredTypeFitter.fit(exports, "levels", [1.0])
	_expect_typed(testing, levels["value"], TYPE_INT, "an exported enum array (\"2/2:Low,High\")")

	var texture := PlaceholderTexture2D.new()
	var textures := DeclaredTypeFitter.fit(exports, "textures", [texture])
	testing.ok(not (textures["value"] as Array).is_typed(),
			"an object element type → the array passes through untyped")
	testing.eq((textures["value"] as Array).size(), 1, "an object element type → the value as given")
	testing.eq(textures["error"], "", "an object element type → no error")
	print("")


# The typed-array fit on its own: what passes through, what it builds, and the
# warning and error it returns.
static func _test_fit_to_typed_array(testing) -> void:
	testing.begin("DeclaredTypeFitter.fit fits an untyped array to a typed property")
	var resource: Resource = TypedArrayScriptedResource.new()

	var scalar := DeclaredTypeFitter.fit(resource, "scores", 4)
	testing.eq(scalar["value"], 4, "a value that is not an array passes through")
	testing.eq(scalar["error"], "", "a value that is not an array → no error")

	var untyped_target: Resource = PlaceholderLikeResource.new()
	var untyped := DeclaredTypeFitter.fit(untyped_target, "note", [1.5])
	testing.ok(not (untyped["value"] as Array).is_typed(),
			"a property that holds no typed array → the array stays untyped")
	testing.eq(untyped["warning"], "", "a property that holds no typed array → no warning")

	var untyped_array_target: Resource = PlaceholderLikeResource.new()
	untyped_array_target.set("note", [])
	var untyped_array := DeclaredTypeFitter.fit(untyped_array_target, "note", [1.5])
	testing.ok(not (untyped_array["value"] as Array).is_typed(),
			"a property that holds an untyped array → the array stays untyped")
	testing.eq(untyped_array["value"], [1.5],
			"a property that holds an untyped array → the value as given")
	testing.eq(untyped_array["warning"], "",
			"a property that holds an untyped array → no warning")

	var fitted := DeclaredTypeFitter.fit(resource, "scores", [1.5, 2.0])
	var fitted_value: Array = fitted["value"]
	testing.eq(fitted_value.get_typed_builtin(), TYPE_INT, "the value is an Array[int]")
	testing.eq(fitted_value[0], 1, "1.5 → 1")
	testing.eq(fitted["error"], "", "a lossy element → no error")
	testing.ok(str(fitted["warning"]).contains("index 0 "),
			"a lossy element → the warning names its index")
	testing.ok(str(fitted["warning"]).contains("int"), "the warning names the element type")

	var tags := DeclaredTypeFitter.fit(TypedArrayResource.new(), "tags", [&"name"])
	testing.eq(tags["error"], "", "a StringName converts into an Array[String]")
	testing.eq(typeof((tags["value"] as Array)[0]), TYPE_STRING, "the element is now a String")

	var mismatch := DeclaredTypeFitter.fit(resource, "scores", ["x"])
	testing.ok(str(mismatch["error"]).contains("'scores'"), "a mismatch → the error names the property")
	testing.ok(str(mismatch["error"]).contains("index 0"), "a mismatch → the error names the index")
	testing.ok(not (mismatch["value"] as Array).is_typed(), "a mismatch → the value is returned as given")
	print("")


static func _test_declared_type(testing) -> void:
	testing.begin("DeclaredTypeFitter.declared_type reads the type a property list declares")
	var resource: Resource = PlaceholderLikeResource.new()
	testing.eq(DeclaredTypeFitter.declared_type(resource, "icon"), TYPE_OBJECT,
			"a Texture2D property → TYPE_OBJECT")
	testing.eq(DeclaredTypeFitter.declared_type(resource, "missing"), TYPE_NIL,
			"a name the list does not hold → TYPE_NIL")

	var grouped: Resource = PlaceholderLikeGroupedResource.new()
	testing.eq(DeclaredTypeFitter.declared_type(grouped, "price"), TYPE_INT,
			"an int property with a same-name category header after it → TYPE_INT")
	testing.eq(DeclaredTypeFitter.declared_type(grouped, "Stats"), TYPE_NIL,
			"a name only a group header holds → TYPE_NIL")
	print("")


static func _new_holder(testing) -> RefCounted:
	var script := GDScript.new()
	script.source_code = _HOLDER_SOURCE
	testing.eq(script.reload(), OK, "holder script compiles")
	var holder: RefCounted = script.new()
	return holder


static func _new_placeholder_exports(testing) -> RefCounted:
	var script := GDScript.new()
	script.source_code = _PLACEHOLDER_EXPORTS_SOURCE
	testing.eq(script.reload(), OK, "placeholder exports script compiles")
	var exports: RefCounted = script.new()
	return exports


static func _expect_typed(testing, value: Variant, element_type: int, label: String) -> void:
	testing.ok(value is Array and (value as Array).is_typed()
			and (value as Array).get_typed_builtin() == element_type,
		"%s → a typed array of %s" % [label, type_string(element_type)])

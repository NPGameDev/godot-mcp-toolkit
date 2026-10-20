@tool
extends RefCounted
## Shared Variant coercion helper and its serialisation inverse.
##
## _coerce_value: JSON dict → Godot typed value (for property writes, method args).
## _serialize_value: Godot typed value → JSON-safe dict (for property reads, responses).
## _check_resource_paths: pre-coercion gate that validates Resource refs resolve.
##
## Both directions share a symmetric tag vocabulary — keep aligned or round-trip breaks.

# Direct preload (not via _hub) to avoid circular dependency — _hub preloads us.
const _FileGuard := preload("res://addons/godot_mcp_toolkit/security/file_guard.gd")


static func coerce_value(value: Variant) -> Variant:
	if typeof(value) == TYPE_ARRAY:
		var result: Array = []
		for element in value:
			result.append(coerce_value(element))
		return result
	if typeof(value) != TYPE_DICTIONARY:
		return value
	match str(value.get("type", "")):
		"Resource", "ResourceRef":
			var resource_path := str(value.get("path", ""))
			if resource_path.is_empty():
				# Fall through: {"type":"Resource","resource_type":"X"} → inline NewResource
				var res_class := str(value.get("resource_type", value.get("class", "")))
				if not res_class.is_empty():
					return coerce_value({"type": "NewResource", "class": res_class,
						"properties": value.get("properties", {})})
				return null
			var guard := _FileGuard.resolve_safe(resource_path)
			if guard["error"] != null:
				return null
			return ResourceLoader.load(resource_path, "", ResourceLoader.CACHE_MODE_REPLACE)
		"NewResource":
			var res_class := str(value.get("class", ""))
			if res_class.is_empty() or not ClassDB.class_exists(res_class):
				return null
			if not ClassDB.is_parent_class(res_class, "Resource"):
				return null
			if not ClassDB.can_instantiate(res_class):
				return null
			var resource = ClassDB.instantiate(res_class)
			if resource == null:
				return null
			var props: Dictionary = _safe_dict(value.get("properties", {}))
			for key in props.keys():
				resource.set(str(key), coerce_value(props[key]))
			return resource
		"Vector2":
			return Vector2(
				float(value.get("x", 0.0)),
				float(value.get("y", 0.0)),
			)
		"Vector3":
			return Vector3(
				float(value.get("x", 0.0)),
				float(value.get("y", 0.0)),
				float(value.get("z", 0.0)),
			)
		"Vector4":
			return Vector4(
				float(value.get("x", 0.0)),
				float(value.get("y", 0.0)),
				float(value.get("z", 0.0)),
				float(value.get("w", 0.0)),
			)
		"Vector2i":
			return Vector2i(int(value.get("x", 0)), int(value.get("y", 0)))
		"Vector3i":
			return Vector3i(
				int(value.get("x", 0)),
				int(value.get("y", 0)),
				int(value.get("z", 0)),
			)
		"Color":
			return Color(
				float(value.get("r", 0.0)),
				float(value.get("g", 0.0)),
				float(value.get("b", 0.0)),
				float(value.get("a", 1.0)),
			)
		"Rect2":
			return Rect2(
				float(value.get("x", 0.0)),
				float(value.get("y", 0.0)),
				float(value.get("w", 0.0)),
				float(value.get("h", 0.0)),
			)
		"Rect2i":
			return Rect2i(
				int(value.get("x", 0)),
				int(value.get("y", 0)),
				int(value.get("w", 0)),
				int(value.get("h", 0)),
			)
		"Transform2D":
			var x_axis: Dictionary = _safe_dict(value.get("x_axis", {}))
			var y_axis: Dictionary = _safe_dict(value.get("y_axis", {}))
			var origin_2d: Dictionary = _safe_dict(value.get("origin", {}))
			return Transform2D(
				Vector2(float(x_axis.get("x", 1.0)), float(x_axis.get("y", 0.0))),
				Vector2(float(y_axis.get("x", 0.0)), float(y_axis.get("y", 1.0))),
				Vector2(float(origin_2d.get("x", 0.0)), float(origin_2d.get("y", 0.0))),
			)
		"Transform3D":
			var basis_dict: Dictionary = _safe_dict(value.get("basis", {}))
			var basis_x: Dictionary = _safe_dict(basis_dict.get("x", {}))
			var basis_y: Dictionary = _safe_dict(basis_dict.get("y", {}))
			var basis_z: Dictionary = _safe_dict(basis_dict.get("z", {}))
			var origin_3d: Dictionary = _safe_dict(value.get("origin", {}))
			var basis := Basis(
				Vector3(float(basis_x.get("x", 1.0)), float(basis_x.get("y", 0.0)), float(basis_x.get("z", 0.0))),
				Vector3(float(basis_y.get("x", 0.0)), float(basis_y.get("y", 1.0)), float(basis_y.get("z", 0.0))),
				Vector3(float(basis_z.get("x", 0.0)), float(basis_z.get("y", 0.0)), float(basis_z.get("z", 1.0))),
			)
			return Transform3D(
				basis,
				Vector3(
					float(origin_3d.get("x", 0.0)),
					float(origin_3d.get("y", 0.0)),
					float(origin_3d.get("z", 0.0)),
				),
			)
		"NodePath":
			return NodePath(str(value.get("path", "")))
		"PackedVector2Array":
			var arr := PackedVector2Array()
			var elements = value.get("values", [])
			if typeof(elements) == TYPE_ARRAY:
				for el in elements:
					var v = coerce_value(el)
					if v is Vector2:
						arr.append(v)
					elif typeof(v) == TYPE_DICTIONARY and not (v as Dictionary).has("_coerce_error"):
						arr.append(Vector2(float(v.get("x", 0.0)), float(v.get("y", 0.0))))
					else:
						return {"_coerce_error":
							"PackedVector2Array elements must be Vector2. Use: {type:'PackedVector2Array', values: [{type:'Vector2', x:0, y:0}, ...]}"}
			return arr
		"PackedVector3Array":
			var arr := PackedVector3Array()
			var elements = value.get("values", [])
			if typeof(elements) == TYPE_ARRAY:
				for el in elements:
					var v = coerce_value(el)
					if v is Vector3:
						arr.append(v)
					elif typeof(v) == TYPE_DICTIONARY and not (v as Dictionary).has("_coerce_error"):
						arr.append(Vector3(float(v.get("x", 0.0)), float(v.get("y", 0.0)), float(v.get("z", 0.0))))
					else:
						return {"_coerce_error":
							"PackedVector3Array elements must be Vector3. Use: {type:'PackedVector3Array', values: [{type:'Vector3', x:0, y:0, z:0}, ...]}"}
			return arr
		"PackedColorArray":
			var arr := PackedColorArray()
			var elements = value.get("values", [])
			if typeof(elements) == TYPE_ARRAY:
				for el in elements:
					var v = coerce_value(el)
					if v is Color:
						arr.append(v)
					elif typeof(v) == TYPE_DICTIONARY and not (v as Dictionary).has("_coerce_error"):
						arr.append(Color(float(v.get("r", 0.0)), float(v.get("g", 0.0)),
							float(v.get("b", 0.0)), float(v.get("a", 1.0))))
					else:
						return {"_coerce_error":
							"PackedColorArray elements must be Color. Use: {type:'PackedColorArray', values: [{type:'Color', r:1, g:0, b:0, a:1}, ...]}"}
			return arr
		"LayerMask":
			var lm_category := str(value.get("category", "2d_physics"))
			return layers_to_mask(value.get("layers", []), lm_category)
		_:
			# Reject unknown type tags instead of silently passing through.
			var type_tag := str(value.get("type", ""))
			if not type_tag.is_empty():
				return {"_coerce_error":
					"Unknown type tag '%s'. Supported: Vector2, Vector3, Vector4, Vector2i, Vector3i, Color, Rect2, Rect2i, Transform2D, Transform3D, NodePath, Resource, NewResource, PackedVector2Array, PackedVector3Array, PackedColorArray, LayerMask." % type_tag}
			# No type key — generic dict with recursive coercion.
			var result := {}
			for k in value.keys():
				result[k] = coerce_value(value[k])
			return result


## Convert a layer-number value to a bitmask integer.
## Accepts: int (returned as-is), or Array of layer numbers (int) or
## named layers (String) → bitmask.  Named layers are resolved via
## ProjectSettings (layer_names/{category}/layer_N).
static func layers_to_mask(value: Variant, category: String = "2d_physics") -> int:
	if typeof(value) == TYPE_ARRAY:
		var mask := 0
		for layer in value:
			if typeof(layer) == TYPE_STRING:
				var n := _resolve_layer_name(str(layer), category)
				if n >= 1:
					mask |= (1 << (n - 1))
			else:
				var n := int(layer)
				if n >= 1 and n <= 32:
					mask |= (1 << (n - 1))
		return mask
	return int(value)


## Resolve a named layer to its 1-based number by scanning ProjectSettings.
## Returns -1 if the name is not found.
static func _resolve_layer_name(layer_name: String, category: String) -> int:
	for n in range(1, 33):
		var key := "layer_names/%s/layer_%d" % [category, n]
		if ProjectSettings.has_setting(key):
			var stored: String = str(ProjectSettings.get_setting(key))
			if stored.to_lower() == layer_name.to_lower():
				return n
	return -1


## Project a {r,g,b,a} JSON dict onto a Color with opaque-white channel
## defaults (tint / modulate semantics).  A non-dict value yields [param default]
## (itself opaque white unless overridden); within a dict, each absent channel
## falls to 1.0 so a partial {r,g,b} stays fully opaque.  Distinct from the
## "Color" type tag above, whose channels default to opaque BLACK (paint
## semantics) — the two defaults must not be conflated.
static func color_from_dict(d: Variant, default: Color = Color(1, 1, 1, 1)) -> Color:
	if typeof(d) != TYPE_DICTIONARY:
		return default
	return Color(
		float(d.get("r", 1.0)), float(d.get("g", 1.0)),
		float(d.get("b", 1.0)), float(d.get("a", 1.0)))


static func serialize_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_NIL:
			return null
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_VECTOR2:
			return {"type": "Vector2", "x": value.x, "y": value.y}
		TYPE_VECTOR3:
			return {"type": "Vector3", "x": value.x, "y": value.y, "z": value.z}
		TYPE_VECTOR4:
			return {"type": "Vector4", "x": value.x, "y": value.y, "z": value.z, "w": value.w}
		TYPE_VECTOR2I:
			return {"type": "Vector2i", "x": value.x, "y": value.y}
		TYPE_VECTOR3I:
			return {"type": "Vector3i", "x": value.x, "y": value.y, "z": value.z}
		TYPE_COLOR:
			return {"type": "Color", "r": value.r, "g": value.g, "b": value.b, "a": value.a}
		TYPE_RECT2:
			return {
				"type": "Rect2",
				"x": value.position.x, "y": value.position.y,
				"w": value.size.x, "h": value.size.y,
			}
		TYPE_RECT2I:
			return {
				"type": "Rect2i",
				"x": value.position.x, "y": value.position.y,
				"w": value.size.x, "h": value.size.y,
			}
		TYPE_TRANSFORM2D:
			return {
				"type": "Transform2D",
				"x_axis": {"x": value.x.x, "y": value.x.y},
				"y_axis": {"x": value.y.x, "y": value.y.y},
				"origin": {"x": value.origin.x, "y": value.origin.y},
			}
		TYPE_TRANSFORM3D:
			return {
				"type": "Transform3D",
				"basis": {
					"x": {"x": value.basis.x.x, "y": value.basis.x.y, "z": value.basis.x.z},
					"y": {"x": value.basis.y.x, "y": value.basis.y.y, "z": value.basis.y.z},
					"z": {"x": value.basis.z.x, "y": value.basis.z.y, "z": value.basis.z.z},
				},
				"origin": {"x": value.origin.x, "y": value.origin.y, "z": value.origin.z},
			}
		TYPE_NODE_PATH:
			return {"type": "NodePath", "path": str(value)}
		TYPE_PACKED_VECTOR2_ARRAY:
			# Emit the tagged form coerce_value parses back: each element is
			# itself a tagged {type:"Vector2",x,y} dict (recurse so the round-trip
			# is exact). Iterating a typed PackedVector2Array yields Vector2 elements.
			var packed_v2: Array = []
			for element in value:
				packed_v2.append(serialize_value(element))
			return {"type": "PackedVector2Array", "values": packed_v2}
		TYPE_PACKED_VECTOR3_ARRAY:
			var packed_v3: Array = []
			for element in value:
				packed_v3.append(serialize_value(element))
			return {"type": "PackedVector3Array", "values": packed_v3}
		TYPE_PACKED_COLOR_ARRAY:
			var packed_col: Array = []
			for element in value:
				packed_col.append(serialize_value(element))
			return {"type": "PackedColorArray", "values": packed_col}
		TYPE_STRING_NAME:
			return str(value)
		TYPE_ARRAY:
			var serialized_array: Array = []
			for element in value:
				serialized_array.append(serialize_value(element))
			return serialized_array
		TYPE_DICTIONARY:
			var serialized_dictionary: Dictionary = {}
			for key in value.keys():
				serialized_dictionary[str(key)] = serialize_value(value[key])
			return serialized_dictionary
		TYPE_OBJECT:
			if value == null:
				return null
			if value is Node:
				return str((value as Node).get_path())
			if value is Resource:
				var resource := value as Resource
				return {
					"type": "Resource",
					"path": resource.resource_path,
					"class": resource.get_class(),
				}
			return "<unserialisable>"
		_:
			return var_to_str(value)


## Pre-coercion gate: recursively scan for {type:"Resource",path:...} entries
## and return the first path that fails FileGuard or ResourceLoader.load.
## Empty string means all Resource refs resolve.
static func check_resource_paths(value: Variant) -> String:
	if typeof(value) == TYPE_DICTIONARY:
		var vtype := str(value.get("type", ""))
		if vtype == "Resource" or vtype == "ResourceRef":
			var resource_path := str(value.get("path", ""))
			if resource_path.is_empty():
				# Fall through: Resource with no path + class/resource_type → NewResource
				var res_class := str(value.get("resource_type", value.get("class", "")))
				if not res_class.is_empty():
					return check_resource_paths({"type": "NewResource", "class": res_class,
						"properties": value.get("properties", {})})
				return "<empty path>"
			var guard := _FileGuard.resolve_safe(resource_path)
			if guard["error"] != null:
				return resource_path
			if ResourceLoader.load(resource_path) == null:
				return resource_path
		elif vtype == "NewResource":
			var res_class := str(value.get("class", ""))
			if res_class.is_empty() or not ClassDB.class_exists(res_class):
				return "<invalid class: %s>" % res_class
			if not ClassDB.is_parent_class(res_class, "Resource"):
				return "<not a Resource: %s>" % res_class
			# Recurse into properties to check nested Resource refs
			var props: Dictionary = value.get("properties", {}) if typeof(value.get("properties", null)) == TYPE_DICTIONARY else {}
			for key in props.keys():
				var nested := check_resource_paths(props[key])
				if nested != "":
					return nested
		else:
			# Recurse into untyped dict values for nested sub-resources
			for key in value.keys():
				var nested := check_resource_paths(value[key])
				if nested != "":
					return nested
		return ""
	if typeof(value) == TYPE_ARRAY:
		for element in value:
			var missing := check_resource_paths(element)
			if missing != "":
				return missing
	return ""


## Coerce a JSON value using the existing property value as a type hint.
## When the JSON dict lacks a "type" key, injects the correct type tag
## inferred from the current Variant type so coerce_value() handles it.
## Falls back to plain coerce_value() when no inference is possible.
static func coerce_value_hint(raw: Variant, existing: Variant) -> Variant:
	if typeof(raw) != TYPE_DICTIONARY or (raw as Dictionary).has("type"):
		return coerce_value(raw)
	var tag := ""
	match typeof(existing):
		TYPE_VECTOR2:   tag = "Vector2"
		TYPE_VECTOR3:   tag = "Vector3"
		TYPE_VECTOR4:   tag = "Vector4"
		TYPE_VECTOR2I:  tag = "Vector2i"
		TYPE_VECTOR3I:  tag = "Vector3i"
		TYPE_COLOR:     tag = "Color"
		TYPE_RECT2:     tag = "Rect2"
		TYPE_RECT2I:    tag = "Rect2i"
	if tag.is_empty():
		return coerce_value(raw)
	var tagged := (raw as Dictionary).duplicate()
	tagged["type"] = tag
	return coerce_value(tagged)


static func _safe_dict(value: Variant) -> Dictionary:
	return value if typeof(value) == TYPE_DICTIONARY else {}

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
const _FileGuard := preload("res://addons/godot_mcp_toolkit/file_guard.gd")


static func coerce_value(value: Variant) -> Variant:
	if typeof(value) == TYPE_ARRAY:
		var result: Array = []
		for element in value:
			result.append(coerce_value(element))
		return result
	if typeof(value) != TYPE_DICTIONARY:
		return value
	match str(value.get("type", "")):
		"Resource":
			var resource_path := str(value.get("path", ""))
			if resource_path.is_empty():
				return null
			var guard := _FileGuard.resolve_safe(resource_path)
			if guard["error"] != null:
				return null
			return ResourceLoader.load(resource_path)
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
		_:
			return value


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
		if vtype == "Resource":
			var resource_path := str(value.get("path", ""))
			if resource_path.is_empty():
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
		return ""
	if typeof(value) == TYPE_ARRAY:
		for element in value:
			var missing := check_resource_paths(element)
			if missing != "":
				return missing
	return ""


static func _safe_dict(value: Variant) -> Dictionary:
	return value if typeof(value) == TYPE_DICTIONARY else {}

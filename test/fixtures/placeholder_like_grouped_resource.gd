extends Resource
## Test double for a script resource whose script is not @tool and whose property
## list interleaves inspector headers with its properties, as the editor holds it.
##
## Like placeholder_like_resource.gd, it declares its properties in
## _get_property_list() and stores raw values to stand in for the editor's
## placeholder instance. Its list has an int [code]price[/code] followed by a
## category header of the same name, the layout of the engine's own
## export_group_no_name_conflict_with_properties.gd test, and a [code]Stats[/code]
## group header that names no property. A placeholder's set() stores nothing for a
## header's name, so _set() refuses it.

var _values := {}


func _get_property_list() -> Array[Dictionary]:
	return [
		{"name": "Stats", "type": TYPE_NIL, "usage": PROPERTY_USAGE_GROUP},
		{"name": "price", "type": TYPE_INT, "usage": PROPERTY_USAGE_DEFAULT},
		{"name": "price", "type": TYPE_NIL, "usage": PROPERTY_USAGE_CATEGORY},
	]


func _set(property: StringName, value: Variant) -> bool:
	if property == &"price":
		_values[property] = value
		return true
	return false


func _get(property: StringName) -> Variant:
	return _values.get(property)

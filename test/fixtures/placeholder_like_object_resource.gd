extends Resource
## Test double for a script resource with a Texture2D property whose script is not
## @tool, as the editor holds it.
##
## Like placeholder_like_resource.gd, it declares its property in
## _get_property_list() and stores raw values to stand in for the editor's
## placeholder instance, which stores a String given for a Texture2D property as
## given.

var _values := {}


func _get_property_list() -> Array[Dictionary]:
	return [
		{
			"name": "icon",
			"type": TYPE_OBJECT,
			"hint": PROPERTY_HINT_RESOURCE_TYPE,
			"hint_string": "Texture2D",
			"usage": PROPERTY_USAGE_DEFAULT,
		},
	]


func _set(property: StringName, value: Variant) -> bool:
	if property == &"icon":
		_values[property] = value
		return true
	return false


func _get(property: StringName) -> Variant:
	return _values.get(property)

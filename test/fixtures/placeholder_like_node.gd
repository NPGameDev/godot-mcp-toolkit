extends Node
## Test double for a node whose script is not @tool, as the editor holds it.
##
## The editor gives such a script a placeholder instance, whose set() stores each
## value as given instead of converting it to the property's declared type. The
## headless unit runner gives scripts a live instance, which converts, so this
## script declares its [code]hp[/code] and [code]icon[/code] properties in
## _get_property_list() and stores raw values to stand in for the placeholder. A
## placeholder reads an unset property as the script's default, so [code]hp[/code]
## starts at 0 and [code]icon[/code], a Texture2D, at null. It lives in a file, not
## as an inner class, so a duplicated or instanced node gets the same script.

var _values := {&"hp": 0}


func _get_property_list() -> Array[Dictionary]:
	return [
		{"name": "hp", "type": TYPE_INT, "usage": PROPERTY_USAGE_DEFAULT},
		{"name": "icon", "type": TYPE_OBJECT, "hint": PROPERTY_HINT_RESOURCE_TYPE,
			"hint_string": "Texture2D", "usage": PROPERTY_USAGE_DEFAULT},
	]


func _set(property: StringName, value: Variant) -> bool:
	if property == &"hp" or property == &"icon":
		_values[property] = value
		return true
	return false


func _get(property: StringName) -> Variant:
	return _values.get(property)

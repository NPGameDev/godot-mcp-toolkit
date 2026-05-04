@tool
class_name MCPToolkitSceneStats
extends MCPToolkitExtension
## Example extension: scene statistics (GDScript).
##
## Registers two commands under a shared group:
## - scenestats.summary  — node count, script count, class breakdown
## - scenestats.find_by_class — list node paths matching a given class


func register(registry, server: Node) -> void:
	var group_meta := {
		"name": "scenestats",
		"description": "Scene statistics and class search",
	}

	registry.add("scenestats.summary", _cmd_summary, {
		"description": "Return node count, script count, and class breakdown for the open scene",
		"annotations": {"readOnlyHint": true, "idempotentHint": true},
		"group": group_meta,
	})

	registry.add("scenestats.find_by_class", _cmd_find_by_class, {
		"description": "Find all nodes matching a given class name in the open scene",
		"input_schema": {
			"type": "object",
			"properties": {
				"class_name": {
					"type": "string",
					"description": "Engine class name to search for (e.g., Sprite2D, CharacterBody3D)",
				}
			},
			"required": ["class_name"],
		},
		"annotations": {"readOnlyHint": true, "idempotentHint": true},
		"group": group_meta,
	})


func _cmd_summary(_params: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"success": false, "error": "No scene open", "code": "NOT_FOUND"}
	var stats := {"node_count": 0, "script_count": 0, "classes": {}}
	_walk(root, stats)
	return {"success": true, "data": stats}


func _cmd_find_by_class(params: Dictionary) -> Dictionary:
	var target: String = params.get("class_name", "")
	if target.is_empty():
		return {"success": false, "error": "class_name is required", "code": "INVALID_PARAM"}
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"success": false, "error": "No scene open", "code": "NOT_FOUND"}
	var matches: Array[String] = []
	_find(root, target, matches)
	return {"success": true, "data": {"class_name": target, "matches": matches, "count": matches.size()}}


func _walk(node: Node, stats: Dictionary) -> void:
	stats["node_count"] += 1
	var cls: String = node.get_class()
	if not stats["classes"].has(cls):
		stats["classes"][cls] = 0
	stats["classes"][cls] += 1
	if node.get_script() != null:
		stats["script_count"] += 1
	for child in node.get_children():
		_walk(child, stats)


func _find(node: Node, target: String, matches: Array[String]) -> void:
	if node.get_class() == target or node.is_class(target):
		matches.append(str(node.get_path()))
	for child in node.get_children():
		_find(child, target, matches)

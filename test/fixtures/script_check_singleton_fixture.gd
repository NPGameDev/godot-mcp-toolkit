class_name MCPToolkitProbeSingleton
extends Node
## script_check fixture: a singleton that keeps self in a static var typed as
## its own class, with a factory that uses the class name as a value. The
## unit tests also check edited copies of it under this path.


static var instance: MCPToolkitProbeSingleton


static func create() -> MCPToolkitProbeSingleton:
	return MCPToolkitProbeSingleton.new()


func _enter_tree() -> void:
	instance = self

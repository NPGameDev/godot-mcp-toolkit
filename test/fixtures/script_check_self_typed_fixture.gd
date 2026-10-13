class_name MCPToolkitProbeSelfTyped
extends Node
## script_check fixture: self used as the script's own class, in a return, a
## typed local, a cast and a typed argument. The unit tests also check edited
## copies of it under this path.


func with_speed(_speed: float) -> MCPToolkitProbeSelfTyped:
	return self


func typed_local() -> Node:
	var me: MCPToolkitProbeSelfTyped = self
	return me


func cast_self() -> Object:
	return self as MCPToolkitProbeSelfTyped


func register_self() -> void:
	take(self)


func take(_other: MCPToolkitProbeSelfTyped) -> void:
	pass

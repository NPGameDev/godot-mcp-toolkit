class_name MCPToolkitSelfTypedFixture
extends RefCounted
## script_check fixture (test/units/paths_versioning_tests.gd): passes `self` to a
## parameter typed as its own class_name.


func take(_other: MCPToolkitSelfTypedFixture) -> void:
	pass


func pass_self() -> void:
	take(self)

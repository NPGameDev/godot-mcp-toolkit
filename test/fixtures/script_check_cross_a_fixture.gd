class_name MCPToolkitProbeCrossA
extends RefCounted
## script_check fixture: passes self to another script's parameter typed with
## this script's class_name. The parameter's script is
## script_check_cross_b_fixture.gd.


func register_with_partner() -> void:
	MCPToolkitProbeCrossB.new().take(self)

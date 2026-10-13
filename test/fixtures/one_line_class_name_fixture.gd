class_name MCPToolkitOneLineFixture extends Node
## script_check fixture: the one-line class_name form, with a body that compiles
## only on a Node base.


func attach_child() -> void:
	add_child(Node.new())

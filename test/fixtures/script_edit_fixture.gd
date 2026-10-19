extends Node


func old_name() -> int:
	return 1


func caller() -> int:
	return old_name()

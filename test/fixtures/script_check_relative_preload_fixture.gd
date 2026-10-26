extends RefCounted
## script_check fixture: preloads its sibling by a path relative to this folder.

const Sibling := preload("compile_probe_sibling.gd")


func answer() -> int:
	return Sibling.ANSWER

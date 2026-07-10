@tool
extends Node
## Tool-sweep environment probe (committed fixture).
##
## Its @tool method is called via node_call_method during the Version Preflight to
## read the AUTHORITATIVE running engine version: Engine.get_version_info() reached
## through real callv() dispatch, which the sandboxed execute_code / Expression path
## cannot do (Expression resolves no engine singletons). Committed so the sweep opens
## the scene and calls the method with zero per-run setup.
## See Validations/tool-sweep.md -> Version Preflight.


## The running editor binary's own version, straight from the engine:
## {major, minor, patch, hex, status, string, build, hash, year}.
func get_engine_version() -> Dictionary:
	return Engine.get_version_info()

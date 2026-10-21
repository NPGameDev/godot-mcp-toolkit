@tool
extends RefCounted
## The identity every toolkit HTTP request sends.
##
## One fixed User-Agent replaces the engine's default, which names the Godot
## version and the OS. It carries no version, no Godot version and no OS, so a
## request says nothing about the machine or the project.

## The User-Agent value.
const USER_AGENT := "godot-mcp-toolkit"


## Returns the headers a toolkit request passes to [method HTTPRequest.request]:
## the User-Agent alone.
static func request_headers() -> PackedStringArray:
	return PackedStringArray(["User-Agent: " + USER_AGENT])

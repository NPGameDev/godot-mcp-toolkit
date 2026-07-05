@tool
class_name MCPToolkitSuccess
extends RefCounted
## Success-response builder — symmetric with [method MCPToolkitError.fail].
##
## [method ok] stamps every success response with [code]"success": true[/code], so
## a handler cannot accidentally omit the key the dispatch contract requires.
## Use it for every successful return, just as [MCPToolkitError] is
## used for every failure.


## Stamps [param data] with [code]"success": true[/code] and returns it as the
## success response. [param data] carries the handler's result payload (default an
## empty dict). The returned dictionary is [param data] itself, mutated in place.
## [codeblock]
## return MCPToolkitSuccess.ok({"value": 42})
## # => {"value": 42, "success": true}
## [/codeblock]
static func ok(data: Dictionary = {}) -> Dictionary:
	data["success"] = true
	return data

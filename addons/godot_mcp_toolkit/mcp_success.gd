@tool
class_name MCPToolkitSuccess
extends RefCounted
## Success-response builder — symmetric with MCPToolkitError.fail().
##
## Guarantees every success response includes "success": true so handlers
## cannot accidentally omit the key required by ADR 0004.


## Build a success response Dictionary.
## [codeblock]
## return MCPToolkitSuccess.ok({"value": 42})
## # => {"value": 42, "success": true}
## [/codeblock]
static func ok(data: Dictionary = {}) -> Dictionary:
	data["success"] = true
	return data

@tool
extends RefCounted
## Node.js availability check used by the onboarding wizard and dock
## warnings. Centralised so both UI surfaces share a single detection path.


## Check if Node.js is installed and meets the minimum version (20+).
## Returns { "found": bool, "version": String, "meets_minimum": bool }.
static func check(min_major: int = 20) -> Dictionary:
	var output := []
	var exit_code := OS.execute("node", ["--version"], output, true)
	if exit_code != 0 or output.is_empty():
		return {"found": false, "version": "", "meets_minimum": false}
	var raw: String = output[0].strip_edges()
	if not raw.begins_with("v"):
		return {"found": true, "version": raw, "meets_minimum": false}
	var parts := raw.substr(1).split(".")
	if parts.is_empty():
		return {"found": true, "version": raw, "meets_minimum": false}
	var major := parts[0].to_int()
	return {"found": true, "version": raw, "meets_minimum": major >= min_major}

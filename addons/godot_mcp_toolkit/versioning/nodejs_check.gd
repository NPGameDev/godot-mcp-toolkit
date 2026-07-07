@tool
extends RefCounted
## Detects whether Node.js is installed and meets the minimum version.
## Centralises detection so every UI surface uses the same path and
## macOS/Linux login-shell fallback (for version managers like nvm).


## Check if Node.js is installed and meets the minimum version (22+).
## Returns { "found": bool, "version": String, "meets_minimum": bool }.
## On macOS/Linux, if the direct "node" command fails, falls back to a login
## shell check — GUI apps (e.g. Godot opened from Finder) don't inherit the
## shell PATH where version managers (nvm, fnm, volta) install Node.
## The MCP client runs from a terminal and will find Node regardless, so a
## login-shell hit is treated as "found" with no warning needed.
static func check(min_major: int = 22) -> Dictionary:
	var result := _try_direct(min_major)
	if result["found"]:
		return result
	var os_name := OS.get_name()
	if os_name == "macOS" or os_name == "Linux":
		return _try_login_shell(min_major)
	return result


static func _try_direct(min_major: int) -> Dictionary:
	var output := []
	var exit_code := OS.execute("node", ["--version"], output, true)
	if exit_code != 0 or output.is_empty():
		return {"found": false, "version": "", "meets_minimum": false}
	return _parse_version(output[0], min_major)


static func _try_login_shell(min_major: int) -> Dictionary:
	var output := []
	var exit_code := OS.execute(_login_shell(), ["-l", "-c", "node --version"], output, true)
	if exit_code != 0 or output.is_empty():
		return {"found": false, "version": "", "meets_minimum": false}
	return _parse_version(output[0], min_major)


# The user's login shell from $SHELL (default /bin/bash when unset) — the seam that
# lets a version-manager Node resolve, used by the version probe.
static func _login_shell() -> String:
	var shell: String = OS.get_environment("SHELL")
	return shell if not shell.is_empty() else "/bin/bash"


static func _parse_version(raw_output: String, min_major: int) -> Dictionary:
	var raw: String = raw_output.strip_edges()
	if not raw.begins_with("v"):
		return {"found": true, "version": raw, "meets_minimum": false}
	var parts := raw.substr(1).split(".")
	if parts.is_empty():
		return {"found": true, "version": raw, "meets_minimum": false}
	var major := parts[0].to_int()
	return {"found": true, "version": raw, "meets_minimum": major >= min_major}

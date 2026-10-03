@tool
extends RefCounted
## Detects whether Node.js is installed and meets the minimum version.
## Centralises detection so every UI surface uses the same path and
## macOS/Linux login-shell fallback (for version managers like nvm).


## Check if Node.js is installed and meets the minimum version (22+).
## Returns { "found": bool, "version": String, "meets_minimum": bool }.
##
## On Windows, the probe first looks for node.exe along PATH and spawns only a file
## it found: starting a program that is not there makes the engine print an error
## that GDScript cannot suppress.
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
	var program := "node"
	if OS.get_name() == "Windows":
		# Look before spawning (see check()). Spawning the resolved absolute path
		# also stops Windows running a node.exe from the working directory, which it
		# searches ahead of PATH when the engine passes a bare "node".
		program = _find_node_on_windows_path()
		if program.is_empty():
			return _not_found()
	var output := []
	var exit_code := OS.execute(program, ["--version"], output, true)
	if exit_code != 0 or output.is_empty():
		return _not_found()
	return _parse_version(output[0], min_major)


# The first node.exe held by an absolute PATH entry, or "" when there is none.
static func _find_node_on_windows_path() -> String:
	# DirAccess.file_exists rather than FileAccess.file_exists: on Godot 4.2 the latter
	# opens the file, and the editor warns when the requested name differs in case from
	# the one on disk. The instance method needs a directory to open on; the editor's own
	# folder always exists.
	var files := DirAccess.open(OS.get_executable_path().get_base_dir())
	if files == null:
		return ""
	return resolve_on_path(OS.get_environment("PATH"), "node.exe", files.file_exists)


## Returns the absolute path of the first [param executable_name] that
## [param file_exists] confirms along [param path_variable], or "" when no entry
## holds it.
##
## [param path_variable] is a Windows PATH value: entries separated by ";", each
## optionally quoted or ending in a separator. Only entries that name a fixed location
## (drive-qualified like "C:\bin", or network like "\\host\share") are tried; a
## relative entry such as "." would resolve against the working directory, so it is
## skipped.
##
## [param file_exists] receives each candidate and returns whether a file is there.
## Keeping the filesystem behind it lets the walk run without a real PATH. Candidates,
## and the returned path, are absolute and use forward slashes.
static func resolve_on_path(
		path_variable: String, executable_name: String, file_exists: Callable) -> String:
	for entry: String in path_variable.split(";", false):
		var directory := _fixed_directory(entry)
		if directory.is_empty():
			continue
		var candidate := directory + "/" + executable_name
		if file_exists.call(candidate):
			return candidate
	return ""


# One PATH entry as a directory with forward slashes, no quotes and no trailing
# separator; "" when the entry does not name a fixed location.
static func _fixed_directory(entry: String) -> String:
	var normalized := entry.trim_prefix("\"").trim_suffix("\"").replace("\\", "/")
	if not _is_fixed_location(normalized):
		return ""
	return normalized.rstrip("/")


# True for "C:/dir" and "//host/share", which mean the same place whatever the working
# directory is. "C:dir", "/dir" and "dir" all depend on it.
static func _is_fixed_location(path: String) -> bool:
	if path.length() >= 3 and path[1] == ":" and path[2] == "/":
		var drive := path[0]
		return (drive >= "A" and drive <= "Z") or (drive >= "a" and drive <= "z")
	return path.length() > 2 and path.begins_with("//") and path[2] != "/"


static func _try_login_shell(min_major: int) -> Dictionary:
	var output := []
	var exit_code := OS.execute(_login_shell(), ["-l", "-c", "node --version"], output, true)
	if exit_code != 0 or output.is_empty():
		return _not_found()
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


static func _not_found() -> Dictionary:
	return {"found": false, "version": "", "meets_minimum": false}

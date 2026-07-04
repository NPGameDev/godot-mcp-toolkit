@tool
extends RefCounted
## Detects whether Node.js is installed and meets the minimum version.
## Centralises detection so every UI surface uses the same path and
## macOS/Linux login-shell fallback (for version managers like nvm).


## Check if Node.js is installed and meets the minimum version (20+).
## Returns { "found": bool, "version": String, "meets_minimum": bool }.
## On macOS/Linux, if the direct "node" command fails, falls back to a login
## shell check — GUI apps (e.g. Godot opened from Finder) don't inherit the
## shell PATH where version managers (nvm, fnm, volta) install Node.
## The MCP client runs from a terminal and will find Node regardless, so a
## login-shell hit is treated as "found" with no warning needed.
static func check(min_major: int = 20) -> Dictionary:
	var result := _try_direct(min_major)
	if result["found"]:
		return result
	var os_name := OS.get_name()
	if os_name == "macOS" or os_name == "Linux":
		return _try_login_shell(min_major)
	return result


## Resolve the user's real absolute node path and the login-shell PATH on macOS.
##
## GUI-launched MCP clients on macOS run under launchd with a minimal PATH and
## never source the user's shell rc files, so a version-manager Node
## (nvm/fnm/volta/Apple-Silicon Homebrew) is invisible to them ([code]spawn
## ENOENT[/code]). Reusing the same login-shell probe [method check] uses, this
## resolves the absolute [code]node[/code] binary plus the resolved PATH so the
## editor can emit a launchd-proof .mcp.json (absolute command + PATH backstop).
## The probe fences each value behind a unique prefix so a noisy login shell
## (p10k / nvm banners printed while rc files are sourced) can't corrupt parsing.
##
## Returns [code]{ "node": String, "path": String }[/code] — both absolute; both
## [code]""[/code] when resolution fails (node absent, or the manager only exports
## it from an interactive rc file a login shell skips) or the platform is not
## macOS. A caller derives the sibling [code]npx[/code] from [code]node[/code]'s
## directory and falls back to a bare [code]npx[/code] command when this yields "".
static func resolve_launch_paths() -> Dictionary:
	var empty := {"node": "", "path": ""}
	# Only macOS has the launchd-minimal-PATH problem; every other platform lets
	# the client find node/npx directly, so resolution is unnecessary there.
	if OS.get_name() != "macOS":
		return empty
	# printf with unique prefixes: we read only the fenced lines and ignore any
	# banner a login shell prints while sourcing rc files. Read stdout only (no
	# stderr) so rc-file stderr chatter cannot interleave into the parsed values.
	var probe := "printf 'MCPNODEPATH=%s\\n' \"$PATH\"; printf 'MCPNODEBIN=%s\\n' \"$(command -v node)\""
	var output := []
	var exit_code := OS.execute(_login_shell(), ["-l", "-c", probe], output, false)
	if exit_code != 0 or output.is_empty():
		return empty
	var node_path := ""
	var resolved_path := ""
	for raw_line in str(output[0]).split("\n"):
		var line: String = raw_line.strip_edges()
		if line.begins_with("MCPNODEBIN="):
			node_path = line.substr("MCPNODEBIN=".length())
		elif line.begins_with("MCPNODEPATH="):
			resolved_path = line.substr("MCPNODEPATH=".length())
	# No node ⇒ report nothing so the caller emits the bare-npx fallback (recovered
	# by the dock nudge + docs), rather than a half-resolved command.
	if node_path.is_empty():
		return empty
	return {"node": node_path, "path": resolved_path}


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
# lets a version-manager Node resolve, shared by the version and path probes.
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

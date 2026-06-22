@tool
extends RefCounted
## Canonical project-root identity for the multi-instance registry.
##
## The normalized path is the `_key` the TypeScript bridge reads from
## projects.json; the 12-char hash names the per-instance entry file
## (entries/<hash>.json) AND — via ProjectPaths — the per-instance user:// dir.
## ONE canonicalization recipe, two consumers: any change to the recipe shifts
## both the bridge-read key and the on-disk filenames, so it is frozen contract.
##
## All methods are static — identity by value, no instance state, no lifecycle.


## Canonicalize a project-root path: backslash → slash, strip trailing slash,
## and lowercase on case-insensitive filesystems. Windows and macOS default
## filesystems are case-insensitive; lowercasing avoids mismatches between
## Godot's globalize_path and Node.js process.cwd() when the TS bridge reads
## the same registry file.
static func canonical(path: String) -> String:
	var result := path.replace("\\", "/").rstrip("/")
	if OS.get_name() in ["Windows", "macOS"]:
		result = result.to_lower()
	return result


## The canonical key for the current project root (the bridge-read `_key`).
static func current() -> String:
	return canonical(ProjectSettings.globalize_path("res://"))


## 12-char hex hash of an ALREADY-canonical key. The argument is hashed
## verbatim — it is NOT re-canonicalized, so callers must pass a key from
## canonical() / current(); a raw path would hash to a wrong, non-matching value.
static func hash_of(canonical_key: String) -> String:
	return canonical_key.sha256_text().substr(0, 12)


## 12-char hex hash of the current project root — the entry-file / instance-dir
## filename token. The only blessed "from scratch" path: current_hash() ==
## hash_of(current()) by construction.
static func current_hash() -> String:
	return hash_of(current())

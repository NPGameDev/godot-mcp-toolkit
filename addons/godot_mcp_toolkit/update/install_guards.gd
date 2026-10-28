@tool
extends RefCounted
## The cases where the toolkit never installs an update by itself, whatever the
## install mode says.
##
## [method facts] looks at the project and the editor; [method refusal] judges those
## facts and stays pure, so each rule is tested with literal facts.

# Direct preload, not core/modules.gd: the aggregator preloads this file.
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")

## The contributor-only environment variable that lets a headless editor install,
## for the integration tests. Set to [code]1[/code].
const HEADLESS_OVERRIDE_ENV := "GODOT_MCP_UPDATE_ALLOW_HEADLESS"

## [method refusal] results.
const TOOLKIT_REPOSITORY := "toolkit_repository"
const LINKED_FOLDER := "linked_folder"
const VERSION_CONTROL_FOLDER := "version_control_folder"
const HEADLESS := "headless"

const _ADDONS_PATH := "res://addons"
const _ADDON_NAME := "godot_mcp_toolkit"
# Files only the toolkit's own repository holds: installing there would overwrite
# the source with a release.
const _REPOSITORY_MARKERS := [
	"res://scripts/build-plugin-release.sh",
	"res://test/run_unit_tests.gd",
]


## What the rules look at, read from this project and editor: [code]toolkit_repository[/code],
## [code]linked_folder[/code], [code]version_control_folder[/code], [code]headless[/code]
## and [code]headless_allowed[/code], all booleans. [method DirAccess.is_link] is
## Godot 4.3+, so on 4.2 a linked folder is not detected.
static func facts() -> Dictionary:
	var addons := DirAccess.open(_ADDONS_PATH)
	var addon_path := _ADDONS_PATH.path_join(_ADDON_NAME)
	var git_path := addon_path.path_join(".git")
	var in_repository := false
	for marker in _REPOSITORY_MARKERS:
		in_repository = in_repository or FileAccess.file_exists(marker)
	var linked := false
	if addons != null and addons.has_method("is_link"):
		linked = bool(addons.call("is_link", _ADDON_NAME))
	return {
		TOOLKIT_REPOSITORY: in_repository,
		LINKED_FOLDER: linked,
		VERSION_CONTROL_FOLDER: FileAccess.file_exists(git_path) or DirAccess.dir_exists_absolute(git_path),
		HEADLESS: VersionUtils.is_headless(),
		"headless_allowed": OS.get_environment(HEADLESS_OVERRIDE_ENV) == "1",
	}


## The first rule [param facts] break, or an empty string when the toolkit may
## install. [param facts] has the shape [method facts] returns; a missing key counts
## as false.
static func refusal(facts: Dictionary) -> String:
	if bool(facts.get(TOOLKIT_REPOSITORY, false)):
		return TOOLKIT_REPOSITORY
	if bool(facts.get(LINKED_FOLDER, false)):
		return LINKED_FOLDER
	if bool(facts.get(VERSION_CONTROL_FOLDER, false)):
		return VERSION_CONTROL_FOLDER
	if bool(facts.get(HEADLESS, false)) and not bool(facts.get("headless_allowed", false)):
		return HEADLESS
	return ""


## The sentence that explains the refusal [param reason] to the user.
static func describe(reason: String) -> String:
	match reason:
		TOOLKIT_REPOSITORY:
			return "This project is the toolkit's own repository; a release would overwrite its source."
		LINKED_FOLDER:
			return "The toolkit's folder is a link to another place."
		VERSION_CONTROL_FOLDER:
			return "The toolkit's folder is a git checkout or submodule; update it with git."
		HEADLESS:
			return "A headless editor never installs updates."
	return ""

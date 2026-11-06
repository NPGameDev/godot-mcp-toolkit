@tool
extends RefCounted
## The cases where the toolkit never installs an update by itself, whatever the
## install mode says.
##
## [method facts] looks at the project and the editor; [method refusal] judges those
## facts and stays pure, so each rule is tested with literal facts.

# Direct preloads, not core/modules.gd: the aggregator preloads the installer,
# which reaches this file.
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")

## The test-only environment variable that lets a headless editor install, for the
## integration tests. Set to [code]1[/code]; nothing outside a test should set it.
const HEADLESS_OVERRIDE_ENV := "GODOT_MCP_UPDATE_ALLOW_HEADLESS"

## [method refusal] results.
const TOOLKIT_REPOSITORY := "toolkit_repository"
const LINKED_FOLDER := "linked_folder"
const VERSION_CONTROL_FOLDER := "version_control_folder"
const HEADLESS := "headless"

## The installed addon folder.
const ADDON_FOLDER := "res://addons/godot_mcp_toolkit"

# Files only the toolkit's own repository holds: installing there would overwrite
# the source with a release.
const _REPOSITORY_MARKERS := [
	"res://scripts/build-plugin-release.sh",
	"res://test/run_unit_tests.gd",
]


## What the rules look at, read from this project and editor: [code]toolkit_repository[/code],
## [code]linked_folder[/code], [code]version_control_folder[/code], [code]headless[/code]
## and [code]headless_allowed[/code], all booleans. [code]linked_folder[/code] is
## [method FolderFiles.is_link], which counts anything but a clear "not a link" as one.[br]
## [br]
## [param addon_path] is the folder the link and git facts look at. Only tests pass it.
static func facts(addon_path: String = ADDON_FOLDER) -> Dictionary:
	var git_path := addon_path.path_join(".git")
	var in_repository := false
	for marker in _REPOSITORY_MARKERS:
		in_repository = in_repository or FileAccess.file_exists(marker)
	var read := headless_facts()
	read[TOOLKIT_REPOSITORY] = in_repository
	read[LINKED_FOLDER] = FolderFiles.is_link(ProjectSettings.globalize_path(addon_path))
	read[VERSION_CONTROL_FOLDER] = FileAccess.file_exists(git_path) or DirAccess.dir_exists_absolute(git_path)
	return read


## The two [method facts] the headless rule looks at, without the walk and the process the
## others can cost: [code]headless[/code] and [code]headless_allowed[/code].
static func headless_facts() -> Dictionary:
	return {
		HEADLESS: VersionUtils.is_headless(),
		"headless_allowed": OS.get_environment(HEADLESS_OVERRIDE_ENV) == "1",
	}


## The first rule [param guard_facts] break, or an empty string when the toolkit may
## install. [param guard_facts] has the shape [method facts] returns; a missing key counts
## as false.
static func refusal(guard_facts: Dictionary) -> String:
	if bool(guard_facts.get(TOOLKIT_REPOSITORY, false)):
		return TOOLKIT_REPOSITORY
	if bool(guard_facts.get(LINKED_FOLDER, false)):
		return LINKED_FOLDER
	if bool(guard_facts.get(VERSION_CONTROL_FOLDER, false)):
		return VERSION_CONTROL_FOLDER
	if headless_refused(guard_facts):
		return HEADLESS
	return ""


## Whether [param guard_facts] describe a headless editor without the test override.
static func headless_refused(guard_facts: Dictionary) -> bool:
	return bool(guard_facts.get(HEADLESS, false)) and not bool(guard_facts.get("headless_allowed", false))


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

@tool
extends RefCounted
## The project setting that says whether the toolkit installs its own updates.
##
## [constant MANUAL] only links to a new version. [constant ASK] asks before installing. No
## mode installs unasked, because an update must stay visible to whoever is working in the
## project. The value lives in project.godot because the files an update changes are
## committed: which version a project runs is the team's choice.

const SETTING := "mcp_toolkit/updates/install_mode"

const MANUAL := "manual"
const ASK := "ask"

const DEFAULT := ASK

## The values the setting accepts.
const VALUES := [MANUAL, ASK]


## The mode [param project_settings] holds: [ProjectSettings] or a stand-in with
## [code]has_setting[/code] and [code]get_setting[/code]. A missing key reads as
## [constant DEFAULT], and any value that is not one of [constant VALUES] as
## [constant MANUAL], so an unreadable choice never installs.
static func read(project_settings: Object) -> String:
	if project_settings == null or not project_settings.has_setting(SETTING):
		return DEFAULT
	var value := str(project_settings.get_setting(SETTING)).strip_edges().to_lower()
	return value if VALUES.has(value) else MANUAL


## Stores [param mode] in [param project_settings] and saves it when it changed.
## A mode outside [constant VALUES] is ignored.
## Returns the save's error, or [constant OK] when nothing changed.
static func save(project_settings: Object, mode: String) -> Error:
	if not VALUES.has(mode) or read(project_settings) == mode:
		return OK
	project_settings.set_setting(SETTING, mode)
	return project_settings.save()

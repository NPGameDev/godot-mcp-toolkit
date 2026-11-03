@tool
extends RefCounted
## The project setting that says whether the toolkit installs its own updates.
##
## [constant MANUAL] only links to a new version, as the update check always did.
## [constant ASK] asks before installing; [constant AUTOMATIC] installs when the
## editor closes without asking. The value lives in project.godot because the files
## an update changes are committed: which version a project runs is the team's
## choice. Until the setup step that explains it has been seen, every mode behaves
## as [constant MANUAL] (see [code]core/consent.gd[/code]).

const SETTING := "mcp_toolkit/updates/install_mode"

const MANUAL := "manual"
const ASK := "ask"
const AUTOMATIC := "automatic"

const DEFAULT := ASK

## The values in the order the inspector and the setup step list them.
const VALUES := [MANUAL, ASK, AUTOMATIC]


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
## Returns the save's error, or [constant OK] when nothing changed.
static func save(project_settings: Object, mode: String) -> Error:
	if not VALUES.has(mode) or read(project_settings) == mode:
		return OK
	project_settings.set_setting(SETTING, mode)
	return project_settings.save()

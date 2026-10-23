@tool
extends RefCounted
## The names each engine setting the toolkit writes has had across Godot versions,
## newest first, and the lookup that picks the one the running editor defines.
##
## A Godot rename keeps the old name answering only through a compatibility map that
## the editor builds when it loads saved settings, so an editor started without saved
## settings knows only the new name. That same map makes the old name answer
## [code]has_setting[/code] when it is built, so the names are tried newest first.
## The lookup asks the store and never compares versions. When Godot renames another
## of these settings, prepend its new name to the list and add a unit case for it.

## The editor's sleep between frames while it is unfocused, in microseconds.
const UNFOCUSED_SLEEP_USEC := [
	"interface/editor/timers/unfocused_low_processor_mode_sleep_usec",
	"interface/editor/unfocused_low_processor_mode_sleep_usec",
]


## The first name in [param candidates] that [param store] defines. [param store] is
## the editor settings or any object with [code]has_setting[/code]. Returns
## [code]""[/code] when it defines none of them.
static func resolve(store: Object, candidates: Array) -> String:
	for candidate in candidates:
		var setting_name := str(candidate)
		if store.has_setting(setting_name):
			return setting_name
	return ""

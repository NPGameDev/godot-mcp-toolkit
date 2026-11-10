@tool
extends RefCounted
## Where the recovery plugin lives: the second editor plugin that exists only while an
## update is in flight, and puts the backup back at the next start when the installed
## version does not load.
##
## Its folder starts with a dot, so the Plugins list and the editor's file scan skip it,
## and the editor still enables it at start from the saved entry, which names its
## [code]plugin.cfg[/code] by its full path.

## The recovery plugin's [code]plugin.cfg[/code], as [code]editor_plugins/enabled[/code] in
## [code]project.godot[/code] names it.
const PLUGIN_CFG := "res://addons/.godot_mcp_toolkit_recovery/plugin.cfg"

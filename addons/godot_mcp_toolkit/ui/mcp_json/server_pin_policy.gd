@tool
extends RefCounted
## Server-version pin policy: maps the project's version setting to the npm package
## spec a .mcp.json write runs, then judges an entry's spec against that choice.
##
## The choice lives in the [constant SERVER_VERSION_SETTING] project setting.
## [method read_version_setting] reads it, and [method save_version_setting] sets it
## and saves project.godot, the only file this module writes. Everything else is
## pure: a classification is a plain string that callers store and compare.

## The released npm package a write runs; the version part a write appends is the
## pin.
const RELEASE_PACKAGE := "@npgamedev/godot-mcp-server"

## The ProjectSettings key that picks the server version "Write .mcp.json" pins:
## empty for the version this toolkit was tested with, [constant LATEST_SETTING_VALUE]
## for the newest release, anything else as an npm version, range or tag. It is a
## team-shared choice, so it lives in project.godot.
const SERVER_VERSION_SETTING := "mcp_toolkit/server/version"

## The [constant SERVER_VERSION_SETTING] value (trimmed, any case) that asks for the
## newest server release.
const LATEST_SETTING_VALUE := "latest"

## Pin modes [method pin_mode] reports for a [constant SERVER_VERSION_SETTING] value.
const MODE_PINNED := "pinned"
const MODE_LATEST := "latest"
const MODE_CUSTOM := "custom"

## Server-spec classifications (see [method classify_server_entry]): an npx entry
## with no version, an npx entry with one ([constant SPEC_NPX_PREFIX] + the version
## part), a local build ([constant SPEC_LOCAL_PREFIX] + its path), or an entry that
## is none of those.
const SPEC_NPX_BARE := "npx-bare"
const SPEC_NPX_PREFIX := "npx:"
const SPEC_LOCAL_PREFIX := "local:"
const SPEC_UNKNOWN := "unknown"

## What [method nudge_state] says about the file's server spec: nothing to offer, a
## toolkit-written unversioned entry the pin would fix, a toolkit-written entry that
## no longer matches, or a spec someone set by hand.
const NUDGE_NONE := "none"
const NUDGE_UNPINNED := "unpinned"
const NUDGE_DIFFERS := "differs"
const NUDGE_FOREIGN := "foreign"

# An exact semver version with an optional prerelease, the only version part npm
# resolves to one fixed release.
static var _exact_version := RegEx.create_from_string("^\\d+\\.\\d+\\.\\d+(-[0-9A-Za-z.-]+)?$")


## The pin mode a [constant SERVER_VERSION_SETTING] value selects: [constant
## MODE_PINNED] for an empty value, [constant MODE_LATEST] for [constant
## LATEST_SETTING_VALUE] (trimmed, any case), else [constant MODE_CUSTOM].
static func pin_mode(version_setting: String) -> String:
	var value := version_setting.strip_edges()
	if value.is_empty():
		return MODE_PINNED
	if value.to_lower() == LATEST_SETTING_VALUE:
		return MODE_LATEST
	return MODE_CUSTOM


## The npm package spec a write emits for [param version_setting] (the
## [constant SERVER_VERSION_SETTING] value): the package at [param compatible] when
## the setting is empty, at [code]latest[/code] when it asks for the newest, else at
## the setting's own value, trimmed and not validated (npm reports a bad spec when
## the client launches the server).
static func resolve_package_spec(version_setting: String, compatible: String) -> String:
	var mode := pin_mode(version_setting)
	if mode == MODE_PINNED:
		return RELEASE_PACKAGE + "@" + compatible
	if mode == MODE_LATEST:
		return RELEASE_PACKAGE + "@" + LATEST_SETTING_VALUE
	return RELEASE_PACKAGE + "@" + version_setting.strip_edges()


## True iff [param package_spec]'s version part (after its last "@") is one exact
## semver version, prerelease allowed. A bare package name, a range or a tag is not.
static func is_exact_spec(package_spec: String) -> bool:
	var at := package_spec.rfind("@")
	if at <= 0:
		return false
	return _is_exact_version(package_spec.substr(at + 1))


## Classify the server a parsed mcpServers [param entry] runs: [constant
## SPEC_NPX_BARE] when its last arg is the package with no version, [constant
## SPEC_NPX_PREFIX] + the version part when it has one, [constant SPEC_LOCAL_PREFIX]
## + the path for [code]node <path>[/code], else [constant SPEC_UNKNOWN] (not an
## object, no args, or another command). The Windows [code]cmd /c npx[/code] and the
## bare [code]npx[/code] forms classify alike.
static func classify_server_entry(entry: Variant) -> String:
	if not entry is Dictionary:
		return SPEC_UNKNOWN
	var args_value: Variant = entry.get("args", [])
	if not args_value is Array or args_value.is_empty():
		return SPEC_UNKNOWN
	var args: Array = args_value
	match str(entry.get("command", "")):
		"node":
			return SPEC_LOCAL_PREFIX + str(args[0]) if args.size() == 1 else SPEC_UNKNOWN
		"npx", "cmd":
			return _classify_package_arg(str(args[args.size() - 1]))
	return SPEC_UNKNOWN


## True iff classifications [param a] and [param b] run the same server: equal, or
## one is the unversioned npx form and the other is npx at [code]latest[/code],
## which npx resolves alike.
static func same_spec(a: String, b: String) -> bool:
	if a == b:
		return true
	var newest := [SPEC_NPX_BARE, SPEC_NPX_PREFIX + LATEST_SETTING_VALUE]
	return a in newest and b in newest


## The classification a write would produce now: [constant SPEC_LOCAL_PREFIX] +
## [param dev_path] when a local server path is set, else that of the package spec
## [param version_setting] resolves to against [param compatible].
static func desired_classification(version_setting: String, compatible: String, dev_path: String) -> String:
	if not dev_path.is_empty():
		return SPEC_LOCAL_PREFIX + dev_path
	return _classify_package_arg(resolve_package_spec(version_setting, compatible))


## The project's [constant SERVER_VERSION_SETTING] value, "" when unset.
static func read_version_setting() -> String:
	return str(ProjectSettings.get_setting(SERVER_VERSION_SETTING, ""))


## Set the project's [constant SERVER_VERSION_SETTING] to [param value] and save
## project.godot, where the team shares it. A failed save is logged as a warning;
## the setting still applies to this editor session. Returns the save's error code.
static func save_version_setting(value: String) -> int:
	ProjectSettings.set_setting(SERVER_VERSION_SETTING, value)
	var error := ProjectSettings.save()
	if error != OK:
		push_warning("[MCP] could not save project.godot (err %d): the server version setting applies to this session only" % error)
	return error


## What to tell the user about the file's server spec [param on_disk], given
## [param last_written] (the spec this machine last wrote for the project, "" when
## none is recorded) and [param desired] (see [method desired_classification]).
## [constant NUDGE_NONE] when the file has no readable entry or already runs the
## desired server. A toolkit-written entry (it matches the record, or it is the
## unversioned form an older toolkit wrote before records existed) is [constant
## NUDGE_UNPINNED] when it floats and the desired spec is an exact version, else
## [constant NUDGE_DIFFERS]. Anything else was set by hand or by a teammate:
## [constant NUDGE_FOREIGN].
static func nudge_state(on_disk: String, last_written: String, desired: String) -> String:
	if on_disk == SPEC_UNKNOWN or same_spec(on_disk, desired):
		return NUDGE_NONE
	var toolkit_written := on_disk == last_written or (on_disk == SPEC_NPX_BARE and last_written.is_empty())
	if not toolkit_written:
		return NUDGE_FOREIGN
	var floating := same_spec(on_disk, SPEC_NPX_BARE)
	var desired_exact := (desired.begins_with(SPEC_NPX_PREFIX)
			and _is_exact_version(desired.substr(SPEC_NPX_PREFIX.length())))
	return NUDGE_UNPINNED if floating and desired_exact else NUDGE_DIFFERS


static func _classify_package_arg(arg: String) -> String:
	if arg == RELEASE_PACKAGE:
		return SPEC_NPX_BARE
	if arg.begins_with(RELEASE_PACKAGE + "@"):
		return SPEC_NPX_PREFIX + arg.substr(RELEASE_PACKAGE.length() + 1)
	return SPEC_UNKNOWN


static func _is_exact_version(version: String) -> bool:
	return _exact_version.search(version) != null

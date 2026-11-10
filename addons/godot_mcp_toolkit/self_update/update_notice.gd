@tool
extends RefCounted
## Builds the notice that reports the last apply's result to the dock badge.
##
## A notice is [code]{KIND: UPDATED or FAILED, VERSION, FROM_VERSION, REASON,
## SERVER_CHANGED: bool}[/code], plus [code]RESTORED: true[/code] after the recovery plugin
## put the old version back, with the key constants below.

# Direct preload, not core/modules.gd: the aggregator preloads the installer,
# which reaches this file.
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")

## [constant KIND] values: the release was installed.
const UPDATED := "updated"
## The release was not installed; [constant REASON] says why.
const FAILED := "failed"

## The notice key for [constant UPDATED] or [constant FAILED], a String.
const KIND := "kind"
## The notice key for the release the apply was about, a String.
const VERSION := "version"
## The notice key for the version installed before the apply, a String.
const FROM_VERSION := "from_version"
## The notice key for why the release was not installed, a String, empty when it was.
const REASON := "reason"
## The notice key for whether the installed release is tested with another server than the
## one before it, a bool.
const SERVER_CHANGED := "server_changed"
## The notice key, present only as [code]true[/code], for a failure the recovery plugin
## answered by putting the version before it back.
const RESTORED := "restored"


## The notice for what the settle at an editor start found. [param settled] is what
## [method UpdateSettler.settle] returns for an applied or a failed update, and
## [param updated] says which. A failure after the recovery plugin put the old version back
## adds [constant RESTORED].
static func of_settle(settled: Dictionary, updated: bool) -> Dictionary:
	var notice := {
		KIND: UPDATED if updated else FAILED,
		VERSION: settled["to"],
		FROM_VERSION: settled["from"],
		REASON: settled["reason"],
		SERVER_CHANGED: updated and settled["compatible_server"] != VersionUtils.COMPATIBLE_SERVER_VERSION,
	}
	if bool(settled.get("restored", false)):
		notice[RESTORED] = true
	return notice


## The notice for a staged release the editor's exit will not install: [param version] is
## that release, [param from_version] the one still installed and [param reason] why.
static func not_installed(version: String, from_version: String, reason: String) -> Dictionary:
	return {
		KIND: FAILED,
		VERSION: version,
		FROM_VERSION: from_version,
		REASON: reason,
		SERVER_CHANGED: false,
	}

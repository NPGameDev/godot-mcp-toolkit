@tool
extends RefCounted
## The files a release publishes beside its zip, and the URLs they download from.
##
## Every name and URL is built here from the version alone, never taken from a
## reply, as the update check's badge links are. The scheme and host can be replaced
## for a local test server through the update check's contributor-only host
## variable; the manifest's signature makes another host harmless.

# Direct preload, not core/modules.gd: the aggregator preloads this file.
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")

const _DOWNLOAD_HOST := "https://github.com"
const _DOWNLOAD_PATH := "/NPGameDev/godot-mcp-toolkit/releases/download/v%s/%s"


## The release zip of [param version] ([code]X.Y.Z[/code]).
static func archive_name(version: String) -> String:
	return "godot-mcp-toolkit-%s.zip" % version


## The update manifest of [param version].
static func manifest_name(version: String) -> String:
	return "godot-mcp-toolkit-%s.update.json" % version


## The signature over the update manifest of [param version].
static func signature_name(version: String) -> String:
	return manifest_name(version) + ".sig"


## The download URL of the asset [param asset_name] of [param version].
## [param env_host] is the update check's host variable; see
## [method UpdateCheck.resolve_host].
static func download_url(env_host: String, version: String, asset_name: String) -> String:
	return UpdateCheck.resolve_host(env_host, _DOWNLOAD_HOST) + _DOWNLOAD_PATH % [version, asset_name]

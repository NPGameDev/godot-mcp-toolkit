@tool
extends RefCounted
## The files a release publishes beside its zip, and the URLs they download from.
##
## Every name and URL is built here from the version or the trust document's number
## alone, never taken from a reply, as the update check's badge links are. The scheme and
## host can be replaced for a loopback test server through the update check's
## contributor-only host variable, which accepts nothing else.

# Direct preload, not core/modules.gd: the aggregator preloads the installer,
# which reaches this file.
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")

const _DOWNLOAD_HOST := "https://github.com"
const _DOWNLOAD_PATH := "/NPGameDev/godot-mcp-toolkit/releases/download/v%s/%s"
const _TRUST_DOCUMENT_PATH := "/NPGameDev/godot-mcp-toolkit/releases/download/trust-%d/%s"


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


## The file name of trust document [param number]: the release asset, the committed file
## and the stored file alike.
static func trust_document_name(number: int) -> String:
	return "trust-%d.json" % number


## The download URL of trust document [param number], from its own release rather than a
## version's. [param env_host] is as in [method download_url].
static func trust_document_url(env_host: String, number: int) -> String:
	return UpdateCheck.resolve_host(env_host, _DOWNLOAD_HOST) + _TRUST_DOCUMENT_PATH % [number, trust_document_name(number)]

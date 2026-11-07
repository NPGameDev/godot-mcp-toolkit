@tool
extends RefCounted
## Reads a verified release's kept files back from the update folder.
##
## A verified release's manifest and signature wait in its version folder, so an editor start
## can offer the release again without a request, and the editor's exit reads them before it
## installs. Nothing kept is trusted as it stands: every caller checks the signature again
## against the trust chain this machine holds then.[br]
## [br]
## The exit's install reads through [method files], so that function stays a plain read.

# Direct preloads, not core/modules.gd: the aggregator preloads the installer,
# which reaches this file.
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")
const ReleaseManifest := preload("res://addons/godot_mcp_toolkit/self_update/release_manifest.gd")
const ReleaseSignature := preload("res://addons/godot_mcp_toolkit/self_update/release_signature.gd")


## The kept files of [param version] in [param update_folder]:
## [code]{"manifest": PackedByteArray, "signature": PackedByteArray}[/code], or an empty
## dictionary when either file is missing.
static func files(version: String, update_folder: String) -> Dictionary:
	var folder := UpdateFolder.version_folder(version, update_folder)
	var manifest_path := folder.path_join(ReleaseAssets.manifest_name(version))
	var signature_path := folder.path_join(ReleaseAssets.signature_name(version))
	if not FileAccess.file_exists(manifest_path) or not FileAccess.file_exists(signature_path):
		return {}
	return {
		"manifest": FileAccess.get_file_as_bytes(manifest_path),
		"signature": FileAccess.get_file_as_bytes(signature_path),
	}


## The kept manifest of [param version], checked again: [code]{"manifest": what
## ReleaseManifest.parse returns, "bytes": its text}[/code], or an empty dictionary when it or
## its signature is missing or does not check out. [param options] is what
## [method ReleaseSignature.chain] takes.
static func read(version: String, update_folder: String, options: Dictionary) -> Dictionary:
	var kept := files(version, update_folder)
	if kept.is_empty():
		return {}
	var manifest_bytes: PackedByteArray = kept["manifest"]
	var signature: PackedByteArray = kept["signature"]
	if not ReleaseSignature.is_trusted(manifest_bytes, signature, null, options):
		return {}
	var manifest := ReleaseManifest.parse(manifest_bytes.get_string_from_utf8(), version)
	if not str(manifest["error"]).is_empty():
		return {}
	return {"manifest": manifest, "bytes": manifest_bytes}


## Whether [param update_folder] holds the manifest and signature of [param version] and the
## chain no longer trusts that signature, as when a key was dropped after the release was
## staged. [param options] is what [method ReleaseSignature.chain] takes.
static func signature_refused(version: String, update_folder: String, options: Dictionary) -> bool:
	var kept := files(version, update_folder)
	if kept.is_empty():
		return false
	var manifest_bytes: PackedByteArray = kept["manifest"]
	var signature: PackedByteArray = kept["signature"]
	return not ReleaseSignature.is_trusted(manifest_bytes, signature, null, options)

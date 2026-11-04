@tool
extends RefCounted
## Unit tests for the names and download URLs of a release's assets and of trust
## documents: built from the version or the number alone, on GitHub unless the update
## check's host variable replaces the scheme and host.

const Testing := preload("res://test/units/testing.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")


static func run(testing: Testing) -> void:
	_test_names(testing)
	_test_urls(testing)
	_test_trust_documents(testing)


static func _test_names(testing: Testing) -> void:
	testing.begin("Release assets: names from the version")
	testing.eq(ReleaseAssets.archive_name("1.2.0"), "godot-mcp-toolkit-1.2.0.zip", "the zip")
	testing.eq(ReleaseAssets.manifest_name("1.2.0"), "godot-mcp-toolkit-1.2.0.update.json", "the manifest")
	testing.eq(ReleaseAssets.signature_name("1.2.0"), "godot-mcp-toolkit-1.2.0.update.json.sig", "the signature")
	print("")


static func _test_urls(testing: Testing) -> void:
	testing.begin("Release assets: download URLs")
	testing.eq(ReleaseAssets.download_url("", "1.2.0", "godot-mcp-toolkit-1.2.0.zip"),
			"https://github.com/NPGameDev/godot-mcp-toolkit/releases/download/v1.2.0/godot-mcp-toolkit-1.2.0.zip",
			"no host variable → the GitHub release download")
	testing.eq(ReleaseAssets.download_url("http://127.0.0.1:8123/", "1.2.0", "x.sig"),
			"http://127.0.0.1:8123/NPGameDev/godot-mcp-toolkit/releases/download/v1.2.0/x.sig",
			"a host variable → its scheme and host, the same path")
	testing.eq(ReleaseAssets.download_url("ftp://example.com", "1.2.0", "x.sig"),
			"https://github.com/NPGameDev/godot-mcp-toolkit/releases/download/v1.2.0/x.sig",
			"a host variable that is not http or https → ignored")
	print("")


static func _test_trust_documents(testing: Testing) -> void:
	testing.begin("Release assets: a trust document, from its number alone")
	testing.eq(ReleaseAssets.trust_document_name(7), "trust-7.json", "the file name")
	testing.eq(ReleaseAssets.trust_document_url("", 7),
			"https://github.com/NPGameDev/godot-mcp-toolkit/releases/download/trust-7/trust-7.json",
			"no host variable → its own release, not a version's")
	testing.eq(ReleaseAssets.trust_document_url("http://127.0.0.1:8123/", 7),
			"http://127.0.0.1:8123/NPGameDev/godot-mcp-toolkit/releases/download/trust-7/trust-7.json",
			"a host variable → its scheme and host, the same path")
	testing.eq(ReleaseAssets.trust_document_url("ftp://example.com", 7),
			"https://github.com/NPGameDev/godot-mcp-toolkit/releases/download/trust-7/trust-7.json",
			"a host variable that is not http or https → ignored")
	print("")

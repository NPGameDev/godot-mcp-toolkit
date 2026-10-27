@tool
extends RefCounted
## Unit tests for the names and download URLs of a release's assets: built from the
## version alone, on GitHub unless the update check's host variable replaces the
## scheme and host.

const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/update/release_assets.gd")


static func run(testing) -> void:
	_test_names(testing)
	_test_urls(testing)


static func _test_names(testing) -> void:
	testing.begin("Release assets: names from the version")
	testing.eq(ReleaseAssets.archive_name("1.2.0"), "godot-mcp-toolkit-1.2.0.zip", "the zip")
	testing.eq(ReleaseAssets.manifest_name("1.2.0"), "godot-mcp-toolkit-1.2.0.update.json", "the manifest")
	testing.eq(ReleaseAssets.signature_name("1.2.0"), "godot-mcp-toolkit-1.2.0.update.json.sig", "the signature")
	print("")


static func _test_urls(testing) -> void:
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

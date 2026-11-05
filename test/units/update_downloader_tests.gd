@tool
extends RefCounted
## Unit tests for the release file downloader: the rule every hop must pass, both shapes an
## engine reports a redirect in, and fetches through loopback listeners. A host no test can
## reach is covered at the rule's function; a second listener counts the hops that get out.

const Testing := preload("res://test/units/testing.gd")
const UpdateDownloader := preload("res://addons/godot_mcp_toolkit/self_update/update_downloader.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")

const _BODY := "release file"
const _FRAME_LIMIT := 1200


static func run(testing: Testing, tree: SceneTree) -> void:
	await tree.process_frame
	_test_hosts_the_rule_allows(testing)
	_test_hosts_the_rule_refuses(testing)
	_test_loopback_hop_needs_the_host_variable(testing)
	_test_redirect_shapes(testing)
	await _test_each_redirect_code_is_followed(testing, tree)
	await _test_engine_following_stays_off(testing, tree)
	await _test_relative_location(testing, tree)
	await _test_off_list_hop_reaches_no_listener(testing, tree)
	await _test_redirect_limit(testing, tree)
	await _test_redirect_without_location(testing, tree)
	await _test_not_found_stays_a_plain_failure(testing, tree)
	await _test_size_limit(testing, tree)
	await _test_target_file(testing, tree)
	_test_refused_start(testing, tree)


static func _test_hosts_the_rule_allows(testing: Testing) -> void:
	testing.begin("Update downloader: the hosts a hop may reach")
	for url: String in [
		"https://github.com/NPGameDev/godot-mcp-toolkit/releases/download/v1.2.0/a.zip",
		"https://objects.githubusercontent.com/github-production-release-asset/1/2?sp=r&sig=a%2Fb",
		"https://release-assets.githubusercontent.com/github-production-release-asset/1/2",
		"https://a.b.githubusercontent.com/c",
		"https://github.com",
	]:
		testing.eq(UpdateDownloader.hop_refusal(url), "", "%s → allowed" % url)
	print("")


static func _test_hosts_the_rule_refuses(testing: Testing) -> void:
	testing.begin("Update downloader: the hops the rule refuses")
	for url: String in [
		"https://evil.example/a.zip",
		"https://raw.githubusercontent.com/NPGameDev/godot-mcp-toolkit/main/a.zip",
		"https://a.raw.githubusercontent.com/a.zip",
		"https://evilgithubusercontent.com/a.zip",
		"https://githubusercontent.com/a.zip",
		"https://evilgithub.com/a.zip",
		"https://www.github.com/a.zip",
		"https://github.com.evil.example/a.zip",
		"https://objects.githubusercontent.com.evil.example/a.zip",
		"https://github.com@evil.example/a.zip",
		"https://github.com:443@evil.example/a.zip",
		"https://github.com?@evil.example/a.zip",
		"https://github.com#@evil.example/a.zip",
		"https://github.com\\@evil.example/a.zip",
		"https://evil.example?/github.com/a.zip",
		"http://github.com/a.zip",
		"http://objects.githubusercontent.com/a.zip",
		"ftp://github.com/a.zip",
		# Built at run time: the language server checks every string literal as a file path,
		# and on Windows a leading "//" is a network path whose lookup blocks the editor.
		"/" + "/github.com/a.zip",
		"github.com/a.zip",
		"/a.zip",
		"",
		"HTTPS://github.com/a.zip",
		"https://GITHUB.com/a.zip",
		"https://RAW.githubusercontent.com/a.zip",
		"https://github.com./a.zip",
		"https://raw.githubusercontent.com./a.zip",
		"https://objects.githubusercontent.com./a.zip",
		"https://.githubusercontent.com/a.zip",
		"https://a..githubusercontent.com/a.zip",
		"https://github.com:8443/a.zip",
		"https://github.com/a zip",
		"https://github.com/a.zip\n",
	]:
		testing.eq(UpdateDownloader.hop_refusal(url), UpdateDownloader.REFUSED_HOST, "%s → refused" % url.c_escape())
	print("")


# The host variable opens its own address and no other, and only when it names loopback.
static func _test_loopback_hop_needs_the_host_variable(testing: Testing) -> void:
	testing.begin("Update downloader: a loopback hop needs the host variable")
	var env_host := "http://127.0.0.1:8123"
	testing.eq(UpdateDownloader.hop_refusal("http://127.0.0.1:8123/a.zip", env_host), "", "the variable's own address → allowed")
	testing.eq(UpdateDownloader.hop_refusal("http://127.0.0.1:8123/a.zip", env_host + "/"), "",
			"a variable with a trailing slash → the same address")
	testing.eq(UpdateDownloader.hop_refusal("https://github.com/a.zip", env_host), "", "GitHub stays allowed beside it")
	for url: String in [
		"http://127.0.0.1:8123/a.zip",
	]:
		testing.eq(UpdateDownloader.hop_refusal(url), UpdateDownloader.REFUSED_HOST, "no variable → %s refused" % url)
	for url: String in [
		"http://127.0.0.1:9000/a.zip",
		"http://127.0.0.1:81234/a.zip",
		"http://localhost:8123/a.zip",
		"http://127.0.0.1:8123@evil.example/a.zip",
		"http://127.0.0.1:8123.evil.example/a.zip",
		"https://127.0.0.1:8123/a.zip",
	]:
		testing.eq(UpdateDownloader.hop_refusal(url, env_host), UpdateDownloader.REFUSED_HOST, "%s → refused" % url)
	testing.eq(UpdateDownloader.hop_refusal("https://evil.example/a.zip", "https://evil.example"),
			UpdateDownloader.REFUSED_HOST, "a variable off the machine → opens nothing")
	print("")


# Both shapes pinned on every runner, since each engine shows only one of them to a listener.
static func _test_redirect_shapes(testing: Testing) -> void:
	testing.begin("Update downloader: what counts as a redirect")
	for code: int in [301, 302, 303, 307, 308]:
		testing.ok(UpdateDownloader.is_redirect(HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED, code), "%d at the engine's limit → a redirect" % code)
		testing.ok(UpdateDownloader.is_redirect(HTTPRequest.RESULT_SUCCESS, code), "%d as a plain reply → a redirect" % code)
		testing.ok(not UpdateDownloader.is_redirect(HTTPRequest.RESULT_CONNECTION_ERROR, code), "%d on a broken connection → not one" % code)
	for code: int in [200, 300, 304, 305, 404, 500]:
		testing.ok(not UpdateDownloader.is_redirect(HTTPRequest.RESULT_SUCCESS, code), "%d → not a redirect" % code)
	print("")


static func _test_each_redirect_code_is_followed(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update downloader: each redirect status is followed")
	for code: int in [301, 302, 303, 307, 308]:
		var server := UpdateFixtures.LoopbackReleaseServer.new({"final": _BODY.to_utf8_buffer()})
		server.redirect("/start", code, server.host() + "/final")
		var outcome: Dictionary = await _fetch(tree, [server], server.host(), server.host() + "/start", 1024)
		var connections := server.connections()
		server.stop()
		testing.eq(outcome.get("ok"), true, "%d → the fetch succeeds" % code)
		testing.eq(outcome.get("code"), 200, "%d → the last reply is the 200" % code)
		testing.eq(_text(outcome), _BODY, "%d → the body is the final file's" % code)
		testing.eq(connections, 2, "%d → two requests" % code)
	print("")


# A hop the engine followed itself would never reach the rule, so the first reply must show.
static func _test_engine_following_stays_off(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update downloader: the engine follows nothing itself")
	var downloader := UpdateDownloader.new()
	tree.root.add_child(downloader)
	var http: HTTPRequest = null
	for child: Node in downloader.get_children():
		if child is HTTPRequest:
			http = child as HTTPRequest
	var max_redirects := http.max_redirects if http != null else -1
	downloader.free()
	testing.eq(max_redirects, 0, "the request's own redirect limit → 0")
	print("")


static func _test_relative_location(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update downloader: a Location without a host")
	var server := UpdateFixtures.LoopbackReleaseServer.new({"final": _BODY.to_utf8_buffer()})
	server.redirect("/start", 302, "/final")
	var rooted: Dictionary = await _fetch(tree, [server], server.host(), server.host() + "/start", 1024)
	server.stop()
	testing.eq(_text(rooted), _BODY, "a path from the root → on the same host")

	var second := UpdateFixtures.LoopbackReleaseServer.new({"final": _BODY.to_utf8_buffer()})
	var first := UpdateFixtures.LoopbackReleaseServer.new({})
	first.redirect("/start", 302, "//" + second.host().trim_prefix("http://") + "/final")
	var scheme_relative: Dictionary = await _fetch(tree, [first, second], first.host(), first.host() + "/start", 1024)
	var second_hits := second.connections()
	first.stop()
	second.stop()
	testing.eq(scheme_relative.get("refusal"), UpdateDownloader.REFUSED_HOST, "//host/path → refused")
	testing.eq(second_hits, 0, "and no request reaches that host")
	print("")


# The first listener is the host variable's address, so the rule allows it; the second has
# another port, so it stands in for a host off the list.
static func _test_off_list_hop_reaches_no_listener(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update downloader: an off-list hop reaches no listener")
	for code: int in [302, 307]:
		for form: String in ["http://127.0.0.1:%d/final", "http://github.com@127.0.0.1:%d/final"]:
			var second := UpdateFixtures.LoopbackReleaseServer.new({"final": _BODY.to_utf8_buffer()})
			var port := int(second.host().get_slice(":", 2))
			var first := UpdateFixtures.LoopbackReleaseServer.new({})
			first.redirect("/start", code, form % port)
			var outcome: Dictionary = await _fetch(tree, [first, second], first.host(), first.host() + "/start", 1024)
			var second_hits := second.connections()
			first.stop()
			second.stop()
			testing.eq(outcome.get("ok"), false, "%d to %s → the fetch fails" % [code, form])
			testing.eq(outcome.get("refusal"), UpdateDownloader.REFUSED_HOST, "%d to %s → refused for its host" % [code, form])
			testing.eq(second_hits, 0, "%d to %s → no request reaches it" % [code, form])
	print("")


static func _test_redirect_limit(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update downloader: at most five redirects")
	var at_limit := _redirect_chain(UpdateDownloader.MAX_REDIRECTS)
	var allowed: Dictionary = await _fetch(tree, [at_limit], at_limit.host(), at_limit.host() + "/hop0", 1024)
	var allowed_requests := at_limit.connections()
	at_limit.stop()
	var past_limit := _redirect_chain(UpdateDownloader.MAX_REDIRECTS + 1)
	var refused: Dictionary = await _fetch(tree, [past_limit], past_limit.host(), past_limit.host() + "/hop0", 1024)
	var refused_requests := past_limit.connections()
	past_limit.stop()
	testing.eq(UpdateDownloader.MAX_REDIRECTS, 5, "the limit")
	testing.eq(allowed.get("ok"), true, "five redirects → followed")
	testing.eq(allowed_requests, 6, "the first request and the five hops")
	testing.eq(refused.get("ok"), false, "a sixth redirect → the fetch fails")
	testing.eq(refused.get("refusal"), UpdateDownloader.REFUSED_TOO_MANY, "with its reason")
	testing.eq(refused_requests, 6, "and the sixth is never requested")
	print("")


static func _test_redirect_without_location(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update downloader: a redirect that names no place")
	var server := UpdateFixtures.LoopbackReleaseServer.new({})
	server.redirect("/start", 302, "")
	var outcome: Dictionary = await _fetch(tree, [server], server.host(), server.host() + "/start", 1024)
	server.stop()
	testing.eq(outcome.get("ok"), false, "no Location → the fetch fails")
	testing.eq(outcome.get("code"), 302, "reporting the status")
	testing.eq(outcome.get("refusal"), "", "with nothing to refuse")
	print("")


# The trust walk ends at a 404 and treats any other failure differently, so the status must
# reach the caller, after a redirect too.
static func _test_not_found_stays_a_plain_failure(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update downloader: a 404 reaches the caller as a 404")
	var server := UpdateFixtures.LoopbackReleaseServer.new({})
	server.redirect("/start", 302, server.host() + "/gone")
	var direct: Dictionary = await _fetch(tree, [server], server.host(), server.host() + "/gone", 1024)
	var redirected: Dictionary = await _fetch(tree, [server], server.host(), server.host() + "/start", 1024)
	server.stop()
	testing.eq(direct.get("ok"), false, "a 404 → the fetch fails")
	testing.eq(direct.get("code"), 404, "reporting the status")
	testing.eq(direct.get("result"), HTTPRequest.RESULT_SUCCESS, "as an answered request")
	testing.eq(direct.get("refusal"), "", "with nothing refused")
	testing.eq(redirected.get("code"), 404, "a 404 after a redirect → the same status")
	print("")


static func _test_size_limit(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update downloader: the size limit")
	var server := UpdateFixtures.LoopbackReleaseServer.new({"final": _BODY.to_utf8_buffer()})
	server.redirect("/start", 302, server.host() + "/final")
	var at_limit: Dictionary = await _fetch(tree, [server], server.host(), server.host() + "/final", _BODY.length())
	var past_limit: Dictionary = await _fetch(tree, [server], server.host(), server.host() + "/final", _BODY.length() - 1)
	var past_after_hop: Dictionary = await _fetch(tree, [server], server.host(), server.host() + "/start", _BODY.length() - 1)
	server.stop()
	testing.eq(at_limit.get("ok"), true, "a body at the limit → fetched")
	testing.eq(past_limit.get("ok"), false, "one byte past it → the fetch fails")
	testing.eq(past_limit.get("result"), HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED, "for its size")
	testing.eq(past_after_hop.get("result"), HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED, "and the limit holds after a hop")
	print("")


static func _test_target_file(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update downloader: a target file")
	var folder := UpdateFixtures.scratch("downloader_target")
	var target := ProjectSettings.globalize_path(folder.path_join("file.bin"))
	DirAccess.make_dir_recursive_absolute(target.get_base_dir())
	var server := UpdateFixtures.LoopbackReleaseServer.new({"final": _BODY.to_utf8_buffer(), "empty": PackedByteArray()})
	server.redirect("/start", 307, server.host() + "/final")
	server.redirect("/to-nothing", 307, server.host() + "/empty")
	server.redirect("/to-gone", 307, server.host() + "/gone")
	server.redirect("/to-elsewhere", 307, "http://127.0.0.1:9/final")
	var fetched: Dictionary = await _fetch(tree, [server], server.host(), server.host() + "/start", 1024, target)
	var written := FileAccess.get_file_as_string(target)
	DirAccess.remove_absolute(target)
	var to_nothing: Dictionary = await _fetch(tree, [server], server.host(), server.host() + "/to-nothing", 1024, target)
	var left_after_empty := FileAccess.file_exists(target)
	var to_gone: Dictionary = await _fetch(tree, [server], server.host(), server.host() + "/to-gone", 1024, target)
	var left_after_gone := FileAccess.file_exists(target)
	var to_elsewhere: Dictionary = await _fetch(tree, [server], server.host(), server.host() + "/to-elsewhere", 1024, target)
	var left_after_refusal := FileAccess.file_exists(target)
	server.stop()
	UpdateFixtures.remove(folder)
	testing.eq(fetched.get("ok"), true, "a redirected fetch → succeeds")
	testing.eq(written, _BODY, "the file holds the final body, not the redirect's")
	testing.eq(to_nothing.get("ok"), true, "an empty final reply → succeeds")
	testing.ok(not left_after_empty, "and the redirect's own body is not left as the file")
	testing.eq(to_gone.get("code"), 404, "a 404 after a redirect → fails")
	testing.ok(not left_after_gone, "and no file stays")
	testing.eq(to_elsewhere.get("refusal"), UpdateDownloader.REFUSED_HOST, "a refused hop → fails")
	testing.ok(not left_after_refusal, "and no file stays")
	print("")


# A URL the rule refuses sends nothing and reports at once: no finished signal will follow.
static func _test_refused_start(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update downloader: a first URL the rule refuses")
	var server := UpdateFixtures.LoopbackReleaseServer.new({"final": _BODY.to_utf8_buffer()})
	var previous_host := OS.get_environment(UpdateFixtures.HOST_ENV)
	OS.unset_environment(UpdateFixtures.HOST_ENV)
	var downloader := UpdateDownloader.new()
	tree.root.add_child(downloader)
	var error := downloader.fetch(server.host() + "/final", 1024, 5.0)
	server.poll()
	downloader.free()
	var hits := server.connections()
	server.stop()
	if not previous_host.is_empty():
		OS.set_environment(UpdateFixtures.HOST_ENV, previous_host)
	testing.eq(error, ERR_UNAUTHORIZED, "loopback with no host variable → refused")
	testing.eq(hits, 0, "and nothing sent")
	print("")


# A listener whose /hop0 redirects to /hop1 and so on for `redirects` hops, ending at a file.
static func _redirect_chain(redirects: int) -> UpdateFixtures.LoopbackReleaseServer:
	var last_hop := "end"
	var server := UpdateFixtures.LoopbackReleaseServer.new({last_hop: _BODY.to_utf8_buffer()})
	for hop: int in range(redirects):
		var next := last_hop if hop == redirects - 1 else "hop%d" % (hop + 1)
		server.redirect("/hop%d" % hop, 302, "%s/%s" % [server.host(), next])
	return server


# Runs one fetch with the host variable set to `env_host`, polling `servers`, and returns its
# outcome, or an empty dictionary when none came within the frame limit.
static func _fetch(tree: SceneTree, servers: Array, env_host: String, url: String, size_limit: int, target_file: String = "") -> Dictionary:
	var previous_host := OS.get_environment(UpdateFixtures.HOST_ENV)
	OS.set_environment(UpdateFixtures.HOST_ENV, env_host)
	var downloader := UpdateDownloader.new()
	tree.root.add_child(downloader)
	var outcomes: Array[Dictionary] = []
	downloader.finished.connect(func(outcome: Dictionary) -> void: outcomes.append(outcome))
	var error := downloader.fetch(url, size_limit, 5.0, target_file)
	var frames := 0
	while error == OK and outcomes.is_empty() and frames < _FRAME_LIMIT:
		for server: UpdateFixtures.LoopbackReleaseServer in servers:
			server.poll()
		await tree.process_frame
		frames += 1
	# One more round, so a hop the fetch wrongly sent at its end still registers.
	for server: UpdateFixtures.LoopbackReleaseServer in servers:
		server.poll()
	downloader.free()
	if previous_host.is_empty():
		OS.unset_environment(UpdateFixtures.HOST_ENV)
	else:
		OS.set_environment(UpdateFixtures.HOST_ENV, previous_host)
	return outcomes[0] if not outcomes.is_empty() else {}


static func _text(outcome: Dictionary) -> String:
	var body: PackedByteArray = outcome.get("body", PackedByteArray())
	return body.get_string_from_utf8()

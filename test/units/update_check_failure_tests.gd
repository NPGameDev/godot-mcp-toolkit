@tool
extends RefCounted
## Unit tests for what stops an update check: which kind each fetch and accept outcome is,
## which kinds a click can retry, and the sentence each kind shows.

const Testing := preload("res://test/units/testing.gd")
const UpdateCheckFailure := preload("res://addons/godot_mcp_toolkit/self_update/update_check_failure.gd")
const TrustChain := preload("res://addons/godot_mcp_toolkit/self_update/trust_chain.gd")


static func run(testing: Testing) -> void:
	_test_kind_of_a_fetch(testing)
	_test_kind_of_a_release_file(testing)
	_test_kind_of_an_accept(testing)
	_test_what_a_click_can_retry(testing)
	_test_messages(testing)


static func _outcome(result: int, code: int, refusal: String = "") -> Dictionary:
	return {"ok": false, "result": result, "code": code, "refusal": refusal, "body": PackedByteArray()}


static func _test_kind_of_a_fetch(testing: Testing) -> void:
	testing.begin("Update check failure: the kind of a failed fetch")
	for result: int in [
		HTTPRequest.RESULT_CANT_CONNECT,
		HTTPRequest.RESULT_CANT_RESOLVE,
		HTTPRequest.RESULT_CONNECTION_ERROR,
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR,
		HTTPRequest.RESULT_TIMEOUT,
	]:
		testing.eq(UpdateCheckFailure.of_fetch(_outcome(result, 0)), "unreachable", "result %d → unreachable" % result)
	for code: int in [429, 500, 503]:
		testing.eq(UpdateCheckFailure.of_fetch(_outcome(HTTPRequest.RESULT_SUCCESS, code)), "github_error", "HTTP %d → GitHub's error" % code)
	testing.eq(UpdateCheckFailure.of_fetch(_outcome(HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED, 302)), "github_error",
			"the engine's redirect limit → GitHub's error")
	testing.eq(UpdateCheckFailure.of_fetch(_outcome(HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED, 200)), "security",
			"a reply over the size limit → the security check")
	testing.eq(UpdateCheckFailure.of_fetch(_outcome(HTTPRequest.RESULT_SUCCESS, 302, "an off-list hop")), "security",
			"a refused hop → the security check, whatever the result says")
	print("")


static func _test_kind_of_a_release_file(testing: Testing) -> void:
	testing.begin("Update check failure: the kind of a failed manifest or signature fetch")
	testing.eq(UpdateCheckFailure.of_release_file(_outcome(HTTPRequest.RESULT_SUCCESS, 404)), "not_ready", "HTTP 404 → not ready")
	for code: int in [403, 410, 500]:
		testing.eq(UpdateCheckFailure.of_release_file(_outcome(HTTPRequest.RESULT_SUCCESS, code)), "github_error", "HTTP %d → GitHub's error" % code)
	testing.eq(UpdateCheckFailure.of_release_file(_outcome(HTTPRequest.RESULT_TIMEOUT, 0)), "unreachable", "a timeout → unreachable")
	testing.eq(UpdateCheckFailure.of_release_file(_outcome(HTTPRequest.RESULT_SUCCESS, 404, "an off-list hop")), "security",
			"a refused hop → the security check, whatever the code says")
	testing.eq(UpdateCheckFailure.of_fetch(_outcome(HTTPRequest.RESULT_SUCCESS, 404)), "github_error",
			"any other file's 404 → GitHub's error")
	print("")


static func _test_kind_of_an_accept(testing: Testing) -> void:
	testing.begin("Update check failure: the kind of a refused document")
	testing.eq(UpdateCheckFailure.of_accept(TrustChain.INVALID), "security", "invalid → the security check")
	testing.eq(UpdateCheckFailure.of_accept(TrustChain.NOT_EXPECTED), "security", "not expected → the security check")
	testing.eq(UpdateCheckFailure.of_accept(TrustChain.WRITE_FAILED), "store_write", "a failed write → the store")
	testing.eq(UpdateCheckFailure.of_accept(TrustChain.NO_STORE), "no_data_folder", "no store → the data folder")
	print("")


static func _test_what_a_click_can_retry(testing: Testing) -> void:
	testing.begin("Update check failure: a click retries all but a missing data folder")
	for kind: String in ["unreachable", "github_error", "not_ready", "security", "store_write"]:
		testing.ok(UpdateCheckFailure.can_retry(kind), "%s → a click can retry" % kind)
	testing.ok(not UpdateCheckFailure.can_retry("no_data_folder"), "no data folder → a click cannot help")
	testing.ok(not UpdateCheckFailure.can_retry(""), "no failure → nothing to retry")
	print("")


static func _test_messages(testing: Testing) -> void:
	testing.begin("Update check failure: the sentence for each kind")
	testing.eq(UpdateCheckFailure.message("unreachable"),
			"Couldn't reach GitHub to check this update. Check your connection and click Update to try again. The toolkit also tries again the next time you open the editor.",
			"unreachable → check the connection")
	testing.eq(UpdateCheckFailure.message("github_error"),
			"GitHub isn't responding. Try Update again in a few minutes. The toolkit also tries again the next time you open the editor.",
			"GitHub's error → try again in a few minutes")
	testing.eq(UpdateCheckFailure.message("security"),
			"This update failed its security check, so it won't install. Your connection isn't the problem. The toolkit checks again the next time you open the editor.",
			"the security check → it won't install")
	testing.eq(UpdateCheckFailure.message("store_write", "C:/data/trust"),
			"Couldn't save update security data to C:/data/trust. Make sure you can write to that folder, then click Update to try again.",
			"the store → names the folder")
	var variable := "APPDATA" if OS.has_feature("windows") else "HOME"
	testing.eq(UpdateCheckFailure.message("no_data_folder"),
			"This update can't install here because your system doesn't set %s, so the toolkit has nowhere to save its update security data. Set that variable and reopen the editor." % variable,
			"no data folder → names this system's variable")
	testing.eq(UpdateCheckFailure.message("not_ready"),
			"This release isn't ready to install from the editor yet. Try Update again later.",
			"a release with no manifest yet → try again later")
	testing.eq(UpdateCheckFailure.message(""), "", "no failure → no sentence")
	print("")

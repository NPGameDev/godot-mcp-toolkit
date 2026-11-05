@tool
extends RefCounted
## What stopped the toolkit checking an update, and what the badge says about it.
##
## A check is the walk along the trust chain and the verify of the release's manifest. Each
## failure leaves the badge's links in place, and the user decides from the sentence here.

# Direct preloads: core/modules.gd does not list this folder's scripts.
const TrustChain := preload("res://addons/godot_mcp_toolkit/self_update/trust_chain.gd")

## No answer: no connection, no name, a timeout or a failed TLS handshake.
const UNREACHABLE := "unreachable"
## GitHub answered with something other than the file.
const GITHUB_ERROR := "github_error"
## A document, a signature or a redirect that does not hold.
const SECURITY := "security"
## The store could not keep a document.
const STORE_WRITE := "store_write"
## The system names no data folder, so there is no store.
const NO_DATA_FOLDER := "no_data_folder"


## The kind of failure a not-ok [signal UpdateDownloader.finished] outcome is. An off-list
## hop and an oversized reply are refusals of what came back, not trouble reaching it.
static func of_fetch(outcome: Dictionary) -> String:
	if not str(outcome["refusal"]).is_empty():
		return SECURITY
	var result := int(outcome["result"])
	if result == HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
		return SECURITY
	if result == HTTPRequest.RESULT_SUCCESS or result == HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED:
		return GITHUB_ERROR
	return UNREACHABLE


## The kind of failure an outcome of [method TrustChain.accept] other than
## [constant TrustChain.ACCEPTED] is.
static func of_accept(outcome: String) -> String:
	match outcome:
		TrustChain.WRITE_FAILED:
			return STORE_WRITE
		TrustChain.NO_STORE:
			return NO_DATA_FOLDER
	return SECURITY


## Whether a click can change the result. With no data folder only the user's system can.
static func can_retry(kind: String) -> bool:
	return not kind.is_empty() and kind != NO_DATA_FOLDER


## The sentence the badge shows for [param kind]. [param store_folder] is the store a
## [constant STORE_WRITE] failed to write.
static func message(kind: String, store_folder: String = "") -> String:
	match kind:
		UNREACHABLE:
			return "Couldn't reach GitHub to check this update. Check your connection and click Update to try again. The toolkit also tries again the next time you open the editor."
		GITHUB_ERROR:
			return "GitHub isn't responding. Try Update again in a few minutes. The toolkit also tries again the next time you open the editor."
		SECURITY:
			return "This update failed its security check, so it won't install. Your connection isn't the problem. The toolkit checks again the next time you open the editor."
		STORE_WRITE:
			return "Couldn't save update security data to %s. Make sure you can write to that folder, then click Update to try again." % store_folder
		NO_DATA_FOLDER:
			return "This update can't install here because your system doesn't set %s, so the toolkit has nowhere to save its update security data. Set that variable and reopen the editor." % ("APPDATA" if OS.has_feature("windows") else "HOME")
	return ""

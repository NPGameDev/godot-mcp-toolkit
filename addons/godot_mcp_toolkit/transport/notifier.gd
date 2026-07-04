@tool
extends RefCounted
## Builds and sends the JSON-RPC result / error / notification frames to a peer,
## size-guarding results against the peer's send buffer; broadcasts a notification
## to a supplied set of authenticated peers. Shared by the editor server (Mode A)
## and the runtime autoload (Mode B), so it stays export-clean — no editor symbols,
## only WebSocketPeer / JSON / MCPToolkitError.

const JSONRPC_VERSION := "2.0"


## Sends a JSON-RPC result frame, guarding it against the peer's outbound buffer.
## A response larger than that buffer is rejected wholesale by the native WS path
## (no chunking) — without the guard it would vanish silently and the bridge would
## see a hung request. guard_response_size swaps it for a compact, deliverable
## RESPONSE_TOO_LARGE error so the caller learns to narrow/paginate. max_bytes is
## the peer's own buffer (set at accept), so this needs no ProjectSetting read.
## log_prefix tags the send-failure warning with the calling server's name.
static func send_result(peer: WebSocketPeer, id, result, log_prefix: String) -> void:
	var response := {
		"jsonrpc": JSONRPC_VERSION,
		"id": id,
		"result": result,
	}
	response = MCPToolkitError.guard_response_size(response, peer.outbound_buffer_size)
	var send_err := peer.send_text(JSON.stringify(response))
	if send_err != OK:
		push_warning("%s send_text failed for id %s (err %d) - response not delivered" % [log_prefix, str(id), send_err])


## Sends a JSON-RPC error frame. Not size-guarded: error frames are compact by
## construction, so there is nothing to truncate.
static func send_error(peer: WebSocketPeer, id, code: int, error_message: String) -> void:
	var response := {
		"jsonrpc": JSONRPC_VERSION,
		"id": id,
		"error": {
			"code": code,
			"message": error_message,
		},
	}
	peer.send_text(JSON.stringify(response))


## Sends a JSON-RPC notification frame (no id) to one peer, skipping a peer that
## is not OPEN. A notification carries no request id, so a too-large frame can't be
## answered with an error — at minimum surface a send failure so an over-buffer
## notification is never silently dropped. log_prefix tags that warning.
static func send_notification(peer: WebSocketPeer, method: String, params: Dictionary, log_prefix: String) -> void:
	if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var send_err := peer.send_text(JSON.stringify({
		"jsonrpc": JSONRPC_VERSION,
		"method": method,
		"params": params,
	}))
	if send_err != OK:
		push_warning("%s notification '%s' send_text failed (err %d)" % [log_prefix, method, send_err])


## Broadcasts a config-change notification to every OPEN peer in authed_peers,
## carrying no request id (callers reload their tool list, not answer a request).
## Uses the dock-broadcast envelope ({notification, params?}), distinct from the
## per-request send_notification envelope. Returns the number of peers a frame was
## sent to, so the caller can log a summary. A too-large frame can't be answered
## with an error here either — surface a send failure so a dropped frame is visible.
static func broadcast(authed_peers: Array, notification_type: String, params: Dictionary, log_prefix: String) -> int:
	var payload := {"notification": notification_type}
	if not params.is_empty():
		payload["params"] = params
	var message := JSON.stringify(payload)
	var count := 0
	for peer in authed_peers:
		if peer is WebSocketPeer and peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			# Cast: the loop var is Variant (caller-supplied Array element), so the
			# call needs a typed receiver for the Error return.
			var send_err := (peer as WebSocketPeer).send_text(message)
			if send_err != OK:
				push_warning("%s broadcast '%s' send_text failed (err %d)" % [log_prefix, notification_type, send_err])
			count += 1
	return count

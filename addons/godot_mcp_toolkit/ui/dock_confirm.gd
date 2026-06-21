@tool
extends RefCounted
## Self-freeing confirmation-dialog factory for the dock.
##
## A stateless `static func` helper (no instance). The dock's two yes/no
## confirm flows (clear-audit, overwrite-.mcp.json) build the same
## ConfirmationDialog shape; this is the single place that shape — and the
## self-free guarantee — lives.


# Toast/severity-free by design: the factory only builds + shows the dialog and
# runs the caller's confirm/cancel callbacks. Any toast a flow needs is emitted
# from within its own callback (the caller's concern, not the factory's).


## Builds a ConfirmationDialog, pops it centered on the editor base control, and
## frees it on EVERY dismissal — OK runs `on_confirm`, Cancel/Esc/✕ runs
## `on_cancel` (if given) — then `queue_free()`s itself. No caller cleanup is
## needed: the self-free is baked in here so no call site can leak the dialog.
##
## `cancel_text` empty → keep the default "Cancel" button label. `on_cancel`
## empty → dismiss-and-free only (the plain "are you sure?" case).
##
## The engine routes the window-close (✕) and Esc through the same `canceled`
## signal as the Cancel button (AcceptDialog::_cancel_pressed), so connecting
## `confirmed` + `canceled` covers all three dismissal paths.
static func confirm(
		title: String,
		body: String,
		ok_text: String,
		on_confirm: Callable,
		cancel_text: String = "",
		on_cancel: Callable = Callable()) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.exclusive = false
	dialog.title = title
	dialog.dialog_text = body
	dialog.ok_button_text = ok_text
	if not cancel_text.is_empty():
		dialog.cancel_button_text = cancel_text
	dialog.confirmed.connect(func() -> void:
		if on_confirm.is_valid():
			on_confirm.call()
		dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void:
		if on_cancel.is_valid():
			on_cancel.call()
		dialog.queue_free()
	)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()

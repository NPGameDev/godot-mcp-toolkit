@tool
extends RefCounted
## Presents an editor popup dialog: opens it centered and raises it to the front.
##
## A non-exclusive editor dialog sinks behind the main viewport the moment the
## viewport is clicked; re-triggering its opener button would then re-render the
## already-open-but-hidden window and feel unresponsive. Routing every
## button-opened dialog through this one place keeps that raise consistent:
## grab_focus() both raises and focuses, and — unlike move_to_foreground, which
## is deprecated in 4.6+ — is bound and non-deprecated across every supported
## engine version.


## Pops [param dialog] centered and raises it to the foreground. Pass an explicit
## [param size] for reused dialogs: a no-arg popup_centered reuses the window's
## current size (grow-only across reopens), so a reused dialog drifts without one.
static func present(dialog: Window, size: Vector2i = Vector2i.ZERO) -> void:
	if size == Vector2i.ZERO:
		dialog.popup_centered()
	else:
		dialog.popup_centered(size)
	dialog.grab_focus()

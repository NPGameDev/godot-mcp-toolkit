@tool
extends RefCounted
## Signal bus for gate/profile state changes.
##
## Decouples the dock UI from feature_gate_settings (PS manager).
## Both subscribe to the signals they care about; neither calls methods
## on the other directly.  Adding a third consumer (telemetry, status
## bar, notification toasts) is just another .connect().

## Emitted after gate or profile state changes — subscribers refresh
## their feature-toggle UI (checkboxes, PS bools, lock warnings).
signal features_changed()

## Emitted after profile or .mcp.json state changes — subscribers
## refresh their status labels (power-user warning, mcp.json hint).
signal status_changed()

## Emitted after .mcp.json env vars are written — tells the MCP server
## to broadcast a config_reloaded notification to connected TS bridges.
signal config_reloaded()

## Emitted when the user tries to toggle a gate in a locked profile.
signal profile_lock_warning(profile: int)

## Emitted by the dock after it applies a profile switch, so the PS
## manager can acknowledge it and avoid re-triggering from its poll loop.
signal profile_acknowledged(profile: int)

## Emitted after a gate-toggle toast is shown. Listeners (future status
## bar, telemetry) can react without coupling to the notifier.
signal gate_toast_requested(msg: String, severity: int)

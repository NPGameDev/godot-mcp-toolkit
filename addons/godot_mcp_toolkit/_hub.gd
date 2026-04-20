@tool
extends RefCounted
## Centralized preloads for plugin-internal scripts.
##
## Every file that needs MCPError, MCPCoerce, or MCPCommandRegistry preloads
## this hub and re-aliases the constants it needs. Script paths live here only
## — if a file moves, update this file and nothing else.

const MCPError := preload("res://addons/godot_mcp_toolkit/mcp_error.gd")
const MCPCoerce := preload("res://addons/godot_mcp_toolkit/_coerce.gd")
const MCPCommandRegistry := preload("res://addons/godot_mcp_toolkit/command_registry.gd")
const MCPFileGuard := preload("res://addons/godot_mcp_toolkit/file_guard.gd")
const MCPUntrusted := preload("res://addons/godot_mcp_toolkit/untrusted.gd")
const MCPFeatureRegistry := preload("res://addons/godot_mcp_toolkit/feature_registry.gd")
const MCPFeatureGate := preload("res://addons/godot_mcp_toolkit/feature_gate.gd")
const MCPScrubber := preload("res://addons/godot_mcp_toolkit/scrubber.gd")
const MCPAudit := preload("res://addons/godot_mcp_toolkit/audit.gd")
const MCPRegistryClient := preload("res://addons/godot_mcp_toolkit/registry_client.gd")

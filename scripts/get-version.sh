#!/usr/bin/env bash
# Extract the version from plugin.cfg (used by CI to validate version sync).
grep '^version=' addons/godot_mcp_toolkit/plugin.cfg | cut -d'"' -f2

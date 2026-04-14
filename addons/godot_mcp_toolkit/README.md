# Godot MCP Toolkit

This plugin runs a localhost (`127.0.0.1:6505`) WebSocket server inside the Godot editor so Claude Code can drive scene / node / script operations via MCP.

## Enable

Project Settings → Plugins → tick **Godot MCP Toolkit**.

## Companion bridge

You also need the TypeScript MCP server from the separate `godot-mcp-server` npm package:

```
npm install -g godot-mcp-server
```

## Connect Claude Code

Copy `addons/godot_mcp_toolkit/.mcp.json.template` up one level into your project root and rename it to `.mcp.json`. Then `cd` to your project root and run `claude` — `/mcp` should list `godot-mcp-toolkit` once the editor and plugin are running.

(Iter 21+ adds a one-click menu item in the editor's MCP dock that writes this file for you.)

## Minimum Godot version

Godot 4.3+. See the [repo root README](../../README.md) for the full stack overview.

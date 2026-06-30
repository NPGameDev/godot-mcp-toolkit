# AGENTS.md

Guidance for AI coding agents working in this repository. This is the
tool-agnostic doc map; Claude Code reads the fuller, Claude-specific
[`CLAUDE.md`](CLAUDE.md) instead.

This repo is the **Godot MCP Toolkit** — a Godot 4.2+ editor plugin written in
GDScript. The repo root is also a Godot project used for development; the shipped
plugin lives under `addons/godot_mcp_toolkit/`.

## Read these first

Read in order before making changes:

1. [`docs/architecture/README.md`](docs/architecture/README.md) — subsystems,
   the editor/runtime split, and the transport, with diagrams.
2. [`docs/dev/code-standards.md`](docs/dev/code-standards.md) — GDScript style,
   naming, and comment conventions. Follow these for all code you write.
3. [`docs/dev/contract.md`](docs/dev/contract.md) — the request/response and
   transport contract between the toolkit and the server (the toolkit owns it).
   Read before touching dispatch, command results, or the WebSocket protocol.
4. [`docs/dev/glossary.md`](docs/dev/glossary.md) — the project's shared
   vocabulary.
5. [`docs/adr/`](docs/adr/) — architecture decision records: the rationale
   behind the larger design choices.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for environment setup, how to run
checks, the commit format, and the pull-request checklist.

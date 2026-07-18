---
title: Documentation
permalink: /
nav_order: 1
---

# Godot MCP Toolkit — Documentation map

Every documentation surface of this repository, organized by what you want to
do. Shipped docs (under `addons/godot_mcp_toolkit/docs/`) travel with the addon
into your project; everything else lives here on GitHub.

## Use it

- [Root README](../README.md) — what the toolkit is, quickstart, security
  overview, and known limitations. Start here.
- [Compatibility](../addons/godot_mcp_toolkit/docs/compatibility.md) (shipped) —
  supported Godot versions, per-version tool behavior, headless mode, C#
  requirements, and export stripping.
- [Troubleshooting](troubleshooting.md) — the 60-second checklist, a
  connectivity probe, and symptom-to-fix entries for the common failure modes.
- [Security recommendations](../addons/godot_mcp_toolkit/docs/security-recommendations.md)
  (shipped) — per-tool risk notes and recommended client-side permission rules.
- [Advanced configuration](../addons/godot_mcp_toolkit/docs/advanced_configuration.md)
  (shipped) — ports, limits, environment variables, and platform-specific setup.
- [Multi-instance](../addons/godot_mcp_toolkit/docs/multi-instance.md) (shipped)
  — running several editors or git worktrees side by side.

## Extend it

- [Extending the toolkit](../addons/godot_mcp_toolkit/docs/extending.md)
  (shipped) — the extension API: register your own MCP commands in GDScript,
  with hot-reload, timeouts, and cancellation.
- The **mcp-extension-creator** companion skill
  (`addons/godot_mcp_toolkit/CompanionSkills/mcp-extension-creator/`) — a Claude
  Code skill that walks an agent through building an extension.
- [Testing your extension](testing-locally.md#testing-an-extension) — how to
  validate extension tools end-to-end, sweep-style and smoke-style.

## Contribute to it

- [CONTRIBUTING](../CONTRIBUTING.md) — environment setup, checks, commit
  format, the PR checklist, and the documentation rules.
- [Testing locally](testing-locally.md) — every test layer, when to run it, and
  how to add coverage for a new tool.
- [Architecture](architecture/README.md) — subsystems, the editor/runtime
  split, transport and contract surface, with diagrams.
- [Code standards](dev/code-standards.md) — GDScript style, naming, typing, and
  the editor-plugin hard gates.
- [Contract](dev/contract.md) — the request/response and transport contract
  between the toolkit and the server (the toolkit owns it).
- [Glossary](dev/glossary.md) — the project's shared vocabulary.
- [ADRs](adr/) — architecture decision records.

## Who owns what

The toolkit and the server document some topics jointly. One repo is canonical
per topic; the other summarizes and links:

| Topic | Canonical owner | The other repo does |
|---|---|---|
| Security model | **toolkit** — shipped `security-recommendations.md` + repo `SECURITY.md` (policy) | server SECURITY.md mirrors policy; README summarizes + links |
| Client setup | **server** — `docs/mcp-clients.md` (GitHub) | toolkit README links it |
| Token efficiency | **server** — `docs/token-efficiency.md` (GitHub) | toolkit cites the headline figure + links |
| Compatibility | **toolkit** — shipped `addons/godot_mcp_toolkit/docs/compatibility.md` + Info-panel `res://` entry | server links the shipped doc on GitHub |
| Troubleshooting | **toolkit repo `docs/troubleshooting.md`** (GitHub, NOT shipped) — pinned URL below | server links the SAME URL; no server twin, no shipped copy |
| Tool reference | **server** — generated `docs/tool-reference/` | toolkit links it |
| Architecture | each repo its own `docs/architecture/README.md` | cross-link |

The pinned troubleshooting URL — link this exact address from both repos:

```
https://github.com/NPGameDev/godot-mcp-toolkit/blob/main/docs/troubleshooting.md
```

**Where a doc goes.** A doc ships inside `addons/godot_mcp_toolkit/docs/` only
if the in-editor UI opens it through a `res://` path (it is consulted while
working in a project) or it must legally travel with the addon. Everything else
is a repo doc here on GitHub, linked by URL. See the
[Documentation section of CONTRIBUTING](../CONTRIBUTING.md#documentation) for
the full rules, including the generated files you must never hand-edit.

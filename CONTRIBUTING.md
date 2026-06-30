# Contributing to Godot MCP Toolkit

Thank you for your interest in contributing! This guide covers everything you
need to get started.

## Prerequisites

- **Godot 4.2+** (4.4+ recommended)
- **Node.js >= 20** (for the companion server)
- **Git**

This project spans three repositories that live as siblings on disk:

| Repo | What it is |
|------|-----------|
| [`godot-mcp-toolkit`](https://github.com/NPGameDev/godot-mcp-toolkit) (this repo) | Godot editor plugin (GDScript) |
| [`godot-mcp-server`](https://github.com/NPGameDev/godot-mcp-server) | TypeScript MCP bridge (npm package) |
| [`godot-mcp-creation`](https://github.com/NPGameDev/godot-mcp-creation) | Execution plan and design docs |

Clone all three as siblings:

```bash
git clone https://github.com/NPGameDev/godot-mcp-toolkit.git
git clone https://github.com/NPGameDev/godot-mcp-server.git
git clone https://github.com/NPGameDev/godot-mcp-creation.git  # optional, for plan context
```

## Dev environment setup

### 1. Build the server

```bash
cd godot-mcp-server
npm install
npm run build
```

### 2. Open the toolkit in Godot

This repo root IS a Godot project (`project.godot` at root). Open it in Godot
4.4+, then enable the plugin:

**Project Settings -> Plugins -> "Godot MCP Toolkit" -> Active**

Leave the editor running while you work. The plugin runs a localhost WebSocket
server that the MCP bridge connects to.

### 3. Verify the connection

```bash
cd godot-mcp-server
npm run smoke
```

The smoke test port-checks `127.0.0.1:6550`. If nothing is listening, it prints
instructions and exits. Make sure the Godot editor is running with the plugin
enabled.

## Running checks

### GDScript validation

After editing any `.gd` file, run:

```bash
godot --headless --check-only --path <toolkit-repo-root>
```

This catches syntax errors without launching the full editor.

### Server-side linting and formatting

```bash
cd godot-mcp-server
npm run lint         # ESLint check
npm run format       # Prettier check
npm run format:fix   # auto-fix formatting
```

### Smoke test

```bash
cd godot-mcp-server
npm run smoke        # single-pass: all tools always available
npm run smoke:single # single pass (inherits your env vars)
```

The Godot editor must be running with the plugin enabled for smoke tests to pass.

## Dependency policy

All npm dependencies use **exact** versions (no `^` or `~` prefixes). This
ensures reproducible installs. Dependency updates are deliberate PRs, not
silent drift from caret ranges. When adding a dependency, pin it:

```bash
npm install --save-exact some-package
```

## Code standards

This repo ships its own coding standards and a cross-repo contract. Read them
before writing code — they are the authoritative references for how toolkit code
should look and behave. New to the codebase? Read these in order:

1. [`docs/architecture/README.md`](docs/architecture/README.md) — the
   subsystems, the editor/runtime split, and the transport, with diagrams. Start
   here for the big picture.
2. [`docs/dev/code-standards.md`](docs/dev/code-standards.md) — GDScript style,
   naming, static typing, and comment conventions, plus the editor-plugin hard
   gates every contribution must respect.
3. [`docs/dev/contract.md`](docs/dev/contract.md) — the request/response and
   transport contract between the toolkit and the server. The toolkit owns this
   contract; read it before touching dispatch, command results, ports, or the
   WebSocket protocol.
4. [`docs/dev/glossary.md`](docs/dev/glossary.md) — the shared vocabulary used
   throughout the code and docs.
5. [`docs/adr/`](docs/adr/) — architecture decision records: the rationale
   behind the larger design choices.

## Submitting changes

### Branch naming

Use descriptive branch names: `feat/add-x`, `fix/crash-on-y`,
`docs/update-readme`.

### Commit format

We use [Conventional Commits](https://www.conventionalcommits.org/). One commit
per logical change.

```
<type>(<scope>): <imperative description>
```

**Types:** `feat`, `fix`, `refactor`, `docs`, `chore`, `test`, `build`

**Scopes:** `plugin`, `tools`, `config`

**Examples:**
- `feat(plugin): add tilemap batch-paint command`
- `fix(tools): handle null scene root in scene_get_tree`
- `docs(config): update .mcp.json template`

### Pull request checklist

- [ ] `godot --headless --check-only` passes (if GDScript changed)
- [ ] Smoke test passes (`npm run smoke` in server repo)
- [ ] Code follows the [coding standards](docs/dev/code-standards.md)
- [ ] Contract changes (dispatch, command results, transport) are reflected in [`docs/dev/contract.md`](docs/dev/contract.md)
- [ ] No unrelated changes included
- [ ] Commit message follows Conventional Commits format
- [ ] CHANGELOG.md updated if user-facing

### What makes a good PR

- **Small and focused.** One feature or fix per PR.
- **Tested.** Describe how you verified the change works.
- **Documented.** Update CLAUDE.md or inline comments if behavior changes.

## Architecture overview

For an in-depth, up-to-date explanation of the toolkit's subsystems, the
editor/runtime split, the transport, and the key design decisions, read the
in-repo architecture document:

[`docs/architecture/README.md`](docs/architecture/README.md)

It renders on GitHub with diagrams inline and is the canonical reference for how
the toolkit fits together.

## Code of conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md).
Please read it before participating.

## Questions?

Open a [discussion](https://github.com/NPGameDev/godot-mcp-toolkit/issues) or
file an issue. We're happy to help.

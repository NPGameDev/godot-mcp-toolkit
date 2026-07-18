---
title: Testing locally
permalink: /testing-locally/
nav_order: 4
---

# Testing locally

How to validate toolkit changes before submitting a PR: every test layer, what
it catches, and when to run it. For runtime symptoms and their fixes (port
collisions, cache corruption, platform quirks), see
[troubleshooting.md](troubleshooting.md) — this guide covers the workflow only.

## Environment setup

- A standard **Godot 4.2–4.7 editor build**. The .NET/mono build is not needed
  for toolkit development — it only matters when you test against a C# game
  project.
- `godot` is usually **not on your `PATH`**. Every command below that runs Godot
  takes the editor binary explicitly — as the `GODOT_BIN` environment variable
  or a script argument. On Windows, prefer the `_console` variant of the editor
  executable so script output reaches your terminal.
- The repo root is itself a Godot project. Open it in the editor, then enable
  the plugin: **Project Settings → Plugins → "Godot MCP Toolkit" → Active**. The
  MCP dock appears in the bottom panel; its status section shows the WebSocket
  server state.

## Static analysis: `validate_gdscript.sh`

Run after editing any `.gd` file:

```bash
GODOT_BIN=/path/to/godot-editor-binary \
  bash scripts/test_framework/validate_gdscript.sh
```

The script loads the full editor headless and compiles every project script, so
it catches cross-file errors (`class_name` resolution, coroutine propagation,
type mismatches) that a per-file syntax check cannot. It times itself out, so a
hung editor will not hang your terminal.

Two rules:

- **The first argument is the Godot binary, not a file to check.** If you pass a
  `.gd` path as the first argument, no Godot runs and the script reports a
  meaningless "PASS". Pass the binary (or set `GODOT_BIN`); the script always
  validates the whole project.
- **One instance at a time.** Two Godot processes opening the same project fight
  over the project lock (reliably so on Windows). Never run two validations, or
  a validation and a unit run, simultaneously.

Do not use `godot --headless --check-only` as a substitute: without `--script`
it validates nothing and exits successfully, which reads as a pass.

## Unit tests (headless, no editor window)

```bash
GODOT_BIN=/path/to/godot-editor-binary \
  bash -c '"$GODOT_BIN" --headless --script test/run_unit_tests.gd'
```

The runner executes every test group and reports per-group results. It needs a
**warm global class cache**: the bare `--script` runner does not scan the
project, so on a fresh clone (or after deleting `.godot/`) class names fail to
resolve with parse errors. Run `validate_gdscript.sh` first — its editor pass
scans the project and warms the cache — or open the editor once. Same
one-process-at-a-time rule as above.

## Tool sweep (interactive, editor required)

The sweep exercises every registered tool end-to-end from an MCP client: happy
path, guard rejections, parameter edge cases, and hint quality. It is driven
from markdown content-maps, not from a script:

- [`Validations/tool-sweep.md`](../Validations/tool-sweep.md) — the index.
- `Validations/Sections/NN-*.md` — the per-domain instructions an agent
  executes against a live editor.
- [`Validations/SWEEP-COVERAGE-MANIFEST.md`](../Validations/SWEEP-COVERAGE-MANIFEST.md)
  — maps every tool to its sweep coverage (test numbers, guards, combo chains,
  hint checks).

When you add a tool or change a parameter, add sweep entries per
[`Validations/SWEEP-MAINTENANCE-PROTOCOL.md`](../Validations/SWEEP-MAINTENANCE-PROTOCOL.md)
and update the manifest. The sweep is interactive by design — an agent runs the
maps and judges responses; there is no automated driver for it.

## Interactive verification

Some changes need human-in-the-loop verification in a real session: UI changes
(dock, wizard, dialogs), editor mutations you want to see land in the scene
tree, and runtime tools against a running game. Open the repo-root project in
the editor, connect your MCP client (the repo root carries a `.mcp.json`, so
launching `claude` from the repo root connects), and exercise the changed
surface directly.

## Adding a new tool — checklist

1. Register the command handler in the toolkit (`addons/godot_mcp_toolkit/commands/`).
2. Add sweep entries and update the sweep manifest (protocol above).
3. Add a smoke-test section server-side (the server repo's `test/sections/` and
   its `test/SMOKE-COVERAGE-MANIFEST.md` — see the server repo's testing guide).
4. Run `validate_gdscript.sh`.
5. Verify the tool interactively in the editor.

## Testing an extension

Extensions register project-specific MCP commands in GDScript (see the shipped
[`extending.md`](../addons/godot_mcp_toolkit/docs/extending.md)). Two
complementary approaches, mirroring how the built-in tools are tested:

### Sweep-style: a content-map for your extension

Write a markdown content-map in the sweep style (an index plus per-tool
sections, like `Validations/tool-sweep.md` and `Validations/Sections/`): for
each extension tool, list the happy-path call, the guard rejections you expect,
parameter edge cases, and the hints the responses should carry. Then have an
agent (or yourself) execute it against a live editor: call the tool, check the
response shape, note pass/fail per case. A small local GDScript driver you
write yourself works too — the pattern is the same: call, assert the response
shape, log the result.

### Smoke-style: a server-side section

If you want protocol-level validation, add a section to the server repo's smoke
suite. Sections live in `test/sections/` and are plain objects the harness
(`test/harness.ts`) runs — it handles port discovery and token auth for you, so
a minimal section is just the calls and assertions:

```ts
import type { TestCtx } from "../helpers.js";
import { CALL_TIMEOUT } from "../helpers.js";

export const TOOLS_TESTED: string[] = ["<your_tool_name>"];

export async function testMyExtension(ctx: TestCtx): Promise<void> {
  const { bridge, pass, fail } = ctx;
  const result = (await bridge.call(
    "<your_command_name>",
    { some_param: "value" },
    CALL_TIMEOUT,
  )) as { code?: string };
  if (result && !result.code) {
    pass("my extension: happy path");
  } else {
    fail(`my extension: unexpected ${JSON.stringify(result)}`);
  }
}
```

Register the section in the suite's section list, then run it in isolation with
`npm run smoke:single -- --only <N>` (from the server repo, editor running with
your extension loaded). The server repo's `docs/testing-locally.md` carries the
fuller template and the `--only` mechanics.

### Extension author checklist

1. Register the tool in your extension.
2. Write the sweep-style content-map entries.
3. Add a smoke-style section if you want protocol-level coverage
   (server-side).
4. Validate your GDScript: run this repo's
   `scripts/test_framework/validate_gdscript.sh` from your project's root (it
   validates whichever project it is run from — your extension is project
   GDScript like any other).
5. If you touched server-side code, `npm run build` in the server repo.
6. Verify interactively in the editor.

## When something fails

Runtime symptoms — the editor will not bind its port, log tools return busy,
the client will not connect, caches corrupt after a branch switch — live in
[troubleshooting.md](troubleshooting.md), one entry per symptom. This guide
stays with the workflow.

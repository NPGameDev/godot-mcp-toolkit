# Contributing to Godot MCP Toolkit

Thank you for your interest in contributing! This guide covers everything you
need to get started.

## Prerequisites

- **Godot 4.2+** (4.4+ recommended)
- **Node.js >= 22** (for the companion server)
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

For the full local workflow — every test layer, when to run it, the environment
each layer needs, and the common failure modes — see
[`docs/testing-locally.md`](docs/testing-locally.md). The essentials:

### GDScript validation

After editing any `.gd` file, run:

```bash
bash scripts/test_framework/validate_gdscript.sh
```

Pass the Godot editor binary as the `GODOT_BIN` environment variable or as the
first argument — `godot` is not assumed to be on `PATH`. The script loads the
full editor headless and compiles every project script, so it catches cross-file
`class_name` errors a per-file check would miss. Run one instance at a time.

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

## Continuous integration

CI runs in two tiers, plus a release path. The authoritative detail (job shapes,
the sibling-pin ritual, the 4.2 class-cache warm-up mechanics) lives in the header
comments of each workflow under `.github/workflows/` — this is the
contributor-facing summary.

- **Floor — gates every push and PR** (`ci.yml`). **Static validation**
  (`validate_gdscript.sh`, editor-headless) runs on the 4.3.0 + 4.7.0 boundary
  versions, and the **unit suite** runs on all six supported versions (Godot
  **4.2.0 through 4.7.0**, including the 4.2 cold class-cache warm-up) — a real
  execution signal on every version, every push. A single aggregate job,
  **`Toolkit floor OK`**, `needs:` the whole floor — that one name is what a
  required check binds to, never an individual matrix row. Green floor is a merge
  precondition.
- **Deep tier — opt-in** (`cross-version.yml`). The full **two-editor behavioral
  matrix** — GDScript-editor and .NET/mono-editor, Godot **4.2 through 4.7** —
  boots a real headless editor and round-trips the complete smoke + flows suites
  through the WebSocket bridge, plus a **dispatch-integration** leg on one row and
  a mono-editor unit leg on the two boundary flavors (4.2.0 + 4.7.0). It does not
  run on a plain push. Trigger it by putting **`[run-cross-version-ci]`** in your
  commit message, via **`workflow_dispatch`** (optionally with a `sibling-ref`
  override), or automatically as part of a release (below).
- **Release** (`release.yml`). A **`v*` tag push** first runs the deep behavioral
  matrix (the zip job `needs:` it — a cross-version regression can never ship),
  then builds the plugin zip, **install-smokes the actual artifact** (unzips it
  into a scratch project and boots a headless editor to prove the plugin enables),
  and uploads it as a GitHub Release. You can rehearse the whole path without
  releasing by running `release.yml` via **`workflow_dispatch`** — it is a
  **dry-run** by default (everything runs; the Release upload is skipped).

The behavioral tier is **mirrored in both repos** (toolkit and server): each side
runs the full two-editor matrix against a pinned SHA of the other, so an opt-in run
in either repo proves the whole GDScript + .NET contract for that repo's change. It
is opt-in only and driven by one shared composite action, so the mirror costs
nothing when idle and cannot drift between the two repos.

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

## Compatibility engineering

The end-user compatibility reference (version tiers, per-tool matrices, degraded
behavior) ships with the addon at
[`addons/godot_mcp_toolkit/docs/compatibility.md`](addons/godot_mcp_toolkit/docs/compatibility.md).
This section covers the contributor side: how the cross-version support is
implemented and what constraints it puts on new code.

### Version guard implementation

All version-dependent API calls use **dynamic dispatch** to avoid GDScript
static-resolution parse errors:

```gdscript
# Safe — has_method() + call() bypasses static resolution
if EditorInterface.has_method("close_scene"):
    EditorInterface.call("close_scene")

# UNSAFE — direct call causes parse error on older Godot even inside dead branch
if Engine.get_version_info().minor >= 5:
    EditorInterface.close_scene()  # ERROR on 4.4: method not found at parse time
```

Centralized version helpers in `core/modules.gd`:
- `Modules.VersionUtils.is_at_least(ver, min)` / `is_at_most(ver, max)` — single-bound version checks
- `Modules.VersionUtils.is_version_in_range(ver, min, max)` — range version check (used by command registry)
- `Modules.get_undo_redo()` — returns the editor `EditorUndoRedoManager` via the
  stored `EditorPlugin` (4.0+ stable; works on all supported versions). Returns
  `null` only in headless mode or before the plugin is set. Operations registered
  through it create Edit > Undo history; direct property mutations bypass history.
- `Modules.get_toaster()` — returns `EditorToaster` or `null` on < 4.4
  (`EditorInterface.get_editor_toaster()` is 4.4+)
- `Modules.get_editor_theme()` — returns the editor theme. Uses
  `EditorInterface.get_editor_theme()`, which is bound on all supported versions
  (4.2+); the `get_base_control().get_theme()` fallback only mattered on the
  unsupported 4.0/4.1 and never triggers on 4.2+

**Bare static-method `Callable` — 4.2 NIL-self abort.** Don't form a `Callable` from a bare
static-method reference. On Godot **4.2 only**, the compiler binds a bare member-function
reference to `SELF`; inside a `static` function `SELF` is `NIL`, so the call silently aborts
(`Invalid get index '<method>' (on base: 'Nil')`) and returns a typed-default value **with no
error propagated** — a silent wrong result on 4.2, correct on 4.3+. Fixed upstream between 4.2
and 4.5 (`gdscript_compiler.cpp` SELF→CLASS for static members). **Instead:** pass the resolved
value directly (e.g. the `Node`), or inject an instance method. Guarded by a headless 4.2 unit
test (`test/units/signal_resolver_tests.gd`).

### Server-side version awareness

The plugin sends its Godot version in the WebSocket auth handshake. The
companion `@npgamedev/godot-mcp-server` uses this to:

1. **Runtime gating** — tools with a `godotMinVersion` requirement (e.g.
   `scene_close` requires 4.5+) return an `UNSUPPORTED` error before the
   call reaches the plugin. Defence-in-depth: the plugin also checks.
2. **Startup logging** — the server logs the connected Godot version.

Environment variable `GODOT_MCP_HIDE_UNAVAILABLE=1` is reserved for future
use (hiding version-incompatible tools from `tools/list`).

### CI limitations

CI runs `scripts/test_framework/validate_gdscript.sh` (editor-headless +
per-file script runner) on Godot 4.3+. **Godot 4.2 is excluded from this
static-validation matrix** because its editor scan aborts on `class_name`
cross-references before completing — all detected errors are false
positives, not real script problems. This is a chicken-and-egg bug in
Godot 4.2's GDScript module (fixed in 4.3): the scanner needs the class
cache to resolve `class_name` identifiers, but the class cache is built
by the scan. Both standard and .NET editor builds have the same issue.

**Godot 4.2 unit tests DO run in CI**, via the floor `unit-tests` job
(`.github/workflows/ci.yml`, a 4.2-4.7 matrix using the `godot-units` composite
action). On the 4.2 leg it warms the global class
cache with a background editor-scan boot gated on the cache artifact itself
(a frame-count quit races the threaded scan, and `--import` cannot warm
4.2.0 — it hangs without writing the cache, an engine bug fixed by 4.2.2),
tolerating the transient `class_name` errors, then runs the headless unit
suite and gates on the unit runner's exit code, so 4.2 gets a real execution
signal on every push/PR. A clean cross-file `class_name` *static* validation
still cannot run on 4.2 (that is the 4.3 analyzer fix) — the 4.2 CI signals
are unit execution (floor) and the behavioral run below.

**Godot 4.2 also runs the behavioral CI tier**: the cross-version workflow's
smoke + flows matrix (`.github/workflows/cross-version.yml`) includes 4.2
alongside 4.3–4.7, with a 4.2-only class-cache warm-up step before the editor
launch (same editor-scan warm-up as the unit job). The interactive
tool sweep stays local (mandatory on large toolkit iterations, optional on
medium ones).

> **Validation vocabulary.** **SWEEP** = the toolkit's interactive, GDScript
> tool-exercise suite (`Validations/`, not run in CI). **SMOKE** = the server's
> automated, WS-behavioral suite (`godot-mcp-server` `test/sections/`, the CI
> cross-version tier). Both exercise the tools; only SMOKE runs in CI.

### Future development constraints

- **Typed for loops** (`for x: Type in arr:`) require Godot 4.2+. Used in
  `extension_loader.gd`. Safe at current minimum.
- **Typed dictionaries** (`Dictionary[K, V]`) require Godot 4.4+. Not
  currently used in the codebase. If the minimum supported version remains
  4.2, this syntax must not appear in any `.gd` file.
- **`@export_tool_button`** requires Godot 4.4+. Same constraint.
- **`@abstract`** requires Godot 4.5+. Same constraint.
- **`EditorDock`** (new in 4.6) hosts the toolkit dock on 4.6+ via
  `EditorPlugin.add_dock()` (`core/dock_host.gd`, capability-gated on
  `ClassDB.class_exists("EditorDock")` — never referenced statically, which
  would parse-error on 4.2–4.5). On 4.2–4.5 the plugin uses the legacy
  `add_control_to_bottom_panel()`; that path is deprecated from 4.6 and
  renders a collapsed (invisible) panel on 4.7, which is why the gate adopts
  `add_dock` from 4.6.

## Documentation

Documentation is part of the product, so a change to behavior is not done until
the docs match. A few rules keep the docs accurate and consistent.

### Where a doc goes

Godot's Asset Library installs only `addons/godot_mcp_toolkit/**` into a user's
project, so most of the repo never reaches an end user. Decide placement by
*where the doc is consulted*, not by who reads it:

- Ship a doc into `addons/godot_mcp_toolkit/docs/` **only if** the in-editor UI
  opens it through a `res://` path (it is read while working inside a project) or
  it must legally travel with the addon (the attributions file). Shipped docs
  must be self-contained — no links to repo-root files, the plan, or internal
  paths, because those do not travel.
- Everything else — the front door and anything that evolves between releases —
  is a repo doc under `docs/` on GitHub, linked by URL from the Info panel, error
  hints, or the READMEs.

### Files you never hand-edit

Some documentation is generated from the code and will be overwritten:

- The server repo's `docs/tool-reference/` and `docs/api/` are generated from the
  server's tool catalogue and its TSDoc. Link to them; never copy their contents
  into another doc, and never edit them by hand. They regenerate with the
  server's own prompt-free scripts (`npm run docs:tools`, `npm run docs:api`, and
  `npm run measure:tokens` for the token figures) — never a bare `npx`.
- The architecture document's diagrams carry a `data-verified` provenance comment
  recording the commit they were last checked against. If you change a subsystem a
  diagram depicts, update the diagram and bump its `data-verified` stamp.
- Screenshots carry a provenance comment above the embed (the version, Godot
  build, and date they were captured). Keep it current when you replace an image.

### When you add a doc

Add it to the documentation map in `docs/README.md` and to the "Read these first"
list in `AGENTS.md` so agents and contributors can find it. A doc that nothing
points at is a doc nobody reads.

### Numbers

A number appears in prose only if a generator emits it or CI asserts it. Counts
that are copied by hand drift; the counts that never drift are the ones a check
fails the build over. When you need to cite the tool count, the operation count,
or the token figures, take them from the generated tool reference or the
`--tools-count` output rather than typing a literal.

### Entry-point writing

The README, the shipped addon README, and the AssetLib and npm copy are the first
thing a prospective user sees, and in 2026 a README that reads as machine-written
reads as low-effort. Keep the register human:

- Plain section headers, not walls of emoji headers.
- No hype adjectives ("powerful", "seamless", "comprehensive") and no fragment or
  arrow-chain bullets — state what a thing does, in complete sentences, and show
  evidence.
- Vary the rhythm; not every section is three bullets. Let an important section
  run long and a minor one be a single line.
- No unfilled promises — no "docs coming soon", no placeholder for media that
  does not exist yet.
- Put a limitation beside the claim it qualifies, cite concrete numbers with their
  source, and prefer one real screenshot over stock art.
- Write sparingly with dashes and avoid invented hyphenated compounds; they are a
  tell of machine-written prose.

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

- [ ] `validate_gdscript.sh` passes (if GDScript changed)
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

## Versioning

We follow semver — see [RELEASING.md](RELEASING.md) for what constitutes
major/minor/patch. The toolkit and server are versioned **independently** (each
its own version and cadence), so a bump lands on whichever repo actually
changed. You do NOT need to bump versions in your PR — the maintainer handles
that at release time. However, please flag in your PR description if your change
is **breaking** (removes/renames a tool, changes a parameter schema) or if it
introduces a **cross-repo dependency** (a server change that needs a newer
toolkit, or vice versa), so it's versioned and floor-bumped correctly.

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

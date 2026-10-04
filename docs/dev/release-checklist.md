# Release checklist — Toolkit

The manual, interactive gate CI can't cover. **Copy this file per release**, tick each box as
you run it, and record each section's **gate disposition**: walked, skipped with a reason, or a
documented gap with an owner. CI covers static validation, unit execution, and the cross-version
behavioral matrix; this sheet covers the export-safety regressions, concurrent human+MCP editing,
the macOS GUI-launch smoke, and the dock ↔ Project Settings round-trip that need a real editor, a
real export, or a real Mac.

Each item is runnable from a clone of this repo. Use `$GODOT_BIN` for the console editor of
the version under test (e.g. `Godot_v<ver>-stable_win64_console.exe`), and install that
version's **export templates** first (Editor → *Manage Export Templates* → *Download and
Install*). Where a `Plan/…` path is cited it is the **full methodology in the planning repo** —
a secondary reference; the steps here are self-contained.

---

## 1. Export-safety regression (EX5–EX7) — BLOCKING

The toolkit must be invisible in exported games and must not error when shipped disabled.
Mandatory whenever a change touches the runtime autoload, `export_strip`, the dependency
graph, or the addon's shipped file set. Uses the committed **`CLI Test Build Windows`** preset
in `export_presets.cfg` (dogfood-only — not shipped in the addon). **Export to a temp dir
outside the repo** so artifacts are never committed.

> **Methodology gotcha (do not skip).** Judge what actually shipped by counting **`Storing
> File:` lines in the export log**, NOT a raw `grep -a` of the `.pck`:
> `global_script_class_cache.cfg` embeds every addon script path as plaintext and produces
> false "leaked" readings. In binary modes the addon/extension `.gdc` are **expected** to ship;
> assert the *warning* fires, non-script files + `.mcp.json` strip, and the launched build is
> **inert**. Full procedure: `Plan/ExecutionPlan/41l-untricies-export-strip-binary-tokens.md`
> and `…-bis-runtime-autoload-export-safety.md` (planning repo).

- [ ] **EX5 — Disabled-addon dangling-autoload export.** Edit `project.godot`: empty the
      `[editor_plugins] enabled=PackedStringArray()` line but **leave** the `[autoload]
      MCPRuntimeServer=...` line so it dangles. Export debug, launch headless, then restore:
  ```bash
  "$GODOT_BIN" --headless --path . --export-debug "CLI Test Build Windows" /tmp/out/game.exe
  /tmp/out/game.exe --headless 2>&1 | grep -c "SCRIPT ERROR: Parse Error"   # expect 0 (was 9 pre-fix)
  git restore project.godot
  ```
      **PASS:** zero `Parse Error` lines, runtime server inert, process exits 0.

- [ ] **EX6 — Binary-token script-leak warning** (`script_export_mode=2`, Godot 4.3+ default).
      Export and read the export log. **PASS:** `export_strip` warns, naming the addon + each
      leaked extension's exact `.gd` path; `.mcp.json` + non-script addon files are stripped;
      the launched build is inert (no `[MCPTools]` output, port 6570 not listening). The preset
      exclude-filter guard suppresses the warning when the addon is already excluded.

- [ ] **EX6b — Text-mode strip-clean** (`script_export_mode=0`, symmetric to EX6). Flip the
      mode in `export_presets.cfg`, export. **PASS:** **zero** addon/extension `.gd` packed
      (the GDScript plugin emits text scripts and `export_strip`'s `skip()` removes them);
      `.mcp.json` + non-script files also stripped; **no warning fires** (nothing leaked).

- [ ] **EX7 — Cross-version × two-mode.** Re-run EX5–EX6b on each installed version in **both**
      `script_export_mode=0` (Text) and `=2` (Binary tokens). **4.2 is text-only** (binary
      tokenization is 4.3+, so EX6 is N/A there). Use debug/release where templates exist,
      **pack-only** (`--export-pack`) where they don't — **log the launch gap, never silently
      skip**. **Anchors 4.2 / 4.5 / 4.7 (floor / reference / ceiling) must each pass** in every
      applicable mode; 4.3 / 4.4.1 / 4.6.2 are spot-checks, expanded only if an anchor surfaces
      a fault.
  - [ ] 4.2 — Text only
  - [ ] 4.5 — Text + Binary
  - [ ] 4.7 — Text + Binary

> **Project-version caveat:** a build exported by an *older* editor of a project last saved by
> a *newer* one fails to load newer-format scenes (independent of the toolkit). The parse-error
> assertion still holds (autoloads load before the main scene), but use a per-version-native
> project for a clean exit-0 launch.

---

## 2. Concurrent human+MCP editing (HE1–HE5) — BEST-EFFORT

No other MCP tool tests this — validating it is a differentiator. With the editor open, a
connected client, and the plugin active, drive each MCP call while a human edits. A failure is
dispositioned as a documented known-limitation, not a release blocker. Record which scenarios
passed cleanly and which needed turn-taking (for the README note).

- [ ] **HE1 — Script edit + `script_write`.** User is editing a script in the built-in editor;
      fire `script_write` on the same file. **Expected:** user sees updated content, cursor
      position reasonable, no data loss.
- [ ] **HE2 — Scene edit + `scene_create_node`.** User is moving nodes in the scene tree; fire
      `scene_create_node` to add a sibling. **Expected:** tree updates cleanly, selection
      preserved or clearly reset.
- [ ] **HE3 — Undo interleave.** User moves a node, MCP moves the same node, user presses
      Ctrl+Z. **Expected:** Ctrl+Z undoes the MCP change first (most recent), then the user's.
- [ ] **HE4 — Inspector + MCP delete.** User has the inspector open on a node; MCP deletes that
      node. **Expected:** inspector clears / shows an appropriate state — no crash, no stale
      data.
- [ ] **HE5 — Mid-drag + MCP reparent.** User is mid-drag in the 2D/3D viewport; MCP reparents
      the node being dragged. **Expected:** no crash; the drag either completes or cancels
      cleanly.

Full methodology: `Plan/ExecutionPlan/41o-stability-sanity-check.md` → Part G-pre-2 (planning
repo).

---

## 3. macOS GUI-launch smoke — CONDITIONALLY BLOCKING

**BLOCKING if a Mac is available (Intel or Apple Silicon).** If no Mac is available, record it
as a **documented coverage gap for this release — never a silent skip.** CI is headless and
never exercises a desktop client spawned from Finder/Dock, so this is the only cross-check that
a GUI-launched client resolves the bare-`npx` config and connects.

- [ ] **macOS GUI-launch round-trip.** Run the full procedure in
      [`macos-gui-launch-validation.md`](macos-gui-launch-validation.md): enable the plugin,
      GUI-launch an MCP client (Claude Desktop primary) from Finder/Dock, verify a clean
      connect (no `spawn npx ENOENT`), `discover_tools` + a read tool round-trip, and that
      opening the editor does not mutate `.mcp.json`.
- [ ] **No third-party runtime deps — verify no vendored code ships.** The addon under
      `addons/` is GDScript only; confirm no bundled third-party runtime code is present.
- [ ] **If no Mac:** documented coverage gap recorded for this release (not skipped silently).

---

## 4. Dock ↔ Project Settings round-trip — BEST-EFFORT

The dock's *Security & Response Limits* and *Audit Log* sections edit five Project Settings: the
script cap, save cap and WS buffer (`mcp_toolkit/limits/script_read_cap_kb`,
`save_read_cap_kb`, `ws_buffer_kb`) and the audit log's Enabled and Max KB
(`mcp_toolkit/audit/enabled`, `max_size_kb`). An edit in either surface must show in the
other, and neither may undo the other. Run with the plugin active, both dock sections
expanded, and **Project → Project Settings** open on the `mcp_toolkit/` keys. The checks
write `project.godot`; restore it afterwards with `git restore project.godot`.

- [ ] **DS1 — Inspector → dock.** Change each of the five values in Project Settings.
      **Expected:** the dock shows each new value without reopening anything.
- [ ] **DS2 — Dock → inspector.** Change each of the five values in the dock.
      **Expected:** the inspector shows each new value, and `project.godot` carries it.
- [ ] **DS3 — No revert.** After DS1, change a *different* dock control.
      **Expected:** the inspector edits from DS1 survive.
- [ ] **DS4 — Connect keeps the caps.** Set a non-default script cap, then connect an MCP
      client with neither `GODOT_MCP_SCRIPT_READ_LIMIT` nor `GODOT_MCP_WS_BUFFER_LIMIT` set.
      **Expected:** the dock and the inspector still show the cap, and after any further
      settings save `project.godot` still has it.
- [ ] **DS5 — Same ranges.** In the inspector, type an out-of-range value: script cap `10`,
      WS buffer `100000`. **Expected:** each is clamped to the dock's range (`64` and `8192`).

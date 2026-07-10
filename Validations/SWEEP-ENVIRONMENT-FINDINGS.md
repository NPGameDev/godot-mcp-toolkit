# Sweep Environment Findings — Godot 4.2 floor run (41n-nonies)

- **Date:** 2026-07-10
- **Sibling of:** [`RESULTS.md`](RESULTS.md) (run 41n-nonies, partial S0–S7, Godot 4.2 floor)
- **Purpose:** Root-cause analysis of the environment/tooling problems hit during that run, written so another agent (or a maintainer) can **preflight them and improve the setup**. Every cause below is grounded in the plugin source under `addons/godot_mcp_toolkit/`, with `file:line` citations.

## TL;DR / headline correction

Two classes of problem cost the run: (1) the running Godot version was **mis-detected** (read as 4.5, actually 4.2), and (2) console + screenshot introspection **appeared broken**. Investigation shows these are a mix of **genuine 4.2 limitations**, a **minimized editor window**, and a **misleading stale log** — **NOT** a headless editor, which is what was concluded mid-run.

**The mid-run "connected to a headless editor" conclusion was wrong.** The code shows the connected editor was almost certainly a **GUI Godot 4.2 editor that was minimized/backgrounded**. Three independent facts converged into a false "headless" story (see the meta-lesson at the end).

---

## 1. Version mis-detected (read 4.5, actually 4.2)

**Cause.** Version was inferred from two unreliable signals:
- `application/config/features` ProjectSetting = `"4.2"` — but that is the project's *declared floor*, not the running engine (a newer editor can open a 4.2-tagged project).
- The editor boot banner read from the log file = `v4.5.stable` — but that line came from a **stale log** (see §3), not the current session.

The plugin *does* compute the true version — `versioning/mcp_version_utils.gd:20-22` calls `Engine.get_version_info()` — but **no MCP tool exposes it**, and `execute_code` cannot reach the `Engine` singleton (project convention blocks engine singletons in `execute_code`).

**Recommendation.**
- Detect via a **ClassDB version-boundary probe** (this is what ultimately worked): `classdb_search("TileMapLayer")` present ⇒ engine ≥ 4.3; only legacy `TileMap` present ⇒ 4.2. Queries the live engine registry, not a declared/stale string.
- More authoritative still: the plugin stamps a **live `godot_version`** field (from `Engine.get_version_info()`) into every registry entry — `registry/registry_client.gd:175`, `registry/store/registry_entry_file.gd:78`. Read that field from the system `projects.json` entry for the project.
- **Maintainer fix:** add a small `server.info` / `meta.version` MCP tool that returns `Engine.get_version_info()`, so a client never has to infer the version.

---

## 2. Console buffer always empty (`editor_get_console source:buffer` → 0 lines) — a genuine 4.2/4.3 limitation

**Cause.** `logging/log_buffer.gd:78-81` selects its capture strategy with `ClassDB.class_exists("Logger")`. The `Logger` class is **4.4+**. On 4.2 the plugin falls back to *tailing* `user://logs/godot.log` — but Godot **hard-disables file logging in editor mode on every version** (`commands/editor/editor_log_reader.gd:168-170`), so that file is never written and the tail is always empty. This is why the console worked on the prior 4.5/4.7 runs (Logger class present → live capture) but not here. Scene/node mutations still worked because they use EditorInterface APIs directly, independent of the log.

**Consequence for the sweep.** Every section's console-isolation check (scan the buffer for `UndoRedo history mismatch`) and S7's console-seed tests (7.5–7.10) were **vacuous on 4.2** — they proved nothing. This is a real floor limitation, not a headless artifact, and it would happen on any GUI 4.2/4.3 editor.

**Recommendation.**
- Do not rely on console-buffer validation on 4.2/4.3. Treat console-isolation and console-seed checks as **N/A on the floor**; validate console + undo/redo-mismatch behavior on a **4.4+ editor**.
- **Maintainer fix:** the 4.2 fallback is ineffective. Either capture via a 4.2-available channel (e.g. an `EditorLog`/Output hook), or make `editor_get_console` return an explicit "console capture unsupported on < 4.4" signal instead of a silent empty buffer — a silent empty buffer reads as "clean," which is dangerously misleading for an isolation check.

---

## 3. `"fallback to stale log — no post-boot log found"` + the misleading `RendererDummy` line

**Cause.** Same root as §2. Editor mode never writes `user://logs/godot.log`, so `editor_log_reader.gd:214-254` (a "post-boot log" = a file with mtime ≥ the plugin boot time, stamped at `mcp_server.gd:192`) finds no current-session file and falls back to the newest *pre-existing* one. In this session that old file was from a prior **`--headless --script test/run_unit_tests.gd`** run — a non-editor `SceneTree` run, which *does* write the log, using the dummy renderer — hence the `RendererDummy` / `DummyMesh` "leaked at exit" lines and unit-test `PASS` output. **That stale content is what made the mid-run diagnosis wrongly conclude "headless."**

**Recommendation.**
- Treat `source:file` on 4.2 as unreliable; never infer the running version or renderer from it.
- **Maintainer fix:** when the stale-fallback fires, surface that the content is from a *previous* session much more loudly (the warning exists but is easy to under-weight), or do not present stale content as "the console" at all.

---

## 4. `editor_screenshot` → 2×2 / 81-byte stub — collapsed viewport, NOT headless

**Cause.** `commands/editor/editor_screenshot.gd:33-40` checks headless **first** and returns a hard `HEADLESS_UNSUPPORTED` error — a genuinely headless editor can therefore never return a 2×2 image. The 2×2 stub is the **collapsed-viewport path** (`editor_screenshot.gd:21-27`, `COLLAPSED_VIEWPORT_WARNING`): `EditorInterface.get_editor_viewport_2d()/3d()` returns Godot's "no frame composited yet" 2×2 floor when the editor window is **minimized or backgrounded** (display server present, but nothing rendered). This matches the original PC-lock, and the most recent repo commit — `2d3be04 "fix(editor): clearer screenshot warning on a collapsed viewport"` — addresses exactly this case.

**Recommendation.**
- For screenshot / visual tests, keep the editor window **un-minimized and in the foreground** (a locked or minimized desktop yields the 2×2 collapse). Treat a `COLLAPSED_VIEWPORT_WARNING` / 2×2 result as "foreground the window," not "broken tool."

---

## 5. The real "port thief" risk (why a headless instance *can* own port 6550)

**Cause.** It did **not** happen this session (the 2×2 screenshot proves a GUI editor answered — a headless editor would have returned `HEADLESS_UNSUPPORTED`), but the risk is real and the repo already documents it. The CI warm-up step `scripts/test_framework/run_units_cold.sh:106` boots `godot --headless --editor --path .` — a *real* (headless) editor boot that fires `_enter_tree()` → `RegistryClient.register()` and **claims port 6550**. The script itself labels it *"H1 — the zombie warm-up editor holding 6550/6005 … PORT THIEF"* and mitigates with force-kill + relocation (`run_units_cold.sh:147-264`). The plain `--script` unit runner (`run_units_cold.sh:286`) does **not** register (a `--script` `SceneTree` run never constructs `EditorNode`, so no EditorPlugin lifecycle, so `RegistryClient.register()` is never called). There is no in-plugin guard excluding a headless *editor* from registering — by design, since Mode A is meant to work under `--headless --editor` for automation.

**Recommendation.**
- After any local CI/test run, ensure no lingering `godot --headless --editor` warm-up process survives (Task Manager). A surviving one can hold 6550 and the bridge will connect to it instead of your GUI editor.
- **Pin the port** for deterministic connection: set `GODOT_MCP_EDITOR_PORT` in `.mcp.json` so both the editor and the bridge use one known port (`transport/port_config.gd:66-82`), bypassing registry discovery and any zombie holder.

---

## Meta-lesson (why it looked like a broken diagnosis)

No single tool reading was wrong — each was objective. But the *composite* inference over-fit to "headless" because three unrelated facts converged: an **empty buffer** (the 4.2 `Logger`-class gap), a **stale log** (editor mode doesn't write a log file, *plus* the newest old file was a real headless test run), and a **2×2 screenshot** (a minimized window). The literal `RendererDummy` string in the stale log then "confirmed" the wrong story.

The single preflight that would have prevented the whole detour: **establish the running version authoritatively (ClassDB probe or registry `godot_version`) and recognize the 2×2 as a minimized-window signal + the empty 4.2 buffer as the known Logger-class limitation — rather than inferring version and renderer from log content that a 4.2 editor never actually produces.**

---

## Action items to improve the setup

**Operator / sweep-runner practices (do this before a run):**
1. Detect the running version via a **ClassDB probe** (`classdb_search("TileMapLayer")`) or the registry `godot_version` field — never the `features` PSA or the boot-banner log line.
2. Run the sweep on a **4.4+ GUI editor kept in the foreground** (un-minimized). A locked or minimized desktop collapses the viewport (2×2 screenshots).
3. If deliberately validating the **4.2 floor**, expect console capture + live-log introspection to be genuinely unavailable there; mark console-isolation / console-seed / undo-mismatch checks **N/A** rather than "PASS."
4. **Pin `GODOT_MCP_EDITOR_PORT`** in `.mcp.json` and ensure no lingering `godot --headless --editor` warm-up process (from CI) is holding the port.

**Maintainer / plugin fixes (candidates):**
1. Add a `server.info` / `meta.version` MCP tool returning `Engine.get_version_info()` (kills the version-inference guesswork). — `versioning/mcp_version_utils.gd:20-22`
2. Make console capture functional on 4.2/4.3, **or** have `editor_get_console` return an explicit "unsupported on < 4.4" signal instead of a silent empty buffer that reads as "clean." — `logging/log_buffer.gd:78-81`, `commands/editor/editor_log_reader.gd:168-170`
3. Make the stale-log fallback flag its previous-session content far more loudly, or stop surfacing it as "the console." — `commands/editor/editor_log_reader.gd:214-254`
4. (Already improved: collapsed-viewport screenshot warning — commit `2d3be04`.)

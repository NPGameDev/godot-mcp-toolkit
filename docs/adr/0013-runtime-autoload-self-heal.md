---
status: accepted
---

# 0013 — runtime-autoload self-heal on load

## Context

The `MCPRuntimeServer` runtime autoload (Mode B — the game-side WebSocket server) was registered
**only** in `_enable_plugin()`, which the editor fires on the disabled→enabled toggle. It does **not**
fire when the editor opens a project that is *already* enabled. So a project whose enabled flag was
applied out-of-band — a hand-edited or copied `project.godot`, a project template, or VCS propagation
of a hand-set `[editor_plugins] enabled` entry — opens with the plugin **enabled but the
`[autoload] MCPRuntimeServer` line absent**. The editor-side tools (Mode A) work, but Mode B is
silently dead: the autoload that would host the runtime server is never instantiated, and because the
autoload is baked into the *game* at F5, nothing the user does in that session brings it back. This was
observed in a team/VCS setting where every clone inherited "enabled, no autoload."

The invariant the plugin intends is *"plugin enabled ⟹ runtime autoload registered."* It was asserted
at first-enable but never re-asserted on subsequent loads, so an externally-broken project never
recovered.

## Decision

Re-assert the invariant on **every load**, in `_enter_tree()`, via a dedicated private wrapper
`_self_heal_autoloads()` that delegates to a shared `_ensure_autoloads_registered()`. The heal is
unconditional on absence and has **no opt-out flag** — it restores the designed first-enable state.

The shared helper registers each entry of a new `_REQUIRED_AUTOLOADS` const (a list of `[name, path]`
pairs; one today, the list shape future-proofs a second) using
`ProjectSettings.set_setting("autoload/" + name, "*" + path)` followed, once after the loop and only if
something changed, by `ProjectSettings.save()` and `ProjectSettings.emit_signal("settings_changed")`.
A `has_setting("autoload/" + name)` guard means a present value is **never clobbered** and a healthy
project gets **no write** (no `project.godot` diff). The "which are missing" decision is factored into a
**pure** `_compute_missing_autoloads(present: PackedStringArray, required: Array) -> Array` —
plain-data-in, plain-data-out — so it is unit-testable headless; the side-effecting shell does the
`ProjectSettings` probing and writing. `_enable_plugin()` is refactored to call the same
`_ensure_autoloads_registered()`, so the first-enable and self-heal paths can never diverge.

Placement is **early** — between `SettingsRegistration.register_all()` and `PluginComposer.compose()`.
The extension watcher and the other `settings_changed` consumers are wired *inside* `compose()`, so
healing before it means the mandatory `emit_signal("settings_changed")` fires into **zero listeners** —
no premature poke. `call_deferred` would be strictly worse here: it would emit *after* the watcher is
live.

The heal **deliberately uses `set_setting` + `save` rather than `add_autoload_singleton`** — a
considered deviation from the code-standards default of registering autoloads via
`_enable_plugin`/`_disable_plugin` with the editor API. The reasons:

- **The heal needs an explicit disk write.** `add_autoload_singleton` updates the editor's in-memory
  state but does not persist to `project.godot`; the game reads `project.godot` at F5, so without a
  `save()` the heal would not survive to the build. The direct path persists by construction.
- **Undo-free by construction.** `add_autoload_singleton` pushes a startup undo entry — a stray Ctrl+Z
  right after open would undo the heal. The direct `set_setting` path leaves no undo entry, so the
  autoload cannot be accidentally undone away.
- **Cache-correct via the emit.** The `emit_signal("settings_changed")` refreshes the editor's
  in-memory view of the autoload list after the disk write, the same cache-correctness pattern
  `project_commands.gd` uses (FIX-D).
- **Version-stable.** `set_setting` / `save` / `emit_signal` behave identically on 4.2–4.6.

`_disable_plugin()` keeps `remove_autoload_singleton` unchanged — removal is a genuine editor action
with no disk-persistence requirement, and the symmetry concern is one-directional (the heal is about
*restoring* absence, not undoing the toggle).

A headless unit asserts that the `_REQUIRED_AUTOLOADS`-derived `"autoload/<name>" = "*<path>"` set
**equals** `export_strip.gd`'s `_AUTOLOAD_KEY` / `_AUTOLOAD_VAL` — the keys export-strip nulls for the
bake and restores after. Drift between the two (a renamed or one-sidedly-added autoload) would ship the
autoload in the exported PCK, so the unit fails the build instead.

## Consequences

- A project opened in the broken state self-heals on load: the autoload reappears in Project Settings →
  Autoload and is persisted to `project.godot` before any F5, so runtime tools work without the user
  touching anything.
- A healthy project is untouched — the `has_setting` guard short-circuits, so there is no
  `project.godot` write and no git diff on open.
- `_enable_plugin()` and the heal share one code path; the const-match unit guards the export-strip
  coupling against future drift.
- Export composition is unaffected: `export_strip` still nulls the autoload for the bake and restores it
  after, unchanged by the heal.

## Considered and rejected

- **Lazy heal on first runtime connection / runtime-tool call.** Too late: the autoload is baked into
  the game at F5, so a heal triggered by a runtime call cannot fix the *current* session. On-load
  catches 100% of the broken state (it only manifests at project-open) before any F5.
- **An opt-out flag ("leave the autoload unregistered").** Adds configuration complexity for a state
  that is simply broken. A genuine "Mode A only" preference is better served by a future PostRelease
  EditorSetting that suppresses the *runtime server*, not by leaving the autoload entry missing.
- **`add_autoload_singleton` for the heal.** Adds a startup undo entry (a stray Ctrl+Z undoes the heal)
  and does not persist to `project.godot` (the game reads disk at F5), which is exactly what the heal
  needs. See the Decision rationale above.

> Update (2026-07-05): the registration mechanism now lives in `core/autoload_registration.gd`
> (`ensure_registered` / `unregister` / the pure `compute_missing`), with the required-autoload identity
> — the `[name, path]` pairs plus the `settings_key`/`settings_value` derivation — extracted to the
> shared pure-const leaf `core/autoload_identity.gd`, which `export_strip.gd` also reads for its
> null-for-bake/restore, so the two sides share one home instead of a pinned const pair.

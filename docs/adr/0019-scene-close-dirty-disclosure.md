# scene_close discloses discarded unsaved edits (best-effort, 4.7-only)

`scene.close` closes an open scene tab. Until now it closed silently, giving the
caller no signal that the tab held **unsaved edits** — closing throws those away,
and an agent driving the tool had no way to know a discard happened. For a 1.0
that is honest about destructive actions, the tool must both *declare* itself
destructive and, where the editor can tell us, *disclose* whether a discard
actually occurred.

The blocker is a version constraint. A reliable "is this scene dirty?" query is
only exposed to GDScript in **Godot 4.7**: `EditorInterface.get_unsaved_scenes()`
(returns the `PackedStringArray` of unsaved scene paths) is ClassDB-bound in 4.7
and absent in 4.5/4.6. On 4.5/4.6 there is no bound dirty query at all —
`EditorUndoRedoManager.is_history_unsaved` is unbound, and only the
`mark_scene_as_unsaved` *setter* exists — so the editor cannot answer "was this
tab dirty?" before it closes.

## Decision

**Declare destructive on every version; disclose the discard best-effort, 4.7-only.**

- **`destructiveHint: true` + honest description on all versions.** The server tool
  metadata now marks `scene_close` destructive and the description states that
  unsaved edits in the closed tab are discarded (save with `editor_save_scene`
  first). This is version-independent — it is metadata and prose, not a runtime
  probe.
- **`unsaved_changes_discarded: bool` in the response — only where detectable
  (4.7+).** Before the tab is switched/closed, the toolkit reads
  `get_unsaved_scenes()` (gated by `EditorInterface.has_method("get_unsaved_scenes")`,
  the codebase feature-detect idiom, not a version-string compare) and reports
  whether the closed path was in that set. **Below 4.7 the field is omitted
  entirely** — absence signals "not determinable here", deliberately distinct from
  a present `false`, which would falsely claim a detected-clean tab.
- **The tool always closes on every version.** Only disclosure *fidelity* differs
  by version; behavior (the tab closes) does not.

## Deliberately NO refuse-to-close (`force`) guard

A guard that *refuses* to close a dirty tab unless the caller passes `force: true`
was considered and **rejected for 1.0**. Such a guard needs only-when-dirty
detection — which is 4.7-only — so any guard is necessarily either
**version-divergent** (refuses on 4.7, silently closes on 4.5/4.6, the worst kind
of inconsistency for an agent-facing tool) or **fires on every close** regardless
of dirtiness (forcing the flag on saves that never had edits, training callers to
pass `force` reflexively). Neither is acceptable.

The cross-version path to a real guard is a **content-hash comparison** (hash the
on-disk scene vs the in-editor state to detect dirtiness without a bound query),
which works on 4.5/4.6 too but is a larger design. It is deferred and filed at
`Plan/Ideas/PostRelease/2026-07-08-scene-close-dirty-guard-hash.md`. Recorded here
so a future contributor does not re-litigate the "just add a `force` flag"
shortcut without seeing the version-divergence trap.

## Consequences

- The tool is honest by default: destructive metadata + a save-first description on
  every supported version, and a concrete per-call discard signal on 4.7.
- Callers must not rely on `unsaved_changes_discarded` being present — it is a 4.7+
  affordance. On 4.5/4.6 they should treat the close as potentially discarding and
  save first if that matters (the description says so).
- A stricter refuse-to-close guard remains open, gated on the deferred hash-based
  detection, not on the 4.7-only query.

Iteration: `41o-nonies`.

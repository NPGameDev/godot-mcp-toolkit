# Opt-in, machine-wide crash-safe unfocused-responsive mode

To keep MCP commands responsive while the editor is **unfocused** — the normal
state during a session, since the user is looking at the chat — the toolkit
lowers the global editor setting
`interface/editor/unfocused_low_processor_mode_sleep_usec` (default ~100000 µs ≈
10 fps) to a boosted value while an authenticated client is connected, then
restores it on the last disconnect. The engine re-reads that setting on every
focus-out (`editor_node.cpp`), so writing the EditorSetting is the correct,
clean integration point.

The original implementation held the pre-boost value **only in memory** and
mutated the setting silently and unconditionally. That had five problems: it is
an obtuse global side-effect (the key is machine-wide — every project on that
editor version), it was not optional, its state was invisible, and — the real
footgun — `set_setting` does not persist immediately (`editor_settings.cpp`); it
reaches disk only when some later `save()` flushes it. Once flushed, a **crash**
(or a **concurrent second editor**) left the global stranded at the boosted
value, and on the next launch the leftover boosted value was read back as the
"original" — so the true default was lost permanently. The crash and concurrency
failures share one root cause: reading a boosted value as the original.

**Decision: Option A — keep the dynamic connect-boost/disconnect-restore
behaviour, but make it opt-in (default on), visible, machine-wide crash-safe, and
conflict-aware.**

- **Opt-in, tunable, in *Editor* Settings (not Project Settings).** Two new keys:
  `mcp_toolkit/performance/keep_editor_responsive_unfocused` (bool, default
  `true`) gates the behaviour, and `mcp_toolkit/performance/unfocused_responsive_sleep_usec`
  (int, default `16666` = 60 fps; not clamped) is the boosted value. These are
  the **only** EditorSettings the toolkit owns — every other toolkit setting is a
  `mcp_toolkit/*` ProjectSetting. The exception is deliberate: the effect is
  machine-global, the preference is personal (battery/CPU), it must not be
  committed to `project.godot`/VCS, and "off" is only truly off at global scope
  (a per-project opt-out cannot stop a concurrent project from boosting the
  shared global).
- **Machine-wide, version-keyed, first-writer-wins, conflict-aware backup.** The
  true original is persisted once to `unfocused_sleep_backup_<major.minor>.json`
  in the registry dir (`registry_client.gd::registry_dir()`), under the existing
  registry file lock. A second instance that connects while a backup already
  exists does **not** overwrite it (so it never captures a boosted value as the
  original). Restore — on disconnect, and as a **startup self-heal** — reads the
  live value `C`: if `C` equals the value we wrote (`B`), restore the stored
  original `O`; if `C != B`, a human/other tool changed it, so keep `C`. Either
  way the backup is deleted. The backup stores **both** `O` and `B` so the
  compare works even if the configured boosted value changed between sessions.
- **Default 60 fps (not 30).** Interactive users can't perceive 30 vs 60 (both
  dwarfed by agent thinking time), but automated rapid-fire runs (smoke/sweep/
  dispatch) pay the poll latency directly — ~20–30 s added per full smoke run at
  30 fps. 60 favours the dev/test loop and max snappiness, is zero behavioural
  change from before, and is tunable down to 30 (documented power-saver) or off.
- **Visible state.** A 3-state dock indicator (Off / On (idle) / On · active ·
  {fps} fps) plus an inline toggle (mirrors the audit-enabled toggle, but
  read/writes the EditorSetting) and activation/deactivation log lines. The
  wizard discloses the behaviour and flags that it lives in Editor Settings. No
  toast — `EditorToaster` is not reliable on 4.2, and a missable notice is worse
  than a steady indicator.

## Considered alternatives

- **Remove the boost and educate users to set the EditorSetting themselves
  (Option B).** Rejected: the unfocused state is the *common* case for MCP, so B
  is laggy by default.
- **One-time wizard sets the setting once, always-on (Option C).** Rejected:
  always-on wastes background CPU even with no client connected; A boosts only
  while connected.
- **Wizard gates A behind explicit consent (Option D).** Folded into A — consent
  is delivered by the dock indicator + wizard note, with no blocking step
  (default is on).
- **Per-instance backup (in `user://…/project_instance_<hash>/`).** Rejected: the
  protected key is machine-global but `user://` is per-project — narrower than the
  thing being backed up — so it leaves a persistent cross-project crash leak (true
  original siloed in a crashed project that may never reopen). The backup must be
  machine-wide.
- **Reference-count active connections across instances to fix the transient
  concurrent de-boost.** Rejected for 1.0: a refcount leaks on crash and leans on
  Windows dead-instance GC that `OS.is_process_running` reports unreliably. The
  residual transient dip (a disconnecting instance de-boosts a still-connected
  peer until its next fresh connect) is never persistent corruption and already
  existed before this change.
- **WebSocket reader thread instead of the frame-rate lever.** Rejected for this
  iter and filed post-1.0 (`Plan/Ideas/PostRelease/2026-06-07-websocket-reader-thread-latency.md`):
  it removes the 4-frame pickup batching but **not** the execution floor (command
  execution must marshal to the main thread at the main-loop cadence, and
  multi-yield mutations pay one frame per yield regardless). Complementary, not a
  replacement, and a sizeable threading project.

## Known limitations (documented, not coded)

- **Exact-`B` manual write is undetectable.** If the user sets the key to exactly
  `B` while it is already `B`, the engine de-dupes the same-value write
  (`editor_settings.cpp` — `changed` only when `p_value != old`), emitting no
  `settings_changed` and recording nothing in `get_changed_settings()`, so no
  listener could catch it. On restore the toolkit treats it as its own and reverts
  to `O`.
- **Transient concurrent de-boost.** See the refcount note above — a brief
  responsiveness dip, never persistent corruption.

Full source-verified analysis (engine line references, blast radius, cost,
rejected alternatives): `Insights/unfocused-throttle-analysis.md`. Grilling
session: `Plan/Reference/GrillingSessions/2026-06-07-unfocused-throttle.md`.
Supersedes the silent in-memory boost added in iter 28b
(`unfocused-throttle-fix`).

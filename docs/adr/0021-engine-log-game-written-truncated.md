# The engine debug log is game-written and truncated per launch, not an editor+game shared append

The engine debug log (`user://logs/godot.log`, path from the
`debug/file_logging/log_path` project setting) is written **only by the
game/play process** — the editor process never writes it. Godot gates the
`RotatedFileLogger` on a `!editor` term
(`(!log_file.is_empty() || (!project_manager && !editor && GLOBAL_GET("debug/file_logging/enable_file_logging")))`,
`main.cpp`, source-verified on 4.2–4.5), so an editor `--editor` session adds no
file logger; only an explicit `--log-file` on the command line would force one,
which normal usage never does. Each game launch **truncates** `godot.log` fresh:
`RotatedFileLogger`'s constructor calls `rotate_file()` unconditionally
(`core/io/logger.cpp`), copying the prior `godot.log` to a timestamped backup and
reopening the base path with `FileAccess::WRITE` (length 0). Prior sessions live
in timestamped siblings; `godot.log` is always the current session.

An earlier mental model — captured in a now-corrected `playtest_log_reader.gd`
comment — treated the file as "written by both editor + game processes," an
editor+game shared **append** target. That was factually wrong on every supported
version and led two of the four log readers to hardcode the default
`user://logs/godot.log` rather than resolve the configurable setting.

## Decision

Model the engine debug log as a **game-written, single-session, truncate-on-launch
file** whose path comes from `debug/file_logging/log_path`. Concretely:

- **Resolve the path in one place.** Every log reader resolves
  `debug/file_logging/log_path` through the export-clean `LogHelpers`
  (`configured_log_path()` raw / `resolve_log_path()` globalized) rather than
  hardcoding the default, so a relocated log path is honored uniformly.
- **Treat a shrunken file as rotation — but distinguish the two reader kinds.** A
  *tail* reader whose byte offset is a genuine high-water read cursor
  (`log_buffer.gd`) recognizes a fresh-truncated file when its offset exceeds the
  file length and resets that cursor to 0. The Mode-A `debugger.get_log` reader has
  **no** such cursor: after truncation the whole `godot.log` *is* the current
  session, so it reads unconditionally from **byte 0** and keeps only a boolean
  "a session has started" flag (the prior snapshotted byte offset was a vestige of
  the discredited shared-append model, removed in 41o-undecies-bis).
- **Do not** re-introduce the editor+game shared-append assumption. The editor
  never writes the file; the buffer/file readers populate only from a running or
  already-run game (a core reason the 4.5 Logger API — real-time in-memory capture
  of editor output — matters on 4.5+, where 4.2–4.4 have no such capture).

Full engine analysis (writer guard per version, rotation call sites, verification
greps): `Insights/engine-log-file-writer-and-rotation.md` in the plan repo.

## Consequences

- The console `source="file"` reader and the runtime `debugger.get_log` file
  source now honor a relocated `log_path`; in the default case every reader's
  output — including the runtime `path` metadata and the console hints — stays
  byte-identical.
- A future engineer reading the readers sees the corrected model at the source and
  in this record, and will not re-hardcode the default or re-assume a shared
  append.
- Because `godot.log` is truncated per launch, a *tail* reader that carries a
  high-water offset across a game launch must guard the rotation case, while the
  Mode-A session reader drops its byte offset entirely and reads from byte 0
  (implemented in 41o-undecies-bis).

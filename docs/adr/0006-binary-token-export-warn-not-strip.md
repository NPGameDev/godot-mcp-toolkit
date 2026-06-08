# Warn, don't strip, binary-token GDScript exports

Godot's default Script Export Mode (Binary tokens / compressed, 4.3+) compiles
every `.gd` to `.gdc` in the built-in `EditorExportGDScript` plugin, which is
registered before any addon and saves the `.gdc` + breaks the per-file export loop
before `export_strip.gd` runs. So addon and extension scripts ship as compiled
`.gdc` in any binary-token mode. The natural fix — pre-excluding the addon in
`_export_begin` — is blocked: `EditorExportPreset.set_exclude_filter` is not bound
to GDScript (still unbound in 4.6 — godotengine/godot#4054).

**Decision: warn, do not strip.** `export_strip.gd` detects the leak by observing
which of its own `_export_file` calls fire — a binary mode never delivers the
addon/extension `.gd` (the built-in tokenizer consumes them first), only the
addon's non-script files — and emits an export-time warning:
`EditorExportPlatform.add_message()` on 4.4+ (export dialog), `push_warning()` on
4.3 (Output log). A non-script-file guard suppresses the warning when the user has
already excluded the addon (no false positive). Godot 4.2 has no binary-token mode
(scripts ship as text and are stripped), so it never warns. The detection is
version-agnostic — it reads no preset state, so it works on 4.3 where
`get_script_export_mode()` is unbound.

The leak is **cosmetic**: the shipped scripts are orphaned (their editor-only
loader is stripped) and GDScript loads lazily, so they are never parsed or
executed. A runtime-safety audit confirms no runtime path reaches them — no
`add_custom_type`, no resource loaders, no static-init; the runtime autoload is
nulled in every export and additionally self-gates on `not OS.has_feature("editor")`
(false in every export template, debug and release). The cost is dead weight in the
PCK plus revealing that MCP tooling was used — and even a perfect strip cannot hide
the latter (`global_script_class_cache.cfg` embeds addon paths as plaintext). The
inert `[mcp_toolkit]` ProjectSettings keys carried in `project.binary` (e.g.
`internal/bootstrap_complete`) are a cosmetic fingerprint of the same class — no
secrets (the auth token and registry live in `user://`, never packed) — left in
place for the same reason; an optional settings strip is tracked as a high-priority
post-1.0 idea (`Plan/Ideas/PostRelease/2026-06-08-strip-mcp-toolkit-projectsettings.md`).

The bug is **4.3+ only** (binary tokenization was introduced in 4.3). Extends
**ADR 0005** (single-level extension discovery / strip): the warning counts the
same single-level extension set. Full source-verified analysis (engine line
references for 4.2–4.6): `Insights/export-strip-binary-token-analysis.md`.

## Considered alternatives

- **File relocation during the bake** (move addon `.gd` off disk in `_export_begin`,
  restore in `_export_end`). The only mechanism that actually strips, but rejected:
  it is an on-disk, persistent change whose recovery code lives *inside* the addon
  directory it moves, so a crash before `_export_end` leaves the addon broken with
  no self-heal; and moving `plugin.gd` / `.uid` mid-export risks breaking the export
  itself. The autoload-null we keep is in-memory only and self-heals; relocation is
  not.
- **`.gdignore` written at export time.** Rejected: `.gdignore` is honored only
  during an EditorFileSystem scan, but the export file list is already built from
  the in-memory tree — a fresh ignore needs a rescan, and a mid-export rescan is the
  scan-collision crash class fixed in 41l-tricies. A persistent `.gdignore` would
  also hide the addon from the editor.
- **Addon self-adds to the exclude filter.** Rejected: the clean version needs the
  unbound `set_exclude_filter` (#4054); the `export_presets.cfg` file-edit
  workaround is stale for the live in-memory preset, clobbered on the next editor
  save, inconsistent between editor and CLI exports, and invasively rewrites the
  user's owned export config.
- **C#/GDExtension helper** to call `set_exclude_filter`. Rejected: adds a binary,
  non-GDScript dependency to a GDScript-only AssetLib addon.
- **De-register the built-in GDScript export plugin during the bake.** Rejected:
  would ship the user's whole game as text, downgrading the script protection they
  chose; fragile global-registry mutation mid-export.

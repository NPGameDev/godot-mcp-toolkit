# 0028 — Order the export strip before the GDScript tokenizer

**Status:** Accepted

**Date:** 2026-10-26

**Supersedes:** [ADR 0006](0006-binary-token-export-warn-not-strip.md).

## Context

`core/export_strip.gd` is the export plugin that keeps the toolkit out of a user's
game: it skips every `addons/godot_mcp_toolkit/` file, each GDScript extension (a
direct `MCPToolkitExtension` subclass, [ADR 0005](0005-single-level-extension-discovery.md))
and `res://.mcp.json`, and nulls the runtime autoload for the bake. In Godot's
default Script Export Mode, binary tokens (4.3+), the addon and extension scripts
still shipped as `.gdc` plus `.gd.remap` (issue #99).

ADR 0006 put this down to the built-in GDScript export plugin being "registered
before any addon", concluded that no in-addon fix existed without the unbound
`EditorExportPreset.set_exclude_filter` (godotengine/godot#4054), and settled on a
warning. The cause was wrong. The engine sorts the export plugins **by name**
before the per-file loop (`left->get_name() < right->get_name()` in
`editor/export/editor_export_platform.cpp`, on every version from 4.2 to 4.7), then
offers each file to the plugins in that order and stops at the first one that
skips or remaps it. The built-in plugin is named `"GDScript"` and remaps every
`.gd` to `.gdc` outside Text mode; ours was `"MCPExportStrip"`, which sorts after
it, so our `skip()` never saw a script. Registration order plays no part.

## Decision

**The strip's plugin name sorts before `"GDScript"`: `_get_name()` returns the
`const _PLUGIN_NAME := "0MCPExportStrip"`.**

- **A leading digit.** `"0"` sorts before every letter, upper or lower case, so the
  name stays ahead of `"GDScript"` (and of any built-in plugin named with a letter)
  however the rest of it is spelled. A comment beside the `const` says why, and the
  unit suite pins both the `< "GDScript"` order and the first character.
- **No version guard.** `_get_name` is a required virtual since 4.2 and the sort
  exists on every supported version. The name otherwise reaches only the
  customization hash (for plugins that customize resources; this one does not) and
  the engine's "plugin not supported on platform" warning (this plugin does not
  override `_supports_platform`).
- **`set_exclude_filter` is not needed.** The strip removes the files itself, in
  every Script Export Mode, so the shipped file set equals the Text-mode set
  that already exported and launched cleanly.
- **The leak detection stays, as a cause-neutral net.** It still compares which
  addon and extension files reach `_export_file`: if the addon's non-script files
  arrive but none of its `.gd` do, or a computed extension path never arrives,
  those scripts did not reach the strip. Unless the preset already excludes them,
  another export plugin that sorts before ours consumed them first (an
  obfuscator, for example) and they may ship. The warning says that much, drops
  the Text-mode advice, and names the paths to add to the preset's exclude
  filter. It is delivered as before:
  `add_message()` on 4.4+, `push_warning()` on 4.2 and 4.3.

Verified live with a headless `--export-debug` of the dogfood project plus one
GDScript extension, on 4.3, 4.5 and 4.7 in binary-token and Text modes and on 4.2
in Text mode, counting entries in the parsed PCK directory: before the rename,
binary-token builds carried every addon script and the extension as `.gdc` plus
`.gd.remap` and the export warned; after it, no build carries an addon or
extension script, no export warns, and every build launches with no script error.

## Considered and rejected

Carried from ADR 0006, where each was weighed as a way around the wrong cause; none
is needed now that the strip runs first.

- **File relocation during the bake** (move addon `.gd` off disk in
  `_export_begin`, restore in `_export_end`). An on-disk change whose recovery code
  lives inside the directory it moves: a crash before `_export_end` leaves the
  addon broken with no self-heal.
- **`.gdignore` written at export time.** Honoured only during a filesystem scan;
  the export file list is already built, and a mid-export rescan risks a
  scan-collision crash.
- **The addon adds itself to the exclude filter.** Needs the unbound
  `set_exclude_filter`; editing `export_presets.cfg` instead is stale for the live
  preset, clobbered on the next editor save, and rewrites config the user owns.
- **A C# or GDExtension helper** to call `set_exclude_filter`. Adds a binary,
  non-GDScript dependency to a GDScript-only Asset Library addon.
- **De-registering the built-in GDScript export plugin during the bake.** Ships the
  user's whole game as text, downgrading the script protection they chose.

New with this decision:

- **A letter prefix such as `"AMCPExportStrip"`.** Works today, but a later rename
  to a lowercase or later-letter name would silently sort after `"GDScript"` again.
  A digit holds for any letter.
- **Dropping the warning.** With the strip first, the built-in tokenizer can no
  longer trigger it, but a third-party export plugin that sorts earlier still can,
  and the user would get no other signal.

## Consequences

- Exported builds carry no addon or extension script in any Script Export Mode.
  The workaround ADR 0006 advised (Text mode, or the addon in the exclude filter)
  is no longer needed and is harmless to keep.
- Paths remain as metadata in `global_script_class_cache.cfg`, `uid_cache.bin`
  and `project.binary`, the cosmetic fingerprint ADR 0006 already accepted.
  `uid_cache.bin` ships on every supported version; on 4.2 and 4.3 it names only
  the addon's icon. On 4.7 the preset's exclude filter drops the addon from both
  caches; on 4.2 to 4.6 the engine copies them whole. A raw byte grep of the PCK
  still finds these paths, so a check counts entries in the PCK directory instead.
- The plugin's `editor_plugins/enabled` entry stays in `project.binary` on every
  version. The strip could null it for the bake, as it does the runtime autoload,
  but a project save during the export would then write the plugin disabled, and
  no in-plugin heal exists for it: a disabled plugin never loads to restore its
  own entry. The autoload null has that heal, at plugin load (issue #99).
- The release checklist's binary-token row expects zero addon `.gdc` and no
  warning, where it used to expect the warning.
- A future rename of the plugin must keep a name that sorts before `"GDScript"`;
  the unit pins fail otherwise.

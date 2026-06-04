# Single-level extension discovery (and matching export strip)

An extension is a **direct** subclass of `MCPToolkitExtension` — GDScript:
`base == "MCPToolkitExtension"`; C#: a `[GlobalClass]` whose name starts with
`MCPToolkit` (C# cannot inherit the GDScript base). Multi-level inheritance
(`class_name Child extends ParentExt extends MCPToolkitExtension`) is
intentionally **not** supported: every class in the global class list is
discovered and loaded independently, so transitive discovery would load both an
intermediate base and its leaf, producing order-dependent **double registration**
(the command registry is last-writer-wins) whenever a child calls
`super.register()` or shares a tool namespace. Single-level is also strictly
safer — it cannot double-register. Shared code should use composition (static
helpers), not an intermediate base.

The export-strip plugin (`export_strip.gd`) uses the **same** single-level
definition (`base == "MCPToolkitExtension"`), so "what is an extension" has one
meaning across discovery and stripping. Extension files are orphaned in a shipped
build anyway (the editor-only loader that references them is stripped, and
GDScript loads lazily), so stripping is build hygiene rather than
crash-prevention; a stray multi-level file simply ships as a harmless orphan.

## Considered alternatives

- **Transitive discovery (walk the full ancestry).** Rejected: enables multi-level
  but breaks the intuitive "subclass an existing extension to customise it"
  pattern with order-dependent duplicate registrations, and adds an
  intermediate-base hot-reload cache-staleness edge.
- **Transitive strip with single-level discovery.** Rejected: two different
  definitions of "extension" in one feature, plus a base-name-prefix
  false-positive, for no real benefit — the files it would catch are harmless
  orphans.

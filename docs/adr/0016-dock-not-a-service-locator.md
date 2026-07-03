# The dock is a UI surface, not a service locator

Three cross-cutting behaviors were reachable only through the dock: writing
`.mcp.json` from the bundled template (`dock.write_mcp_json`), showing the
Info / Help dialog, and showing the extension catalog (`dock.show_info_dialog` /
`dock.show_extension_catalog`). The Tools menu and the onboarding wizard held a
dock reference solely to call them — the dock had drifted into a **service
locator**: consumers reached *through* it for behaviors that are not dock
behaviors at all (the two dialogs are not even dock children — they parent to
`EditorInterface.get_base_control()`), coupling every non-dock surface to the
dock's presence and API. The coupling was about to get worse: the enable-time
`.mcp.json` prompt can fire when the dock isn't built, so it cannot route
through a dock method at all.

**Decision: the dock is a UI surface, not a service locator. Cross-cutting
behaviors live in injected collaborators, and every surface — the dock included
— consumes them.**

Two collaborators, deliberately not one (lumping a config-write flow and a
dialog presenter into one shared class would just rebuild a smaller service
locator):

- **`ui/mcp_json_write_flow.gd`** owns the confirm-then-write `.mcp.json` flow:
  the overwrite confirmation, its Cancel-opens-the-file recovery, delegation to
  `MCPJsonSync.write_from_template` (which stays pure I/O), and the outcome
  report through a caller-supplied `(ok, message, severity, tooltip)` callback.
  The dock panel supplies its toast-and-resync sink, the Tools menu its own
  toast, the wizard fires and forgets.
- **`ui/toolkit_dialog_presenter.gd`** owns the two editor-global dialogs
  (Info / Help, extension catalog): lazy creation, base-control parenting,
  reuse across shows, and immediate-`free()` disposal.

**Wiring.** The composer builds both **before** the dock and injects them into
the dock, the Tools menu, and the wizard; the Handle owns their lifecycle — its
`dispose()` frees the presenter's dialogs immediately during teardown,
preserving the leak-check-safe immediate-free discipline the dock's
`_exit_tree` used to provide. The wizard no longer receives the dock at all
(its dock-reveal step was already plugin-owned); the Tools menu keeps a dock
reference **only** for `show_audit_dialog()`.

**Audit stays a dock section.** The audit viewer is owned by the dock's audit
section (settings + view/clear + lazy viewer) — a genuine dock surface, not an
editor-global dialog — so `dock.show_audit_dialog()` remains the correct route,
not a locator smell. See the "dock section vs editor-global dialog" boundary in
`docs/dev/glossary.md`.

**The boundary test for future behaviors:** if a dialog parents to the editor
base control, or a flow can fire when the dock isn't built, it belongs in an
injected collaborator — never behind a dock method.

## Considered alternatives

- **One combined "dock services" collaborator.** Rejected — a config-write flow
  and a dialog presenter are two unrelated responsibilities with different
  reasons to change; one class serving both is a smaller service locator under
  a new name.
- **Folding the confirm-write flow onto `MCPJsonSync`.** Rejected — the
  repository is UI-free by design (pure file I/O, no EditorInterface); the
  confirmation dialog and the OS-open recovery are UI flow.
- **Moving the audit dialog out too.** Rejected — the audit viewer is a dock
  section's lazy child, not an editor-global dialog; extracting it would cut a
  cohesive dock section in half.

Iteration: `Plan/ExecutionPlan/41n-undecies-call-method-tool-hint.md` (Part F);
grill log `Plan/Reference/GrillingSessions/2026-07-03-41n-undecies-pass3-sweep-fixes.md`.

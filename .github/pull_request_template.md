## Summary

<!--
Show the change in the smallest view that makes the point: pseudocode, a call
tree, a scene/node tree, a shallow file tree, a Mermaid diagram, or a `diff`
sketch of the shape that changes. Keep prose to a line or two around it, and use
the terms in docs/dev/glossary.md.
-->

## Evidence

<!--
Show that the change works, before and after. Screenshots are best for a visual
change (a dock, an inspector, the viewport); otherwise paste test or console
output, naming the test that failed before and passes now.
-->

- **Before:**
  **After:**

## Merge Danger

<!--
Door: two-way if a revert undoes it cleanly; one-way if it is hard to walk back
(a contract or wire-format change, a renamed setting, deleted data).
Blast Radius: one word for how far a break would reach (e.g. none, docs, editor,
runtime, contract), then any ramifications worth flagging.
-->

**Door:**

**Blast Radius:**

## Checklist

- [ ] `validate_gdscript.sh` passes (if GDScript changed)
- [ ] Smoke test passes (`npm run smoke` in server repo)
- [ ] Code follows the [coding standards](https://github.com/NPGameDev/godot-mcp-toolkit/blob/main/docs/dev/code-standards.md)
- [ ] Contract changes (dispatch, command results, transport) are reflected in [`docs/dev/contract.md`](https://github.com/NPGameDev/godot-mcp-toolkit/blob/main/docs/dev/contract.md)
- [ ] No unrelated changes included
- [ ] Commit message follows [Conventional Commits](https://www.conventionalcommits.org/)
- [ ] CHANGELOG.md updated (if user-facing)

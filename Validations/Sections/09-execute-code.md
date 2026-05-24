# Section 9 — execute_code & Hints

**Dependencies:** Section 2 (main.tscn open with nodes)
**Tools tested:** execute_code (editor context)
**Tests:** 8
**Gate:** Skip entire section if execute_code is unavailable (read-only mode)

---

**9.1** `execute_code` — code=`2 + 2`
- **Expect:** Returns 4

**9.2** `execute_code` — code=`EditorInterface.get_edited_scene_root().name`
- **Expect:** Returns "Sv2Main" (editor context)

**9.3** `execute_code` (singleton hint) — code=`OS.get_name()`
- **Expect:** error OR result. If error, must include hint about Expression limitations with singletons and suggest alternatives.

> **REGRESSION WATCH (FIX-4, T:98c02f3):** If `OS.get_name()` FAILS without a
> helpful hint mentioning Expression limitations and suggesting alternatives,
> the singleton hint has regressed. Note: 4.5+ may support this — if it succeeds,
> that's fine too. Flag as **Major** only if it fails without hint.

**9.4** `execute_code` (load() hint) — code=`load("res://icon.svg")`
- **Expect:** error with context-aware hint distinguishing "load a resource for assignment" vs "execute script logic"

> **REGRESSION WATCH (FIX-H + 279efed):** If load() fails with only a generic
> "method not found" error without the expanded context-aware hint, the load()
> hint has regressed. The hint should mention node_set_property for resource
> assignment or suggest runtime context for script execution. Flag as **Major**.

**9.5** `execute_code` — code=`get_tree().get_nodes_in_group("sv2_test")`
- **Expect:** Returns empty array `[]`

**9.6** `execute_code` — code=`Engine.get_version_info()["major"]`
- **Expect:** Returns 4 (or error with hint if Expression can't access Engine)

**9.7** `execute_code` — code=`invalid syntax here @@@`
- **Expect:** error with diagnostic info (parse failure)

**9.8** `execute_code` — code=`ProjectSettings.get_setting("application/config/name")`
- **Expect:** error OR success depending on Expression sandbox. If error, should have hint.

---

## Cleanup

None.

# Section 11 — Save System

**Dependencies:** None
**Tools tested:** save_write, save_read, save_list, save_delete
**Tests:** 4

---

**11.1** `save_write` — save_path=`user://saves/sv2_save.json`, content=`{"score": 42, "level": 3}`
- **Expect:** success

**11.2** `save_read` — save_path=`user://saves/sv2_save.json`
- **Expect:** JSON content with score=42, level=3

**11.3** `save_list`
- **Expect:** includes sv2_save.json

**11.4** `save_delete` — save_path=`user://saves/sv2_save.json`
- **Expect:** success

---

## Console error check

Call `editor_get_console` and scan output since section start for unexpected errors.
- **FAIL** if any line contains: `UndoRedo history mismatch`, `SCRIPT ERROR`, `FATAL`, or unexpected `ERROR:` lines not caused by intentional guard tests.
- **PASS** if only expected noise (e.g., `Failed loading resource` from NOT_FOUND guard tests).
- Note: expected errors from guard tests (e.g., loading nonexistent resources) are NOT failures.

## Cleanup

- Call `discover_tools` with reset=true to deactivate all on-demand groups activated during this section

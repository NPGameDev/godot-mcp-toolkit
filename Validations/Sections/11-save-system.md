# Section 11 — Save System

**Dependencies:** None
**Tools tested:** save_write, save_read, save_list, save_delete
**Tests:** 7

---

**11.1** `save_write` — save_path=`user://saves/sv2_save.json`, content=`{"score": 42, "level": 3}`
- **Expect:** success

**11.2** `save_read` — save_path=`user://saves/sv2_save.json`
- **Expect:** JSON content with score=42, level=3

**11.3** `save_list`
- **Expect:** includes sv2_save.json

**11.4** `save_delete` — save_path=`user://saves/sv2_save.json`
- **Expect:** success

**11.5** `save_read` — path=`user://addons/godot_mcp_toolkit/anything`
- **Expect:** PATH_DENIED — the entire `user://addons/godot_mcp_toolkit/` directory is denied (protects auth token, audit log)

**11.6** `save_write` — path=`user://addons/godot_mcp_toolkit/evil.txt`, content=`x`
- **Expect:** PATH_DENIED

**11.7** `save_read` paging + configurable cap (concern 025)
1. `save_write` — path=`user://saves/sv2_page.txt`, content = a 1000-char string (e.g. 1000× `A`)
2. `save_read` — path=`user://saves/sv2_page.txt`, `max_bytes`=400
   - **Expect:** `bytes_returned`=400, `offset`=0, `next_offset`=400, `total_bytes`=1000, `truncated`=true
3. `save_read` — path=`user://saves/sv2_page.txt`, `offset`=400, `max_bytes`=400
   - **Expect:** `bytes_returned`=400, `next_offset`=800, `truncated`=true
4. `save_read` — path=`user://saves/sv2_page.txt`, `offset`=800, `max_bytes`=400
   - **Expect:** `bytes_returned`=200, `next_offset`=1000, `truncated`=false (final window — page until `truncated` is false)
5. `save_read` — path=`user://saves/sv2_page.txt`, `offset`=1000 (at EOF)
   - **Expect:** success, `bytes_returned`=0, `next_offset`=1000, `truncated`=false (no error past EOF)
6. Cap: set `mcp_toolkit/limits/save_read_cap_kb`=64 (Project Settings → `mcp_toolkit/limits/`, or `meta_set_limits save_read_cap_kb=64`), then `save_read` with `max_bytes`=100000
   - **Expect:** INVALID_PARAMS (window exceeds the 64 KB cap; default 256 KB == the former hardcoded ceiling, so the default is unchanged)
   - Restore the cap to 256 afterward.
7. `save_delete` — path=`user://saves/sv2_page.txt` (cleanup)

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- Call `discover_tools` with reset=true to deactivate all on-demand groups activated during this section

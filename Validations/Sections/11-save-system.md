# Section 11 — Save System

**Dependencies:** None
**Tools tested:** save_write, save_read, save_list, save_delete
**Tests:** 6

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

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- Call `discover_tools` with reset=true to deactivate all on-demand groups activated during this section

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

**11.7** `save_read` paging (concern 054 — uniform pagination)

> **`save_read_cap_kb` is NOT covered here — by design.** The configurable
> read cap (`mcp_toolkit/limits/save_read_cap_kb`) is *config*, not an
> agent-settable param — and it intentionally is not (you do not want an LLM
> raising its own output ceiling). It cannot be exercised end-to-end from the
> agent-driven sweep, so it is validated **server-side** in smoke
> `test/sections/21_response_caps.ts` (§21), which owns the cap-enforcement
> coverage (window-exceeds-cap → INVALID_PARAMS, default-ceiling unchanged).
> Do not re-add a cap step here.

> **Fixture size — keep tiny on purpose.** A 10-byte file exercises the exact
> same multi-window pagination contract (truncated → truncated → final, hint
> presence/absence, clean EOF) as a megabyte file. Use a small `max_bytes` so a
> few bytes page across 3 windows. Do NOT inflate the fixture to hundreds or
> thousands of bytes — large inline content bloats agent context and slows the
> sweep substantially with zero added coverage.

1. `save_write` — path=`user://saves/sv2_page.txt`, content = a 10-char string (`AAAAAAAAAA`, 10× `A`)
2. `save_read` — path=`user://saves/sv2_page.txt`, `max_bytes`=4
   - **Expect:** `bytes_returned`=4, `offset`=0, `next_offset`=4, `total_bytes`=10, `truncated`=true. Uniform pagination contract (concern 054): because `truncated` is true, a `hint` field is present naming `next_offset`.
3. `save_read` — path=`user://saves/sv2_page.txt`, `offset`=4, `max_bytes`=4
   - **Expect:** `bytes_returned`=4, `next_offset`=8, `truncated`=true, `hint` present (truncated).
4. `save_read` — path=`user://saves/sv2_page.txt`, `offset`=8, `max_bytes`=4
   - **Expect:** `bytes_returned`=2, `next_offset`=10, `truncated`=false, **no `hint`** (final window — the hint is omitted once `truncated` is false; page until then). Same contract shape as `script_read` (see Section 6.2), in byte units.
5. `save_read` — path=`user://saves/sv2_page.txt`, `offset`=10 (at EOF)
   - **Expect:** success, `bytes_returned`=0, `next_offset`=10, `truncated`=false (no error past EOF)
6. `save_delete` — path=`user://saves/sv2_page.txt` (cleanup)

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- Call `discover_tools` with reset=true to deactivate all on-demand groups activated during this section

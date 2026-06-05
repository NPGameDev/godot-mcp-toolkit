# Advanced Configuration

These are **optional fine-tuning knobs** that most users never need to touch —
the defaults are chosen to work well out of the box. They live under
**Project → Project Settings → `mcp_toolkit/`** (enable *Advanced Settings* to
see them) and can also be set with `ProjectSettings`.

None of these values are clamped in code: the recommended ranges below are
guidance, not enforced limits. An extreme value is allowed and is your
responsibility.

## Concurrency

The toolkit serialises editor mutations and arbitrates scene access across
multiple MCP clients. These keys tune that machinery.

### `mcp_toolkit/concurrency/scan_idle_timeout_ms` — default `5000`

How long a scene save or open waits for an in-progress `EditorFileSystem` scan
to finish before giving up, in milliseconds. Opening or saving a scene *during*
a scan can read inconsistent filesystem state and crash the editor, so the
toolkit waits the scan out first and **aborts the operation with a `TIMEOUT`
error** if the scan hasn't settled in time — it never proceeds into an active
scan.

- `0` = fail fast (don't wait at all).
- Recommended `1000`–`30000`.
- Raise it for large projects whose imports take long to scan, at the cost of
  longer save/open stalls when a scan is genuinely stuck.

### `mcp_toolkit/concurrency/mutation_watchdog_grace_ms` — default `60000`

Extra grace, in milliseconds, added to a mutation's deadline before the dispatch
**watchdog** force-clears a wedged mutation lock. The deadline is the in-flight
command's *declared* `timeout_ms` (or the 300 s system maximum for a command
that doesn't declare one) **plus** this grace.

The watchdog is a **safety net**: it only fires if a mutation handler aborts or
hangs and would otherwise block *all* further mutations until the editor
restarts. In normal operation it never fires. Lowering this shortens recovery
from such a (rare) wedge but risks force-clearing a legitimately slow handler;
the generous default makes a false fire effectively impossible for any
well-behaved command.

### `mcp_toolkit/concurrency/scene_lease_ttl_ms` — default `8000`

When multiple clients edit different scenes, a time-bounded *lease* prevents
cross-scene contamination: tab-dependent commands from a non-holding client
queue until the holder's lease expires. This is how long, in milliseconds, the
holder may go without renewing before a waiting client can steal the lease.

- Lower = snappier hand-off between clients, but more tab switching.
- Higher = fewer tab switches, but a waiting client blocks longer.

## Limits

### `mcp_toolkit/limits/ws_buffer_kb` — default `1024`

WebSocket per-peer buffer size, in KB (minimum 256). Raise it if you send very
large payloads (e.g. big `script_write` bodies) and see truncated or dropped
connections under load. Can also be overridden per-connection by the
`GODOT_MCP_WS_BUFFER_LIMIT` env var in `.mcp.json`.

---

*These are advanced tunables. If you're not sure, leave the defaults.*

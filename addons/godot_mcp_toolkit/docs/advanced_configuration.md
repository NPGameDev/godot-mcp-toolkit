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

## Editor responsiveness while unfocused

> **Note — these two keys live in Editor Settings, not Project Settings.**
> Open **Editor → Editor Settings** and search for `mcp_toolkit/performance`.
> Everything else in this document is a *Project* setting; these two are the
> exception, because they control a **machine-global editor behaviour** and are a
> personal battery/CPU preference — so they are deliberately **not** written to
> `project.godot` (never committed to version control).

When the editor loses focus, Godot throttles its process loop to a low-power
frame rate (the `interface/editor/unfocused_low_processor_mode_sleep_usec`
editor setting, ~10 fps by default). The toolkit polls its WebSocket inside that
loop, so an unfocused editor answers MCP commands only ~2–3 times per second.
During a normal MCP session the editor *is* unfocused (you're looking at the chat
window), so the toolkit raises the unfocused frame rate while a client is
connected, then restores it on the last disconnect.

### `mcp_toolkit/performance/keep_editor_responsive_unfocused` — default `true`

Opt-in switch. When **on** (default), the toolkit boosts the unfocused frame rate
while at least one MCP client is connected. When **off**, Godot's default
low-power unfocused throttle is left untouched — choose this if you are
battery/CPU-sensitive and don't mind slower command pickup while the editor sits
in the background. A matching toggle and a live **Off / On (idle) / On · active**
indicator are in the dock's *Server Status* section.

### `mcp_toolkit/performance/unfocused_responsive_sleep_usec` — default `16666`

The boosted unfocused process sleep, in microseconds. Lower = higher frame rate =
snappier commands but more background CPU. Not clamped.

- `16666` ≈ **60 fps** (default) — maximum snappiness; also keeps automated
  smoke/sweep runs fast. Zero behavioural change from earlier toolkit versions.
- `33333` ≈ **30 fps** (power-saver) — roughly half the background CPU. The
  difference is imperceptible to an interactive user (command latency is
  dominated by the agent's thinking time) and adds only ~20–30 s to a full
  automated smoke run.
- The poll loop runs every 4th frame, so the effective MCP poll rate is about a
  quarter of the frame rate (≈15 Hz at 60 fps, ≈7.5 Hz at 30 fps).

> A quick CPU sanity-check on one machine showed an idle editor's background CPU
> at 60 fps vs 30 fps vs the 10 fps default differs only modestly; exact numbers
> are machine-specific, so treat the above as guidance, not a measurement.

### Crash- and concurrency-safety

The boosted value is a machine-global setting, and Godot only flushes editor
settings to disk on certain events (closing the settings dialog, quitting, …), so
a crash *after* such a flush — or a second editor running at the same time —
could otherwise leave the setting stranded at the boosted value. To prevent that:

- Before boosting, the toolkit records the **true original** value once, to a
  small machine-wide, Godot-version-keyed backup file (in the toolkit's registry
  directory — the same place multi-instance discovery uses), under a
  first-writer-wins file lock. A second editor that connects while the first is
  already boosting will **not** overwrite that backup, so the true original is
  never lost.
- On the last disconnect — and again as a **self-heal on the next editor
  startup** — the toolkit reverts the setting **conflict-aware**: if the live
  value still equals the value the toolkit wrote, it is restored to the true
  original; if you (or another tool) changed it in the meantime, **your value is
  kept** and the backup is simply cleared. Either way the boost can never persist
  without a live connection.

**Documented edge cases:**

- If you manually set the key to *exactly* the boosted value while it is already
  boosted, Godot emits no change event (same-value writes are no-ops), so the
  toolkit cannot tell your value from its own — on restore it treats it as its own
  and reverts to the original. This is the single case the conflict-aware check
  cannot detect.
- With two editors connected at once, if the first disconnects it restores the
  setting while the second is still connected, so the second runs at the default
  unfocused rate until its next fresh connection. This is a brief responsiveness
  dip, never a persistent change, and matches the toolkit's earlier behaviour.

---

*These are advanced tunables. If you're not sure, leave the defaults.*

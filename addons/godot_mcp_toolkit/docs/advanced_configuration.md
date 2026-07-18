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

## Reading large data — caps & the pagination contract

Read tools that can return a large payload are **capped per call** and **paginate**
instead of streaming a whole file in one response (responses are sent whole over a
size-limited WebSocket frame, so an uncapped read would silently drop). Two tools
page today — `save_read` (a `user://` file, in **bytes**) and `script_read` (a
project script, in **lines**) — and they share one **uniform pagination contract**,
so the loop you learn for one applies to the other.

### The uniform pagination contract

On a capped read you always get:

- **`has_more`** (bool) — `true` when more data remains beyond this window,
  `false` when this window reached the end. Always present on a successful read.
- **`total_<unit>`** — the full size of the source (`total_bytes` for `save_read`,
  `total_lines` for `script_read`), so you know how much is left.
- **`returned`** — the size of this window (bytes for `save_read`, lines for
  `script_read`).
- **`next_<cursor>`** — the value to pass back to resume, present **only when
  `has_more` is `true`** (`next_offset` for `save_read`, `next_start_line` for
  `script_read`).
- **`hint`** — a one-line prose instruction, present **only when `has_more` is
  `true`**, telling you exactly which cursor to feed back.

**The loop is always the same:** call the tool; if `has_more` is `true`, pass the
returned `next_<cursor>` back as the matching request parameter and call again;
stop when `has_more` is `false`.

**Worked example — `save_read` (bytes).** Request `offset` (default `0`) +
`max_bytes`; resume with `next_offset`:

```
save_read  path=user://saves/big.dat  max_bytes=400
  → { returned: 400, offset: 0, next_offset: 400,
      total_bytes: 1000, has_more: true,
      hint: "more bytes remain — re-call save.read with offset = next_offset (400) until has_more is false" }
save_read  path=user://saves/big.dat  offset=400  max_bytes=400
  → { returned: 400, next_offset: 800, total_bytes: 1000, has_more: true, hint: … }
save_read  path=user://saves/big.dat  offset=800  max_bytes=400
  → { returned: 200, next_offset: 1000, total_bytes: 1000, has_more: false }   # done — no hint
```

**Worked example — `script_read` (lines).** Request `start_line`/`end_line`
(1-based); resume with `next_start_line`:

```
script_read  file_path=res://big.gd  start_line=1  end_line=200
  → { start_line: 1, end_line: 200, total_lines: 520, returned: 200, has_more: true,
      next_start_line: 201,
      hint: "more lines remain — re-call script.read with start_line = next_start_line (201) until has_more is false" }
script_read  file_path=res://big.gd  start_line=201  end_line=400
  → { start_line: 201, end_line: 400, total_lines: 520, returned: 200, has_more: true, next_start_line: 401, hint: … }
script_read  file_path=res://big.gd  start_line=401  end_line=600
  → { start_line: 401, end_line: 520, total_lines: 520, returned: 120, has_more: false }   # clamped to EOF, done — no hint
```

A **full** `script_read` (no `start_line`) that fits under the cap returns
`has_more: false` and `total_lines` as well, so both read shapes carry the same
fields. The request-parameter names stay unit-appropriate (`offset`/`max_bytes`
for bytes, `start_line`/`end_line` for lines) — only the response *shape* is
uniform.

### When a cap change takes effect (no restart)

The limit settings below are read by the handler **on every call**, so a change —
via the dock's spinbox, the Settings UI, or `meta_set_limits` — applies to the
**very next call**. There is no restart and no reconnect.

**The server is not pushed the value.** The MCP server advertises a *static*
`max_bytes` schema bound as a sanity ceiling; the **toolkit enforces the real,
live cap at call time**. A request above the live cap is rejected with
`INVALID_PARAMS` whose message names the *current* cap — so if you lower the cap,
the model learns the new limit **reactively from that error**, not from the
advertised schema. (This is why a value that the schema appears to permit can
still be rejected: the live cap is authoritative.)

## Limits

### `mcp_toolkit/limits/save_read_cap_kb` — default `256`

The largest window `save_read` returns in a single call, in KB (minimum 64). A
`user://` file bigger than this cap can still be read in full by paging — see
**Reading large data** above for the `offset` / `next_offset` loop. This is the
only way to read a file larger than the WebSocket frame ceiling (see `ws_buffer_kb`
below), because responses are sent whole.

Raising this above `ws_buffer_kb` is a footgun: a window that would not fit the
WebSocket buffer is rejected with `FILE_TOO_LARGE` before it is sent, rather than
silently dropped. If you raise the cap, raise `ws_buffer_kb` to match (and note
the runtime caveat below).

### `mcp_toolkit/limits/script_read_cap_kb` — default `256`

The largest payload `script_read` returns in a single call, in KB. A project
script bigger than this cap is read in full by paging on **lines** — see **Reading
large data** above for the `start_line` / `next_start_line` loop. A full read that
would exceed the cap is rejected with `FILE_TOO_LARGE` and a hint to use a line
range.

### `mcp_toolkit/limits/ws_buffer_kb` — default `1024`

WebSocket per-peer buffer size, in KB (minimum 256). Raise it if you send very
large payloads (e.g. big `script_write` bodies) and see truncated or dropped
connections under load. Can also be overridden per-connection by the
`GODOT_MCP_WS_BUFFER_LIMIT` env var in `.mcp.json`.

> **Runtime (exported game) caveat.** This setting tunes the **editor** server
> only. The runtime server that runs inside an exported game uses a **fixed 1 MB
> per-peer buffer** and ignores `ws_buffer_kb`, so raising `ws_buffer_kb` does
> **not** raise the runtime ceiling — page large runtime reads with `save_read`'s
> `offset` instead.

## Listen ports (editor & runtime)

Two of the toolkit's three MCP channels bind a **dynamic** TCP port. By default
each **scans** a small band and publishes the bound port to the machine-wide
registry, so the MCP server discovers it with no configuration. You can instead
**pin** an exact port or **relocate** the scan band, per channel. These are read
from the process environment (the `.mcp.json` `env` block, or a shell `export`
before launch) — the toolkit never writes them.

| Env var | Channel | Effect | Default |
|---|---|---|---|
| `GODOT_MCP_EDITOR_PORT` | Editor channel | **Pin** — bind this exact port or fail | — (scan) |
| `GODOT_MCP_EDITOR_PORT_MIN` / `_MAX` | Editor channel | **Relocate** the scan band (inclusive) | `6550` / `6560` |
| `GODOT_MCP_RUNTIME_PORT` | Runtime channel (the running game) | **Pin** — bind this exact port or fail | — (scan) |
| `GODOT_MCP_RUNTIME_PORT_MIN` / `_MAX` | Runtime channel | **Relocate** the scan band (inclusive) | `6570` / `6585` |

The same `GODOT_MCP_EDITOR_PORT` / `GODOT_MCP_RUNTIME_PORT` are **also read by the
MCP server** to decide which port to **dial** — inherited by both processes, a pin
makes listen and dial agree with zero discovery. The `_MIN`/`_MAX` band vars are
**listen-side only** (the server never reads them; discovery covers the scanned
case). The third channel — the GDScript **LSP** — is Godot's to bind, so it stays
**connect-pin-only** via the server-side `GODOT_MCP_LSP_PORT` / `GODOT_MCP_LSP_HOST`
(next section).

### Pinned vs. Scanned — the two modes are exclusive

- **Pinned** (a `*_PORT` pin is set): the listener binds that **exact** port or
  **fails loudly** — it never scans to a different port. If the port is occupied it
  retries the same port briefly (to ride out a previous instance still releasing
  it), then surfaces a **dock warning** (editor) or a loud game-console error
  (runtime) naming the port. A pin makes the `_MIN`/`_MAX` band **irrelevant** — it
  is ignored (a one-line note is logged).
- **Scanned** (no pin): the listener scans the band (default, or `_MIN`/`_MAX` if
  set), binds the first free port, and publishes it for discovery. This is the
  **low-friction** default — you don't have to manage env on both sides. If the
  **whole band** is occupied, the editor shows the same dock warning naming the
  range and keeps retrying.

A malformed pin, an out-of-range port (valid range `1–65535`), or `MIN > MAX` is a
**clear error** on the dock + console, never a silent fall-back to the default.

### An environment variable is not a sync channel

The editor process (which **listens**) and the MCP server process (which **dials**)
read the environment **independently**. A pin only makes them agree if **both**
processes inherit the **same** value:

- **The normal `.mcp.json` case sets `env` for the server only.** If you also launch
  the Godot editor from a **desktop shortcut**, that shortcut does **not** inherit a
  shell's transient `export` (notably on Windows), so the pin reaches the server but
  not the editor — the server would then dial a port nobody is listening on. It now
  **fails fast** with a precise message instead of hanging (and the editor dock shows
  the mismatch), but the real fix is to make both sides inherit the pin.
- **The supported pattern (harness / parallel tests):** `export` the pin **once**,
  then launch the editor **and** the MCP server/client as children of that same
  environment so both inherit it:

  ```bash
  export GODOT_MCP_EDITOR_PORT=6557
  godot --editor --path /path/to/project &   # editor inherits the pin (listens on 6557)
  # …launch the MCP client from the same shell so its server inherits it too (dials 6557)
  ```

- **Prefer Scanned mode** if you don't want to manage env on both sides — registry
  discovery keeps the two in agreement automatically.

## macOS: launching your MCP client (Node / PATH)

Modern GUI-launched MCP clients — Claude Desktop, VS Code, and Cursor — capture
your login shell's environment and resolve a bare `npx` to a version-manager Node
on their own, so the standard `npx -y @npgamedev/godot-mcp-server` config connects
whether you launch the client from Finder/Dock or a terminal. The toolkit writes
that standard command; there is nothing macOS-specific to configure.

**If a client won't connect on macOS**, work through these:

- **Launch the client from a terminal to see its error.** `open` won't help — start
  the app's binary from a shell. A terminal launch inherits your `PATH` and prints
  the client's real startup error, which tells you what to fix.
- **Confirm `.mcp.json` is present at your project root** and Node 22+ is installed
  (`node --version`). If `.mcp.json` is missing, click **Write .mcp.json** in the
  MCP Toolkit dock.
- **Move your version-manager init into `~/.zprofile`.** If your Node lives behind a
  version manager (nvm/fnm/volta) whose init is only in `~/.zshrc`, a login-shell
  launch won't see it — add it to `~/.zprofile` too so Finder/Dock launches resolve
  Node as well.
- **Zero-config alternative:** install Node from the **official nodejs.org
  installer**. It lands on the default `PATH`, so no shell setup is needed.

**Point a Mac at a local server build** (development) by setting
`GODOT_MCP_DEV_SERVER_PATH` in the environment to your built `dist/index.js` — the
toolkit then emits a `node <that path>` command instead of the released `npx` form.

## Language server (LSP)

The `lsp_*` tools connect to Godot's built-in GDScript language server. The MCP
server discovers the right endpoint per project from the registry, so a **single
editor needs no configuration**. These two env vars (set in a project's
`.mcp.json` `env` block) override discovery — needed only when running the LSP in
**more than one editor at once** (see `docs/multi-instance.md`).

### `GODOT_MCP_LSP_PORT` — default: discovered (else `6005`)

The GDScript LSP port this project's server connects to. Top priority — bypasses
registry discovery. Set it to the `--lsp-port` you launched that editor with.

### `GODOT_MCP_LSP_HOST` — default: discovered (else `127.0.0.1`)

The host for the GDScript LSP. Rarely needed — the LSP is localhost-only. Mirrors
the familiar `lsp.serverHost` client setting.

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

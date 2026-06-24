---
status: accepted
---

# 0009 — Filesystem & untrusted-content trust boundary

The toolkit is the **authoritative** boundary for both halves of the file/content surface:
it is the only process that touches the filesystem and the only one that returns
project-authored content to the LLM. The server is a thin npm bridge that adds
**defense-in-depth**, never the primary guard. This ADR records where each protection lives
and — as importantly — where it deliberately does **not**, so a future refactor (or the 41n
review) doesn't re-open or accidentally weaken it.

## Threat model

The **LLM is the untrusted actor.** Two risks: (1) it supplies a path that escapes the
project (`../`, absolute, UNC, symlink) to read/write outside `res://`/`user://`; (2) it is
fed file/project content that contains injected instructions it mistakes for commands.
Installed *extensions* run at full trust (they can do raw `DirAccess` I/O) and are **out of
scope** — the guards below protect a *well-meaning* command from *LLM-supplied* input, not
the host from a malicious extension.

## Decision

**Path guarding — authoritative in the toolkit; syntactic subset on the server.**
- `FileGuard.resolve_safe(path, ["res://"])` (the **project guard**) and
  `resolve_safe_user(path)` (the **user guard**, `user://`, also denies plugin internals) are
  called by **every** fs handler before any I/O. They reject empty / `..` / absolute / UNC /
  non-allowed-prefix **and canonicalize** (`globalize_path → simplify_path`) to re-assert the
  boundary after lexical `.`/`..` collapse. Canonicalization is **lexical only** — it does *not*
  resolve OS symlinks, so a symlink escape is **out of scope** (single-user localhost threat
  model; see 41n concern 021). Canonicalization is editor-side, so only the toolkit can do it.
- The server adds a **purely syntactic** pre-filter (`src/path_guard.ts`), declared per-tool
  via `ToolDef.pathParams` and wired once into dispatch (`registerToolWrapped`), that
  fast-fails an out-of-bounds path with `PATH_DENIED` **before** the WS round-trip. It is a
  **strict subset** of the toolkit guard: it must never reject a path the toolkit accepts. It
  does **not** canonicalize.

**Untrusted content — wrap once, at origin.** `Untrusted.wrap(kind, source, body)` envelopes
content in a per-call-nonce `<untrusted-{8hex}>` tag and **scrubs inner envelope tags**
(anti-breakout). It is applied where the bytes are first produced — the **toolkit** for fs/
project content (`script.read`, `resource.load`, `scene.get_tree`, `save.read`, animation,
console/errors, project settings), the **server** only for content it fetches itself (LSP
hover). The server **passes toolkit-wrapped content through untouched** — re-wrapping would
double-wrap, and because the wrapper scrubs inner tags it would corrupt the envelope the LLM
relies on.

**Extension path guards — declarative, toolkit-enforced only.** `MCPToolkitCommandOptions`
exposes `.guard_project_path(param)` / `.guard_user_path(param)`; the dispatch
(`mcp_toolkit_command_registry.call_command`) runs the matching `FileGuard` on the declared param before
invoking the handler. Opt-in; **not** flowed to the server (the toolkit is authoritative, and
this keeps the extension contract flexible). Extension authors also have the imperative
helpers — `Untrusted.wrap` and `FileGuard.resolve_safe`/`resolve_safe_user` — documented in
`extending.md`, for output-wrapping and for path needs the declarative guards don't cover.

## Terminology

- **Project guard** — `FileGuard.resolve_safe` (`res://` boundary). Used by reads, writes, and
  deletes alike — the name is about the *domain*, not the operation.
- **User guard** — `FileGuard.resolve_safe_user` (`user://` boundary; also denies the toolkit's
  own internal paths).
- **Untrusted envelope** — the `<untrusted-{nonce} kind=… source=…>…</untrusted-{nonce}>`
  wrapper signalling to the LLM that the enclosed bytes are data, not instructions.

## Provenance rule for wrapping (the audit criterion)

**Wrap** any response field whose bytes originate **outside** the toolkit's/server's own code;
**do not wrap** toolkit-*generated* structural data or binary.

| Wrap (outside-origin) | Don't wrap (toolkit-generated / binary) |
|---|---|
| file contents (script, resource, save) | counts, status, success flags |
| user-authored scene / resource / animation data | paths the toolkit itself constructed |
| editor console / error output | ClassDB / engine metadata |
| project settings | screenshots / binary image data |
| external results the server fetches (LSP) | |

A 2026-06-13 completeness audit confirmed every fs handler calls a guard and every
outside-origin field is wrapped (no gaps). `FileGuard` and `Untrusted` are pinned by toolkit
units, and a shared path fixture is mirrored in the server + toolkit unit suites to enforce the
strict-subset invariant (no path is server-deny / toolkit-allow).

## Considered and rejected

- **A central `paramName → prefixes` map on the server.** Incomplete (12+ fs params, not 3),
  unsafe (it would false-reject `asset_import.source_path` (absolute-allowed), mis-prefix
  `editor_screenshot.save_path`, and catch scene-tree node paths), and **conflicts with
  extensions** (would wrongly guard an extension param merely named `file_path`). Replaced by
  per-`ToolDef` declaration.
- **Re-wrapping fs content on the server.** Double-wraps and corrupts the origin envelope.
- **Fully-declarative built-in path guards** (dropping the manual `resolve_safe` calls). A
  larger refactor; deferred to post-1.0. Built-ins keep their in-handler guards; extensions get
  the declarative form.
- **A declarative output auto-wrap flag for extensions.** Real footguns (which field?
  stringify? double-wrap vs the inner-tag scrub?); deferred to a Tentative idea. Extensions
  wrap output imperatively via the documented `Untrusted.wrap` helper instead.

## Consequences

- The server pre-filter is fail-open-safe: a missed param loses fast-fail but opens no hole
  (the toolkit still guards). New fs-path tools should declare `pathParams` (and add a case to
  the shared fixture) but forgetting can't create an escape.
- Contributors must not add server-side wrapping of toolkit content, nor a central server path
  map. Both are called out here and in code comments at the former TODO sites.

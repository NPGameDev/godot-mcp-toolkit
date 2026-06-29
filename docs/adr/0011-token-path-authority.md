---
status: accepted
---

# 0011 — Token-path authority (toolkit publishes, server validates)

Extends 0009 (the toolkit is the authoritative filesystem/content boundary; the server adds
defense-in-depth, never the primary guard).

## Context

The session token's on-disk LOCATION was a split contract. The toolkit wrote the token to a
`user://` path and published that `user://` literal into the registry, while the out-of-engine
server RE-DERIVED the absolute path independently: a SHA-256 of the canonical project root for the
per-instance subdirectory, `config/name` for the app-data folder, and a per-OS reimplementation of
Godot's user-data directory. That duplicated derivation was fragile and had ZERO awareness of
`application/config/use_custom_user_dir`: a project with a relocated user dir writes its token to the
relocated `user://` (engine-correct), but the server derived the DEFAULT `app_userdata` path and
opened the wrong file — a silent authentication failure with no actionable signal.

## Decision

- The TOOLKIT is the single authority for the token location. At its editor-side registry publish
  sites it publishes the GLOBALIZED ABSOLUTE path (`globalize_path(get_token_path())`) instead of the
  `user://` literal. `globalize_path` reads `use_custom_user_dir` live, so a relocated user dir is
  honored automatically. In-engine readers keep `get_token_path()`'s `user://` form. The runtime
  autoload's empty `token_path` is a separate writer and is never globalized.
- The SERVER consumes `entry.token_path` and re-asserts it STRUCTURALLY (lexical): absolute · no `..`
  segment · existing regular file · suffix `…/addons/godot_mcp_toolkit/project_instance_<12-hex>/mcp_token`
  (a FORMAT check on the instance segment, NOT a recomputed hash). It performs NO SHA-256 and NO path
  re-derivation.
- A missing, empty, malformed, or absent published token fails LOUD with `AUTH_FAILED` and an
  actionable relocation hint ("the project may have moved; reconnect or relaunch"). No silent
  stale-open, no hang.
- `GODOT_MCP_TOKEN_PATH` remains an explicit operator override: a trusted absolute path to an existing
  regular file, read directly, bypassing the registry and the suffix shape check.

## Threat model

The token is a SHARED SECRET. Redirecting the server to a different token file is a DENIAL OF SERVICE,
not privilege escalation: auth rejects a token T'≠T, and gaining access already requires holding T.
The structural-pattern guard constrains the real risks — it blocks `..` traversal and pins the
`…/project_instance_<hash>/mcp_token` suffix; the prefix stays unconstrained, acceptable only because a
redirected read yields no valid token and its contents never flow back to its writer. Symlink
resolution is out of scope — the single-user localhost threat model of 0009, under which
canonicalization is lexical only. The published path is already canonical (Godot globalizes a fixed,
clean `user://addons/…` template), so a `realpath` syscall would buy nothing. Recomputing the hash
would re-introduce the cross-repo hash-algorithm duplication this change removes, for ~zero marginal
security gain — and a decoupling's guard must not re-add the coupling it removes.

## Considered and rejected

- **Server-side hash recompute / path re-derivation** — the very coupling this change removes, and the
  source of the `use_custom_user_dir` blindspot.
- **`fs.realpath` symlink resolution** — contradicts 0009's lexical-only, single-user-localhost stance;
  the published path is already canonical, so it adds a syscall for no gain.
- **Dropping `GODOT_MCP_TOKEN_PATH` server-side** — a documented operator knob in the same trusted tier
  as `GODOT_MCP_PORT`: both are read from the `.mcp.json` server `env`, applied at launch and on
  config-reload. Removing it is a breaking change with no security benefit — and even at that
  reachability a redirected token is DoS-bounded (auth rejects a wrong token), never an escalation.

## Consequences

- Projects with a relocated `use_custom_user_dir` authenticate. The cross-repo hash duplication leaves
  the server entirely. There is one authority (the toolkit) for the token location; the server is a
  thin structural validator that fails loud instead of silently opening a stale or wrong path.

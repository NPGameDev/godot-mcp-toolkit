# 0025 — LSP claimant liveness is corroborated against the WebSocket port

**Status:** Accepted

**Date:** 2026-07-25

**Amends:** [ADR 0008](0008-lsp-port-registry-authoritative.md) — the
registry-authoritative decision stands; the liveness mechanism it names does not.

## Context

ADR 0008 made the server the authority on GDScript-LSP port ownership. It reads
the machine-wide `projects.json` registry, collects the entries claiming a given
`lsp_port`, keeps the ones whose recorded PID is still alive
(`liveLspClaimants`), and connects only when this project is the strictly
earliest such claimant. Every link in that chain held except the liveness test.

`process.kill(pid, 0)` answers one question: does a signalable process hold this
number? It does not say the process is a Godot editor, and it does not say it is
the editor that wrote the entry. PIDs are a bounded, recycled resource, and on
Windows they come back around fast enough to collide during ordinary use.

Two registry properties turn that gap into a user-visible failure:

- **Stale editor entries accumulate.** `RegistryProjection.rebuild()`
  (`addons/godot_mcp_toolkit/registry/store/registry_projection.gd`) deduplicates
  editor entries only when two of them claim the same WebSocket command **`port`**
  — and concurrent editors bind distinct WS ports (6550, 6552, 6553…), so that
  pass never fires between them. Entries with `port <= 0` are kept
  unconditionally. There is deliberately no dead-PID GC, because
  `OS.is_process_running()` returns false for live sibling editors on Windows. An
  editor that crashes or is force-killed never reaches `deregister()`, so its
  entry stays in `by_path` indefinitely.
- **Every editor publishes the same LSP port.** `lsp_publisher.gd`'s
  `resolve_lsp_endpoint()` reads `network/language_server/remote_port`, which is
  `6005` unless the user changed it. So each accumulated entry claims 6005.

A stale entry therefore becomes a live claimant of 6005 the moment its recorded
PID is handed to some unrelated process. It started before any editor opened
since, so it satisfies the `started_at <=` rule and the live project is the one
declared in conflict. The user gets `LSP_PORT_CONFLICT` on a machine with exactly
one editor open, and the error's advice — close the other editor, or pin
`--lsp-port` — names a second editor that does not exist.

The same predicate carries the defect further. `liveLspClaimants` also gates the
registry-miss fallback, so the same stale entry can produce `LSP_UNAVAILABLE` for
a project that has no entry of its own, and the dock's LSP indicator reads the
same resolution, so it flips to `conflict` alongside.

Captured evidence: four leaked entry files, all stale, none live. The two editor
entries came from editors closed three and eleven days earlier, and both of their
project directories still existed on disk.

## Decision

**An entry counts as a live LSP claimant only when its recorded PID is alive
*and* something answers on the WebSocket command port that same entry
advertises.**

- The PID check stays as the cheap first filter — a provably dead PID (`ESRCH`)
  is settled without opening a socket.
- The corroboration is a TCP connect to `127.0.0.1:<entry.port>`: the peer's own
  advertised WS command port, which is unique per editor. A closed editor is not
  listening there, and a recycled PID cannot fake it. The probe budget is 300 ms
  (a loopback refusal returns in single-digit milliseconds), the socket closes
  with a graceful FIN rather than a reset, and surviving candidates are probed
  concurrently, so the added latency is one round trip rather than one per entry.
- **`ECONNREFUSED` is the only outcome that removes a claimant.** A timeout, a
  local resource limit, an unrecognized error code, or a port that cannot be
  probed at all each leave the claimant counted.

That last rule is the fail-closed policy, and the reason is asymmetry rather than
caution: the two failure directions differ in kind. Treating an inconclusive
probe as proof of death drops a genuine rival, and on Godot 4.2–4.4 there is no
root-mismatch backstop behind the registry check (ADR 0008's "4.2–4.4
limitation"), so the result is another project's symbols returned with no
protest. That is the silent-wrong-data failure ADR 0008 exists to prevent.
Keeping an unproven claimant counted is at worst the behavior users already
have, a visible and wrong `LSP_PORT_CONFLICT`, and never worse than that.

The graceful FIN is for the peer's benefit. The toolkit wraps every accepted
stream in a `WebSocketPeer` and warns `accept_stream failed` when the stream dies
before the wrap (`ws_transport.gd`), so a reset would put probe noise in a real
editor's Output dock. Once wrapped, the reaped connection is silent: `cleanup()`
erases an unauthenticated closed peer without printing.

## Considered and rejected

- **Entry-file mtime as a freshness gate.** The entry file has no heartbeat. It
  is written at `register()`, again by a one-shot 5–10 s jittered re-verify, on a
  token rewrite, and on an LSP-settings change. Nothing refreshes it
  periodically, so `mtime` is a start timestamp carrying nothing `started_at`
  does not already carry, and an editor open for five days shows the same
  five-day-old timestamp as a dead one. Worse, only peers with `started_at <=`
  ours can trip the conflict rule, so a freshness gate would preferentially drop
  the long-running peers that constitute a **genuine** conflict. It fails in the
  dangerous direction.
- **A heartbeat field in the entry schema.** This would work. It needs a toolkit
  writer plus a schema field, and it only helps users who update the addon —
  whereas under ADR 0024 the server versions independently, so a server-side fix
  reaches every user on whatever addon they already have, including the entries
  already leaked on their disk.
- **Projection GC on an mtime TTL.** Inherits the mtime defect above, and its
  failure mode is deleting a live long-running editor's entry, which breaks that
  editor's own discovery.
- **Pruning by `lsp_port` in the projection.** Two genuinely live editors both on
  6005 *is* a real conflict; pruning one of them hides it. Deciding which to keep
  needs an in-Godot liveness signal, which does not exist.
- **Leaning on the 4.5+ root-verification guard alone.** It ships only on 4.5+.
  Softening the registry pre-check reopens the silent-wrong-project hole on
  4.2–4.4.
- **GC by project-path existence.** Disproved by the captured evidence: both
  stale entries' project directories still existed on disk.
- **Server-side GC of the registry.** `registry.ts` is a reader by contract —
  "the plugin writes; this module reads." Making the reader a writer would put
  two uncoordinated processes on one file.
- **A mockable probe seam for the tests.** Injecting a fake liveness result would
  re-introduce a heuristic into the very assertion meant to catch a bad liveness
  heuristic, and it adds production surface that exists only for tests. The tests
  bind real loopback listeners instead.

## Consequences

- **One predicate change closes both failure paths.** The conflict check and the
  registry-miss fallback both run through `liveLspClaimants`, so the false
  `LSP_PORT_CONFLICT` and the false `LSP_UNAVAILABLE` are the same defect and get
  the same fix. The dock indicator resolves through the same path and is
  corrected without a separate patch.
- **A genuinely live rival editor still conflicts.** The predicate narrows what
  counts as a claimant; it does not soften the `started_at <=` earliest-claimant
  rule, and a same-second tie still fails both sides rather than risk one of them
  returning another project's data.
- **Endpoint resolution becomes asynchronous.** The probe is a socket, so
  `liveLspClaimants` and everything above it up to `getLspStatus` return
  promises. The cost lands once per LSP connection, not once per request.
- **No user-facing text changes.** Post-fix, `LSP_PORT_CONFLICT` fires only for a
  peer that is PID-alive and answering on its WS port, which is a real editor. The
  existing version-tailored hint is correct advice for the only case that can now
  reach it, so hedging it would make the message less accurate. The message was
  only ever wrong because the verdict was.
- **The residual surface is narrow but real.** An unrelated process squatting on
  the exact WS port recorded in a stale entry would still corroborate that entry.
  That is a far smaller target than "any recycled PID," and it shrinks further
  because a new editor that binds a stale entry's WS port triggers the
  projection's same-`port` dedup on its own `register()`.

## Known limitation — a `--lsp-port` override still publishes 6005

This decision does not fix the second false-conflict class, and should not be
read as doing so. `resolve_lsp_endpoint()` reads only the editor setting, and the
engine consumes `--lsp-port` before the plugin can observe it, so an editor
launched with `--lsp-port 6015` still publishes `lsp_port: 6005`. That editor is
genuinely running with a responding WS port, so the new probe **corroborates**
it — working exactly as designed, and with no purchase whatsoever on a registry
entry that is honest about the wrong number.

The resulting shape: editor A is unpinned and genuinely owns 6005; B and C are
pinned to 6015 and 6025 but both publish 6005. If B or C started earlier, **A**
draws a false `LSP_PORT_CONFLICT`, while B and C carry `GODOT_MCP_LSP_PORT`
overrides that bypass the registry entirely and work fine, so the editor that
breaks is the one left on the default configuration.

This is pre-existing, neither caused nor cured here, and it is mitigated by
following the documented recipe for every editor rather than only the extra ones
— which is why `addons/godot_mcp_toolkit/docs/multi-instance.md` was tightened
alongside this change. Tracked in
`Plan/Ideas/PostRelease/2026-07-25-pinned-lsp-port-misreported-in-registry.md`.

---

Source-verified analysis (engine 4.2–4.7, the registry writers, the captured
leak): `Insights/lsp-multi-instance-port-analysis.md`. Decision log with the full
evidence trail:
`Plan/Reference/GrillingSessions/2026-07-25-41s-lsp-conflict-false-positive.md`.

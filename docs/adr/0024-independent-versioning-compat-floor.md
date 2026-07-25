# 0024 — Independent versioning with a declared compatibility floor

**Status:** Accepted

**Date:** 2026-07-24

**Supersedes:** the implicit lockstep-versioning convenience adopted in the
iter-31 version-sync pass (both manifests unified to `1.0.0`, "bump both
together").

## Context

The toolkit plugin (GDScript, distributed via Godot AssetLib / the Godot Asset
Store) and the MCP server bridge (TypeScript, distributed via npm) are two
separately installed artifacts that join at runtime over a localhost WebSocket.

When their versions were first unified, the two manifests disagreed
(`package.json` said `0.0.1`, `plugin.cfg` said `0.1.0`) and neither inspired
confidence, so they were set to a common `1.0.0`. "Bump both in lockstep" rode
along as a convenience — it was never weighed against independent versioning plus
a compatibility story. Four facts make lockstep the wrong long-term model:

1. **The code already tolerates skew.** The connect-time handshake
   (`compareVersions` in the server's `channel.ts`, built in the 41l series)
   computes major/minor mismatch and *warns* on human-facing channels — it
   **never refuses** the connection. It was built to detect divergence, not to
   forbid it.
2. **Distribution already produces skew.** The shipped `.mcp.json` runs the
   server via **unpinned `npx`**, so the server auto-updates while the installed
   AssetLib addon stays put. "Matching versions in the field" is already fiction;
   lockstep's one selling point is already leaky.
3. **CI already tests pairings by SHA pins**, not by shared version numbers
   (`SIBLING_PIN_TOOLKIT` / `SIBLING_PIN_SERVER`). The "tested together"
   guarantee is a pin, not version equality.
4. **The two artifacts are genuinely separable** — different languages, different
   distribution channels, different audiences (a user may care about only one).
   The ecosystem precedent for that shape is **independent + floor** (ESLint and
   its plugins, Babel plugins, VS Code and its extensions). Lockstep is reserved
   for **two halves of one tightly coupled library** (React + ReactDOM, Angular's
   `@angular/*`) — not our shape.

Lockstep also forces *dishonest* bumps: the unchanged repo inflates its version
just to stay level, and the two cadences are coupled for no functional reason.

Full grill decision log and blast radius:
`Plan/Reference/GrillingSessions/2026-07-21-independent-versioning-compat-floor.md`.

## Decision

The toolkit and the server **version independently** — each carries its own
semver, its own git tags, and its own release cadence. A version bump on one side
means *that* artifact changed; the other does not bump unless it also changed.

Compatibility is expressed as a **declared floor**, not a shared version number
and not a full compatibility matrix:

- The **server** declares the **minimum toolkit** it requires; the **toolkit**
  declares the **minimum server** it requires (`major.minor`). This is npm's
  `peerDependencies` / `engines` model — but the toolkit is a Godot addon, not an
  npm package, and the two are runtime peers over a WebSocket, so the check is
  hand-rolled in the handshake rather than resolved by a package manager.
- A side raises its floor **only** when it takes a real dependency on the other
  side's newer wire contract. Such a raise is a **MAJOR** bump — it drops support
  for older siblings, exactly like raising the Node `engines` floor. Floors are
  monotonic and move rarely.
- The **existing handshake** enforces the floor **softly**: it compares the two
  versions and emits a loud, actionable warning on a breach, but **never
  refuses** the connection. A **newer** sibling is always allowed (there is no
  hard ceiling — a newer-sibling major-skew already warns, which is the soft
  ceiling).
- **`1.0.0` is the synchronized baseline** — both ship `1.0.0` at first release.
  Divergence begins *after* `1.0.0`, when one side changes and the other does
  not.

**The precision test** (independent versioning is not "ignore compatibility").
Scenario: *add three server tools, toolkit unchanged.*

- If the new tools need **no** new toolkit handler → the toolkit stays put, the
  server bumps a minor, the declared floor is unchanged, and a skewed user is
  fine.
- If they **do** need new handlers → the toolkit had to ship them too, so **both
  bumped anyway**, and the server's floor rises to require the new toolkit.

→ The floor couples the two repos **exactly when the wire contract actually
changes, and leaves them independent otherwise.** That is the honest version of
"many improvements on one side without the other needing a bump."

## Consequences

- **Release mechanics are symmetric.** Each repo has a first-class
  `scripts/release.sh` that releases only itself. The common case (one repo
  changed) runs that one script. A change spanning both repos uses the server
  script's opt-in `--with-sibling` mode, which **delegates** the toolkit half to
  the toolkit's own `release.sh` — the two produce independent versioned
  releases, never a shared number. There is no "coordinator that bumps both."
- **Rollback is per-repo.** A botched release patches only its own repo. The
  sibling is dragged in only if the bad release had raised a floor, or the fix
  changes the wire contract.
- **The floor machinery is deferred, not free today.** At the `1.0.0`
  synchronized baseline there is no skew to gate, and the handshake still compares
  *product versions* (not the declared floor). Because the handshake warns on any
  minor-or-patch difference and the unpinned `npx` invocation auto-pulls server
  patches, the **first** independent bump — even a server patch against an
  unchanged toolkit — will over-warn against a still-compatible sibling. The
  `min_toolkit` / `min_server` constants and the floor-aware comparison must land
  **with or before the first release that breaks the `1.0.0` symmetry**. That
  work is tracked as `version-mismatch-ux`
  (`Plan/Ideas/PostRelease/2026-07-21-version-mismatch-ux-hardening.md`),
  now load-bearing under this model.
- **Every MAJOR is a fleet-wide day-one skew event** for unpinned-`npx` users —
  a reason to keep floor raises (and therefore MAJORs) deliberate and rare.
- **The iter-31 "sync check validates they match" premise is retired.** There is
  no version equality to enforce after `1.0.0`; the CI analogue is asserting each
  repo's declared floor, not equality.

## Explicitly not changed

- The handshake's never-refuse, human-only-warning behavior — it already fits
  this model.
- The per-tool **Godot** version gating (`godotMinVersion` / `godotMaxVersion`).
  That is tool ↔ engine compatibility — a different axis entirely from the
  toolkit ↔ server declared floor.
- `1.0.0` as the first-release version for both artifacts (the synchronized
  baseline).

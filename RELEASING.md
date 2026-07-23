<!-- This file is kept identical in both repos — edit both together. -->

# Releasing

This document is the maintainer's guide to cutting a release. It is kept
**byte-identical** in the toolkit repo and the server repo — the process is one
coordinated whole, and a contributor who only ever sees one repo still gets the
full picture. If you edit it in one repo, copy the change to the other.

## Release day (TL;DR)

The at-a-glance sequence. Each step links to its detailed section below.

1. **Bump the sibling pins** with a `[run-cross-version-ci]` commit and let the
   cross-version matrix go green — see [Sibling-pin ritual](#sibling-pin-ritual).
2. **Run the manual validation gate** — see
   [Manual pre-release gate](#manual-pre-release-gate).
3. **Dry-run the release workflow** (`workflow_dispatch`, `dry-run: true`) and
   require it green — see [Dry-run rehearsal](#dry-run-rehearsal).
4. **Run `./scripts/release.sh <version>`** (try `--dry-run` first) — see
   [The release script](#the-release-script).
5. **Review the paused CHANGELOG** and the `npm pack` listing, then let the
   script commit + tag — see [The release script](#the-release-script).
6. **Push** the released repo: `git push origin main vX.Y.Z` — see
   [The gated release flow](#the-gated-release-flow).
7. **Watch the gated CI go green** (the behavioral matrix runs before publish) —
   see [The gated release flow](#the-gated-release-flow).
8. **Submit the Asset Store / AssetLib update** (toolkit only) — see
   [Asset distribution](#asset-distribution).
9. **Run the post-publish checks** (`--tools-count`, npm/GH render, the one-time
   `.mcp.json` flip) — see [Post-publish follow-ups](#post-publish-follow-ups).

## Version scheme

The toolkit plugin and the MCP server bridge are **versioned independently** —
each has its own semantic version, its own git tags, and its own release
cadence. A version bump on one side means *that* artifact changed; the other
side does not bump unless it also changed. Both ship `1.0.0` at first release
(the synchronized baseline); versions diverge from there.

Because the two are installed separately and joined at runtime over a localhost
WebSocket (much like an editor and a language server, or an npm host and its
plugin), compatibility is expressed as a **declared floor**, not a matching
version number:

- The **server** declares the **minimum toolkit** version it needs.
- The **toolkit** declares the **minimum server** version it needs.

At connect time the two exchange versions and, if either side is below the
other's floor, the bridge emits a clear, actionable warning (and update
guidance) — it **never refuses** the connection. A newer sibling is always
allowed. See [Compatibility](#compatibility) below.

The version components describe each artifact's **own** public surface:

### MAJOR (breaking)

A bump from `1.x.y` to `2.0.0` means downstream consumers of **that artifact**
must change something. Examples:

- Remove or rename an MCP tool
- Change a tool's parameter schema incompatibly (rename a required parameter,
  change a type, remove a parameter)
- Change the WebSocket protocol or authentication mechanism
- Break the extension-author API (rename or remove an
  `MCPToolkitExtensionOptions` builder method, change the `register()` signature,
  claim a new reserved namespace) — extension authors are downstream consumers
  too
- Drop a previously supported Godot version from the compatibility matrix, or
  raise the server's minimum Node.js floor (`engines`)
- Raise this artifact's **declared minimum-sibling floor** past a previously
  supported sibling version (the server raising `min_toolkit`, or the toolkit
  raising `min_server`) — it drops support for older siblings, exactly like
  raising the Node floor
- Change the npm package name or binary entry point

### MINOR (feature)

A bump from `1.0.x` to `1.1.0` means new capabilities, fully backwards
compatible. Examples:

- Add a new MCP tool or a new on-demand tool group
- Add new optional parameters to an existing tool
- Add a new UI feature (a dock panel, a menu item)
- Extend the extension API surface (new builder methods, new hooks)
- Add or extend a companion skill
- Add support for a new Godot version to the compatibility matrix (dropping one
  is MAJOR — this is the mirror)
- Move a tool between the startup surface and an on-demand group —
  discoverability changes, capability does not
- Meaning-shifting tool description or hint changes — these are behavior-bearing
  for LLM consumers

### PATCH (fix)

A bump from `1.0.0` to `1.0.1` means bug fixes and improvements that do not
change the public API surface. Examples:

- Bug fix in tool behavior
- Performance improvement
- Meaning-preserving hint or description wording fixes — meaning-shifting edits
  are MINOR: descriptions steer LLM tool selection, so they are behavior-bearing
- Documentation correction shipped alongside code
- Dependency version bump (pinned, tested)
- CI or build improvement with no runtime effect

## Compatibility

The two artifacts version independently, so mismatched pairs are the **normal**
state in the wild — the shipped `.mcp.json` runs the server via unpinned `npx`,
so servers auto-update while the installed AssetLib addon stays put. This is
supported by design, governed by a **declared floor** on each side:

- Each release declares the **minimum sibling** it needs — the server a
  `min_toolkit`, the toolkit a `min_server` (`major.minor`). A side raises its
  floor **only** when it adds a real dependency on the other side's newer wire
  contract (that raise is a MAJOR bump — it drops older siblings).
- At connect the two exchange versions. If a sibling is **at or above** the
  floor, the pair is compatible. If **below**, the bridge still connects but
  emits a loud, actionable warning naming which side to update and how ("server
  1.2 needs toolkit ≥ 1.1 — update the addon via AssetLib, or pin the server").
- A **newer** sibling than you were built against is always allowed; individual
  tools added in a newer server minor may return a clear error against an older
  toolkit until the addon is updated (the connect warning says so).

This is the npm `peerDependencies` / `engines` model carried over the wire: the
floor couples the two repos exactly when the wire contract changes, and leaves
them independent otherwise.

**Status (1.0.x).** Both artifacts ship the synchronized `1.0.0` baseline, so
there is no skew to gate yet. The connect-time handshake already compares the two
versions and prints a human-readable warning on any mismatch (it never refuses) —
but at 1.0.0 it compares *product versions*, not the declared floor, so the first
independent bump (even a server patch, which the unpinned `npx` invocation
auto-pulls) will warn against a still-compatible sibling. The `min_toolkit` /
`min_server` constants and floor-aware comparison described above land early in
the 1.x series, replacing the product-version warning; until then, treat a
version-mismatch warning as advisory.

## The gated release flow

Releasing is **not** a naive "tag → publish". Both repos' release workflows
(`.github/workflows/release.yml`) are **gated on the full cross-version
behavioral matrix**, and a red matrix leg **blocks the release** — that is the
design, not a failure of the release script.

When you push a `v*` tag:

1. `release.yml` calls `cross-version.yml` (via `workflow_call`) as a
   `behavioral` job — the whole two-editor matrix (GDScript + .NET/mono editors,
   Godot 4.2 through 4.7) runs first, against the pinned sibling.
2. **Server:** the package-shape gate runs — `npm pack` (materializes the exact
   tarball), `publint` (lints the package for publish-time footguns), and
   generated-docs freshness (both `docs:api` **and** `docs:tools`, so a stale
   tool reference reddens the gate). Then `npm publish` + a GitHub Release.
3. **Toolkit:** the release zip is built, and a **zip install-smoke** boots a
   headless 4.7 editor against the unzipped artifact. Then a GitHub Release with
   the zip attached.

The publish / GH-Release / zip steps `needs:` the behavioral job, so they run
**only** if the matrix is green.

**Push with an explicit refspec** — `git push origin main vX.Y.Z`. Do not use
`git push --follow-tags`: that flag pushes *every* reachable unpushed annotated
tag, so a stray experimental `v*` tag would ride along and fire the release gate.

## Dry-run rehearsal

**Before creating a tag, rehearse the release workflow.** Trigger `release.yml`
via `workflow_dispatch` with its `dry-run` input left at its default (`true`).
This runs everything — the called behavioral matrix and the package-shape /
zip-build gates — but skips `npm publish` and GH-Release creation. Require it
green before you cut the tag.

**Re-run escape hatch.** If a tag push fails transiently *after* the tag is
created, the deliberate recovery is to **dispatch `release.yml` on the tag ref
with `dry-run: false`**. Never delete and re-push a tag — a published tag that
moves is a trust and security problem, and the release gate will refuse to
re-cover it cleanly.

## Vacuous-gate caveat (maintainer warning)

The behavioral gate is only as strong as its opt-in job conditions. If
`release.yml` ever gains a **new trigger type** (for example a `schedule:`
trigger), the behavioral callee's opt-in jobs would **all-skip**, and the
`behavioral:` call would then succeed **vacuously** — un-gating publish while
appearing green. **Whenever you change what triggers `release.yml`, re-verify the
callee's job gates.** (An anti-vacuous assert job in `cross-version.yml` guards
this in CI, but the human check is the backstop when triggers change.)

## Sibling-pin ritual

The tag-fired behavioral gate checks out the sibling **at a pinned revision**
(`SIBLING_PIN_TOOLKIT` in the server's `cross-version.yml`, `SIBLING_PIN_SERVER`
in the toolkit's). A stale pin certifies a *drifted* sibling — green tests of the
wrong pairing.

**Before running the release script, bump the pin to the certified sibling
revision** in a dedicated commit carrying `[run-cross-version-ci]`, and let that
run go green. That commit *is* the tested-integration event.

Expect a **metadata-only offset** at tag time: the pin-bump and version-bump
commits land *after* the pins are set, so each pin trails the sibling's tagged
SHA by exactly those commits (pin bump + version bump). That is **code-identical**
by design — SHA-equality is impossible and is not the goal. The property that
matters is that the pinned revision is code-identical to what ships. The release
script's code-identical pre-flight enforces exactly this.

## Manual pre-release gate

CI cannot cover everything. **Before tagging, run the manual validation gate** —
the interactive re-run of the checks CI can't reach (export-strip, connection
stability, security, human + MCP concurrent editing):

**See [`docs/dev/release-checklist.md`](docs/dev/release-checklist.md).**

Work through it and confirm it green before you create the tag. The release
script prints a reminder and requires an explicit confirmation.

## The release script

Each repo carries a first-class `scripts/release.sh` that releases **that** repo
— it validates the version, runs the pre-flights, bumps the manifest, rolls the
CHANGELOG, pauses for you to curate, then commits and creates an **annotated**
tag. It does **not** push.

```bash
# Common case — release one repo (run from that repo's root):
./scripts/release.sh 1.1.0

# Rehearse first — validate + report, write nothing:
./scripts/release.sh 1.1.0 --dry-run

# A change that spans BOTH repos (rare) — from the server repo:
./scripts/release.sh 1.1.0 --with-sibling 1.2.0   # two independent versions

# After pushing — confirm the release converged (read-only):
./scripts/release.sh --verify 1.1.0
```

What it does:

- Validates the version is well-formed semver and is a real advance over the
  highest existing tag (or equal, on the untagged first-release / recovery path).
- Fetches `origin/main` first, then checks the repo is on `main`, clean, and
  up-to-date with the remote.
- Runs the pre-flights: the target version is available (untagged locally + on
  `origin`, and — server — not on npm), the sibling pin is code-identical to the
  sibling's `main`, CI is green on both HEADs, and — server — the generated docs
  are fresh.
- Bumps the manifest (server: `package.json` + `package-lock.json` via
  `npm version`; toolkit: `plugin.cfg`).
- Rolls the CHANGELOG `## [Unreleased]` section into `## [X.Y.Z] - YYYY-MM-DD`,
  then recreates an empty `## [Unreleased]`.
- **Pauses** for you to review and curate the CHANGELOG (and, on the server, to
  eyeball the `npm pack` file listing). Only after you confirm does it commit and
  create the annotated tag. It **never amends after tagging**.
- Prints the push command and, for the toolkit, the Asset submission form values.

The `--with-sibling` mode is for a change that genuinely spans both repos (for
example a floor-raising wire-contract change). It **delegates the toolkit half to
the toolkit's own `release.sh`** and then releases the server — two *independent*
versioned releases in one run. The `--verify` mode is a read-only post-push check
that confirms the tag reached both origins and the server package resolved on npm.

## Rollback (if a release goes bad)

Releases are **forward-only**. Do not reuse or move a published version or tag.

**npm.** Prefer `npm deprecate <pkg>@<bad-version> "<reason; use X.Y.Z>"` plus a
fixed **patch release**, over `npm unpublish` (the 72-hour window breaks installs
for anyone who already pulled it). A first-line mitigation is repointing the
`latest` dist-tag at the last-good version (`npm dist-tag add <pkg>@<good> latest`).
Post-December-2025, npm auth has **no long-lived tokens** — `npm deprecate` and
`npm dist-tag` are **interactive maintainer-machine operations** (a fresh
`npm login`, ~2-hour session; OIDC mints publish credentials only and cannot run
these). Run them **from a maintainer machine**, never scripted in CI.

**GitHub.** Edit or delete the bad Release, keeping the tag. (If GitHub
**immutable releases** are ever enabled, this path disappears — assets freeze and
deleting a release burns its tag name forever — and rollback becomes
patch-forward only.)

**AssetLib / Asset Store.** Submit an **edit** repointing the Download Commit at
the previous or fixed SHA.

**Independent-versioning consequence.** A botched release patches **only its own
repo** — each side versions independently. The sibling is dragged in **only** if
the bad release had raised a floor, or the fix changes the wire contract;
otherwise the other repo is untouched.

## Asset distribution

The toolkit ships to Godot users through two surfaces during the current
transition:

- **Godot Asset Store** (store.godotengine.org) — the primary target. Version and
  changelog are first-class there. Editor integration lands in Godot 4.7.
- **Legacy Asset Library** — deprecated and heading to read-only, but users on
  Godot 4.2–4.6 still browse the *legacy* AssetLib tab in-editor, so keep the
  listing current while it accepts submissions.

For a release **update** on either surface, submit a new **Version** with the new
full **Download Commit SHA** (the toolkit's tagged commit — `git rev-parse
vX.Y.Z`). A legacy AssetLib edit re-enters moderation and can take days; plan for
that latency. The `release.sh` script prints the three form values (version,
Download Commit SHA, zip name `godot-mcp-toolkit-<ver>.zip`) at tag time so the
submission is transcription, not archaeology.

The server has no equivalent manual step — its release publishes to npm from CI.

## Post-publish follow-ups

After the gated CI publishes:

- **Verify the live package:**
  `npx --yes @npgamedev/godot-mcp-server@<version> --tools-count`. The registry
  can lag a publish by seconds to minutes — poll before concluding failure.
- **Confirm the render:** check the GitHub Releases pages (both repos) and the
  npm package page render correctly.
- **First release only (1.0.0):** flip the committed dogfood `.mcp.json` at the
  toolkit root from its dev form (`command: node` + local `dist/`) to the bare
  `npx` form users receive, so the dogfood config matches the published package.
  (The `.mcp.json.template` already emits bare `npx`; only the committed root file
  needs the flip.)

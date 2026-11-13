<!-- This file is kept identical in both repos — edit both together. -->

# Releasing

This document is the maintainer's guide to cutting a release. It is kept
**byte-identical** in the toolkit repo and the server repo — the process is one
coordinated whole, and a contributor who only ever sees one repo still gets the
full picture. If you edit it in one repo, copy the change to the other.

> **Doing a release right now?** Follow
> [`docs/dev/release-runbook.md`](docs/dev/release-runbook.md) instead. It is the
> ordered walk distilled from the 1.0.0 release: the same steps in the order they
> actually happen across both repos, with the checks to run at each point and the
> traps that have already cost a cycle. This document stays the reference for what
> each mechanism is and why; the runbook is what you work through on the day.

The toolkit's release signing keys, who holds them, and how they rotate are in
the toolkit's
[`docs/dev/trust-chain.md`](https://github.com/NPGameDev/godot-mcp-toolkit/blob/main/docs/dev/trust-chain.md).

## Release day (TL;DR)

The at-a-glance sequence. Each step links to its detailed section below.

1. **Bump the sibling pins** with a `[run-cross-version-ci]` commit and let the
   cross-version matrix go green — see [Sibling-pin ritual](#sibling-pin-ritual).
2. **Run the manual validation gate** — see
   [Manual pre-release gate](#manual-pre-release-gate).
3. **Dry-run the release workflow** (`workflow_dispatch` from a branch; the
   server's `dry-run` input left at `true`, the toolkit's workflow takes no
   input) and require it green — see [Dry-run rehearsal](#dry-run-rehearsal).
4. **Run `./scripts/release.sh <version>`** (toolkit: `--compatible-server <X.Y.Z>`
   or `--keep-compatible-server`; try `--dry-run` first) — see
   [The release script](#the-release-script).
5. **Review the paused CHANGELOG** and the `npm pack` listing, then let the
   script commit + tag — see [The release script](#the-release-script).
6. **Push** the released repo: `git push origin main vX.Y.Z` — see
   [The gated release flow](#the-gated-release-flow).
7. **Watch the gated CI go green** (the behavioral matrix runs before the
   server publishes and before the toolkit uploads its files) — see
   [The gated release flow](#the-gated-release-flow).
8. **Publish the toolkit's release from your machine** (toolkit only): check,
   draft, sign, attach, publish — see
   [The toolkit's publish ritual](#the-toolkits-publish-ritual).
9. **Submit the Asset Store / AssetLib update** (toolkit only) — see
   [Asset distribution](#asset-distribution).
10. **Run the post-publish checks** (`--tools-count`, npm/GH render, the
    toolkit's ledger line, the one-time `.mcp.json` flip) — see
    [Post-publish follow-ups](#post-publish-follow-ups).

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

**For now, releases are lockstep.** Each repo's tag-fired release workflow
requires the pinned sibling to declare the exact version being tagged. Until the
tag gates check the declared floor instead, that forces a lockstep release: both
repos bump to the same version and release together, server first. Versioning
is still independent by design; the gates have not caught up with it yet.

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
state in the wild. **Write .mcp.json** pins the server the toolkit was tested
with, but a hand-written, unpinned `npx` entry picks up each new server while
the installed AssetLib addon stays put. This is supported by design, governed by
a **declared floor** on each side:

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

**Status (1.1.x).** The floor machinery is live on both sides since 1.1.0. The server
declares `MIN_TOOLKIT_VERSION = "1.0"` (`src/shared/version.ts`) and sends `server_version` +
`min_toolkit` in the auth request; the toolkit declares `MIN_SERVER_VERSION = "1.0"`
(`addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd`) and answers with `min_server`.
When the peer is below its floor, each side reports it: the server once per connection, as an
ERROR line on stderr, and the toolkit once per server version in an editor session, as an
editor error and a dock line. Both sides name the same two routes: a toolkit below the server's
floor is told to update the addon or pin an older server, a server below the toolkit's floor to
pin the recommended server from the toolkit dock's `.mcp.json` panel or set the server version
in the MCP client's config. Otherwise the product-version messages stay: a patch difference is
silent, a minor difference warns, a major difference is an error. None of them reaches the MCP
wire or refuses the connection. A local server build (the toolkit's
`mcp_toolkit/server/local_path` editor setting or `GODOT_MCP_DEV_SERVER_PATH`) turns the check
off on both sides, but not at the same moment. The editor skips its check from the next
connection and prints its skip line on every connection. The server skips its check, and prints
its skip line once at startup, only after **Write .mcp.json** has put
`GODOT_MCP_SKIP_VERSION_CHECK=1` into the entry it builds for the local build and the MCP client
has restarted. The toolkit pins the server it was tested with (`COMPATIBLE_SERVER_VERSION`)
when it writes `.mcp.json`, so a fresh config lands on a matching pair; an unpinned config can
drift a minor ahead and warns until it is pinned.

**The pin and patch releases.** Every toolkit release states its pin: `release.sh
--compatible-server X.Y.Z` moves it to a server version npm has, `--keep-compatible-server`
keeps it. A server patch with a user-facing fix ships with a toolkit patch that only moves the
pin, so pinned configs pick the fix up; a server-internal patch needs no toolkit release.

## The gated release flow

Releasing is **not** a naive "tag → publish". Both repos' release workflows
(`.github/workflows/release.yml`) are **gated on the full cross-version
behavioral matrix** (the toolkit also on the whole floor), and a red matrix or
floor leg **blocks the release** — that is the design, not a failure of the
release script.

When you push a `v*` tag:

1. `release.yml` calls `cross-version.yml` (via `workflow_call`) as a
   `behavioral` job — the whole two-editor matrix (GDScript + .NET/mono editors,
   Godot 4.2 through 4.7) runs first, against the pinned sibling. The toolkit's
   `release.yml` also calls `ci.yml` as a `floor` job, with the macOS apply-kill
   rows, and waits on it too.
2. **Server:** the package-shape gate runs — `npm pack` (materializes the exact
   tarball), `publint` (lints the package for publish-time footguns), and
   generated-docs freshness (both `docs:api` **and** `docs:tools`, so a stale
   tool reference reddens the gate). Then `npm publish` + a GitHub Release.
3. **Toolkit:** the release zip and its update manifest are built, and a **zip
   install-smoke** boots a headless 4.7 editor against the unzipped artifact. The
   booted tree is checked against the zip's release file list and the manifest,
   an **update-smoke** installs the zip through the self-update, and
   `scripts/check-release-zip.mjs` checks the zip against the tagged tree. Then
   the zip and the manifest are uploaded as the workflow artifact
   `release-<tag>`. The toolkit's workflow runs with `contents: read` only and
   creates no GitHub Release: you publish it from your machine, as
   [The toolkit's publish ritual](#the-toolkits-publish-ritual) describes.

The server's publish job and the toolkit's `build-and-upload` job `needs:` the
behavioral job, and the toolkit's also the `floor` job (`ci.yml` with the macOS
apply-kill rows), so they run **only** if those are green.

**Push with an explicit refspec** — `git push origin main vX.Y.Z`. Do not use
`git push --follow-tags`: that flag pushes *every* reachable unpushed annotated
tag, so a stray experimental `v*` tag would ride along and fire the release gate.

## The toolkit's publish ritual

The toolkit's release is published from the maintainer's machine by
`scripts/publish-release.sh`, one step per call, with the maintainer's
`scripts/sign-release.sh` between two of them. Each `publish-release.sh` step
refuses unless the one before it is done, and keeps its record in
`dist-plugin/release-<tag>/` beside the files it checked. The sign reads no
record: it checks the clone, the tag and the zip itself. The steps marked *agent* may be run by a coding
agent helping with the release; the other two are typed by the maintainer.
Every step first refuses when a variable that would aim `git`, `gh`, `node` or
`openssl` somewhere else is set, or when `origin` is not the URL pinned in
`scripts/lib/release_identity.sh`.

1. `scripts/publish-release.sh check vX.Y.Z` (*agent*) refuses unless a
   `release.yml` run on the tag ref succeeded: the tag push, or a dispatch on
   the tag ref, never a run on a branch, which skips the tag-only checks. It
   does not wait, so watch the run first (`gh run watch`). It downloads the
   run's artifact `release-vX.Y.Z`, checks the zip against the tag
   (`scripts/check-release-zip.mjs`, the run that decides), and compares the
   manifest with the one this machine writes for that zip.
2. `scripts/publish-release.sh draft vX.Y.Z` (*agent*) creates the draft
   release with the checked zip and manifest, `--verify-tag`, and an empty body.
   When the tag holds trust documents after the first, it uploads those too,
   `trust-2.json` through `trust-N.json`, read from the tag. It copies the zip
   into a new folder, `publish-release-vX.Y.Z.<random>` under `/Users/Shared`
   (`PUBLISH_RELEASE_HANDOFF_ROOT` names another parent), and prints the sign
   command. A draft is invisible to the public.
3. The sign (*maintainer*), typed in a separate admin account that holds the
   release key and runs no coding agent, from a fresh anonymous clone of
   `main`:
   `scripts/sign-release.sh vX.Y.Z <zip> <private-key.pem>`.
   It first refuses a tag that is not `vX.Y.Z`, a missing zip or key, and a
   folder for the signature that fails the rule below. It then copies the zip,
   and reads nothing else it is handed but the key. After that it refuses, in
   this order, when:
   - a variable that aims `git`, `gh`, `node` or `openssl` elsewhere is set
     (`scripts/lib/release_checks.sh` lists them);
   - `origin` is not the pinned URL;
   - the clone has changed or untracked files, or is not at the tip of
     `origin`'s `main`;
   - `origin`'s tag is not the clone's;
   - the tag's commit is not on `origin`'s `main`;
   - the tag's trust documents do not run from `trust-1.json` with no gap,
     `trust-1.json` does not hash to the pinned value, a document does not
     verify against the one before it, or the toolkit at the tag does not
     embed the last one;
   - `scripts/check-release-zip.mjs` does not accept the copy for the tag.

   It writes the manifest itself, from the copy and the tag, and signs only
   that: no manifest is handed to it, and it never calls `gh`. Before it asks
   for the passphrase it shows the tag, its commit's subject, the release
   before with its commit and date, the commits since and what changed under
   `scripts/` and `trust/`, but not the tag's own commit. Open the tag's page on github.com,
   `https://github.com/NPGameDev/godot-mcp-toolkit/releases/tag/vX.Y.Z`, follow
   its commit link, and type the first 8 hex digits of the commit shown there;
   anything else is refused, and so is a tag whose own commit carries the
   release tag before it. It keeps the `.sig` only when a release key of the
   tag's highest trust document verifies it, and refuses a key that is not
   RSA. The manifest and its `.sig` land
   in a new folder, `sign-release-vX.Y.Z.<random>` under `/Users/Shared`
   (`SIGN_RELEASE_OUT_ROOT` names another parent, which must be that account's
   own with no write for group or others, or root's or that account's with
   the sticky bit set). The last line printed is `OUT <folder>`.
4. `scripts/publish-release.sh attach vX.Y.Z [<folder>]` (*agent*) takes the
   manifest and the `.sig` from the sign's folder; with no folder named it
   takes the one `sign-release-vX.Y.Z.*` folder, and refuses on none or
   several. The manifest must be byte-equal to the one `check` passed, and
   `scripts/sign-release.sh --verify` must accept the `.sig`. It compares the
   draft's trust documents with the tag's and with the ones the current latest
   release carries, and only then uploads the `.sig`. It downloads the assets
   back and runs the reader check: the toolkit inside the draft's zip, headless
   on Godot 4.2 and 4.7, must accept each of the draft's documents in order,
   starting from the tag's `trust-1.json` and an empty store, and then trust
   the draft's manifest and signature (`GODOT_BIN_4_2` and `GODOT_BIN_4_7` name
   the binaries). Put the release body on the draft before the next step.
5. `scripts/publish-release.sh publish vX.Y.Z` (*maintainer*), typed in the
   account that made the draft, runs the sign's first six checks again and
   refuses unless `attach` passed for this draft. Then, before anything is
   public, it requires exactly one draft with the expected assets, downloads
   every asset back, and checks the zip against the tag, the manifest against
   the one it writes itself, the `.sig` with `--verify`, each trust document
   against the tag's and against the current latest release's, that the
   repository has immutable releases on, and that the current latest release
   is a lower version. Only then does it publish the draft as the latest
   release and check it: `gh release verify` and `gh release verify-asset` on
   each asset, `immutable: true` on the release, and an anonymous
   `releases/latest` that returns `vX.Y.Z`.

A release whose tag holds a new trust document takes the same five steps: the
document is one of the release's assets, so it goes public with the release.
No `trust-N` tag or release exists.

The `.sig` goes up after the draft exists: a draft is invisible, and an
immutable release locks its assets and tag only when it is published. The dry
run before the tag and the tag run before `check` each take about an hour, most
of it the floor's macOS apply-kill rows.

## Dry-run rehearsal

**Before creating a tag, rehearse the release workflow.** Trigger `release.yml`
via `workflow_dispatch` from a branch. This runs everything — the called
behavioral matrix (and in the toolkit the whole floor) and the package-shape /
zip-build gates — and publishes nothing:

- **Server:** leave the `dry-run` input at its default (`true`); the run skips
  `npm publish` and GH-Release creation.
- **Toolkit:** the workflow takes no input. A dispatch from a branch skips only
  the checks that need a tag (the tag against `plugin.cfg`, the CHANGELOG
  section and the server pin), checks the zip against the commit, and uploads
  the artifact `release-untagged-<sha>`. The workflow cannot create a release.

Require it green before you cut the tag.

**Re-run escape hatch.** If a tag push fails transiently *after* the tag is
created, the deliberate recovery is to **dispatch `release.yml` on the tag
ref**: in the server with `dry-run: false`; in the toolkit with no input, which
runs everything the tag push runs and uploads `release-<tag>`, the run `check`
accepts. Never delete and re-push a tag — a published tag that moves is a trust
and security problem, and the release gate will refuse to re-cover it cleanly.

## Vacuous-gate caveat (maintainer warning)

The behavioral gate is only as strong as its opt-in job conditions. If
`release.yml` ever gains a **new trigger type** (for example a `schedule:`
trigger), the behavioral callee's opt-in jobs would **all-skip**, and the
`behavioral:` call would then succeed **vacuously** — un-gating the release while
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
script prints a reminder and requires an explicit confirmation. In a
non-interactive run, the gate dispositions file answers it instead (see
[Non-interactive runs](#non-interactive-runs)).

## The release script

Each repo carries a first-class `scripts/release.sh` that releases **that** repo
— it validates the version, runs the pre-flights, bumps the manifest, rolls the
CHANGELOG, pauses for you to curate, then commits and creates an **annotated**
tag. It does **not** push.

```bash
# Common case: release one repo's half, from that repo's root. Both repos
# release together at the same version for now; see Version scheme. The
# toolkit's script also states its server pin (--compatible-server X.Y.Z, or
# --keep-compatible-server); the server's script takes neither, so drop it there.
./scripts/release.sh 1.1.0 --compatible-server 1.1.0

# Rehearse first — validate + report, write nothing:
./scripts/release.sh 1.1.0 --compatible-server 1.1.0 --dry-run

# A change that spans BOTH repos (rare) — from the server repo:
./scripts/release.sh 1.1.0 --with-sibling 1.1.0   # versions match while releases are lockstep

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
  are fresh. The script checks CI itself through `gh`, reading every page of
  check runs, which needs gh 2.48 or later (for `--paginate --slurp`). It asks
  you only when `gh` is missing, and a non-interactive run refuses instead.
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
versioned releases in one run. While the tag gates force a lockstep release, the
two versions must be the same. The `--verify` mode is a read-only post-push check
that confirms the tag reached both origins and the server package resolved on npm.
Its exit code tells you what to do next:

| Exit | Meaning | Next step |
| --- | --- | --- |
| 0 | Both origin tags exist and npm serves the version. | Done. |
| 1 | A tag is missing, or the toolkit repo could not be found to check. | Act: push the tag or fix the path. |
| 2 | Both tags exist, but npm does not serve the version yet. | Poll again; the registry can lag by minutes. |

### Non-interactive runs

An agent driving a release has no keyboard to answer the script's two questions:
the manual gate and the curation pause. Pass `--non-interactive` and answer each
one with a flag:

- `--gate-dispositions <file>` answers the manual gate. Write this file before
  the run. It holds a gate disposition for every checklist section: walked,
  skipped with a reason, or a documented gap with an owner. It must exist, be
  non-empty, and name the version being released. The script records its
  SHA-256 in the release commit as a `Manual-Gate-Dispositions: sha256:<hash>`
  trailer. Only the hash goes in, so the record can stay private. CR bytes are
  removed before hashing, so CRLF and LF copies of one record match.
- `--changelog-curated` answers the curation pause. It states that
  `[Unreleased]` was curated and committed before the run. The script refuses an
  empty section, since it cannot stop for you to fill it in.

In this mode, a question with no answer stops the run with an error naming the
flag it needed, and a missing `gh` is an error rather than a prompt. Before the
pre-flights, the run prints each prompt and how it will be answered. Rehearse
with `--dry-run` first. A dry run never reaches the curation pause, so it needs
only `--gate-dispositions`. On the toolkit, both commands also carry the server
pin, as below; on the server, drop it:

```bash
./scripts/release.sh 1.1.0 --compatible-server 1.1.0 --dry-run --non-interactive --gate-dispositions gate.md
./scripts/release.sh 1.1.0 --compatible-server 1.1.0 --non-interactive --gate-dispositions gate.md --changelog-curated
```

The two answer flags are a usage error without `--non-interactive`, so an
interactive run behaves exactly as before. `--with-sibling` cannot be combined
with `--non-interactive`, because the delegated toolkit run would prompt.
`--verify` never prompts and ignores `--non-interactive`.

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

**GitHub.** With **immutable releases** on (the toolkit's `publish` refuses
without them), a published release is fixed forward only: its assets and tag
cannot change, and deleting it burns its tag name for good. Ship a fixed patch release. Before `publish`, the
toolkit's draft can still be deleted and drafted again.

**AssetLib / Asset Store.** On the legacy AssetLib, submit an **edit**
repointing the Download Commit at the previous or fixed SHA. The Asset Store
takes an uploaded zip, so upload the fixed release's CI-built zip as a new
version.

**Independent-versioning consequence.** A botched release patches **only its own
repo** — each side versions independently. The sibling is dragged in **only** if
the bad release had raised a floor, or the fix changes the wire contract;
otherwise the other repo is untouched. While the tag gates force a lockstep
release (see [Version scheme](#version-scheme)), the patch release moves both
repos anyway.

## Asset distribution

The toolkit ships to Godot users through two surfaces during the current
transition:

- **Godot Asset Store** (store.godotengine.org) — the primary target. Version and
  changelog are first-class there. Editor integration lands in Godot 4.7.
- **Legacy Asset Library** — deprecated and heading to read-only, but users on
  Godot 4.2–4.6 still browse the *legacy* AssetLib tab in-editor, so keep the
  listing current while it accepts submissions.

For a release **update**, the Asset Store takes a new **Version** with the
CI-built zip uploaded (the one on the GitHub Release, which `check` took from
the tag's run, never a local build), and the legacy AssetLib takes an edit with
the new full **Download Commit SHA** (the toolkit's tagged commit —
`git rev-parse vX.Y.Z`). A legacy
AssetLib edit re-enters moderation and can take days; plan for that latency.
The `release.sh` script prints the three form values (version, Download Commit
SHA, zip name `godot-mcp-toolkit-<ver>.zip`) at tag time so the submission is
transcription, not archaeology.

Both listing descriptions quote tool counts, and nothing in CI checks them — the
catalogue gate guards the code, not store copy. Re-run `godot-mcp-server
--tools-count` and confirm the figures before you edit either description.

The server has no equivalent manual step — its release publishes to npm from CI.

## Post-publish follow-ups

After the server's CI publishes and the toolkit's `publish` step passes:

- **Record the toolkit's manifest:** `publish` prints a line for
  `trust/released-manifests.txt` (the version and the manifest's SHA-256). Add
  it to the toolkit through a pull request from `chore/ledger-X.Y.Z`.
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

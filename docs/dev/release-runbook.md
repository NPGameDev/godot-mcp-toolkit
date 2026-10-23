# Release runbook

The ordered walk for shipping a release, from a clean main to verified listings. It covers both
repos, because a release is one event across the two: the server publishes to npm, the toolkit
publishes to the Godot listings, and each gates on a pinned revision of the other.

This file is byte-identical in both repos, like `RELEASING.md`. Edit both copies and `cmp` them.
Paths are relative to the repo each step names; an unqualified path is a server-repo path, since
the release scripts and the probes live there.

It orders and links rather than restates. The mechanics live where they already are:

- `RELEASING.md` (both repos): the `release.sh` ritual, the sibling-pin ritual, the dry-run
  rehearsal, rollback.
- `docs/dev/release-checklist.md` (both repos, different content): the manual gates CI cannot reach.
- `test/probes/README.md` (server): the drivers that produce the checklist's evidence.

Work through the phases in order. Each one ends in a state the next phase assumes.

## Before you start

- Both repos on `main`, clean, pushed, with CI green on both HEADs. The release script checks CI
  itself through `gh` (2.48 or later), reading every page of check runs, and stops on anything not
  green. It asks you to confirm only when `gh` is missing, and a non-interactive run refuses
  instead of asking.
- Each repo's sibling pin postdates every cross-repo contract change since the last release. A pin
  taken before a contract change certifies the wrong pairing, and every behavioral leg then fails
  identically, which reads like a code fault.
- Generated docs are fresh (`npm run docs:api && npm run docs:tools`, server). The release script
  and `release.yml` both check this; running it early keeps the fix cheap.
- `npm audit` clean, or every remaining advisory understood and recorded. `release.yml` re-runs a
  production-only audit at high severity before it publishes.
- Release both repos at the same version, server first. They version separately by design, but each
  repo's tag gate requires the pinned sibling to declare the exact version being tagged. Until the
  tag gates check the declared floor instead, that forces a lockstep release.
- Run the `humanizer` skill over the `[Unreleased]` entries in each repo's `CHANGELOG.md`, and edit
  them before anything is tagged; curate each `[Unreleased]` in Keep a Changelog category order
  (Added, Changed, Deprecated, Removed, Fixed, Security; empty ones omitted), so each tag's section
  drops into the merged changelog unchanged. Release notes are the most-read text either project
  ships, and the annotated tag embeds the rolled section permanently, so a tell caught afterwards
  cannot be fixed without the file disagreeing with the tag. Em dashes are the usual finding.
  Applies to new entries only: entries already shipped in a tag stay as they are.

## Phase 1. Rehearse

Fire each repo's `release.yml` through `workflow_dispatch` with `dry-run: true`. The full gated path
runs; publish and GH-Release steps skip. The dispatch input defaults to true, so a dispatch can
never publish by accident.

A rehearsal certifies the **pinned** sibling, not the two HEADs. If every behavioral leg fails
identically, suspect a stale pin before suspecting the code.

## Phase 2. Walk the manual gates

Work through `docs/dev/release-checklist.md` in both repos. This is the half CI cannot reach. The
server side covers connection stability, security boundaries, cross-subsystem flows, dispatch
integration, and the supply-chain audit. The toolkit side covers the export-safety regression,
concurrent human and MCP editing, the macOS GUI-launch smoke, and the dock and Project Settings
round-trip.

The macOS section is blocking if a Mac is available and a documented coverage gap if not. Never
record it as a silent skip.

Four probes print the evidence for the server checklist's §1 and §2 items, so you observe rather
than improvise. Run them from the server repo with the local tsx (never bare `npx`), against a live
editor:

| Checklist | Probe |
| --- | --- |
| §1 B1-B8, connection stability | `test/probes/connection-stability-driver.ts` |
| §2 D2, D3, D5, path guard and auth | `test/probes/path-guard-and-auth-probe.ts` |
| §2 D4, read-only surface | `test/probes/read-only-surface-probe.ts` |
| §2 D5c, D7, oversized inbound | `test/probes/oversize-request-probe.ts` |

`test/probes/README.md` says what each one establishes and how to invoke it.

The release script asks you to confirm this walk happened, and aborts if you decline. In a
non-interactive run the gate dispositions file answers it instead. It is the only gate between a
broken interactive path and a published release, so do not confirm it from memory.

### Patch releases

A patch (x.y.Z) runs every automated gate in full: smoke, flows, dispatch integration, both unit
suites, `smoke:ci`, and the supply-chain audit. It walks only the checklist sections its change
touches. Before you answer the script's gate, write the **gate dispositions**: every section
walked, skipped with a reason, or a documented gap with an owner.

Escalation goes by trigger:

- transport or process lifecycle → server §1;
- security boundaries → server §2;
- the export path → toolkit §1;
- editor lifecycle, or anything human-facing in the editor → a hand walk of the affected surface,
  written for the change.

The full gate (all of them) is for minor and major releases. Where a section needs hardware you do
not have, take its own documented-gap path rather than skipping it silently, and give the gap an
owner. First applied: 1.0.1 (server §1 incl. B9 and §5; the toolkit's macOS GUI-launch smoke
recorded as a documented coverage gap, since no Mac was available).

### The validation ladder

On top of the full gate, a minor release (x.Y.0) runs these live checks:

- On Godot 4.2, the oldest supported version: the full smoke suite and the full tool sweep (the
  toolkit's `Validations/tool-sweep.md`).
- On the newest supported stable, now 4.7: one smoke run.
- A mixed-version handshake check: the previous toolkit with the new server, the new toolkit with
  the previous server, the new pair, and one pair where a side is below the other's floor. For
  1.1.0 that is toolkit 1.0.4 + server 1.1.0, toolkit 1.1.0 + server 1.0.4, 1.1.0 + 1.1.0, and a
  below-floor pair. Read both consoles for every pair: the server's stderr and the editor's Output panel.

A major release (X.0.0) adds a full tool sweep on the newest stable, a local smoke run and full
tool sweep on 4.5, and an npm `-rc` prerelease before the final version.

### Expected mixed-pair failures

With toolkit 1.0.4 and server 1.1.0, these cases fail by design, because they test 1.1.0
behavior the older toolkit lacks. Every other case must pass.

- Flow 02 (`test/flows/02_hot_reload_reachability.ts`), legs A and D: they need the toolkit's
  script reload.
- Smoke section 49 (`test/sections/49_script_edit.ts`), its two `edits` cases: toolkit 1.0.4
  requires `old_string`.

A re-measure on toolkit `v1.0.4` with server `0a12d13` found more. All of them depend on the
reload, and none raises an error or a crash:

- On Godot 4.2.2, flow 01's UPDATE case (`test/flows/01_extension_lifecycle.ts`): a toolkit
  write of an extension is not live, and 1.0.4's refresh hint asks for a restart. The failure
  throws out of the section, so its later cases never run. Flow 02 fails A (the write hint, A
  and the A recovery), B, the C refusal, D and the E rebind.
- On Godot 4.7, flow 02's E rebind.
- 4.2.0 and 4.2.1, where the flows expect the fallback, were not measured.

These were measured at later toolkit commits, not on `v1.0.4` itself:

- Smoke section 12 (`test/sections/12_input_map.ts`), its two `ui_left` cases (binding F9 keeps
  the default's joypad events; unbinding F9 leaves the default). Toolkit 1.0.4's `bind` saves
  the editor's keys-only `InputMap` list. Measured at toolkit `0e81b86` on 4.7: 17 passed, 2
  failed.
- On a toolkit without the `input_map.list` method and the `revert` action, `input_map_list`
  answers `RPC_ERROR` "-32601: Method not found: input_map.list" and `revert` answers
  `INVALID_PARAMS`, with no crash. Smoke section 12's six list, revert and round-trip cases fail.
  Measured against toolkit `567d8b6` on 4.7: 19 passed, 6 failed.

The release's mixed-pair check confirms every entry not yet measured on `v1.0.4`.

### Architecture and contract freshness

Before you write the gate dispositions, run both freshness checks:
`bash scripts/check_arch_freshness.sh` in the toolkit repo, which covers
`docs/architecture/README.md` and `docs/dev/contract.md`, and `npm run check:arch` in the server
repo. Record each repo's stale count in the dispositions.
Staleness the release inherits is advisory: record it and carry on. Staleness the release
introduces blocks it. An entry is the release's own when a commit since the previous release tag
moved one of its depicted files. Before this walk, whoever made that change must re-read the
affected diagram or contract section against the code and set its `data-verified` to that commit or
a later one. The re-attestation is always a separate commit, because a commit cannot name its own
SHA.

## Phase 3. Bump the pins, serialized

Each repo pins the sibling revision it was tested against (`SIBLING_PIN_TOOLKIT` in the server's
`cross-version.yml`, `SIBLING_PIN_SERVER` in the toolkit's), so both pins move to the revisions you
are about to release. Bump each in a dedicated commit carrying `[run-cross-version-ci]`. That commit
is the tested-integration event.

Bump the **consumer first and let it go green before touching the other**. Both repos fire the same
shared behavioral composite, so two correlated runs at once burn twice with no fix in between.

Add the all-platforms trigger token to the commit **body** to run the full grid (three operating
systems by six Godot versions by two editor languages, 36 combos). This is the only point in the
walk where the full grid runs: a tag push or a release dispatch yields an empty non-Linux matrix by
design, so the tag-fired gate is Linux-only. Tokens fire from the body even when they appear as
ordinary prose, so never write a real token literally in a commit message that is not meant to fire
it.

Confirm the aggregate jobs report success by name, not just that the run finished: **Platform matrix
OK** and **Behavioral gate OK**. A matrix can report success with every leg skipped. Sanity-check the
behavioral leg count against the matrix header comment at the top of `cross-version.yml`, and record
both run URLs. A red leg stops the release.

## Phase 4. Release the server

Rehearse the script first, then run it for real:

```bash
./scripts/release.sh <version> --dry-run
./scripts/release.sh <version>
```

An agent-driven release writes the gate dispositions first, then answers the prompts with flags:

```bash
./scripts/release.sh <version> --dry-run --non-interactive --gate-dispositions <file>
./scripts/release.sh <version> --non-interactive --gate-dispositions <file> --changelog-curated
```

There is no pause to curate in, so `[Unreleased]` must be final and committed before the run.
`RELEASING.md` describes the flags.

For a change that genuinely spans both repos, `./scripts/release.sh <server-version> --with-sibling
<toolkit-version>` delegates the toolkit half to the toolkit's own script and then releases the
server, as two independent versioned releases in one run. While the tag gates force a lockstep
release, the two versions must be the same. That path replaces Phase 6. The delegated toolkit
half gets no server pin flag, so the toolkit script refuses it; until that changes, release the
toolkit through Phase 6. A release that moves the pin could not use this path anyway: the new pin
must name a server version npm already serves, and this path tags the toolkit first.

The script runs its pre-flights, rolls the CHANGELOG, then **pauses**. Use the pause: read the rolled
section and the printed `npm pack --dry-run` listing. The listing must be `dist/`, `README.md`,
`LICENSE`, `ATTRIBUTIONS.md`, and `package.json`, and nothing else. Edit the CHANGELOG here if it
needs editing. On resume the script re-checks the tree and aborts unless the only changes are
`package.json`, `package-lock.json`, `CHANGELOG.md`, and regenerated `docs/`. A non-interactive
run does not pause but still prints the listing, so read it in the log before you push.

For a **first release of a package**, the changelog describes what ships. For every release after,
it describes the delta.

The script commits and tags, and does not push. Verify the tag carried its content, since git strips
markdown headers from a tag message unless the script asks it not to:

```bash
git cat-file -p v<version> | head -20
```

Then push both:

```bash
git push origin main v<version>
```

The tag fires the gated `release.yml`, which has three jobs: the behavioral matrix, then publish,
then a job that fetches the published tarball back from the registry and runs it. Watch it to green.

Publishing authenticates through OIDC trusted publishing, bound to this repository and this workflow
filename. There is no token to rotate, and renaming the workflow file breaks publishing until the
trusted publisher is updated on npmjs.com.

Verify: the npm page shows the right version and metadata, its images render, and the package runs
from a clean cache:

```bash
npx --yes @npgamedev/godot-mcp-server@<version> --tools-count
npx --yes @npgamedev/godot-mcp-server@<version> --help
```

## Phase 5. Prove onboarding before the toolkit ships

The server is live and the toolkit is not yet listed. Fix a broken first run here, while it costs
nothing.

Clone the toolkit fresh, build the plugin zip from that clone (`bash scripts/build-plugin-release.sh`),
install it into a brand-new Godot project, enable it, let the onboarding wizard write `.mcp.json`,
and confirm an MCP client reaches the tools through the published bridge.

No step may touch a dev working tree. A zip built from a dev tree picks up untracked import sidecars
that the CI artifact never contains.

## Phase 6. Release the toolkit

Every toolkit release states its server pin, and the toolkit script refuses to run without exactly
one of `--compatible-server <X.Y.Z>` or `--keep-compatible-server`. The toolkit's `main` pins the
last released server until the ship. Once the new server is on npm, the toolkit release moves the
pin with `--compatible-server <server-version>`, which rewrites `COMPATIBLE_SERVER_VERSION` and
the token in `.mcp.json.template`. Its npm probe refuses a server version npm does not serve yet. A
toolkit release that keeps the current pin passes `--keep-compatible-server` instead.

The rest is the Phase 4 ritual:
`./scripts/release.sh <version> --compatible-server <server-version>`, curate at the pause, verify
the tag content, push main and the tag. An agent-driven release runs the same two non-interactive
commands as Phase 4, with the gate dispositions file and the pin flag:

```bash
./scripts/release.sh <version> --compatible-server <server-version> --dry-run --non-interactive --gate-dispositions <file>
./scripts/release.sh <version> --compatible-server <server-version> --non-interactive --gate-dispositions <file> --changelog-curated
```

The toolkit script takes a version, the pin flag, `--dry-run` and the three non-interactive flags;
`--verify` and `--with-sibling` are server-side. The gated workflow builds the zip, install-smokes
it into a scratch project, and attaches it to the GH Release.

The script prints the asset submission values at tag time (version, download commit SHA, zip name).
Keep them on screen.

Get the full 40-character SHA for the listings, since the forms reject a short SHA:

```bash
git rev-parse v<version>
```

## Phase 7. Update the listings

Both listing surfaces carry copy that no CI check guards. Check, upload to or update every place
below:

| Where | URL | What to do |
| --- | --- | --- |
| Asset Store, versions | https://store.godotengine.org/asset/npgamedev/godot-mcp-toolkit/manage/#versions | add the version, Stable, upload the CI zip, paste the merged changelog |
| Asset Store, public listing | https://store.godotengine.org/asset/npgamedev/godot-mcp-toolkit/ | check the new version shows |
| Zip to upload | `https://github.com/NPGameDev/godot-mcp-toolkit/releases/download/v<ver>/godot-mcp-toolkit-<ver>.zip` | the CI-built zip, never a local build |
| Legacy Asset Library, edit | https://godotengine.org/asset-library/asset/edit/23816 | version + full 40-char Download Commit; re-enters moderation |
| Legacy Asset Library, public | https://godotengine.org/asset-library/asset/23816 | check the version after moderation |
| Toolkit GitHub Release | `https://github.com/NPGameDev/godot-mcp-toolkit/releases/tag/v<ver>` | body leads with the merged changelog; zip attached |
| Server GitHub Release | `https://github.com/NPGameDev/godot-mcp-server/releases/tag/v<ver>` | body leads with the server's own CHANGELOG section |
| npm | `https://www.npmjs.com/package/@npgamedev/godot-mcp-server/v/<ver>` | version, provenance badge, images |

1. Re-run `godot-mcp-server --tools-count` and confirm the figures the descriptions quote.
2. Update the legacy AssetLib entry: version, download commit, and the description if it changed. An
   edit re-enters moderation and can take days.
3. Update the Asset Store listing: upload the new zip under Versions with the merged changelog as its
   Version Changelog, mark it stable, and revise the description if the surface changed. The merged
   changelog carries both repos' sections for the version; paste it as is rather than rewriting it
   here. *Before you start* already humanized both sections, so wanting to edit either at this point
   means the humanizer step was skipped, and the fix belongs in the next release rather than in a
   store-only rewrite. 1.0.1 diverged from its own tag this way.

   The merged changelog opens with one `## [<version>] - <date>` heading, a one-sentence summary, a
   compatibility line (Godot minimum, Node minimum, the server minor it pairs with) and upgrade notes
   only when the user must act. A Toolkit block and a Server block follow, each its tag's own
   CHANGELOG section with every bullet's hard wraps joined onto one line. Use full Markdown links
   only, since `#10` and `@user` do not autolink on the store. A footer links both CHANGELOGs at the
   tag and the compare range.
4. Leave the maximum compatible Godot version empty. A hard cap goes stale when the next minor ships.

Store media is 16:9 (mandatory), at least 1280x720 and at most 600 KB.

## Phase 8. Close out

- Confirm both origins carry the tag and the registry resolves the version:
  `./scripts/release.sh --verify <version>` (server, read-only). Exit 0 means both tags and the
  npm version have converged. Exit 1 means a tag is missing or the toolkit repo cannot be found, so
  act on it. Exit 2 means only npm is still catching up, so poll again.
- Check both GH Release bodies. The workflow auto-generates notes from the commit range rather than
  the changelog, so paste the merged changelog at the top of the toolkit's body, above the generated
  notes, and the server's own rolled section at the top of the server's.
- If a release turns out bad, do not reuse or move the tag. `RELEASING.md` has the forward-only
  rollback paths for npm, GitHub, and the two listing surfaces.
- Record anything that surprised you, so the next release does not rediscover it.

## Traps that have fired

- **A stale sibling pin looks like a code fault.** Uniform failure across every behavioral leg is
  the signature. Check the pin first.
- **Correlated cross-repo runs are not parallel-safe.** Serialize the pin bumps.
- **A green matrix can be an empty matrix.** Check the aggregate job names.
- **`git tag -a -F` strips markdown headers** unless the script passes `--cleanup=verbatim`. Read the
  tag back rather than trusting the command's exit code.
- **A dry run must write nothing.** Assert `git status` is clean afterwards rather than trusting the
  banner.
- **`npm view` cannot distinguish an absent version from an unreachable registry** by exit code
  alone. Probe the package first if you are gating on it.
- **Do not add a CLI flag to a post-publish check without confirming it exists.** An unknown flag
  exits non-zero and turns the release red after the publish already landed.
- **Run the full local gate set before committing**, not a subset. Format is the one most often
  skipped, and it is a CI gate.
- **Never build a release zip from a dev working tree.**
- **`release.sh` refuses a dirty tree at entry, so its curation pause cannot be used to write a
  changelog entry that is not already committed.** Anything the rolled section needs has to be in
  `[Unreleased]` before the script starts. This bites hardest in a non-interactive session, where
  the pause cannot be answered by hand at all.
- **A changelog tell cannot be fixed after the tag.** The annotated tag embeds the rolled section,
  so a later edit leaves the file disagreeing with its own tag. Humanize before Phase 1.
- **Generated docs drift silently and the tag run is where you find out.** `release.yml` checks
  freshness at publish time, so a merge that changed a documented symbol without regenerating turns
  the release red. Regenerate during pre-flight, not at the gate.

## One-time steps that will not repeat

Recorded so nobody hunts for them in a later release: taking both impl repos public, the
full-history secret scan (a delta scan is enough now), retiring the cross-repo read token, creating
the listings rather than updating them, flipping the committed dogfood `.mcp.json` at the toolkit
root from its dev form to the bare `npx` form users receive, and enabling Pages, GHSA private
vulnerability reporting, and the merge-queue gate.

The first npm publish also ran on a granular token rather than OIDC, because trusted publishing
cannot perform a package's first-ever publish (npm/cli#8544). The trusted publisher was configured
and the token secret deleted immediately after.

One gap is open by decision rather than oversight: macOS has never been walked by hand. CI covers it
behaviorally on every full-grid run, but the Finder-launched client path is unverified. Walk it when
a Mac is available.

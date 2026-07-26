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

- Both repos on `main`, clean, pushed, with CI green on both HEADs. The release script asks you to
  confirm this and will not proceed without it.
- Each repo's sibling pin postdates every cross-repo contract change since the last release. A pin
  taken before a contract change certifies the wrong pairing, and every behavioral leg then fails
  identically, which reads like a code fault.
- Generated docs are fresh (`npm run docs:api && npm run docs:tools`, server). The release script
  and `release.yml` both check this; running it early keeps the fix cheap.
- `npm audit` clean, or every remaining advisory understood and recorded. `release.yml` re-runs a
  production-only audit at high severity before it publishes.
- Decide the version for each repo independently. They version separately by design, so a release
  can move one and not the other.

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
concurrent human and MCP editing, and the macOS GUI-launch smoke.

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

The release script asks you to confirm this walk happened, and aborts if you decline. It is the only
gate between a broken interactive path and a published release, so do not confirm it from memory.

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

Read `Workflows/release-script-gotchas.md` in the plan repo if you are touching the script itself.

Rehearse the script first, then run it for real:

```bash
./scripts/release.sh <version> --dry-run
./scripts/release.sh <version>
```

For a change that genuinely spans both repos, `./scripts/release.sh <server-version> --with-sibling
<toolkit-version>` delegates the toolkit half to the toolkit's own script and then releases the
server, as two independent versioned releases in one run. That path replaces Phase 6.

The script runs its pre-flights, rolls the CHANGELOG, then **pauses**. Use the pause: read the rolled
section and the printed `npm pack --dry-run` listing. The listing must be `dist/`, `README.md`,
`LICENSE`, `ATTRIBUTIONS.md`, and `package.json`, and nothing else. Edit the CHANGELOG here if it
needs editing. On resume the script re-checks the tree and aborts unless the only changes are
`package.json`, `package-lock.json`, `CHANGELOG.md`, and regenerated `docs/`.

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

Same ritual: `./scripts/release.sh <version>`, curate at the pause, verify the tag content, push main
and the tag. The toolkit script takes only a version and `--dry-run`; `--verify` and `--with-sibling`
are server-side. The gated workflow builds the zip, install-smokes it into a scratch project, and
attaches it to the GH Release.

The script prints the asset submission values at tag time (version, download commit SHA, zip name).
Keep them on screen.

Get the full 40-character SHA for the listings, since the forms reject a short SHA:

```bash
git rev-parse v<version>
```

## Phase 7. Update the listings

Both listing surfaces carry copy that no CI check guards.

1. Re-run `godot-mcp-server --tools-count` and confirm the figures the descriptions quote.
2. Update the legacy AssetLib entry: version, download commit, and the description if it changed. An
   edit re-enters moderation and can take days.
3. Update the Asset Store listing: upload the new zip under Versions with its changelog, mark it
   stable, and revise the description if the surface changed.
4. Leave the maximum compatible Godot version empty. A hard cap goes stale when the next minor ships.

The copy as published lives in the plan repo under `Plan/ExecutionPlan/listing-copy/`. The form
fields, the media rules (16:9 mandatory for the store, minimum 1280x720, maximum 600 KB), and the
editing rules any update follows live in `Plan/ExecutionPlan/42b-submission-values.md`. Image
derivatives live in the art repo under `godot-mcp-toolkit-art/AssetStore/`.

## Phase 8. Close out

- Confirm both origins carry the tag and the registry resolves the version:
  `./scripts/release.sh --verify <version>` (server, read-only).
- Check both GH Release bodies. The workflow auto-generates notes from the commit range rather than
  the changelog, so paste the rolled CHANGELOG section in as the body if you want readers to see
  what changed.
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

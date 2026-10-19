# 0026 — "Write .mcp.json" pins the server version

**Status:** Accepted

**Date:** 2026-10-19

**Relates to:** [ADR 0024](0024-independent-versioning-compat-floor.md). The toolkit
and the server version independently, and this decision chooses which server
version a toolkit's config starts.

## Context

The config the toolkit wrote ran `npx -y @npgamedev/godot-mcp-server` with no
version. `npx` resolves that to the newest release, so every server release reached
every user the next time their MCP client started the server, whatever toolkit
version they had installed.

Under ADR 0024 the two halves release on their own schedules, and each warns when
the other's version is a minor or major away. So a minor server release turned
into a version warning for every user whose addon was older, on the day it shipped.
Most users had done nothing but restart their client. The skew was the default,
and an addon update was the only cure.

## Decision

**"Write .mcp.json" writes `@npgamedev/godot-mcp-server@<version>`, where the
version is the one this toolkit was tested with, unless the project chooses
otherwise.**

- **The pin is a constant.** `COMPATIBLE_SERVER_VERSION`
  (`addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd`) names the server
  version, and `.mcp.json.template` carries the same version for a hand copy. Only
  `scripts/release.sh` changes them: every release must pass either
  `--compatible-server X.Y.Z`, which checks that npm has that version before
  rewriting both files, or `--keep-compatible-server`, which keeps the pin a
  previous release already checked. A release cannot ship a pin nobody chose. The
  keep path and a hand edit skip the npm check, so the CI launch job, which runs
  the written entry, is what catches a pin that does not resolve.
- **Two modes, plus an escape hatch.** The project setting
  `mcp_toolkit/server/version` decides. Empty is **Pinned** (the constant). `latest`
  is **Latest**. Anything else is used as an npm version, range or tag without
  validation. The setting lives in `project.godot` because the server a project
  runs is a team decision: everyone who opens the project should get the same one.
  The dock's `.mcp.json` panel and the setup wizard switch between the two modes.
  The docs say the third case is the user's to keep compatible.
- **No patch-floating mode.** A range like `~1.1.0` would give patch fixes
  without minor skew. It was rejected for three reasons.
  - npm 10's `npx` reuses a cached package that satisfies a range without asking
    the registry, so a range quietly stops moving.
  - `npm_config_prefer_offline`, which keeps pinned starts fast, freezes a range
    the same way.
  - A range takes a new server patch on the day it is published, untested with
    the toolkit, which is a supply-chain exposure the pin avoids.

  A user can still type a range as the custom value.
- **The builder owns `npm_config_prefer_offline`.** The written entry sets it to
  `"true"` only when the spec names one exact version, and removes it for anything
  else, whatever the existing file says. An exact version never changes once
  published, so starting the cached copy is always right. For a floating spec it
  would be wrong.
- **A local server build is a machine fact.** The editor setting
  `mcp_toolkit/server/local_path` (falling back to the `GODOT_MCP_DEV_SERVER_PATH`
  environment variable) makes the entry `node <path>` on every OS. It is an editor
  setting, not a project one, because the path exists only on that machine. Pin
  modes don't apply, since a local build is one exact build already.
- **Nothing is rewritten silently.** A pin only takes effect when someone presses
  **Write .mcp.json** or the dock's button and confirms. The dock compares the file
  with the spec the project wants: an entry the toolkit wrote that no longer matches
  gets an amber offer to update or pin it, and an entry set by hand gets a quiet
  offer to restore the recommended spec. To tell the two apart, the write flow
  records the spec it last wrote in the editor's project metadata. That record is
  machine-local and never committed, so a teammate's toolkit sees a hand-set file
  as hand-set.

## Considered and rejected

- **Record the last-written spec in `project.godot`.** A committed record would
  claim every teammate's file as toolkit-written, and the dock would nag a teammate
  who pinned a version on purpose. The editor's project metadata keeps it per
  machine.
- **Rewrite stale pins automatically on editor start.** The client may be running
  the server when the editor opens, and `.mcp.json` may hold other servers and keys
  a user maintains. A write the user did not ask for would surprise them.

## Consequences

- **Every pin change needs a client restart.** `npx` caches by spec, so the client
  runs a new version only when it starts the server again, and that first start
  downloads it. The success message and the dock's confirmation say so.
- **A server fix reaches Pinned users through a toolkit patch.** The toolkit
  releases a patch that moves the pin (`release.sh --compatible-server`), and users
  get it when they update the addon and write `.mcp.json` again.
- **Latest users still get the newest server on day one.** For them the
  compatibility floor of ADR 0024 stays the safety net, and the version warning
  stays their signal to update the toolkit.
- **The pin is temporary in form.** When the server ships inside the toolkit, the
  bundled server replaces the npm pin and this decision's mechanism goes with it.
- **A CI job proves the written entry starts.** It prints the entry the writer
  builds on Linux, macOS and Windows, launches it, and checks that the server
  answers MCP `initialize` with the pinned version
  (`.github/workflows/mcp-entry-launch.yml`).

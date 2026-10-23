# DISTRIBUTION.md — release + install guide

---

## Dogfood setup (contributors)

The toolkit repo root is itself a Godot 4.5 project, so "developing the
plugin" and "using the plugin against a project" share a single workflow:
open this repo in Godot, run `claude` from its root.

```
# one-time, in the server repo, only when the editor starts with
# GODOT_MCP_DEV_SERVER_PATH set (a local server build); the released npx
# entry needs no build
cd <server repo root>
npm install
npm run build

# every session
# 1) open THIS (toolkit) repo root in Godot 4.5+
# 2) Project Settings -> Plugins -> "Godot MCP Toolkit" -> Active
# 3) from this repo root (where the dogfood .mcp.json lives):
claude
# /mcp should list `godot-mcp-toolkit: connected` with 10+ tools.
```

**The 4.4.1 crash note.** The toolkit-root + `claude` path once crashed Godot
4.4.1 because of a race between the plugin's per-frame TCPServer poll and
claude's auto-indexing of the plugin's `.gd` source files (the
filesystem-importer race). The frame-skip mitigation (toolkit commit
`5116694`) makes that race unreachable under normal use, confirmed on
2026-04-15. A sibling `godot-mcp-dogfood-playground/` project exists and
still works; it's reserved for clean-project / end-user-install verification
(Asset Library install checks, for example), not day-to-day dogfood.

**The dogfood `.mcp.json`.** It is not tracked: each machine's dock writes its
own, in the form for that OS (`cmd /c npx` on Windows, bare `npx` on macOS and
Linux), so a tracked copy would differ between machines. The shipped
`addons/godot_mcp_toolkit/.mcp.json.template` holds the bare-`npx` entry.

## End-user plugin install (manual zip, available today)

1. Grab the latest `godot-mcp-toolkit-*.zip` from the
   [toolkit repo's GitHub releases](https://github.com/NPGameDev/godot-mcp-toolkit/releases).
2. Extract into `<your-godot-project>/addons/`. The zip's top-level entry is
   `addons/godot_mcp_toolkit/`, so the extract creates the right layout.
3. In Godot: Project Settings → Plugins → "Godot MCP Toolkit" → Active.
4. Confirm the editor log shows `[MCPServer] listening on 127.0.0.1:6550`.

## End-user plugin install (Asset Library, once submitted)

1. Inside Godot: AssetLib tab → search "Godot MCP Toolkit" → Download → Install.
2. Same result as the manual zip route.

## End-user server install (pairs with either install route above)

1. `npm install -g @npgamedev/godot-mcp-server` (requires Node ≥ 22).
2. Copy `addons/godot_mcp_toolkit/.mcp.json.template` up one level into your
   Godot project's root and rename to `.mcp.json`.
3. From the project root, run `claude` — `/mcp` lists
   `godot-mcp-toolkit: connected`.

(The editor's MCP dock has a one-click **Write .mcp.json** item that writes
this file for you, so the manual copy is optional.)

---

## Release process (cross-repo)

The plugin and the npm server version independently (ADR 0024): each repo has
its own semver, tags and release cadence, and compatibility is a declared floor
that the connect-time handshake checks, not a matching version number. Each
repo releases itself with its own `scripts/release.sh`. For now each repo's tag
gate requires the pinned sibling to declare the version being tagged, so both
repos still release at the same version, server first.

[RELEASING.md](RELEASING.md) holds the ritual (the version scheme, the release
script and its server-pin flag, the sibling pins) and
[docs/dev/release-runbook.md](docs/dev/release-runbook.md) holds the
release-day order for both repos.

To build the plugin zip by hand:

```
# Unix / macOS
./scripts/build-plugin-release.sh
# Windows (PowerShell)
./scripts/build-plugin-release.ps1
```

It produces `dist-plugin/godot-mcp-toolkit-<version>.zip`, whose top-level entry
is `addons/godot_mcp_toolkit/` (no repo-root noise). Each new version is a new
AssetLib submission (checklist below).

---

## Asset Library submission checklist

1. Pick a clean commit on `main` that passes all smoke checks. Record the full
   40-char SHA — AssetLib's "Download Commit" field requires it.
2. Confirm `icon.png` at repo root is ≥128×128, square, PNG, and is visually
   distinctive at list-view size. The current `icon.png` is the Godot default
   placeholder at 128×128 — **before first submission, replace it with a
   branded MCP-toolkit thumbnail** (keep the filename so the
   `raw.githubusercontent.com/NPGameDev/godot-mcp-toolkit/<sha>/icon.png` URL
   stays stable).
3. Confirm `LICENSE` at repo root matches the declared AssetLib licence (MIT).
4. Go to <https://godotengine.org/asset-library/>, log in, → Submit an asset:
   - **Asset Name:** `Godot MCP Toolkit`
   - **Category:** `Addons`
   - **Godot version:** the toolkit's minimum, the **Minimum** line in the
     README's "Godot version support" (currently `4.2`), not the dogfood
     project's `config/features`
   - **Version:** matches `plugin.cfg` version
   - **Repository URL:** `https://github.com/NPGameDev/godot-mcp-toolkit`
   - **Issues URL:** `https://github.com/NPGameDev/godot-mcp-toolkit/issues`
   - **Download Commit:** full SHA from step 1
   - **Icon URL:**
     `https://raw.githubusercontent.com/NPGameDev/godot-mcp-toolkit/<sha>/icon.png`
   - **License:** `MIT`
   - **Description:** short paragraph — what the plugin does, mention the
     companion `@npgamedev/godot-mcp-server` npm package requirement, link to
	 this repo's README.
   - **Previews:** 1–3 screenshots (editor with plugin enabled + a Claude Code
	 transcript showing a tool call in flight).
5. Submit. Review is manual, typically 1–5 days.
6. For each subsequent version, submit again through the same form — AssetLib
   tracks versions but not automatically.

---

## Release assets inventory (what ships vs what doesn't)

The plugin zip contains **only** `addons/godot_mcp_toolkit/**`, copied whole
from the working tree (build from a clean checkout, or untracked files under the
addon ship too): `plugin.cfg`, `plugin.gd`, `icon.svg`, the `.mcp.json.template`, the addon's
own `README.md`, `LICENSE` and `ATTRIBUTIONS.md`, the user docs under `docs/`,
the companion skills under `CompanionSkills/`, every source folder and the
`.uid` sidecars (the build fails if none ship). The source archive AssetLib
downloads carries the same tree: `.gitattributes` export-ignores every path
outside `addons/`.

Everything outside the addon (the dogfood project's `project.godot` and
`Main.tscn`, `icon.png`, the root docs, `scripts/`, `test/`, `.github/`, the
`.godot/` cache and any local `.mcp.json`) is **not** in the zip: those are
dogfood-project or AssetLib-landing-page concerns, not end-user project
additions.

The `.mcp.json.template` inside the addon directory holds the bare-`npx`
entry. The dock writes the same entry into a project's `.mcp.json`, wrapping
the command in `cmd /c` on Windows.

---

## Pointers

- Server-side release notes: the server repo's `README.md`.
- Attribution: this repo's `ATTRIBUTIONS.md` (GDScript side) and the server
  repo's `ATTRIBUTIONS.md` (TypeScript side).

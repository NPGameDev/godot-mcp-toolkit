# DISTRIBUTION.md — release + install guide

> ⚠️ **Security gate — read first.**
>
> **Do not tag release versions, publish to npm, or submit this plugin to the
> Godot Asset Library before iteration 20 completes.** Iter 18 adds
> transport auth + the `FileGuard` `res://` sandbox; iter 19 adds MCP
> annotations for high-risk tools + the user-scope opt-in; iter 20 adds
> response caps, secret scrubbing, and the audit log.
>
> Iter 08 produces the release *assets* (plugin zip script, npm postbuild,
> AssetLib submission checklist below); it does not trigger the release.

---

## Dogfood setup (contributors)

The toolkit repo root is itself a Godot 4.4 project, so "developing the
plugin" and "using the plugin against a project" share a single workflow:
open this repo in Godot, run `claude` from its root.

```
# one-time, in the server repo
cd <server repo root>
npm install
npm run build

# every session
# 1) open THIS (toolkit) repo root in Godot 4.4+
# 2) Project Settings -> Plugins -> "Godot MCP Toolkit" -> Active
# 3) from this repo root (where the dogfood .mcp.json lives):
claude
# /mcp should list `godot-mcp-toolkit: connected` with 10+ tools.
```

**Post-iter-13c note.** The toolkit-root + `claude` path crashed Godot 4.4.1
pre-iter-13c because of a race between the plugin's per-frame TCPServer poll
and claude's auto-indexing of the plugin's `.gd` source files (the
filesystem-importer race). Iter 13c's F3 frame-skip mitigation (toolkit
commit `5116694`) makes that race unreachable under normal use — confirmed
2026-04-15 late evening via Test 3 (see the plan repo's crash report). A
sibling `godot-mcp-dogfood-playground/` project exists and still works; it's
reserved for clean-project / end-user-install verification (e.g. iter 20
AssetLib install checks), not day-to-day dogfood.

**Pre-iter-20 note.** This repo's dogfood `.mcp.json` (and the byte-identical
`addons/godot_mcp_toolkit/.mcp.json.template`) currently use a path-based
`node <abs-path>/dist/index.js` invocation rather than
`npx -y @npgamedev/godot-mcp-server`, because the scoped npm name is not yet
published (publish is gated on iter 20). Iter 20 publishes to npm and then
swaps both files back to the scoped-npx form — at which point the dogfood
`.mcp.json` works unchanged for end users too. See iter 13b for the original
swap rationale and iter 20's verification for the swap-back.

## End-user plugin install (manual zip, available today)

1. Grab the latest `godot-mcp-toolkit-*.zip` from the
   [toolkit repo's GitHub releases](https://github.com/NPGameDev/godot-mcp-toolkit/releases)
   (note: **no releases exist yet** — gated to iter 20).
2. Extract into `<your-godot-project>/addons/`. The zip's top-level entry is
   `addons/godot_mcp_toolkit/`, so the extract creates the right layout.
3. In Godot: Project Settings → Plugins → "Godot MCP Toolkit" → Active.
4. Confirm the editor log shows `WS server on 127.0.0.1:6550`.

## End-user plugin install (Asset Library, once submitted)

1. Inside Godot: AssetLib tab → search "Godot MCP Toolkit" → Download → Install.
2. Same result as the manual zip route.

## End-user server install (pairs with either install route above)

1. `npm install -g @npgamedev/godot-mcp-server` (requires Node ≥ 20).
2. Copy `addons/godot_mcp_toolkit/.mcp.json.template` up one level into your
   Godot project's root and rename to `.mcp.json`.
3. From the project root, run `claude` — `/mcp` lists
   `godot-mcp-toolkit: connected`.

(Iter 21 adds a one-click menu item in the editor's MCP dock that writes this
file for you — no manual copy needed from that iteration onwards.)

---

## Release process (cross-repo)

The plugin zip and the npm server must ship in lockstep. Version numbers stay
synchronised manually until a bump script lands post-MVP.

1. In the **toolkit repo**: bump `addons/godot_mcp_toolkit/plugin.cfg` →
   `version="X.Y.Z"`.
2. In the **server repo**: bump `package.json` → `"version": "X.Y.Z"` (same
   value).
3. In the toolkit repo: run the release script:
   ```
   # Unix / macOS
   ./scripts/build-plugin-release.sh
   # Windows (PowerShell)
   ./scripts/build-plugin-release.ps1
   ```
   Produces `dist-plugin/godot-mcp-toolkit-<version>.zip`. The top-level entry
   inside the zip is `addons/godot_mcp_toolkit/` (no repo-root noise).
4. In the server repo: `npm pack` to inspect (`tar -tvzf
   npgamedev-godot-mcp-server-<version>.tgz` — scoped names yield dashed
   tarballs), then `npm publish` (requires `npm login`).
5. In the toolkit repo: `git tag v<version>`, `git push origin v<version>`,
   create a GitHub release, and attach the plugin zip.
6. (Only after iter 20.) Re-submit to AssetLib via the checklist below — each
   new version is a new submission.

---

## Asset Library submission checklist (gated to iter 20)

Do not submit before iter 20 completes (see the security gate at the top).

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
   - **Godot version:** minimum from `project.godot` `config/features`
     (currently `4.4`)
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

The plugin zip contains **only** `addons/godot_mcp_toolkit/**`:

```
godot-mcp-toolkit-X.Y.Z.zip
└── addons/
    └── godot_mcp_toolkit/
        ├── plugin.cfg
        ├── plugin.gd
        ├── mcp_server.gd
        ├── icon.svg
        ├── README.md
        └── .mcp.json.template
```

Repo-root files (`project.godot`, `icon.png`, `LICENSE`, `README.md`, `.mcp.json`,
`CLAUDE.md`, `ATTRIBUTIONS.md`, `DISTRIBUTION.md`, `scripts/`, `Main.tscn`, the
`.godot/` cache, smoke artifacts) are **not** in the zip — they are
dogfood-project or AssetLib-landing-page concerns, not end-user project
additions.

The `.mcp.json.template` inside the addon directory is byte-identical to the
dogfood `.mcp.json` at repo root. They are kept in sync manually; iter 01a
and iter 08 include a `diff` check in their verification.

---

## Pointers

- Plan / security gate rationale:
  `<plan-repo>/Plan/ExecutionPlan/00-index.md` §Stage summaries + iters 18–20.
- Server-side release notes: the server repo's `README.md`.
- Attribution: this repo's `ATTRIBUTIONS.md` (GDScript side) and the server
  repo's `ATTRIBUTIONS.md` (TypeScript side).

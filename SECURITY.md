# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately through
[GitHub Security Advisories](https://github.com/NPGameDev/godot-mcp-toolkit/security/advisories):
open the repository's **Security** tab and choose **Report a vulnerability**.
Do not open a public issue for a suspected vulnerability.

This project is maintained on a reasonable-effort, volunteer basis, so we do
not promise response timelines. Security reports are taken seriously and are
prioritized ahead of regular development: we will endeavor to acknowledge your
report, keep you informed as the investigation progresses, and credit you in
the fix's release notes if you wish. If you have not heard back, a follow-up
on the advisory is welcome. Please practice coordinated disclosure — allow us
a reasonable window to investigate and ship a fix before discussing the issue
publicly.

If the issue lives in the companion MCP server rather than the editor plugin,
report it in the
[godot-mcp-server repository](https://github.com/NPGameDev/godot-mcp-server/security/advisories)
instead — same process. When in doubt, report it here and we will route it.

## Supported versions

| Version | Supported |
| --- | --- |
| Pre-release (`main`) | Yes — security fixes land on `main` |
| From 1.0 onward | The latest release |

Until the first tagged release, `main` is the only line that receives fixes.
After 1.0, security fixes target the latest release; upgrading is the supported
path.

## Security model in one paragraph

The plugin runs a WebSocket server inside the Godot editor and authenticates
every connection with a random 64-character hex session token generated on each
plugin start — the companion MCP server reads it from disk, and unauthorized
connections are rejected. File operations are restricted to the project
(`res://`) by a guard that blocks path traversal, absolute OS paths, and paths
that escape the boundary after lexical canonicalization, and that denies the
plugin's own folders (`res://addons/godot_mcp_toolkit/` and
`user://addons/godot_mcp_toolkit/`) under any spelling, whatever the letter case
or a Windows alias name, to every tool that takes a project or user-folder path.
The exception is `asset_import`'s `source_path`, a file anywhere on disk to copy
into the project, which is not checked against these folders. The delete tools also refuse reserved paths: a
dot-named file or folder (`.git`, `.godot`, `.mcp.json`) or anything inside
one, any `project.godot` or `override.cfg`, and any name shaped like a Windows
alias, so none of them can remove the project's git repository. Setting
`GODOT_MCP_READ_ONLY=1` hides every mutating tool from the agent — a
server-side guarantee, independent of the editor. Every tool call is written
to an append-only audit log with a timestamp and parameter hash. Script reads and WebSocket buffers are size-capped, and
content returned from the editor is wrapped in per-call nonce-tagged envelopes
to mitigate prompt injection from file contents.

**Network defaults:** both WebSocket servers (editor and running game) bind
`127.0.0.1` only. Nothing listens on a network interface, and nothing is ever
exposed to the network.

**Self-update:** the toolkit installs a new version of itself only when the
project allows it (`mcp_toolkit/updates/install_mode`, asked in the setup
wizard), and only after you click **Update**. It installs only a release whose
update manifest is signed by a release key that the latest trust document
lists. The first trust document is embedded in each release, in
`addons/godot_mcp_toolkit/self_update/embedded_trust_document.gd`. Later ones
download from this repository's `trust-N` releases and count only when enough
of the previous document's root keys signed them. They are kept once per
machine in `godot_mcp_toolkit/trust/` inside the OS's user data folder. The
manifest pins the zip by size and SHA-256. Every download URL is built from the
version or the document's number, and a redirect may lead only to `github.com`
or a `githubusercontent.com` host other than `raw.githubusercontent.com`. The
test-only variable `GODOT_MCP_UPDATE_CHECK_HOST`
moves these downloads too, not only the update check, but it accepts only a
loopback address, and a server there can serve only releases the maintainer
signed. The addon folder is replaced while the editor closes, and if the new
folder can't be moved in, the old one goes back. The file tools refuse the
update folder, `res://addons/.godot_mcp_toolkit_update/`, as they refuse the
toolkit's own. The chain's main limit is a stolen release key: until a machine
has fetched the trust document that drops it, that machine still trusts the
key, so whoever holds it and can publish to this repository's releases can
ship a release the machine accepts. Major releases, and releases that need a newer Godot, are never installed this
way. See ADR 0029, the shipped
[`self-update.md`](addons/godot_mcp_toolkit/docs/self-update.md) and
[`docs/dev/trust-chain.md`](docs/dev/trust-chain.md).

## What no setting can promise

A Godot project is a code-execution environment: the engine runs GDScript, and
this toolkit exists so an AI agent can drive it — including executing code in
the editor or the running game. No configuration of this plugin makes that
100% safe. Read-only mode, the filesystem guard, and your MCP client's own
permission prompts reduce the blast radius; they do not eliminate it. Treat an
agent-driven editor session with the same care as running a script you did not
write yourself.

If you want stronger isolation than the built-in protections, run the whole
setup — editor, server, and agent — inside a boundary you control. Options,
roughly in order of effort:

- A **container** is the cleanest fit for headless work; a GUI editor inside a
  container needs display forwarding, at which point a VM is usually simpler.
- A **virtual machine** isolates the editor, the project, and the agent
  completely, GUI included.
- A **restricted OS account** with access to only the project directory limits
  what a misbehaving session can touch.
- **Blocking outbound network access** for the sandboxed environment prevents
  exfiltration even if something goes wrong inside it.
- A **disposable environment** (a scratch VM or a clone of the project) means a
  bad session costs you a reset, not a cleanup.

These are suggestions to layer on top of the defaults, not turnkey recipes —
the right amount of isolation depends on the project and on how much autonomy
you give the agent.

## More detail

- The [Security section of the README](README.md#security) — the security
  features at a glance.
- [`addons/godot_mcp_toolkit/docs/security-recommendations.md`](addons/godot_mcp_toolkit/docs/security-recommendations.md)
  — the shipped guide: per-tool risk notes and recommended client-side
  permission rules.

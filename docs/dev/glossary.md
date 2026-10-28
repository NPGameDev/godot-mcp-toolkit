# Domain Glossary — Toolkit

The ubiquitous language of `godot-mcp-toolkit` — the terms this project reserves for its
multi-session concurrency model, editor-responsiveness throttle, test layers, hint surface,
coverage counting, resource values, path safety, script checks, the debugger, and internal module
roles. Definitions here are **normative**: align code, comments, and the architecture
documentation to the term used here.

**Cross-repo SSOT.** This glossary is the **single source of truth** for the project's shared
vocabulary. The server repo's `docs/dev/glossary.md` cross-links it rather than restating it; the
shared terms are all defined here. The lone exception is **Bridge**, which is *server-owned* (the
server *is* the bridge) and defined in the server glossary — see the Bridge entry under
[Internal module naming](#internal-module-naming).

**Related vocabulary defined elsewhere.** The **editor/runtime split** rule — a runtime-shipped
script (the autoload and everything it `preload`s) must statically name zero editor-only classes,
with its "editor-tainted" / "export-clean" / runtime preload-closure / "silent-if-shipped"
vocabulary — is a portable engineering rule, not project-specific domain language. It lives in
`code-standards.md` §8.2, not here.

---

## Concurrency (multi-session)

Terms for the layer that applies when multiple Claude Code agents (WebSocket peers) connect to the
same Godot editor simultaneously.

### Command classification

**Tab-dependent command**
A command that resolves its target via `EditorInterface.get_edited_scene_root()` — the currently
active scene tab.

**Tab-independent command**
A command that operates on explicit file paths or engine singletons, with no reliance on the active
scene tab.

### Scene ownership

**Scene affinity**
A per-peer record of which scene a WebSocket peer is currently working on, set when the peer calls
`scene.open`.

**Scene lease**
A time-bounded exclusive right to the active editor tab, held by one peer at a time. Renewed by each
tab-dependent command from the lease holder. Prevents other peers from switching the active tab.

**Steal**
Forced transfer of the scene lease to a queued peer after the TTL expires, regardless of whether the
current holder is active.

**Auto-reacquire**
Transparent re-acquisition of a scene lease when a peer whose lease was stolen sends its next
tab-dependent command. The system queues the command, waits for lease availability, switches the
active tab, and executes — invisible to the agent.

### Serialization

**Mutation serialization**
Guarantee that no two mutation commands execute concurrently within the same Godot editor,
preventing interleaved scene-tree modifications and UndoRedo confusion.

### Relationships

- A **peer** has at most one **scene affinity** at a time.
- A **scene lease** is held by exactly one **peer** (the one whose **scene affinity** matches the
  active tab).
- A **steal** triggers **auto-reacquire** on the displaced peer's next **tab-dependent command**.
- **Tab-independent commands** bypass the **scene lease** entirely.
- All **tab-dependent commands** (reads and mutations) queue for the **scene lease** when targeting a
  non-active scene — no fallback to on-disk reads (stale data causes LLM confusion).
- **Mutation serialization** applies to all mutation commands regardless of **scene affinity**.

### Example

> **Dev:** "Agent A opened forest.tscn and Agent B opened menu.tscn. Won't B's `node.create_node`
> land on forest?"
> **Domain expert:** "No. B's `scene.open` is a **tab-dependent command** targeting a different scene
> than the **lease** holder's. It queues. After the TTL, B **steals** the lease, the tab switches to
> menu, and B's command executes there."
> **Dev:** "What happens when A comes back?"
> **Domain expert:** "A's next **tab-dependent command** triggers **auto-reacquire** — it queues,
> waits for lease availability, switches back to forest, and executes. A never sees an error."

---

## Editor responsiveness

The language of the **unfocused-responsive throttle**: the toolkit boosts the editor's unfocused
frame rate so MCP commands stay responsive while a client is connected.

**Unfocused-responsive mode**
The state in which the toolkit holds the global editor setting
`unfocused_low_processor_mode_sleep_usec` at a boosted value so the editor keeps a higher frame rate
while unfocused, keeping MCP command latency low. Opt-in (default on); active only while at least one
authenticated client is connected.

**True original**
The value of the global unfocused-sleep setting before the toolkit boosted it — the value a restore
must return to. Captured once (first-writer-wins) and never overwritten by a boosted value.

**Boosted value**
The value the toolkit writes to the global setting while unfocused-responsive mode is active
(default 60 fps; 30 fps documented power-saver).

**Conflict-aware restore**
Restoring the true original only if the live value still equals the boosted value the toolkit set. If
it differs, a human or another tool changed it, so the toolkit yields — it keeps their value and
deletes its backup rather than clobbering the change.

**Machine-wide backup**
The first-writer-wins record of the true original (and the boosted value), stored at machine scope
(the registry dir, version-keyed) so it matches the global setting's scope and is visible across all
projects/instances on that editor version.

**Self-heal**
On editor startup, reverting a leftover boosted value — from a crash or a concurrent instance — to
the true original when no client is connected, then deleting the backup. Guarantees the boost never
persists without a live connection.

---

## Validation vocabulary

The toolkit/server **test layers** and the word this project reserves for each. The canonical
meanings are pinned here — "sweep" especially is easily conflated.

**Smoke**
The server suite (`npm run smoke`) that exercises every tool in **isolation** — happy path, guards,
and error hints, one tool at a time; never cross-tool or stateful flows. Editor-required.

**Flow suite**
The server's **deterministic** suite for the **cross-tool, stateful flows** smoke omits (extension
lifecycle, combo chains, the regression-watch items), with per-section/step pass-fail reporting;
shares the `test/integration` helpers but runs as its own command, not folded into smoke. The
deterministic counterpart to the LLM **sweep**.

**Sweep**
The **LLM-driven**, non-deterministic interactive validation (driven from the
`Validations/tool-sweep.md` content-maps) — hint/UX quality judgment, exploratory edge-discovery,
and confirming **flow suite** failures (stale script vs real regression). The word "sweep" is
reserved for this layer.

### Relationships

- The **flow suite** and **smoke** share one test infrastructure (`test/integration` helpers, no
  duplicated assertions) but are separate run commands.
- A **flow suite** failure is handed to a targeted **sweep** re-run to distinguish a stale script
  from a real regression.

---

## Hint vocabulary

The four things this project calls a "hint." A **hint** is LLM-facing guidance attached to a tool
response, distinct from the response's `error` field and from the tool `description`.

**Success hint**
Guidance emitted on a *successful* command — the next step, a related tool, or a common pitfall.
Static (a per-tool string via `with_success_hint()` / `ToolDef.successHint`) or contextual. Carried
in the response `hint` field.

**Error hint**
*Recovery* guidance emitted on *failure*, keyed to the error code (with optional contextual override;
toolkit `DEFAULT_HINTS`, server `EXCEPTION_HINTS`). Load-bearing for autonomous recovery — has a
**floor**: never silenced by a verbosity setting.

**Contextual hint**
A success- or error-hint *computed at dispatch from the call's params or state* (e.g. `file_delete`
suggesting `scene_delete` for a `.tscn` path), as opposed to a static per-tool string.

**Discovery hint**
Guidance inside `discover_tools` responses that steers group/tool selection — a meta-tool hint, not a
per-command one.

---

## Coverage vocabulary

How this project counts and describes **what its tools can do**, for **human-facing** docs and the
`--tools-count` CLI — never injected into the LLM-facing tool surface (descriptions /
`discover_tools`).

**Operation**
One distinct action a tool can perform — a single value of the tool's action/operation
**discriminator** enum; a tool with no discriminator is exactly one operation. (Named "operation"
rather than "action" to avoid collision with Godot **InputMap actions**, a runtime input concept that
`input_map` / `input_simulate` bind to.)

**Operation coverage**
The total operation count across all **built-in** tools — the honest measure of "what you can do,"
reported alongside (and distinct from) the tool count in `--tools-count` and the tool-reference.
Per-project extension tools are dynamic and excluded. It is a **ceiling** ("up to") — some tools and
operations are Godot-version-gated, so older supported versions expose fewer.

**Action-consolidated tool**
A single tool that multiplexes several **operations** through one **discriminator** param over a
coherent target (e.g. `node_manage` → rename/reparent/reorder/duplicate, all on one node). The
deliberate design that makes tool count < operation count.

**Discriminator**
The single enum param whose value selects which **operation** runs (`action`, `operation`,
`event_type`). Distinct from a **selector/policy** enum that picks a value or behavior without
changing the action (`signals.mode`, `scene.if_exists`, `texture_generate.shape`) — those are not
operations.

### Relationships

- An **action-consolidated tool** exposes ≥2 **operations** via one **discriminator**.
- A single-purpose tool is exactly one **operation** (no discriminator).
- **Operation coverage** = Σ operations over built-in tools ≈ 1.4× the tool count.
- A **discriminator** changes the action; a **selector/policy** enum does not — only the former's
  values count as operations.

---

## Channel vocabulary

The **user-facing** names for the two live WebSocket connections the toolkit exposes. Distinct from
the editor/runtime *split* (which code may parse inside a shipped game — `code-standards.md` §8.2):
this is about the two connections a client can hold. Ports shown are defaults — the live scan bands
are 6550–6560 (editor) and 6570–6585 (runtime).

**Editor channel**
The connection to the WebSocket server inside the Godot **editor** (default port 6550). Carries all
edit-time tools, operating on the edited scene via `EditorInterface`. The default path; most tools
use it. Internal host label: *Mode A* — code comments, ADRs, and the contract doc only; it never
appears in user-facing docs.
_Avoid_: Mode A (user-facing); "editor server" (collides with **Bridge** — the server); "editor
mode" (collides with **Read-only mode**); "editor context" (overloaded — MCP context, context
window, `ToolContext`).

**Runtime channel**
The connection to the WebSocket server inside the **running game** (default port 6570), live only
during a playtest — debug builds only; it self-disables in release exports. Carries the runtime
tools operating on the live `SceneTree`. Plain-English gloss in prose: **the running game**.
Internal host label: *Mode B* — same rule as Mode A.
_Avoid_: Mode B (user-facing); "runtime server" (collides with **Bridge**); "runtime mode" /
"runtime context" (see above). Note that `game` is still a live tool enum value — it is accepted as
a **hidden alias** for `runtime` on both channel-selecting tools (mapped in, not advertised in
`tools/list`) — so use "the running game" as the prose gloss; never claim that no tool accepts
"game".

### Connection deadlines

The two time limits a new connection on either channel must meet, enforced by the shared transport
(`transport/ws_transport.gd`); the contract's C2 states them exactly.

**Auth deadline**
How long a peer has to authenticate once its WebSocket is open: 2000 ms, counted from the moment a
poll first sees the peer open. A peer still unauthenticated at a poll past it is closed with WS code
1008 "auth timeout"; an auth frame already waiting at that poll still counts.
The code holds it as `_AUTH_TIMEOUT_MS` / `_auth_timeout_ms`; "auth timeout" is also the close
reason on the wire.
_Avoid_: "silence window" (the clock does not start at the TCP connect).

**Open deadline**
How long a peer has to complete the WebSocket upgrade after the toolkit accepts its TCP
connection: 5× the **auth deadline** (10 s). A peer still not open past it is dropped with no
close code.

### Relationships

- The two channels are two separate WebSocket servers on distinct ports; a client holds the
  **Editor channel** whenever the editor is open and the **Runtime channel** only during a
  playtest.
- **Noun-light rule:** user-facing prose prefers bare adjectives ("editor tools", "the running
  game"); the "channel" noun appears only where the transport itself is the subject (the design
  philosophy, the architecture doc, the runtime-port configuration note).
- Two tools carry a **channel selector** on a unified vocabulary: both advertise
  `channel: "editor" | "runtime"` — `signal_emit.channel` (default `editor`, edit-first) and
  `execute_code.channel` (default `runtime`, runtime-first). The legacy value `game` is accepted as
  a hidden alias for `runtime` on both (mapped by a field-level value alias, not advertised), which
  is why "the running game" stays the safe prose gloss for the Runtime channel. `node_call_method`
  is editor-only; its runtime counterpart is `execute_code`.

---

## Surface vocabulary

How this project names **which tools a connected client sees**. Two orthogonal axes: how much of
the catalogue is loaded (startup vs full) and whether mutating tools are visible (read-only mode).

**Startup surface**
The tools exposed immediately on connect — the always-on core plus the meta tools; what
`tools/list` returns before any group is activated.

**Full surface**
The startup surface plus every on-demand group activated via `discover_tools`. A ceiling ("up
to") — some tools and operations are Godot-version-gated, so older supported versions expose
fewer.

**Read-only mode**
The orthogonal switch (`GODOT_MCP_READ_ONLY=1`, with a matching dock toggle) that hides every
mutating tool. A filter on whichever surface is active — not a mode of its own, and not a
profile.

### Relationships

- **Read-only mode** filters whichever surface is active — the **startup surface** and the **full
  surface** alike.
- Retired vocabulary — never present these as user-facing modes: "Standard", "Power User",
  "Minimal", "Custom", "Full profile", `GODOT_MCP_PROFILE`, `GODOT_MCP_CUSTOM_TOOLS`,
  `enable_tool_group`.

---

## Update vocabulary

How this project names the way users hear about a new toolkit version.

**Update check**
The toolkit's at-most-daily read of the latest published version (GitHub's latest release, then
the Asset Store's listing of it), compared locally with the installed version
(`versioning/update_check.gd`, run by `versioning/update_check_runner.gd`). It sends nothing about
the project, fails silently, and the `mcp_toolkit/updates/check_for_updates` project setting turns
it off. It waits for the **consent gate**: nothing is sent until the user has seen the setup
wizard's `updates` step.

**Update badge**
The closable dock notice that a newer version is published (`ui/dock/update/dock_update_badge.gd`).
It points at the release on GitHub and the Asset Store and, when the **install mode** allows,
offers Update, then Restart now and Don't install. After an editor start that installed a release,
or failed to, it shows that result until closed. Otherwise closing it hides it until a newer
version.

**Install mode**
The project setting `mcp_toolkit/updates/install_mode` that says whether the toolkit installs its
own updates (`update/install_mode.gd`): `manual` (links only), `ask` (the default; a window asks at
the next editor start) or `automatic` (installs when the editor closes, without asking). Until the
setup wizard's `update_install` step has been seen, every mode acts as `manual`. A major release,
or one that needs a newer Godot, is always `manual`.

**Self-update**
The toolkit verifying and installing a newer version of itself (`update/`, ADR 0029). The
installer stages a release in `user://`; the plugin's `_exit_tree` applies it while the editor
closes (`update/update_applier.gd`), never while it runs, and restores a backup if a write fails.

**Pending update**
A release the installer verified or staged, recorded with its files in
`user://addons/godot_mcp_toolkit/update/` (`update/pending_update.gd`). The editor's next exit
applies a staged one; the next start reports what happened and deletes it.

**Trusted release key**
A public key in `update/trusted_release_keys.gd`. A release is installed from the editor only when
its update manifest carries a signature by one of them; `scripts/sign-release.sh` makes and checks
such a signature.

**Release file list**
`release_files.sha256` in a release's addon folder: every other file with its SHA-256, in
`sha256sum` format (`update/release_file_list.gd`). The self-update deletes only files an installed
release listed and notices the ones changed by hand.

---

## Setup vocabulary

How this project names the first-run walkthrough and what it records. Code names it "onboarding"
(`ui/onboarding_wizard.gd`); everywhere else it is the setup wizard.

**Setup wizard**
The dialog that walks a user through the setup steps, titled "MCP Toolkit — Setup Wizard". A new
user sees every step; after a toolkit update, the next editor start shows only the steps the user
has not seen. The dock footer's **Setup Wizard** button opens it at any time with every step, seen
or not (a button run); while a run is open, the button brings that run forward instead.

**Setup step**
One page of the setup wizard, known by a stable id (`welcome`, `mcp_json`, `optional_steps`,
`updates`, `dock`), never by its position (`core/setup_steps.gd`). A step reworded in place keeps
its id; a step that must be shown again gets a new id.

**Required step** / **optional step**
A required step is one the user loses something by skipping (`welcome`, `mcp_json`, `updates`): it
comes back at every editor start until seen. An optional step (`optional_steps`, `dock`) does too
while the machine-wide `mcp_toolkit/setup_wizard/show_optional_steps` editor setting is on, but
closing the wizard with × counts every optional step the run had not reached as seen, and turning
the setting off hides unseen optional steps. Required steps show whatever that setting says.

**Seen steps**
The set of setup steps the user has seen, per project. A step is seen once the user leaves it with
Next or Done (or a button that moves on), or closes the wizard with × on it; × also counts the
optional steps the run had not reached. "Remind me later" counts nothing.

**Setup step tracker**
The one reader and writer of the seen steps, kept in
`user://addons/godot_mcp_toolkit/mcp_onboarding_shown_v001` as versioned JSON
(`core/setup_step_tracker.gd`; ADR 0027).

**Run planner**
The rule that picks which steps one wizard run shows: every step for a new user, the unseen steps
at an editor start, nothing on a mid-session enable (`SetupSteps.plan_run`).

**Consent gate**
What the toolkit may do on its own, decided from the user's settings and the setup steps they have
seen (`core/consent.gd`). The update check runs only when its setting is on and the `updates` step
has been seen; installing an update also needs the `update_install` step seen and an install mode
that installs. Distinct from tool permissions, which govern what an MCP client may ask for.

---

## Resource value vocabulary

How a tool call names a resource file as a property value.

**Tagged form**
The one way a tool call names an existing resource file as a property value:
`{"type": "Resource", "path": "res://…"}`.
_Avoid_: resource ref, typed path.

**Bare path**
A path String (`res://`, `uid://` or `user://`) given where a Resource value is expected, instead
of the tagged form. The toolkit never binds it: it names the tagged form the caller meant, or
refuses a path no resource can come from (`contract/bare_path_check.gd`).
_Avoid_: raw path, string path, untagged path.

---

## Path safety vocabulary

**Reserved path**
A project path no tool call may delete, because the engine, version control or the developer's
tooling depends on it: anything under a dot-named folder or file (`.git`, `.svn`, `.godot`,
`.claude`, `.mcp.json`), and any file named `project.godot` or `override.cfg`. Deleting one is the
developer's decision, made outside the agent. The delete commands refuse it through
`FileGuard.resolve_safe_delete()` (`security/file_guard.gd`), which also refuses a path segment
shaped like a Windows alias, since Windows can resolve one to a reserved path.
_Avoid_: protected file, metadata path, sensitive path.

---

## Debugger vocabulary

How this project names what the editor's debugger is doing with a game. Never write "paused"
alone: an error break and a breakpoint pause need opposite next steps.

**Error break**
The game stopped by the debugger at an error it cannot continue from: a parse error, a failed
script load, a runtime error. The fix is to stop the game, correct the script and start again.
`debug_state` reports it as `breaked: true` with `can_debug: false`.
_Avoid_: paused (alone), crash, hang.

**Breakpoint pause**
The game stopped by the debugger at a point it can resume from, such as a breakpoint the user set.
`debug_state` reports it as `breaked: true` with `can_debug: true`; `debug_continue` resumes it.
_Avoid_: paused (alone), break (alone).

**Local playtest**
A run of the project on this machine that the editor starts: its Play buttons, Run Current Scene,
Run Specific Scene, or `game_start`. Its game writes this machine's log.
_Avoid_: editor run (also covers a deploy), game session (unqualified).

**Remote deploy**
The editor's one-click deploy with remote debug: the game runs on a device or in a browser and
attaches to the editor's debugger, but writes its log where it runs, never into this machine's
log.
_Avoid_: one-click run, remote run, game session (unqualified).

**Latest debugger session**
The most recent game that attached to the editor's debugger, whether a **local playtest**, a
**remote deploy**, or a game started outside the editor. `debugger_get_log` reports on it; the
debug-session tracker (`transport/debug_session_tracker.gd`) holds its state.
_Avoid_: latest run (a run whose game never attached starts no session), game session
(unqualified).

---

## Script check vocabulary

**Templates folder**
The project's script-templates folder: `res://script_templates/` unless the
`editor/script/templates_search_path` project setting moves it (a sibling folder whose name
starts with it counts too). The engine treats a `.gd` file
under it as a template for new scripts and never parses it, so `script_check` compiles such a
file away from its path to still report its errors.
_Avoid_: templates dir (bare), script_templates (alone, it ignores the setting).

---

## Internal module naming

The canonical names for internal toolkit modules and the architectural roles they occupy. These are
**preload-alias** names (reached as `Modules.<Alias>`, see `core/modules.gd`) — **not** extension-API
`class_name`s. For the naming convention itself, see `code-standards.md`.

**Command Registry** (`MCPToolkitCommandRegistry`, `transport/mcp_toolkit_command_registry.gd`)
The in-memory **dispatch table** — name→Callable + lane/version metadata. The single extension-API
surface (`registry.add(...)`). Not the project store (see *Registry (project/instance store)* below).

**Built-in command installer** (`transport/builtin_command_registration.gd`)
The **one-shot startup enumerator** that runs every `commands/*.register()` call against the Command
Registry. Owns no state. Distinct from the Command Registry it writes to.

**JSON-RPC request router** (`transport/dispatch/server_request_router.gd`)
Routes a **parsed JSON-RPC request** to one of three **dispatch lanes** (read-only / mutation /
scene-lease) per the command's registry flags; owns the dispatcher-level cases (`_cancel`, `echo`,
registry-miss).

**Dispatch lane** (`transport/dispatch/dispatch_lane.gd`: ReadOnlyLane / MutationLane / SceneLeaseLane)
The three concurrency disciplines a routed request can take. Selected by the router; each `drive()`s
its own class of command.

**Registry (project/instance store)** (`RegistryClient`, `Modules.RegistryClient` →
`registry/registry_client.gd`)
The **machine-wide** `projects.json` store: per-editor entry files fanned into `projects.json` for the
bridge. **Distinct from the Command Registry.**

**Monitor** (`UserPathMonitor`, `paths/user_path_monitor.gd`)
An observer of **ongoing settings/FS state** that emits a re-resolve signal when the observed value
changes.

**Detector** (`PlaytestEndDetector`, `core/playtest_end_detector.gd`)
An **edge-detector** of a transition (play→stop). Fires once at the boundary, not continuously.

**Watcher** (`extension_watcher` pattern)
The FS/settings **reconcile** case — a debounced rescan of a live extension set triggered by FS
events. Not an edge-detector; not a continuous-state observer.

**CommandHelpers** (`Modules.CommandHelpers` → `commands/editor_helpers.gd`)
The shared helper module for the `commands/` subsystem: node-resolution, class-checks, file/dir ops,
log-level, profile-convert. The domain qualifier is mandatory — a bare `Helpers` alias is not
permitted.

**Compile probe** (`CompileProbe`, `core/compile_probe.gd`)
The in-memory copy of a `.gd` file that `script_check`, the inline checks of `script_write` and
`script_edit`, and the stale-instance hint compile to judge the file without reloading the script
the editor has loaded. The copy compiles under `<file>.__mcp_probe_<id>.gd` beside the file,
unless the file sits under the project's script-templates folder, when it compiles with no path, and
is then emptied, with its path cleared. It renames the script's `class_name` and checks the original name the way
the engine's analyzer does. It runs in up to three steps: the **rename probe** renames the
declaration and every bare reference to the name; the **declaration probe**, run when that fails,
renames only the declaration; the **keep-name probe**, run on 4.5+ with the Logger capture active
when both fail for a file that owns its registered `class_name`, compiles the source as written and
accepts it when its only error is the clash with its own registered class.

**VersionUtils** (`Modules.VersionUtils` → `versioning/mcp_version_utils.gd`)
The cross-version facts module (the `is_at_least` / `is_at_most` / `is_version_in_range` set). Reached
as the preload alias `Modules.VersionUtils` — it is **not** a `class_name`: there is no
`MCPVersionUtils` class, and the public `MCPToolkit*` class_name set does not include it.

**Dock section** vs **editor-global dialog** (the dock boundary)
A **dock section** is a UI surface owned by and rendered inside the dock (status panel, `.mcp.json`
health panel, unfocused control, audit section, limits section); it may lazily create its own viewer
window, but its home, lifecycle, and API are the dock's — the audit log is a dock section, so
`show_audit_dialog()` stays a dock method. An **editor-global dialog** parents to
`EditorInterface.get_base_control()` — not to the dock — and is reachable from non-dock surfaces
(Tools menu, setup wizard); it is owned by the **dialog presenter**
(`ui/toolkit_dialog_presenter.gd`), never by the dock. The dock is a **UI surface, not a service
locator**: cross-cutting behaviors (the shared `.mcp.json` write flow, the editor-global dialogs)
live in composer-built, injected collaborators that every consumer — dock included — calls directly
(ADR 0016).

**Bridge** — *server-owned term; defined in the server repo's `docs/dev/glossary.md`.*
The **Bridge** is the server (the TypeScript MCP bridge process). The editor (toolkit) side has **no**
bridge: the `transport/debug_bridge.gd` `EditorDebuggerPlugin` is **not** the Bridge despite its
filename. It is a thin adapter that feeds the debugger's session events to the session tracker,
`transport/debug_session_tracker.gd`, which holds the session state. Never call a toolkit-side
component a "bridge."

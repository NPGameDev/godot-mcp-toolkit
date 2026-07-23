# Bundled agent skills

The addon ships two **agent skills** alongside the toolkit — small, self-contained instruction packs that make an AI coding agent better at driving this MCP surface. They live in `addons/godot_mcp_toolkit/CompanionSkills/`, one folder per skill. They are optional: the toolkit works without them, but installing them improves how an agent uses it.

**Installing a skill** — copy the skill's **whole folder** (including its `references/` subfolder) from `addons/godot_mcp_toolkit/CompanionSkills/<skill>/` into your client's skills directory, e.g. `.claude/skills/`. Copy the entire folder, not just the top-level file — the `references/` material is part of the skill.

Two skills ship:

## `godot-mcp-toolkit` — the toolkit workflow skill

**What it is.** The workflow skill teaches an agent how to use this toolkit well: which tool to reach for, how to batch tool calls, how to recover from errors, and how to keep token usage down when driving an MCP-connected editor. It is general-purpose guidance for any build — install it and the agent makes better tool choices from the first request.

**How to install.** Copy `addons/godot_mcp_toolkit/CompanionSkills/godot-mcp-toolkit/` — the whole folder, including `references/` — into your client's skills directory (e.g. `.claude/skills/`).

**Why.** It **measurably reduces the agent's tool calls, tokens, and wall-clock** on a typical build. In a controlled two-wave run — the same game built with and without the skill, at the same toolkit and server version — the skill arm used fewer tool calls, fewer output tokens, less wall-clock, and less money, while completing the same build. The measured figures, the exact scope (game, model, run count, versions), and the honest caveats are published here: <https://github.com/NPGameDev/godot-mcp-server/blob/main/docs/companion-skill-efficiency.md>.

## `mcp-extension-creator` — the extension-authoring skill

**What it is.** This toolkit lets a project register its own MCP tools in GDScript — project-specific helpers the agent calls like built-ins. The extension-authoring skill **eases the workflow of creating those new tools**: it walks an agent through authoring a distributable MCP extension end-to-end, and it carries an opt-in **guided-authoring mode** that turns extension creation into an interactive design conversation. Install it when you want the agent to build or extend the toolkit's tool surface for your project.

**How to install.** Copy `addons/godot_mcp_toolkit/CompanionSkills/mcp-extension-creator/` — the whole folder, including `references/` — into your client's skills directory (e.g. `.claude/skills/`).

**Learn more.** The extension configuration surface it guides you through — how tools are registered, timeouts, cancellation, hot-reload, and C# support — is documented in [extending.md](extending.md), which is the source of truth for writing an extension by hand.

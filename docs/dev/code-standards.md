# Code Standards — Toolkit

The code standard for `godot-mcp-toolkit`, the Godot 4.x editor-plugin / GDScript
half of the project. It does **not** govern the TypeScript server — that repo carries its own
standard.

The document has two parts, and the split is load-bearing:

- **Part I — Portable core** is project-agnostic. It is the set of GDScript and
  Godot-plugin conventions that hold for *any* editor plugin, written so it can be lifted into
  a new plugin as-is. It names this repo's companion documents (a glossary, a contract doc, a
  module taxonomy) only as *optional* alignment points, never as prerequisites.
- **Part II — Project bindings** is this repo's specifics: the `MCPToolkit*` public
  namespace, the nine public classes, the on-disk module taxonomy, the canonical in-tree
  exemplars, and the contract bindings.

**Scope of the general rules.** The general clean-code rules in Part I — naming, formatting,
static typing, comments, and DRY — apply to **all GDScript in the codebase**: the shipped
addon, the `test/` trees, and any tooling script. A file being a test helper or a one-off
script does not lower its readability bar. The genuinely **editor-plugin-specific** rules —
the preload/`class_name` aggregator, the `EditorPlugin` lifecycle, the `@tool` /
editor-runtime / cross-version / export hard gates, Asset-Library hygiene, and god-file
decomposition — are **addon-scoped**: non-addon GDScript is exempt from *those* rules only
because it is not an addon, not because it earns a lower-quality bar. Test scripts are held to
the general rules like every other file. The unit-test rules in [§9](#9-unit-test-code) apply
to test code on top of the general rules.

**On conflict, the hard gates win.** Several addon rules deliberately *deviate* from the base
Godot style guide because the addon runs inside the editor process and ships in export
templates. Those deviations live in [§8 — Godot editor-plugin hard gates](#8-godot-editor-plugin-hard-gates),
and they override stylistic preference wherever the two collide. Each is driven by a concrete
engine bug, an export-template failure mode, a multi-version API gap, or a security boundary at an OS sink.

Primary references:

- GDScript style guide — <https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html>
- Static typing — <https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/static_typing.html>
- Running code in the editor (`@tool`) — <https://docs.godotengine.org/en/stable/tutorials/plugins/editor/making_plugins.html>

---

# Part I — Portable core

## 1. File, folder, and symbol naming

1.1 **Files and folders are `snake_case`.** A named class converts its PascalCase `class_name`
to the snake_case of that name for the filename. *Rationale: cross-platform
case-insensitive-filesystem safety plus Godot convention.* So `class_name MyToolWidget` lives
in `my_tool_widget.gd`, not `MyToolWidget.gd`.

1.2 **Identifier casing** (the base guide, followed verbatim):

| Kind | Case |
|---|---|
| `class_name` / node types / type names | PascalCase |
| Functions / variables | snake_case |
| Signals (past tense) | snake_case |
| Constants | CONSTANT_CASE |
| Enum *name* / enum *members* | PascalCase / CONSTANT_CASE |
| Private / virtual members | leading `_` |

1.3 **Leading underscore means "internal / not API".** Use it for private variables and
private methods. Built-in virtuals (`_enter_tree`, `_ready`, `_process`, `_exit_tree`) keep
their engine-defined underscore. *Rationale: GDScript has no `private` keyword, so the `_`
prefix is the visibility marker.*

1.4 **Signals are named in the past tense** for state changes (`door_opened`). Where the name
describes an *event* rather than a state transition it should still read naturally
(`command_received`, `client_connected`).

### 1.5 Names are intent-revealing, unambiguous, and spelled out

This is a general clean-code rule, codebase-wide — every `.gd`, addon and test alike. A
single-letter or cryptic identifier (a bare `h` for a passed-in object, a `mgr`/`ctx`/`reg`)
is non-conforming everywhere **unless** it is a tight, conventional local: a loop index
`i`/`j`, a math coordinate `x`/`y`/`z`. "It's only test code" is not an exemption.

1. **No unexplained abbreviations — spell out intent, even at the cost of length.** A
   file/class/const/alias name uses whole words, not contractions a reader must already know.
   Expand domain/protocol acronyms in the *name* (`json_rpc_…`, not `rpc_…`). A longer name and
   longer preload path is the accepted trade for a name that reads correctly on first
   encounter. Established, widely-understood initialisms tied to a documented public surface are
   allowed; a private internal `rpc`/`mgr`/`ctx` is not.
2. **Intent revelation.** The name states *what it is or does* in its domain. Bare grab-bag
   tokens (`Helpers`, `Utils`, `Manager`, `Handler`) are allowed only with a domain qualifier
   that says *which* domain (`CommandHelpers`, `LogHelpers`, `VersionUtils`), never alone.
3. **Disambiguation.** No two unrelated concepts share a confusable name, and no
   near-homograph pair lives in one folder. Do not pair a `*registry*` with a `*registrar*`
   (they read identically) — name a one-shot enumerator for its job (a *builder*/*loader*/
   *installer*), not a "registrar". Reserve a word like "Registry" for a genuine store.
4. **Observer-verb convention.** Distinguish observer kinds by verb: a `*_monitor` *observes
   ongoing state* and emits a re-resolve signal; a `*_watcher` reconciles via a filesystem or
   hot-reload signal; a `*_detector` *edge-detects a transition* (`playtest_end_detector`). Do
   not name an edge-detector a "watcher".
5. **Avoid engine-type and cross-role collisions.** A `class_name` never shadows a Godot type;
   a renamed file never takes the base name of the engine header it `extends` (not
   `editor_debugger_plugin.gd`). Internal names avoid words that already denote a *different*
   architectural role elsewhere in the project.
6. **Folder carries domain.** A file inside a bounded-context folder need not repeat the
   domain — but its class/alias must still be self-disambiguating when read *without* the path,
   because a hub alias is read as `<Hub>.<Alias>` with no folder context.
7. **Name every flag at the call site.** A call with two or more positional booleans
   (`open(path, true, false)`) does not say which flag is which, so it is not written: put each
   flag in a local named for it, or have the function take an options dictionary with named keys.

A grab-bag name like `Helpers` is often also a cohesion smell ([§7](#7-design-solid-cohesion-and-decomposition)),
but the rename and the structural split are separate fixes — one fixes the name, the other
fixes the structure. *If your project maintains a glossary, align every public name to its
canonical term.*

---

## 2. Mandatory declaration order

Every script orders its members top-to-bottom exactly as the style guide prescribes, so a
reader always finds each kind of member in the same place. Source: GDScript style guide → "Code
order".

```
01. @tool / @icon / @static_unload          (annotations)
02. class_name
03. extends
04. ## docstring (class documentation comment)
05. signals
06. enums
07. constants
08. static variables
09. @export variables
10. regular variables
11. @onready variables
12. _static_init()
13. other static methods
14. built-in virtuals, in this order:
       _init → _enter_tree → _ready → _process → _physics_process → (other virtuals)
15. overridden custom methods
16. remaining methods
17. inner classes
```

**2.1 Inner classes — type-before-use exception.** The guide places inner classes *last*.
GDScript requires a type to be declared before use in the same file, so when a member variable
is typed by an inner class, that inner class must appear **above** the variable. Allow an inner
class to sit immediately above its first use as a documented exception; prefer last placement
when no such constraint exists.

---

## 3. Formatting

3.1 **Tabs for indentation** (never spaces), one level deeper than the enclosing block.

3.2 **Continuation indentation:** two levels for wrapped function arguments; one level for
wrapped arrays / dicts / enums.

3.3 **~100-column soft guideline.** Keep lines under 100 characters where practical. This is
advisory, not a hard gate — never break a user-facing string literal (a hint string, an error
message) just to satisfy it.

3.4 **One statement per line** (the ternary is the sole exception). No `if x: return y`.
*Rationale: debuggability plus clean diffs.*

3.5 **Two blank lines** between functions and between class-level definitions; one blank line
to separate logical blocks inside a function.

3.6 **One space around operators and after commas.** Spaces inside single-line dict braces:
`{ key = "value" }`.

3.7 **Trailing commas** in multi-line arrays / dicts / enums / call argument lists.
*Rationale: clean diffs when the next element is added.*

3.8 **Prefer English boolean keywords** `and` / `or` / `not` over `&&` / `||` / `!`.

3.9 **Double quotes by default**; single quotes only when they reduce escaping.

---

## 4. Static typing

Source: <https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/static_typing.html>

4.1 **Type every function signature** — typed parameters and an explicit return type
(`-> Type`, or `-> void`). *Rationale: compile-time error detection, autocompletion, and
optimized opcodes.*

4.2 **Prefer `:=` inference when the type is obvious on the same line**; use an explicit
`: Type` when the right-hand side is ambiguous (results of `get()`, `call()`, dynamic dispatch,
or `Variant` JSON values).

4.3 **Type collections where it adds safety:** `Array[String]`, `Array[int]`,
`Array[WebSocketPeer]`. **Do not** use typed `Dictionary[K, V]` — it is 4.4+ only (see
[§8.3](#83-cross-version-compatibility)); use plain `Dictionary` for cross-version JSON
payloads. Typed `Array[...]` is fine (4.0+).

4.4 **Untyped `Variant` / plain `Dictionary` is correct at the JSON-RPC boundary.** Command
handlers receive `parameters: Dictionary` and return `Dictionary` because the payload is
dynamically typed JSON; do not force false precision there. At these boundaries, bare `var`
with `=` (not `:=`) is the correct choice precisely because the value is `Variant`.

4.5 **Avoid `as` for validation.** `as` silently yields `null` on mismatch and can hide bugs.
Validate explicitly instead of trusting a silent cast.

4.6 **Validate every input before the first mutation, and read every documented outcome.** A
command handler checks all of its parameters before it changes anything, so a bad input fails the
call with nothing half-applied. When a helper returns a documented outcome dictionary
([§5.11.3](#511-the-gdscript--godot-doc-comment-layer)), every call site reads it, or says in a
comment why it does not. *Rationale: an outcome nobody reads is a failure nobody reports.*

---

## 5. Comments and documentation

Comments split into two tiers: **doc comments** (`##`) the editor harvests into the in-editor
class reference, and **ordinary comments** (`#`) for implementation notes. The general
philosophy below governs both; [§5.11](#511-the-gdscript--godot-doc-comment-layer) adds the
GDScript/Godot doc-comment specifics on top. Where a Godot convention and a general rule
collide, **the Godot convention wins** — it keeps contributors familiar with the engine.

Each rule carries a confidence flag distilled from the canonical literature and the major
adopted style guides: **[STRONG]** = near-universal · **[common]** = widely held ·
**[contested]** = guidance, not law.

### 5.1 Core principle — intent (the "why"), never history

Code already says *what* it does and *how*; a comment earns its place by saying *why* — the
rationale, the non-obvious constraint, the hazard, the contract a reader can't infer. Two
corollaries:

1. **Why, not what/how.** A comment that restates the next line earns nothing and rots into a
   lie. Comment the *surprising*, not the *obvious*. [STRONG]
2. **Intent, not history.** A comment is self-contained intent for the reader of *this* code,
   not a development log. When it changed, which ticket or iteration produced it, who debated it
   — that belongs in version control, commit messages, and decision records. The comment carries
   the *resulting* intent, rewritten so it stands alone. [STRONG]

```
# ✗ retry 3 times
# ✓ retry 3×: the upstream load-balancer drops the first request after an idle period
```

### 5.2 What a comment is for (the high-value categories)

Write a comment when — and largely only when — it does one of these:

- **Intent / rationale** — *why* this approach, and why the obvious alternatives were rejected.
  The most durable category; structurally unrecoverable from code. [STRONG]
- **Warning of consequences** — hazards the code can't enforce (`# not thread-safe — call only
  from the main loop`; `# O(n²); fine for the fixed menu, never on user data`). Often the
  highest-value comment in a file. [STRONG]
- **Amplification** — flag a detail that looks trivial or removable but isn't, so a future
  "cleanup" doesn't reintroduce a bug (`# the trailing trim is required — the firmware appends a
  NUL byte`). [common]
- **Clarification of the unidiomatic** — explain a deliberate workaround or perf trick so it
  isn't "simplified" away. [common]
- **Invariants, assumptions, preconditions** — correctness conditions the syntax can't express.
  [STRONG]
- **Precision the type can't give** — units, value ranges, null/empty semantics, inclusive vs
  exclusive boundaries (`# timeout in milliseconds; 0 disables (not "instant")`). [STRONG]
- **A stable external reference** — a public issue/bug/PR link, a spec, an RFC, when the
  authoritative rationale lives outside the repo. Phrase it as *intent + constraint*, not
  narration (see [§5.4](#54-intent-not-development-history)). [common]

### 5.3 Express intent in the code first

The cheapest, most reliable comment is the one the code made unnecessary.

- **Prefer self-explanatory code over a comment.** A well-named `is_overdue()` beats
  `# check if overdue`; names and types are compiler-checked and never drift. [STRONG]
- **A comment needed to explain confusing code is a smell — refactor first.** If a block needs
  a paragraph to be understood, the fix is usually extraction or a better name. "Don't comment
  bad code — rewrite it." [STRONG]
- **"Self-documenting code" is the goal, not a licence to omit the *why*.** Names and structure
  carry *what/how*; they cannot carry rationale, rejected alternatives, or hazards. The
  consensus is quality over quantity. [contested]
- **Comment at a different level of abstraction than the code** — go *lower* (precision) or
  *higher* (intent); a same-level comment just echoes the code. [STRONG]

### 5.4 Intent, not development history

Comments are read by strangers reading *this* code; they are not a changelog.

- **Keep process history out of source.** No edit journals, no "changed by … on …", no
  sprint/iteration/ticket narration, no "we decided this during review." Version control records
  who/when/what far better, and the in-source log only rots. Rewrite the *resulting* intent
  inline; relocate the narrative rationale to commit messages and decision records. [STRONG]

  ```
  # ✗ Added in sprint 14 (TICKET-882); reworked after the Apr review — see decision log #7
  # ✓ Serialised single-file to avoid the torn-write race when two writers share the path
  ```

- **Keep load-bearing external references — rephrased as intent + constraint.** A *public*
  bug/PR link or spec reference that explains why this code must exist (or must not be
  "simplified") stays at the site, written as intent. Test: would a contributor with *only this
  repository* understand the why? If a reference is private or unreachable, inline enough context
  to stand alone, or drop it. [common]

  ```
  # ✓ work around <upstream/repo#1234>: the API returns stale data until the next frame, so re-read
  ```

- **No attribution or authorship tags** (`@author`, "created by") — version history owns that,
  and the tag is stale the moment someone else edits. [common]

### 5.5 Documenting the public surface

- **Document every public / exported symbol** — module, type, public function/method, public
  field/enum. Public doc comments feed generated docs and onboard contributors. [STRONG]
- **A doc comment must let a caller use the item without reading its body** — purpose,
  parameters, return/yield, and failure modes. **Document cross-module contracts where they're
  defined** (return shapes, invariants); they are the de-facto API between modules. [STRONG]
- **Document intent and contract, never types.** The signature already carries the types;
  repeating them is pure redundancy. Describe *meaning, units, contract*. [STRONG]

  ```
  # ✗ @param count  the integer count
  # ✓ count: items to take from the head; clamped to the buffer length
  ```

- **Lead with a one-line summary; defer depth** into the detail slot. [STRONG]
- **Give non-obvious public APIs a runnable example** — the fastest contract a user reads.
  Favour *clear* over *realistic*. [common]
- **Cross-reference instead of duplicating** — link a related symbol rather than re-describing
  it; one fact, one home. [STRONG]
- **Mark deprecations with the dedicated tag and name the replacement.** [common]
- **Internal/private comments are need-based, not mandatory.** Keep implementation detail out of
  the public docs. [STRONG]
- **Where the ecosystem supports it, make the public-API-doc requirement machine-enforced** so
  docs don't drift as the API grows. [common]

### 5.6 Anti-patterns (delete on sight)

- **Redundant / parrot comments** that restate the code (`i += 1  # add one`). Delete; rename
  the symbol if the intent was unclear. [STRONG]
- **Misleading / outdated comments ("rot")** — a stale comment is *worse than none*: the reader
  trusts it and builds on a false premise. [STRONG]
- **Commented-out / zombie code** — delete it; version control remembers. [STRONG]
- **Journal / changelog comments** in source → version control. [STRONG]
- **Noise / mumbling** — half-finished thoughts, decorative filler. Resolve or cut. [STRONG]
- **Banner / position-marker overuse** — heavy dividers usually signal the unit does too much
  (extract instead). If used at all, one agreed format, no ASCII-art boxes. [common]
- **Closing-brace / block-end comments** (`# end if`) — a crutch for over-long blocks; extract
  a function. [STRONG]
- **Over-commenting trivial code** — dilutes the rare comment that matters. [STRONG]
- **Apology / excuse comments** ("ugly hack, no time") — fix it or file a tracked issue and
  reference it. [common]
- **Vague or imprecise comments** — if you can't say it clearly, don't. [STRONG]
- **Caller / consumer enumerations** — a comment listing *who calls* the unit (`Used by X and
  Y`, `Called by plugin.gd`). The roster rots the instant a caller is added or renamed, and it
  duplicates what a reference search answers authoritatively. State the unit's **role and
  contract**, not its callers. Keep a consumer reference only when it is *load-bearing context
  the caller can't otherwise know* — e.g. "the runtime autoload preloads this, so keep it
  editor-clean" (a *constraint*, not a roster). [STRONG]

  ```
  # ✗ Used by command_registry.gd and extension_loader.gd to filter version-gated commands
  # ✓ Engine-version comparison helpers for version-gated command registration
  ```

### 5.7 TODO / FIXME and friends

- **Use a small, fixed, greppable marker set** with defined meanings (`TODO` = planned work,
  `FIXME` = known-broken, `HACK` = brittle). Keep the set short. [common]
- **Every marker is actionable + attributable + tracked** — state *what* and *why*, and
  reference a tracking issue where one exists: `TODO(<issue-or-owner>): <description>`. Track the
  real work in the issue tracker, not in source. [STRONG on the marker]
- **Bind time/condition-dependent markers to a concrete trigger** ("remove when all clients send
  v2") — "someday" TODOs never resolve. [common]
- **Scan markers in CI** so orphans surface and get triaged. [common]

### 5.8 Open-source hygiene (comments are public)

- **Never put secrets in comments** — keys, tokens, passwords, private endpoints. Public repos
  are scanned by bots within minutes of a push. [STRONG]
- **No internal-only URLs, absolute developer paths, or unreachable names** — contributors can't
  use them and they leak internal topology. [common]
- **Make ticket references resolvable** — a public tracker, or inline enough context to stand
  alone. [common]
- **Use an SPDX `SPDX-License-Identifier:` header, not a full licence blurb per file** —
  machine-readable, travels with the file, no per-file drift; full text lives once in `LICENSE`.
  [STRONG for OSS]
- **Keep comments professional, inclusive, contributor-facing** — no profanity, snark, blame,
  in-jokes, or non-inclusive terms. [common]
- **Attribute and link copied/adapted code** for licence compliance and provenance. [common]

### 5.9 Keeping comments healthy

- **Update a comment in the same change as the code it describes** — atomically. The one
  discipline that prevents rot. [STRONG]
- **Co-locate a comment with its code** — a detached comment drifts. [STRONG]
- **Treat comment accuracy as a code-review gate** — review that comments are still true and
  carry *why* not *what*. When a reviewer can't follow the code, fix the *code* first. [common]
- **Prefer making the comment unnecessary (refactor-first).** [STRONG]
- **Doc comments are build artifacts, not decoration** — generators consume them; a stale or
  broken doc comment is a defect. [STRONG]
- **Delete dead comments on sight** — zombie code, obsolete TODOs, notes that no longer apply.
  [STRONG]

### 5.10 Relocating stripped rationale

When [§5.4](#54-intent-not-development-history) strips internal narrative rationale out of a
comment, relocate it — to the commit message, to a decision record (ADR), or to the project's
rationale archive — rather than deleting the *thinking*. The comment keeps only the
self-contained *resulting* intent; the narrative trail lives where history belongs. *The
concrete archive mechanism and location are project-specific (see Part II).*

### 5.11 The GDScript / Godot doc-comment layer

The general rules above plus what `##` doc comments, the in-editor Help feed, and Godot
conventions require on top.

5.11.1 **`##` documentation comments** describe classes and public members and feed the
in-editor help (Help / F1). Place the class docstring immediately after `extends` (declaration
order slot 04, [§2](#2-mandatory-declaration-order)).

5.11.2 **`#` for regular comments**, starting with a space. `#region` / `#endregion` markers
take no leading space. (Prefer deleting commented-out code over preserving it,
[§5.6](#56-anti-patterns-delete-on-sight).)

5.11.3 **`##` on `static func` helpers that other modules call** — document the dict-shaped
return contract in the docstring (e.g. `## Returns {"ok": true, "value": <coerced>} on
success.`). These return shapes are the de-facto API between modules; document them where
they're defined.

5.11.4 **Section banners.** A `# -- Title ----` banner can chunk a long file into navigable
sections, substituting for folding regions. Use sparingly and with one agreed format — heavy
banners usually mean the unit does too much and wants extraction
([§5.6](#56-anti-patterns-delete-on-sight)).

5.11.5 **Public-API documentation is mandatory and exemplary.** The public `class_name` types
are the surface Godot auto-generates into the in-editor class reference, so **every public
member** — method, signal, constant, enum, and `@export` var — carries a `##` doc comment.
Depth scales with the member: a one-line brief for a trivial accessor; full parameter/return
prose plus a `[codeblock]` example for a primary entry point. *Internal* (preload-only)
scripts are not in the auto-generated reference, so they carry **at minimum a one-line
class-level `##` brief** plus the cross-module contract docs of 5.11.3 — not the exhaustive
per-member treatment.

5.11.6 **Brief vs. detailed description.** A doc block's **first paragraph is the brief** — the
one-liner shown in lists and tooltips. Separate it from the **detailed** body with a single
blank `##` line (a `##` with nothing after it). Lines within a paragraph are space-joined;
force a break with `[br]`. A block with no blank `##` line is used as both brief and detail.

```gdscript
## Restricts the command to a minimum Godot version.
##
## Versions below [param version] skip registration. Format is "major.minor"
## or "major.minor.patch"; an invalid format warns and is ignored.
func with_min_godot_version(version: String) -> MCPToolkitCommandOptions:
```

5.11.7 **Document parameters and return in prose — there is no `@param`/`@returns` in
GDScript.** Reference each parameter with `[param name]` and state the result with a "Returns
…" sentence. Never restate the signature's types (the signature carries them); describe
meaning, units, and contract.

5.11.8 **BBCode vocabulary — floored to Godot 4.2.** Doc comments are read on every supported
editor down to the 4.2 floor, so use only tags that render there:

- **Cross-references:** `[ClassName]`, `[param]`, `[member]`, `[method]`, `[signal]`,
  `[constant]`, `[enum]`, `[annotation]`.
- **Formatting:** `[b]`, `[i]`, `[u]`, `[code]`, `[codeblock]` (plain), `[br]`, `[url]`,
  `[kbd]`.

  **Forbidden** (4.3+ forms — they render as literal text in a 4.2 editor's doc popup,
  degrading the reference): `[codeblock lang=…]` (use plain `[codeblock]`), `[lb]` / `[rb]`,
  `[constructor]`, `[operator]`. Doc-comment content never affects compilation, so static
  validation cannot catch a violation — this rule is review-enforced (verify by viewing the
  rendered reference in the editor).

5.11.9 **`@`-tags.** `@tutorial(Title): URL` links an external guide. Mark API status with the
**bare** `@deprecated` / `@experimental` only — the `@deprecated: message` /
`@experimental: message` forms are 4.3+ (5.11.8); put the explanation in the description prose
and keep the bare tag for the badge.

5.11.10 **Give non-obvious public entry points a `[codeblock]` example** — the fastest contract
a caller reads. Favour clear over realistic; keep it 4.2-safe (plain `[codeblock]`).

---

## 6. Preloads, `class_name`, and the preload aggregator

6.1 **Prefer `const X := preload(...)` over `class_name` for plugin-internal scripts.**
`class_name` registers globally — it pollutes the user's autocomplete, "Add Node" dialog, and
type hints with names they never need. Reserve `class_name` for types the **end user**
legitimately touches.

6.2 **`class_name` is reserved for the public extension API and shared value types** — the
types an extension author or the dispatch contract needs globally. Everything else (commands,
helpers, monitors, sync) is preload-only.

6.3 **Centralize internal preloads in one aggregator.** A single `extends RefCounted`
aggregator script holds every internal script path as a `const Name := preload(...)`; other
files reach them through one `const <Hub> := preload(".../<aggregator>.gd")` and reference
`<Hub>.FileGuard`, etc. *Rationale: script paths live in one place — if a file moves, update
the aggregator and nothing else.*

6.4 **Two re-export forms, by intent.** When pulling a symbol *through* the aggregator, use
`:=` for a direct preload the file owns, and `=` (untyped) when re-exporting an aggregator
member whose type GDScript can't infer at parse time. The `=` form is required there, not
sloppiness.

6.5 **Beware aggregator cycles.** A file that the aggregator itself preloads must **not**
preload the aggregator back (circular dependency). Leaf helpers that the aggregator collects use
direct `preload()`, never the aggregator, and say so inline.

6.6 **No preload cycle of any length.** If A preloads B, nothing B preloads, directly or
transitively, preloads A. *Rationale: cyclic preloads still misbehave on supported engine
versions.* [Example](code-standards-examples/6.6-no-preload-cycles.md).

---

## 7. Design: SOLID, cohesion, and decomposition

The rules below are the SOLID and Clean-Code grounding applied to GDScript — most sharply the
**single-responsibility principle**, supported by cohesion, DRY, and command/query separation;
the remaining SOLID principles (open/closed, Liskov substitution, interface segregation,
dependency inversion) are the background grounding the same rules serve. Cohesion is a property
of the **whole tree**, not of one class in isolation: apply the *same* decomposition pattern
everywhere so a contributor recognises one shape in every subsystem.

7.1 **One statable responsibility per file (file-level SRP).** A `.gd` file should have a single
reason to change. *Test:* describe the file or class in about 25 words with no "and", "if", "or"
or "but"; if you can't, it is a decomposition candidate. *Rationale: a file you can't spec in a sentence is one
a reader can't hold in their head.*

7.2 **Orchestrator + SRP-children is the standard decomposition.** When a subsystem outgrows one
responsibility, split it into a thin **orchestrator** that constructs, wires, and sequences,
plus a set of single-responsibility **child** modules it composes. The orchestrator owns
lifecycle and delegation, **not** domain logic. *Rationale: one shape for every god-file fix, so
the reader learns it once.*

7.3 **When to split — guidance, not a hard line.** Any one of these is a smell; the combination
is decisive: (a) more than one statable responsibility (7.1); (b) the section banners are really
separating *distinct* responsibilities, not chunks of one; (c) the file mixes editor-only and
runtime-reachable code (the static-graph split in
[§8.2](#82-editorruntime-split-by-the-static-dependency-graph-not-runtime-branches) forces a split anyway). **Size is
a secondary signal only** — a long *cohesive* file (one large command module that does one
thing) is fine, and size alone never forces a split. *Responsibility count, not line count, is
the metric.* Size does trigger a check: a reviewer writes the one-sentence responsibility of each
non-test file over 500 lines that a change touches; a sentence that needs "and" marks it as a
decomposition candidate. There is no hard line ceiling and no function-length limit.

7.4 **DRY — extract one helper for any shape or decision built ≥ 2×.** If the same dict shape,
validation, or branch logic appears in two or more places, extract a single helper and call it
from each site. *Rationale: a duplicated shape is a latent contract that drifts; one builder both
removes the duplication and enforces the invariant in one place.* **Rule of three:** incidental
similarity *expected to diverge* is not duplication — prefer a little repetition over the wrong
abstraction. Extract when the shapes are the *same fact*, not merely look-alikes. **A fix covers
every site with the same defect**, and logic duplicated across those sites moves into one class
they all call. *Rationale: the copies drift, and the one a fix misses keeps the bug.*

```
# ✗ two command handlers each fit a value to a property's declared type
# ✓ one fitter class fits the value; both handlers call it
```

7.5 **Command/Query separation (CQS).** A function or tool either **changes state** or **returns
data**, not both. *Rationale: a read folded into a mutating verb hides the read from callers and
the routing layer.* Extract a read action smuggled inside a mutating verb into its own dedicated
read tool.

7.6 **Decomposed children inherit the editor/runtime discipline.** Splitting a runtime-reachable
file must **not** introduce an editor-only symbol into the runtime preload closure
([§8.2](#82-editorruntime-split-by-the-static-dependency-graph-not-runtime-branches)). Every extracted child of a
runtime-reachable module stays export-clean. *Decomposition is a refactor — it cannot quietly
re-taint the static graph.*

7.7 **Uniformity, with documented exceptions.** Apply this section consistently so every
subsystem reads the same way. Deviations are allowed case-by-case but must be **deliberate and
documented** — an inline comment at the site, or a noted exception in this standard (the same
mechanism 1.1 / 2.1 / 3.4 use).

7.8 **Folder topology is the decomposition made visible — main actor at the domain-folder root,
sub-actors in subdomain child folders.** Group the addon tree into **bounded-context domain
folders**; inside each, the **orchestrator sits at the folder root** and the **sub-actors it
composes live in child folders, divided by subdomain.** This is the on-disk shape of the 7.2
split — a reader opens one folder and finds the orchestrator beside the collaborators it wires,
so a boundary that is invisible in a flat root becomes self-evident. A decomposition's children
are **born in the right folder**, not created flat and relocated later. *(Cross-refs 1.1
file/folder naming and 1.5.6 "folder carries domain".)*

7.9 **Shared code lives with the domain that owns the fact it decides.** A function two or more
modules need goes in the module whose domain owns that decision (a path rule beside the file
guard, a version rule beside the version utility), is reached through the preload aggregator
([§6.3](#6-preloads-class_name-and-the-preload-aggregator)), and is a `static func` on a
runtime-clean leaf whenever a runtime-reachable file needs it (7.6). It never goes in a generic
`*Helpers` grab-bag: a helper that only one group of modules shares goes in a named module in
that group's folder, or in a new domain file. A group's private collaborators sit in the group's
folder from their first commit (7.8). When the owner already computes the fact, it exposes the
fact as an accessor, and callers ask for it instead of rebuilding it from the owner's lower-level
output ([example](code-standards-examples/7.9-ask-the-owner-for-its-fact.md)). *Rationale: a
shared rule has one place to look, and a grab-bag hides it while growing without bound.*

7.10 **Pure leaves depend on nothing impure; dependencies point toward them.** A pure leaf
(`static func` over values, with no engine lookup, I/O or state) preloads only pure leaves, and
lookup code may preload a pure leaf but never the reverse. *Rationale: a rule that fetches its own
data cannot be tested with plain values.*
[Example](code-standards-examples/7.10-pure-leaf-direction.md).

7.11 **Stateful collaborators are built by the composition root and passed in.** A stateful
collaborator that serves more than its builder is built only by the composition root or its sole
orchestrator (7.2) and passed in, never self-built, defaulted or looked up. *Rationale: one place
shows the object graph, and two copies of one state disagree silently.* Existing cases are listed
in [B2](#b2-module-taxonomy-the-on-disk-decomposition) and do not grow.
[Example](code-standards-examples/7.11-inject-stateful-collaborators.md).

7.12 **Type a collaborator with its class.** A parameter or field that always holds one script's
instance is typed with that script, unless that breaks 6.6, 8.2 or 6.1 or changes a signature an
extension sees. *Rationale: a wrong argument becomes a parse error.* Existing loose cases are
listed in [B2](#b2-module-taxonomy-the-on-disk-decomposition) and do not grow.
[Example](code-standards-examples/7.12-type-collaborators.md).

7.13 **No new global access paths.** Do not add an autoload, a static holder of another module's
instance or shared state, or a tree, group or meta lookup to reach a collaborator; pass it in
(7.11). *Rationale: a global hides who depends on what.* Existing holders are listed in
[B2](#b2-module-taxonomy-the-on-disk-decomposition) and do not grow.
[Example](code-standards-examples/7.13-no-new-global-access.md).

---

## 8. Godot editor-plugin hard gates

This is the load-bearing section. Each rule here is driven by a concrete engine bug, an
export-template failure mode, a multi-version API gap, or a security boundary at an OS sink; they are non-negotiable for an `@tool`
addon and **override [§1](#1-file-folder-and-symbol-naming)–[§7](#7-design-solid-cohesion-and-decomposition)
on conflict.**

### 8.1 Universal `@tool`

**Every addon script begins with `@tool`** — helpers, command modules, and the runtime autoload
included. Without `@tool` the editor treats the script as empty, so a preloaded helper silently
no-ops.

### 8.2 Editor/runtime split by the STATIC DEPENDENCY GRAPH (not runtime branches)

A runtime-shipped script (the autoload **and everything it `preload`s**, transitively) must name
**zero** editor-only classes (`EditorInterface`, `EditorPlugin`, `EditorFileSystem`, …).
*Rationale: GDScript resolves identifiers at **parse time**, before any
`Engine.is_editor_hint()` / `OS.has_feature("editor")` runtime guard executes. Naming an editor
class — or `preload`ing a script that does — **parse-fails** the script in an export template
where it ships unstripped (`godotengine/godot#91713`, unfixed across 4.2–4.6). Runtime guards
gate **behavior**, not **parsing**.*

- Adding a `preload` of the editor-tainted aggregator (or of any script that statically names
  `EditorInterface`/`EditorPlugin`) to the runtime autoload, or to any script it pulls in, taints
  the whole closure.
- **Review test:** trace the autoload's full preload closure; if any node in that graph
  references an editor-only symbol, it is a defect. Behavior guards
  (`if Engine.is_editor_hint(): return`) are still required *inside* the autoload to stop it
  *running* in the editor — but they are not a substitute for keeping the **graph** clean.

The "silent-if-shipped" norm matches mature addons (Beehave, Dialogue Manager).

### 8.3 Cross-version compatibility

Target the **oldest supported version (4.2)** and feature-detect upward. Plugins are
**forward-incompatible** (a plugin that calls a 4.5 API won't load in 4.4), so never call a
newer API unconditionally.

- **Dynamic dispatch for version-gated methods:** prefer `obj.has_method("foo")` +
  `obj.call("foo", …)` over a direct call when the method is absent in some supported version.
  (Examples: `EditorInterface.close_scene` is 4.5+; `get_editor_toaster` is 4.4+.)
- **Don't form a `Callable` from a bare static-method reference.** On Godot **4.2 only**, the
  compiler binds a bare member-function reference to `SELF`; inside a `static` function `SELF` is
  `NIL`, so the call silently aborts (`Invalid get index '<method>' (on base: 'Nil')`) and returns a
  typed-default value **with no error propagated** — a silent wrong result on 4.2, correct on 4.3+.
  Fixed upstream between 4.2 and 4.5 (`gdscript_compiler.cpp` SELF→CLASS for static members).
  **Instead:** pass the resolved value directly (e.g. the `Node`), or inject an instance method.
  Guarded by a headless 4.2 unit test.
- **Typed `Dictionary[K, V]` is 4.4+ only** — do not use it; use plain `Dictionary`
  ([§4.3](#4-static-typing)). Typed `Array[...]` is fine (4.0+).
- **Centralize version comparisons** in one version-utility module (an `is_at_least` /
  `is_at_most` / `is_version_in_range` set) rather than hand-rolling string compares at each
  call site.
- **Warn, don't block, on untested-newer engines** — push a warning above the latest tested
  version but run anyway.

### 8.4 No `OS.delay_msec()` / `OS.delay_usec()` in command handlers

These **block the editor main thread** — UI, rendering, and input all freeze for the duration.
Use `await Engine.get_main_loop().create_timer(seconds).timeout` instead; it yields control back
to the engine so the editor stays responsive. *The dispatch system `await`s every handler, so
coroutine handlers work transparently.* **Exemption:** low-level infrastructure where
millisecond blocking is intentional and off the command-handler path (e.g. a file-lock retry).

### 8.5 EditorPlugin lifecycle and teardown symmetry

- **`_enter_tree()` registers; `_exit_tree()` unregisters in reverse order.** Every `add_*` has
  a matching `remove_*` — leaked registrations error on the next editor launch.
- **Autoload registration goes in `_enable_plugin()` / `_disable_plugin()`**, not
  `_enter_tree()` — those fire on plugin *toggle*, not on every editor start, so the autoload
  entry isn't re-added each launch.
- **Free owned scenes/controls you instantiated.** Removing a control from a dock does **not**
  free it.
- **Disconnect signals explicitly in teardown.** Editor singletons
  (`EditorFileSystem.filesystem_changed`, `ProjectSettings.settings_changed`) outlive the plugin
  instance; an undisconnected callback becomes a zombie. Check `is_connected` then `disconnect`.
- **GDScript 2.0 signal syntax only:** `sig.connect(callable)`, never the 3.x
  `connect("sig", self, "method")` string form (it silently fails in 4.x).

### 8.6 Plugin teardown frees with `free()`, not `queue_free()`

In `_exit_tree`, free owned objects with **immediate `free()`** so their script / preload
reference chains release **before** ObjectDB's exit-time leak check runs. `queue_free()` defers
deletion to *after* that check, producing spurious "resources still in use at exit" errors. Clear
the command registry first to break the `Callable → GDScript` chains. **Caveat:** `RefCounted`
subsystems (export plugin, debugger hook, watchers) are **not** freed at all — just null the
reference after the matching `remove_*`; they collect when the last ref drops. *This deviates
from generic `queue_free()` advice — the editor-exit leak check is the reason.*

### 8.7 Discard + recreate a `TCPServer` after a failed `listen()`

A `TCPServer` instance that failed to bind **latches `ERR_ALREADY_IN_USE`** if you retry
`listen()` on the same instance. On any bind failure, call `stop()` and null the reference, then
create a fresh `TCPServer` for the next attempt. *Reusing the latched instance never recovers; a
fresh instance does.*

### 8.8 Heavy editor I/O is deferred and frame-throttled

Polling the TCP/WebSocket listener runs via `call_deferred` (out of the `_process` call stack)
and only every Nth frame, to dodge a documented engine reentrancy race between plugin `_process`
work and FileSystem-dock-triggered main-loop work (`godotengine/godot#46893`, `#54864`,
`#110891`). *Rule: don't move listener/scene I/O back inline into `_process`; it reproduces
editor crashes.* Included here so a reviewer doesn't "simplify" it away.

### 8.9 Check the `send_text` return — oversized WebSocket frames drop wholesale

A `WebSocketPeer.send_text()` frame larger than the peer's `outbound_buffer_size` is **rejected
whole** (`ERR_OUT_OF_MEMORY`, no chunking) — stable 4.2–4.5. An unchecked send therefore drops an
oversized response **silently**: the client sees a hung or closed request, not an error. Check
the `Error` return on every response send, and size-guard the payload at **one central
choke-point** in the send/dispatch path so an over-budget response becomes an actionable error
(a `RESPONSE_TOO_LARGE` code plus a "narrow the query / paginate / raise the buffer" hint) instead
of a silent hang. The same return check applies to fire-and-forget notification sends — at minimum
`push_warning` on a dropped frame so it is visible. *A silent wholesale drop is the hardest
transport failure to diagnose.*

### 8.10 Custom ProjectSettings / EditorSettings

- **After registering a setting, call `set_as_basic(key, true)`** so it shows without the
  "Advanced Settings" toggle (custom settings are hidden by default).
- **Register with `add_property_info` + `set_initial_value`** for a typed, inspector-friendly
  entry; guard creation with `has_setting` so re-runs don't clobber user values.
- **Machine-personal preferences go in `EditorSettings`, not `ProjectSettings`.** A per-user /
  per-machine choice (battery, CPU) must never be committed to `project.godot` /
  VCS — register it under `EditorInterface.get_editor_settings()`.
- **Watch `config/name` for `user://` path shifts.** If the addon stores state under `user://`,
  a project rename orphans it and can flood the console; re-derive paths on change.
- **Never put a setting's user-facing description in `hint_string` under
  `PROPERTY_HINT_NONE`.** The inspector never shows it. The description goes in the docs and
  the dock; a string setting's example value goes in `hint_string` under
  `PROPERTY_HINT_PLACEHOLDER_TEXT`.
- **Unregister settings on uninstall — never on reload.** Scrub custom `ProjectSettings` keys in
  `_disable_plugin` (the uninstall path), **not** in `_exit_tree` (which fires on every reload,
  where the user's config must survive). Null them by **prefix-scanning** the live property list
  for the addon's namespace rather than nulling a hardcoded key list — a scan stays correct as
  keys come and go. Machine-wide `EditorSettings` are shared by every project, so **prompt before
  erasing** them.

### 8.11 `static func` utility modules

- **Stateless helpers are `static func` on a `RefCounted` script**, called without instantiation
  through the preload const. *No lifecycle, no allocation, no instance to thread through — pure
  functions namespaced by their script.*
- **Command modules expose a single `static func register(registry, server)` entry point** that
  adds the module's commands to the registry as Callables. *Uniform, data-driven registration;
  one place sees the full command surface.*

### 8.12 Asset-Library shipping hygiene

- **`plugin.cfg` carries only the documented fields** (`name`, `description`, `author`,
  `version`, `script`). Godot reads no others; version compatibility is declared in the Asset
  Library form, not here.
- **The plugin-id folder name is frozen after first release** — user data references the path.
- **Shipped addon files must be self-contained.** Files under the shipped addon folder must not
  reference paths that don't ship (design docs, ADRs, deep-dive analyses). Those live *outside*
  the shipped tree and may reference each other freely.
- **Ship the Godot-4 sidecar metadata — never strip or git-ignore `.uid` / `.import`.** Godot
  4.4+ `.uid` files (and the 4.x `.import` files for imported assets) carry each resource's stable
  `uid://` identity. They are **project state, not generated output**, and for a *distributed*
  addon they must travel **with** the addon — otherwise `uid://` references into it break when a
  user updates the addon in an existing project. Keep them git-tracked, never delete them in a
  release/build script, and never `export-ignore` them, so **every** channel ships byte-identical
  sidecars. *(Pre-4.4 editors ignore `.uid` harmlessly — safe across the whole 4.2+ floor.)*

### 8.13 Validate a data-derived URL's scheme before `OS.shell_open`

A URL that originates from untrusted or remote-fetched data (a downloaded catalog, a
maintainer-supplied link, any `res://` an adversary could rewrite) must have its scheme validated
against an allowlist (`http` / `https`) before it is passed to `OS.shell_open` or any OS handoff. An
attacker-controlled scheme (`file:`, `javascript:`, a custom handler) reaching an OS sink is an
input-validation boundary breach — reject, don't open, anything outside the allowlist. *Rationale:
the OS handler, not the editor, decides what a non-`http` scheme does; the allowlist keeps an
untrusted link from steering it.*

---

## 9. Unit-test code

These rules govern the headless unit suite: the test scripts, their fixtures, and the runner. The
general rules the scope paragraph names (naming, formatting, typing, comments, DRY) apply to test
code in full; this section adds what is specific to tests. **The rules bind the tests a change
adds or edits:** a new test file, a new test group, or an existing group whose inputs, assertions,
or label the change alters. A group the change leaves alone keeps its shape until a change touches
it, and bringing untouched tests in line is its own test-only change. A file-level rule (the
file's module, its header, its entry-point signature) binds a new file only. In an edited group,
the rules bind the lines the change adds or alters; the group's other assertions keep their
inputs, values, and labels.

9.1 **A unit drives one module through its interface.** A test file calls the module the way its
callers do (its public and `static` functions, the signals it emits, the dictionaries it returns)
and asserts on what comes back. A test touches a `_`-prefixed member only to call an engine
callback the headless runner does not drive (`_process`, `_physics_process`) or to seed or reset
state no public path reaches headless, with an inline comment that says so. *Rationale: a test
that reaches past the interface breaks on every refactor and proves nothing about what callers
get.*

9.2 **One test file per source module, named after it** (`<module>_tests.gd`). A test of a seam
between modules goes in a file named for the seam, whose header names the modules it covers. A
module's cases live in one file. *Rationale: a reader finds a module's tests from the module's
name.*

9.3 **Tests move with the code, unaltered.** When a function moves to another module, its cases
move to that module's test file in the same change with the same inputs, expected values, and
labels. Changing what a moved case asserts is a separate change. *Rationale: a case left behind
misleads the next reader about where the behaviour lives, and an unaltered move is easy to verify
in the diff.*

9.4 **No new duplicate pins.** An input and its expected result are asserted in one place in the
suite. Before adding a case, search the suite for the same call and label, and extend the existing
case if one already pins it. A duplicate that already exists is reported in the change's
description and left in place: retiring an existing assertion is the maintainers' decision, made
test by test. *Rationale: two copies drift apart, and after the next change one of them is wrong.*

9.5 **Every new case is seen to fail once.** A bug fix adds the case that reproduces the bug and
runs it red before the fix. A case for new behaviour fails before the behaviour exists. A case
that pins behaviour already in place passes on its first run, so its author breaks the pinned code
once on purpose (flips a branch, changes a constant), watches the case fail, and restores the
code. The change's description names the red run or the deliberate break. *Rationale: a test that
has never failed may be unable to.*

9.6 **Extracting a class adds tests for it.** When a change moves behaviour out of a class into a
new class that the original then depends on, the change adds a test file for the new class that
drives its interface (9.1, 9.2). The original's tests stay as they are; any the new file makes
redundant are listed in the change's description for the maintainers to retire (9.4). *Rationale:
the extraction creates a new contract, and an untested contract is the first to break.*

9.7 **Expected values are written down, not computed.** An expected value is a literal taken from
the contract, the engine's documented behaviour, or a hand calculation. It never comes from the
code under test, from a copy of its algorithm, or from pasting what a run printed. *Rationale: an
expected value derived from the code passes by construction, including when the code is wrong.*

9.8 **One behaviour per test group, and every assertion says what it checks.** A group (the span
from one `begin` to the next) pins one behaviour and holds at least one assertion. Each
assertion's label states the behaviour in the contract's words (the state, the action, the
result), not the mechanism. *Rationale: a failure line should read as a sentence about the
contract.*

9.9 **Edges and error paths are tested.** A limit, cap, page size, or version floor is asserted at
the limit and one step past it. A function with a documented error result has at least one
assertion on that result. An expected engine error may be muted with
`Engine.print_error_messages = false` around the one call that raises it, and is restored to its
previous value before the next assertion. *Rationale: off-by-one and unhandled-error bugs live at
the edges, which a suite of happy paths never reaches.*

9.10 **A case cleans up before it asserts.** A case builds its own fixtures and frees every `Node`
it creates. It restores every `ProjectSettings` key, `InputMap` entry, environment variable,
`user://` file, and static field it changes before its first assertion: GDScript has no
`try/finally`, and a runtime error in an assertion's expression ends the function before any later
cleanup runs. Temp paths carry the process id. A case reads no state another case left.
*Rationale: the suite runs in one process with nothing to reset it between cases, so a leak in one
case fails a later one.*

9.11 **Time and randomness are controlled.** A case advances time itself: it awaits a counted
number of frames, or calls the object's `_process(delta)` with a fixed delta. A wait on a signal
or a condition has a frame or time cap and fails with a label naming what never happened. A case
that uses randomness seeds it first. A wall-clock delay appears only when the delay is the
scenario (a thread holding a lock while another waits), with a comment. *Rationale: a sleep is
slow on a fast machine and flaky on a slow one.*

9.12 **A signal is checked by count, order, and arguments.** A test of a signal records each
emission and asserts how many fired, in what order, with what arguments. *Rationale: the usual
signal bug is a wrong argument or one emission too many, which "it fired" never catches.*

9.13 **Collaborators are real; stand-ins sit at a real boundary.** In-process collaborators and
engine objects are used for real: a real `Node` tree, real `ProjectSettings` (restored per 9.10).
A hand-written stand-in replaces only what the headless runner cannot provide: another process,
the network, a live editor. An assertion checks what the module did with a stand-in's answer,
never the answer itself. *Rationale: a stand-in for your own code makes the test check the
stand-in.*

9.14 **The unit suite runs headless.** A unit test needs no editor, display, or network beyond
loopback; a `127.0.0.1` listener the case opens and closes is allowed. A module method that cannot
run headless is covered by another suite (smoke or integration), and the module's test file names
that suite in its header or beside the group that skips the method. *Rationale: a coverage gap
with no pointer is invisible.*

9.15 **Tests are never weakened quietly.** A change that lowers the suite's assertion count, or a
file's count other than by an unaltered move (9.3), comments out or disables a group, returns
before a group's assertions, or loosens an expected value has the maintainers' agreement in
review, and its description says which assertions changed and why. *Rationale: a green run with
fewer checks looks the same as a full one, so the drop has to be visible.*

9.16 **Test comments follow §5, with a short header.** A test file's `##` header states, in at
most six lines, what the file pins and through which interface. It carries no change history ("was
relaxed", "extracted so", "written green"), no list of files it mirrors, and no claim stronger
than its assertions make. Group names and assertion labels carry no history either. *Rationale: a
header is read by someone who never saw the history, which belongs in the commit message.*

9.17 **Test code is fully typed (§4).** That includes loop variables
(`for path: String in paths`), locals filled from a `Variant` source (`get()`,
`JSON.parse_string`, `ProjectSettings.get_setting`), and the assertion-helper parameter of every
test entry point. *Rationale: an untyped value hides the shape the assertion depends on.*

---

# Part II — Project bindings

This part records what is specific to *this* repo: the public namespace, the module taxonomy,
the canonical in-tree exemplars, and the contract bindings. Part I's rules are the law; this part
is where they touch concrete files. Paths are relative to the toolkit repo root.

## B1. The `MCPToolkit*` public namespace and the nine public classes

Per [§6.2](#6-preloads-class_name-and-the-preload-aggregator), `class_name` is reserved for the
public extension API and shared value types. This repo registers **exactly nine**, all
`MCPToolkit`-prefixed to avoid colliding with user code. Each file's `snake_case` name matches
the snake_case of its `class_name` ([§1.1](#1-file-folder-and-symbol-naming)) — the
`mcp_toolkit_*` filename and the `MCPToolkit*` class are deliberately the same words. Everything
else is preload-only.

| `class_name` | File |
|---|---|
| `MCPToolkitCommandRegistry` | `addons/godot_mcp_toolkit/transport/mcp_toolkit_command_registry.gd` |
| `MCPToolkitCommandOptions` | `addons/godot_mcp_toolkit/contract/mcp_toolkit_command_options.gd` |
| `MCPToolkitError` | `addons/godot_mcp_toolkit/contract/mcp_toolkit_error.gd` |
| `MCPToolkitSuccess` | `addons/godot_mcp_toolkit/contract/mcp_toolkit_success.gd` |
| `MCPToolkitToolContext` | `addons/godot_mcp_toolkit/contract/mcp_toolkit_tool_context.gd` |
| `MCPToolkitSafeSceneOps` | `addons/godot_mcp_toolkit/scene/mcp_toolkit_safe_scene_ops.gd` |
| `MCPToolkitUndoRedoAction` | `addons/godot_mcp_toolkit/scene/mcp_toolkit_undo_redo_action.gd` |
| `MCPToolkitExtension` | `addons/godot_mcp_toolkit/extensions/mcp_toolkit_extension.gd` |
| `MCPToolkitExtensionOptions` | `addons/godot_mcp_toolkit/extensions/mcp_toolkit_extension_options.gd` |

These nine classes are the project's **canonical examples** of the public-API doc standard
([§5.11.5](#511-the-gdscript--godot-doc-comment-layer)): every public member carries a `##` doc
comment, depth scaling with the member.

**Naming specifics that bind [§1.5](#15-names-are-intent-revealing-unambiguous-and-spelled-out):**

- `MCP`, `LSP`, `UID` are the established initialisms tied to the documented public surface
  (1.5.1); a private internal `rpc`/`mgr`/`ctx` is not.
- "Registry" is reserved for two established stores: `MCPToolkitCommandRegistry` (the dispatch
  table) and the machine-wide project/instance store under `registry/` (1.5.3). Introduce no
  third "Registry".
- "bridge" denotes the **server** (the TypeScript MCP bridge) across the two repos; an
  editor-side `EditorDebuggerPlugin` is a *session-tracker* / *hook*, not a "bridge" (1.5.5).
- The preload aggregator ([§6.3](#6-preloads-class_name-and-the-preload-aggregator)) is
  `addons/godot_mcp_toolkit/core/modules.gd`, aliased `Modules` by every consumer
  (`const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")`, e.g. the
  `Modules` const in `plugin.gd`). Members are read as `Modules.FileGuard`, `Modules.VersionUtils`,
  `Modules.EditorAccess`, etc.

## B2. Module taxonomy (the on-disk decomposition)

The addon follows the folder topology of [§7.8](#7-design-solid-cohesion-and-decomposition): a
bounded-context domain folder per subsystem, the orchestrator at the folder root, sub-actors in
subdomain child folders. The addon root holds only the entry point, `plugin.gd`.

| Domain folder | Orchestrator / root | Subdomain children |
|---|---|---|
| `transport/` | `mcp_server.gd` | `transport/dispatch/` (`dispatch_lane`, `mutation_watchdog`, `server_request_router`); also `ws_transport.gd`, `notifier.gd`, `debug_bridge.gd`, `builtin_command_registration.gd` |
| `registry/` | `registry_client.gd` | `registry/store/` (`file_lock`, `registry_entry_file`, `registry_paths`, `registry_projection`) |
| `extensions/` | `extension_loader.gd` | `extensions/services/` (`extension_discovery`, `extension_meta_commands`, `extension_support`, `extension_watcher`) |
| `commands/` | the per-domain command modules | `commands/{editor,input_map,playtest,tileset}/` |
| `ui/dock/` | `dock.gd` | `ui/dock/{ext,limits,mcp,security,status,update}/` |
| `contract/` | the value types + `coerce.gd` | — |
| `core/` | `plugin_composer.gd`, `modules.gd` (the aggregator) | `editor_access.gd`, `settings_registration.gd`, `tool_menu.gd`, `disable_cleanup_coordinator.gd`, `export_strip.gd`, `playtest_end_detector.gd`, `unfocused_*.gd` |
| `scene/` | `scene_lease.gd` + the public scene types | `undo_redo_helpers.gd`, `signal_pair_resolver.gd` |
| `security/` | — | `audit`, `auth`, `file_guard`, `scrubber`, `untrusted` |
| `paths/` | `project_paths.gd` | `project_key`, `user_path_monitor`, `lsp_publisher` |
| `logging/` | — | `log_buffer`, `log_helpers` |
| `versioning/` | `mcp_version_utils.gd` | `engine_setting_names`, `nodejs_check`, `stale_instance_hint`, `update_check`, `update_check_runner` |
| `runtime/` | `mcp_runtime_server.gd` (the runtime autoload) | — |

`plugin.gd` is a thin orchestrator: lifecycle (`_enter_tree`/`_exit_tree`/`_enable_plugin`/
`_disable_plugin`) delegating composition to `core/plugin_composer.gd`.

**Where shared code goes ([§7.9](#7-design-solid-cohesion-and-decomposition)).** A path rule
lives in `security/file_guard.gd`, a version rule in `versioning/`, a script-reload rule in
`core/`, each reached as a `Modules` member. `commands/editor_helpers.gd` takes nothing new: a
helper that only command handlers share goes in a named module under `commands/<group>/` or in a
new domain file, and a command group's private collaborators sit in `commands/<group>/` from
their first commit.

**Composition ([§7.11](#7-design-solid-cohesion-and-decomposition)–7.13).** The composition root is
`core/plugin_composer.gd` (`compose()`, torn down by `Handle.dispose()`); `plugin.gd` injects only
itself (`EditorAccess.set_plugin`). The runtime autoload `runtime/mcp_runtime_server.gd` is the
runtime's own root. Orchestrators that build children only they use: `transport/mcp_server.gd`,
`transport/dispatch/server_request_router.gd`, `ui/dock/dock.gd`,
`ui/toolkit_dialog_presenter.gd`. Command modules keep `register(registry, server: Node)` (B3).
The existing cases each rule lists, which do not grow:

- **7.11:** `commands/playtest_log_reader.gd` builds its own stand-in `DebugSessionTracker` until
  one is injected and after it is cleared.
- **7.12:** in `core/plugin_composer.gd`'s `Handle`, `_extension_watcher: RefCounted` and the
  untyped `_user_path_monitor`; `transport/mcp_server.gd`'s `bind_user_path_monitor(monitor:
  RefCounted)`.
- **7.13:** `EditorAccess`'s plugin, `LogBuffer`'s store, `ResponseLimits`' env overrides, and the
  playtest log reader's tracker.

## B3. Contract bindings

- The dispatch **contract** value types live under `contract/` —
  `MCPToolkitError`/`MCPToolkitSuccess`/`MCPToolkitToolContext`/`MCPToolkitCommandOptions`
  plus the shared `contract/coerce.gd` coercion path.
- Command modules expose the
  [§8.11](#811-static-func-utility-modules) entry point:
  `static func register(registry: MCPToolkitCommandRegistry, server: Node) -> void` (e.g.
  `register()` in `commands/asset_commands.gd` and `commands/folder_commands.gd`), invoked from the composer so
  one place sees the full command surface.
- Per [§5.10](#510-relocating-stripped-rationale), this repo's decision records live in
  `docs/adr/` (not shipped; the next ADR number is `max(existing) + 1`); the narrative trail for
  a stripped comment relocates to the commit message or an ADR.
- *Optional companions:* a tool/term reference (`docs/dev/contract.md`) and a glossary
  (`docs/dev/glossary.md`) accompany this standard when present — align public names and contract
  shapes to them.

## B4. Canonical exemplars

The in-tree examples a reviewer or contributor jumps to. Each one names a file and a symbol;
line numbers drift, so none are given.

**Comments / docs ([§5](#5-comments-and-documentation)).** The nine public classes (B1) are the
exemplary public-API docs. `commands/editor_helpers.gd` documents dict-shaped return contracts on
its cross-module `static func` helpers (5.11.3). `contract/mcp_toolkit_command_options.gd`
(`with_min_godot_version`) shows the brief / blank-`##` / detail shape with `[param]` prose
(5.11.6–5.11.7).

**Preload aggregator ([§6](#6-preloads-class_name-and-the-preload-aggregator)).**
`core/modules.gd` (its `const Name := preload(...)` set); the cycle-avoidance `NOTE` in the header
of `commands/editor_helpers.gd` ("preloaded by `core/modules.gd`, so it CANNOT import
`core/modules.gd`").

**Cohesion ([§7](#7-design-solid-cohesion-and-decomposition)).** `plugin.gd` (orchestrator) +
`core/plugin_composer.gd` (composition); `transport/mcp_server.gd` (orchestrator) +
`transport/dispatch/`; the folder topology table in B2 is the worked example of 7.8.

**`@tool` universality ([§8.1](#81-universal-tool)).** Every addon `.gd` file begins with
`@tool`.

**Editor/runtime static split ([§8.2](#82-editorruntime-split-by-the-static-dependency-graph-not-runtime-branches)).**
`runtime/mcp_runtime_server.gd`, its runtime dependency-closure `const` block: the runtime
autoload preloads only export-clean scripts (for example `contract/coerce`,
`security/{untrusted,auth,scrubber}`, `logging/{log_helpers,log_buffer}`,
`registry/registry_client`, `transport/{notifier,ws_transport}`, `scene/signal_pair_resolver`)
and **deliberately not** `core/modules.gd` (which statically names `EditorInterface`/
`EditorPlugin`), with the `godot#91713` rationale inline.

**Cross-version gating ([§8.3](#83-cross-version-compatibility)).** Version comparisons centralize
in `versioning/mcp_version_utils.gd` (`is_at_least()`, `is_at_most()`, `is_version_in_range()`).
`has_method` gates: `EditorInterface.has_method("close_scene")` (4.5+) in
`commands/editor_helpers.gd` (`close_scene_tab_safe()`) and `commands/folder_commands.gd`
(`_cmd_folder_delete()`); `has_method("get_editor_toaster")` (4.4+) in `core/editor_access.gd`
(`get_toaster()`); `has_method("get_command_palette")` in `core/tool_menu.gd` (`install()` and
`uninstall()`). The warn-don't-block check is in `plugin.gd`'s `_enter_tree()`
(`VersionUtils.GODOT_TESTED_MAX_VERSION`).

**No `OS.delay_*` in handlers ([§8.4](#84-no-osdelay_msec--osdelay_usec-in-command-handlers)).**
`commands/editor_helpers.gd` uses `await Engine.get_main_loop().create_timer(...).timeout` (e.g.
`ensure_file_indexed()`, `ensure_file_removed()`).

**Lifecycle + `free()` teardown ([§8.5](#85-editorplugin-lifecycle-and-teardown-symmetry),
[§8.6](#86-plugin-teardown-frees-with-free-not-queue_free)).** `plugin.gd` registers in
`_enter_tree()` and reverses in `_exit_tree()`; autoload via `_enable_plugin()` /
`_disable_plugin()`. The composer's teardown, `Handle.dispose()` in `core/plugin_composer.gd`,
frees owned objects with `free()` (`_dock.free()`, `_server.free()`) and nulls RefCounted
subsystems after their `remove_*` (`_export_plugin`).

**TCPServer discard ([§8.7](#87-discard--recreate-a-tcpserver-after-a-failed-listen)).**
`transport/ws_transport.gd`: `_pin_listen()` and `_note_listen_failure()` drop a server that
failed to bind (`stop()` + null) so the next attempt builds a fresh one, and
`shutdown_listener()` does `stop()` + null on shutdown. The runtime server builds its own
`WsTransport`, so it takes the same path.

**Deferred + throttled I/O ([§8.8](#88-heavy-editor-io-is-deferred-and-frame-throttled)).**
`transport/mcp_server.gd`: the comment above `_POLL_FRAME_INTERVAL` (the
`godot#46893`/`#54864`/`#110891` rationale, `_POLL_FRAME_INTERVAL := 4`) and the throttle check in
`_process()`.

**`send_text` return + central size guard ([§8.9](#89-check-the-send_text-return--oversized-websocket-frames-drop-wholesale)).**
`transport/notifier.gd`: `send_result()` routes every response through
`MCPToolkitError.guard_response_size(...)` (the central choke-point), then checks the `send_text`
return; `send_notification()` and `broadcast()` check theirs too.

**Custom settings ([§8.10](#810-custom-projectsettings--editorsettings)).**
`_register_setting()` in `core/settings_registration.gd` guards with `has_setting`, then calls
`set_initial_value`, `set_as_basic(...)` and `add_property_info`.

---

## B5. Paginating tools — the shared `Pagination` envelope

Any tool that caps or pages its result **builds the response through
`Modules.Pagination`** (`contract/pagination.gd`) — never a hand-rolled envelope.
The class owns the contract so every consumer shares it (ADR 0020).

**Invariants — always present:** `has_more` (bool), `total_<unit>` (exact,
walk-all), `returned` (this page's size). Never `truncated` (→ `has_more`) or a
returned-size `count` (→ `returned`); a non-paginating `count` beside no total is
fine and stays.

**Resume mechanism — pick one:**
- *Resumable* → a linear resume field (`next_offset` for index/byte, `next_start_line`
  for line), emitted only when `has_more`, plus a `hint`.
- *Cursor-less* (walk not linearly resumable) → **no** resume field; document the
  in-tool navigation axis (`path_prefix`+filters, or `region`+`bounds`) in the
  `hint`. The integer resume field is a "resume field", not a "cursor".

**Families → builder method:** `list_page` (LIST), `byte_page` (CONTENT-byte),
`line_page` (CONTENT-line); spatial tools are LIST-shaped with `bounds` in `extras`
and no resume field. The generic `build()` is for a one-off shape — a third repeat
graduates into a family method.

**Clamp, don't reject:** a caller window param over the tool's per-tool max is
clamped and disclosed (`limit_clamped: true` in `extras` + a clamp clause the class
appends to `hint`); `≤ 0`/non-int is rejected. `hint` is present iff `has_more`
**or** a clamp occurred.

**No per-emitter marker comment.** The `Modules.Pagination.<family>()` call is the
discoverable contract (greppable); a comment pointing at this doc from a shipped
`addons/` file violates §8.12. The class's own header docstring is self-contained.

---

## B6. The unit suite

Where [§9](#9-unit-test-code) touches this repo's files.

- **The runner.** `test/run_unit_tests.gd` is the headless entry point
  (`godot --headless --script test/run_unit_tests.gd`) and a thin orchestrator: it builds one
  `testing` object (`test/units/testing.gd`) and calls each unit's entry point. The units live in
  `test/units/`, one file per unit, each a `RefCounted` script with
  `static func run(testing) -> void` (a unit that awaits frames takes the runner's tree as a
  second parameter, `run(testing, tree: SceneTree)`). A new unit is one `<module>_tests.gd` (9.2)
  and types the parameter as `testing: Testing`, with
  `const Testing := preload("res://test/units/testing.gd")` for the type (9.17). Test cases live
  in a unit, not in the runner.
- **Registration is part of the change.** The runner has no auto-discovery. A new unit is
  preloaded and called in `run_unit_tests.gd` in the same change, and the change's run shows the
  `=== ALL N PASSED ===` total grown by the assertions it added; a green banner whose total did
  not move means the new cases never ran. A unit whose `run` awaits is called with `await` in the
  runner.
- **Assertions go through `testing`.** `testing.begin(name)` opens a group,
  `testing.ok(value, label)` and `testing.eq(actual, expected, label)` record assertions, and
  `report()` prints the banner and returns the failure count, which the runner turns into the exit
  code. A check that only prints is not an assertion.
- **Exemplars.** Restore before asserting (9.10): `test/units/input_map_tests.gd`, whose cases
  take a `_snapshot_setting` and call `_restore_setting` before the first `testing.eq` (for
  example `_test_bind_builtin_keeps_saved_events`). A seeded private static with its reason (9.1)
  and a named covering suite for an editor-coupled method (9.14): `test/units/scene_ops_tests.gd`
  (the `_save_results` seed and its comment, and the comment on `queue_save`).

---

## Appendix — condensed review checklist

Run over **any changed `.gd` file**. The **general** rows apply to every file (addon, `test/`,
tooling). The **plugin** rows apply to **addon** files only — test scripts are exempt from those
*only* because they are not an addon.

**General — naming & structure**

- [ ] Filename `snake_case`; any new `class_name` is `MCPToolkit`-prefixed and justified, else preload-only ([§1](#1-file-folder-and-symbol-naming), [§6](#6-preloads-class_name-and-the-preload-aggregator))
- [ ] Identifiers: PascalCase types, snake_case funcs/vars, CONSTANT_CASE consts, `_`-prefix for private ([§1.2](#1-file-folder-and-symbol-naming))
- [ ] Names intent-revealing, spelled-out, disambiguated; signals past-tense / event-natural; no call with two or more positional booleans ([§1.4](#1-file-folder-and-symbol-naming), [§1.5](#15-names-are-intent-revealing-unambiguous-and-spelled-out))
- [ ] Members in canonical declaration order; inner classes last unless type-before-use forces earlier ([§2](#2-mandatory-declaration-order))

**General — formatting, typing, comments**

- [ ] Tabs; 2-level arg / 1-level collection continuation; one statement per line; two blank lines between funcs; trailing commas; `and`/`or`/`not`; double quotes ([§3](#3-formatting))
- [ ] Every func has typed params + return type; `:=` when obvious, explicit type for dynamic/`Variant`/`get()`/`call()`; no typed `Dictionary[K,V]`; no `as` for validation; handlers validate every input before the first mutation; a documented outcome dict is read at every call site or the site says why not ([§4](#4-static-typing))
- [ ] Comments carry *why* / contract / hazard, not *what*; no process history, author tags, or caller rosters; load-bearing public refs kept as intent + constraint ([§5.1](#51-core-principle--intent-the-why-never-history)–[§5.6](#56-anti-patterns-delete-on-sight))
- [ ] `##` class docstring after `extends`; cross-module helpers document return shape; brief / blank-`##` / detail; `[param]` + "Returns …" prose; BBCode floored to 4.2 (plain `[codeblock]`, no 4.3+ tags); bare `@deprecated`/`@experimental` ([§5.11](#511-the-gdscript--godot-doc-comment-layer))
- [ ] TODO/FIXME actionable + tracked; no secrets, internal-only URLs/paths; SPDX header not per-file blurb ([§5.7](#57-todo--fixme-and-friends), [§5.8](#58-open-source-hygiene-comments-are-public))
- [ ] No dict shape / validation / decision logic duplicated ≥ 2× — extract one helper (rule of three); a fix covers every site with the same defect ([§7.4](#7-design-solid-cohesion-and-decomposition))

**Unit tests (`test/` files only)**

- [ ] A new or moved case sits in its module's `<module>_tests.gd` (or a seam file whose header names its modules), registered in the runner, and the run's total grew; moved cases are unaltered; a `_` member is touched only to call an undriven engine callback or to seed or reset state, with a comment ([§9.1](#9-unit-test-code)–[§9.3](#9-unit-test-code), [B6](#b6-the-unit-suite))
- [ ] No new duplicate input/expected pin; an existing duplicate is reported, not deleted; no assertion dropped, group disabled, or expected value loosened without the maintainers' agreement ([§9.4](#9-unit-test-code), [§9.15](#9-unit-test-code))
- [ ] Each new case was seen red once (a fix's case before the fix; a pin by a deliberate break) and the description says how; an extraction ships a test file for the new class and lists the pins it makes redundant ([§9.5](#9-unit-test-code), [§9.6](#9-unit-test-code))
- [ ] Expected values are literals from the contract; one behaviour per group; labels state the behaviour; limits tested at and past the edge; documented error results asserted; signals checked by count, order, and arguments ([§9.7](#9-unit-test-code)–[§9.9](#9-unit-test-code), [§9.12](#9-unit-test-code))
- [ ] Nodes freed; settings, `InputMap`, env, `user://` files, and statics restored before the first assertion; no sleeps, every wait capped, randomness seeded; stand-ins only at a real boundary; non-headless methods name their covering suite ([§9.10](#9-unit-test-code), [§9.11](#9-unit-test-code), [§9.13](#9-unit-test-code), [§9.14](#9-unit-test-code))
- [ ] Header at most six lines of intent, with no history, roster, or overclaim; labels free of history; loop variables, `Variant`-sourced locals, and the `testing` parameter typed ([§9.16](#9-unit-test-code), [§9.17](#9-unit-test-code))

**Plugin (addon files only)**

- [ ] File has **one** statable responsibility (no "and"); over-broad files use orchestrator + SRP-children; children born in the right folder; commands vs queries separated; a touched non-test file over 500 lines has its one-sentence responsibility written; a shared function sits in the domain module that owns its fact, never a `*Helpers` grab-bag; a fact the owner computes is read through its accessor ([§7.1](#7-design-solid-cohesion-and-decomposition)–[§7.9](#7-design-solid-cohesion-and-decomposition))
- [ ] A pure leaf preloads only pure leaves; lookup code may depend on rule code, never the reverse ([§7.10](#7-design-solid-cohesion-and-decomposition))
- [ ] Shared stateful collaborators built only in the composition root or their sole orchestrator, injected, never self-built or defaulted ([§7.11](#7-design-solid-cohesion-and-decomposition))
- [ ] Collaborator params/fields typed with their script when reachable without a cycle, taint or new `class_name`; extension-visible signatures unchanged ([§7.12](#7-design-solid-cohesion-and-decomposition))
- [ ] No new autoload, static holder of an instance or shared state, or tree/group/meta lookup for a collaborator ([§7.13](#7-design-solid-cohesion-and-decomposition))
- [ ] Internal scripts via `preload` const through the aggregator; no `class_name` leakage; no aggregator cycle; no preload cycle of any length (6.6); stateless helpers `static func`; command modules expose `register(registry, server)` ([§6](#6-preloads-class_name-and-the-preload-aggregator), [§8.11](#811-static-func-utility-modules))
- [ ] Every `add_*` has a reverse-order `remove_*`; autoload via `_enable/_disable_plugin`; owned controls freed; signals disconnected; GDScript-2.0 connect syntax; custom settings guarded + `set_as_basic` + scrubbed on uninstall (prefix-scan, prompt before erasing machine-wide), no description in `hint_string` under `PROPERTY_HINT_NONE` ([§8.5](#85-editorplugin-lifecycle-and-teardown-symmetry), [§8.10](#810-custom-projectsettings--editorsettings))
- [ ] `@tool` on the file; if runtime-shipped, zero editor-only class names anywhere in its preload graph ([§8.1](#81-universal-tool), [§8.2](#82-editorruntime-split-by-the-static-dependency-graph-not-runtime-branches))
- [ ] Version-gated calls use `has_method()` + `call()`; no `Callable` formed from a bare static-method reference (4.2 binds it to a NIL `self` → silent abort + typed-default return); compares go through the version utility; teardown frees with `free()` (RefCounted subsystems just null'd); failed `TCPServer.listen()` → `stop()` + null + fresh instance; listener/scene I/O stays deferred + throttled; response sends check `send_text` + central size-guard ([§8.3](#83-cross-version-compatibility)–[§8.9](#89-check-the-send_text-return--oversized-websocket-frames-drop-wholesale))
- [ ] `plugin.cfg` only the documented fields; folder id unchanged; shipped files reference no unshipped paths; `.uid`/`.import` sidecars shipped, never stripped or git-ignored ([§8.12](#812-asset-library-shipping-hygiene))
- [ ] Any `OS.shell_open` / OS handoff of a data-derived URL allowlists the scheme (http/https) ([§8.13](#813-validate-a-data-derived-urls-scheme-before-osshell_open))

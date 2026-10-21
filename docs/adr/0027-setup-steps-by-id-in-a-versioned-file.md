# 0027 — Setup steps keyed by id, recorded when left, in a versioned file

**Status:** Accepted

**Date:** 2026-10-19

## Context

The 1.0 setup wizard had three steps, numbered by position. Finishing or closing it
wrote `user://addons/godot_mcp_toolkit/mcp_onboarding_shown_v001` with the content
`1`, and a second file saved the step index so a restart could resume. Every 1.0.x
release kept those three steps, so a `1` meant "saw the 1.0 wizard".

The 1.1 toolkit adds steps, among them one that explains the update check, and the
check must not run until the user has seen it. A user who set up with 1.0 has to
see the new steps and only those. Later releases will add more, and some will
replace a step whose meaning changed. Whatever the toolkit records sits on users'
machines and has to read correctly in newer and older toolkits.

## Decision

**Each setup step has a stable id, the toolkit records the ids the user has seen in
the old flag file as a versioned JSON object, and a step counts as seen once the
user leaves it.**

- **Ids, not positions or a version string.** The steps are `welcome`, `mcp_json`,
  `optional_steps`, `updates` and `dock` (`core/setup_steps.gd`). A new id can go
  anywhere in the table. A step reworded in place keeps its id and is not shown
  again; a step that changes enough to need showing again gets a new id, which also
  lets code ask whether the old one was seen.
- **Seen means left.** Next, Done or a button that moves on records the step. ×
  records the open step and the run's optional steps not reached yet. "Remind me
  later", on the step a run opens on, records nothing, so the run comes back at the
  next editor start. Recording a step when it is displayed would record the step
  behind a "Remind me later".
- **Required steps come back.** A step is required when skipping it costs the user
  something: `welcome` (what the toolkit can do to the project), `mcp_json` (without
  it the client cannot find the toolkit) and `updates` (the update check waits for
  it). Required steps show at every editor start until seen, whatever the
  machine-wide `mcp_toolkit/setup_wizard/show_optional_steps` setting says. That
  setting hides only optional steps.
- **The file keeps its name.** Its content becomes
  `{"format": 1, "seen": ["welcome", ...]}`, written in one `store_string`.
  `format` goes up only for a breaking change. New fields are added under the same
  number, and every rewrite keeps the top-level keys and step ids it does not know.
- **Reading never fails, and never prints.** The tracker
  (`core/setup_step_tracker.gd`) parses with a `JSON` instance, which reports bad
  input through its return value instead of the console.
  - The content `1` reads as the 1.0 steps: `welcome`, `mcp_json`, `dock`.
  - A supported `format` reads `seen`, keeping only ids that match `^[a-z0-9_]+$`.
  - A newer `format` reads `seen` while it is still a list of strings, and counts
    every step as seen when it is not. The file is never written.
  - An empty, corrupt, unreadable or oversized file (over 64 KiB) reads as the 1.0
    steps, and the next record rewrites it in the current format.
  - With no file, the 1.0 progress file counts its steps before the saved index as
    seen. The first record folds them into the file and deletes the progress file,
    which nothing writes any more.
- **A rename carries the seen steps.** When the project's `user://` path moves, the
  toolkit records at the new path the steps its last read or write found seen at the
  old one, unknown ids included. Steps not seen there stay unseen at the new path.

## Considered and rejected

- **Step indexes.** Inserting a step shifts every later index, so a stored index
  stops meaning one step.
- **A "finished on version X" string.** It needs a table of which steps each version
  added, and that table drifts. It also cannot record a step skipped with
  "Remind me later" or a required step left unseen.
- **One id per line, with no version.** It cannot add a field later without a
  reader guessing what the new lines mean.

## Consequences

- **Downgrades stay quiet.** A 1.0.x build checks only that the file exists, so it
  treats the wizard as done. A toolkit that meets a newer `format` reads what it
  can, shows at most the steps it knows are unseen, and leaves the file alone.
- **A corrupt file costs at most two steps.** Falling back to the 1.0 steps shows
  `optional_steps` and `updates` again and rewrites the file. It never re-runs the
  whole wizard for someone who already set up.
- **A step's meaning is tied to its id.** Rewording a required step does not make
  it show again. A change users must see needs a new id, and the old id stays in
  their file.
- **The update check waits for the wizard.** An editor that never shows the wizard,
  such as a headless CI editor, never checks for updates.

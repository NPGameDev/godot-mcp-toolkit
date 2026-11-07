@tool
extends RefCounted
## The setup wizard's steps: their ids, their order, which are required, and the run
## planner that picks the steps one wizard run shows.
##
## A step is known by a stable id, never by its position, so a later toolkit can
## insert a step anywhere in the table. A step reworded in place keeps its id and is
## not shown again to users who have seen it; a step that changes enough to need
## showing again gets a new id.[br]
## [br]
## A required step is one the user loses something by skipping, so it comes back at
## every editor start until it has been seen. The other steps are optional: the
## machine-wide [constant SHOW_OPTIONAL_STEPS_SETTING] hides the optional steps a
## later toolkit adds.[br]
## [br]
## Each step also carries its [enum ClosePolicy]: what closing the wizard with ×
## does to it.

## What closing the wizard with × does to a step: the step open at the time, or an
## optional step the run has not reached.
enum ClosePolicy {
	## Count the step as seen.
	MARK_SEEN,
	## Leave the step unseen, as if the run had not reached it. For a step whose
	## choice the user must make: a closed dialog is not an answer.
	KEEP_UNSEEN,
}

const WELCOME := &"welcome"
const MCP_JSON := &"mcp_json"
const OPTIONAL_STEPS := &"optional_steps"
const UPDATES := &"updates"
const UPDATE_INSTALL := &"update_install"
const DOCK := &"dock"

## The EditorSettings key (bool, default [code]true[/code]) that shows the optional
## steps a toolkit update adds. Machine-wide: it applies to every project on this
## machine, and required steps show whatever its value.
const SHOW_OPTIONAL_STEPS_SETTING := "mcp_toolkit/setup_wizard/show_optional_steps"

# The table, in display order: [id, required, close policy].
const _TABLE := [
	[WELCOME, true, ClosePolicy.MARK_SEEN],
	[MCP_JSON, true, ClosePolicy.MARK_SEEN],
	[OPTIONAL_STEPS, false, ClosePolicy.MARK_SEEN],
	[UPDATES, true, ClosePolicy.MARK_SEEN],
	# The install mode gates what the toolkit may install, so × must not stand in
	# for the user's choice.
	[UPDATE_INSTALL, true, ClosePolicy.KEEP_UNSEEN],
	[DOCK, false, ClosePolicy.MARK_SEEN],
]


## Every step id, in display order.
static func all_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for row in _TABLE:
		ids.append(row[0])
	return ids


## Whether the step [param step_id] is required. Returns [code]false[/code] for an id
## the table does not hold.
static func is_required(step_id: StringName) -> bool:
	for row in _TABLE:
		if row[0] == step_id:
			return bool(row[1])
	return false


## What closing the wizard with × does to the step [param step_id]. Returns
## [constant ClosePolicy.MARK_SEEN] for an id the table does not hold.
static func close_policy(step_id: StringName) -> ClosePolicy:
	for row in _TABLE:
		if row[0] == step_id:
			var policy: ClosePolicy = row[2]
			return policy
	return ClosePolicy.MARK_SEEN


## Whether [param editor_settings] shows the optional steps. Returns its
## [constant SHOW_OPTIONAL_STEPS_SETTING] value, or [code]true[/code] when the key is
## missing or [param editor_settings] is [code]null[/code]. [param editor_settings]
## is [EditorSettings] or a stand-in with [code]has_setting[/code] and
## [code]get_setting[/code].
static func shows_optional_steps(editor_settings: Object) -> bool:
	if editor_settings == null or not editor_settings.has_setting(SHOW_OPTIONAL_STEPS_SETTING):
		return true
	return bool(editor_settings.get_setting(SHOW_OPTIONAL_STEPS_SETTING))


## The steps one wizard run shows, in display order; empty when no run is due.
## [param unseen] holds the ids not seen yet and [param anything_seen] whether any
## step has been seen. [param show_optional] is the
## [constant SHOW_OPTIONAL_STEPS_SETTING] value, [param editor_start] whether the
## plugin loaded with the editor rather than by a mid-session enable, and
## [param button_run] whether the user asked for the wizard.[br]
## [br]
## A button run and a first run show every step, the first run even on a
## mid-session enable. Otherwise only an editor start shows anything: the unseen
## steps, without the optional ones when [param show_optional] is off. A
## mid-session enable shows nothing, since the user is busy with something else
## then.
static func plan_run(
		unseen: Array[StringName], anything_seen: bool, show_optional: bool,
		editor_start: bool, button_run: bool) -> Array[StringName]:
	if button_run or not anything_seen:
		return all_ids()
	var run: Array[StringName] = []
	if not editor_start:
		return run
	for step_id in all_ids():
		if unseen.has(step_id) and (show_optional or is_required(step_id)):
			run.append(step_id)
	return run


## The steps of the run the dock footer's Setup Wizard button starts: every step,
## seen or not. It goes through [method plan_run] so one planner decides every run.
static func plan_button_run() -> Array[StringName]:
	var no_unseen: Array[StringName] = []
	return plan_run(no_unseen, true, true, false, true)


## The steps that closing a run with × records as seen: the step [param index] of
## [param run] that was open, and every optional step of the run not in
## [param visited], leaving out each step whose [method close_policy] is
## [constant ClosePolicy.KEEP_UNSEEN]. Required steps the user never reached stay
## unseen too, so they come back at the next editor start.
static func seen_on_close(
		run: Array[StringName], index: int, visited: Array[StringName]) -> Array[StringName]:
	var closed: Array[StringName] = []
	if index >= 0 and index < run.size():
		closed.append(run[index])
	for step_id in run:
		if not visited.has(step_id) and not is_required(step_id) and not closed.has(step_id):
			closed.append(step_id)
	var seen: Array[StringName] = []
	for step_id in closed:
		if close_policy(step_id) == ClosePolicy.MARK_SEEN:
			seen.append(step_id)
	return seen

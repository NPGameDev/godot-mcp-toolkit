@tool
extends Node
## Drives one [code]stage_stepper.gd[/code] run from the main loop, one step a frame.
##
## It processes only while a run is going, so an editor that installs nothing pays nothing
## for it.

## Emitted on a later frame than [method start], once the run has ended, with the shape
## [method StageStepper.advance] returns. A run that [method cancel] stopped never emits it.
signal finished(outcome: Dictionary)

# Direct preload, not core/modules.gd: the aggregator preloads the installer,
# which reaches this file.
const StageStepper := preload("res://addons/godot_mcp_toolkit/self_update/stage_stepper.gd")

var _stepper: StageStepper = null
var _budget_ms: int = StageStepper.BUDGET_MS


## [param budget_ms] is what each frame's step may spend. A budget of 0 writes one file a
## frame, which lets a test watch the run.
func _init(budget_ms: int = StageStepper.BUDGET_MS) -> void:
	_budget_ms = budget_ms


# The engine turns processing on when a script overrides _process, just before _ready.
func _ready() -> void:
	set_process(_stepper != null)


func _process(_delta: float) -> void:
	var outcome := _stepper.advance(_budget_ms)
	if str(outcome["state"]) == StageStepper.RUNNING:
		return
	set_process(false)
	_stepper = null
	finished.emit(outcome)


## Starts staging the release [param version] from the zip in [param update_folder]. Whatever
## the first step finds, [signal finished] says so on a later frame, so the caller's state is
## settled by then.
func start(version: String, update_folder: String) -> void:
	_stepper = StageStepper.new()
	_stepper.begin(version, update_folder)
	set_process(true)


## Stops a run that is going and deletes what it wrote. Returns whether no part of it is
## left; [code]true[/code] when no run was going.
func cancel() -> bool:
	set_process(false)
	if _stepper == null:
		return true
	var gone := _stepper.cancel()
	_stepper = null
	return gone

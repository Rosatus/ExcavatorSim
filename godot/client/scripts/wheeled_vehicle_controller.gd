class_name WheeledVehicleController
extends Node
## Add under an existing RigidBody3D. Never writes the parent pose.
## Disable keyboard_input when driven by a machine/session input adapter.
@export var parameters: Dictionary = {}
@export var wheel_stations: Array[Dictionary] = []
@export var wheel_animator_path := NodePath("../WheelVisualAnimator")
@export var keyboard_input := false
@export_flags_3d_physics var terrain_collision_mask := 1
var locomotion := WheeledLocomotionState.new()
var _race_locomotion := RaceWheeledLocomotionState.new()
var race_mode := false
var input_enabled := true
var neutral_armed := false
var _focused := true
var _body: RigidBody3D
var _animator: WheelVisualAnimator
var _command := Vector4.ZERO

func _ready() -> void:
	ensure_input_actions()
	_body = get_parent() as RigidBody3D
	_animator = get_node_or_null(wheel_animator_path) as WheelVisualAnimator
	if _body == null or not _configure_locomotion():
		push_error("Invalid wheeled vehicle: " + _active_solver().last_error)
		set_physics_process(false)

func _active_solver() -> WheeledLocomotionState:
	return _race_locomotion if race_mode else locomotion

func _configure_locomotion() -> bool:
	if not race_mode:
		return locomotion.configure(parameters, wheel_stations)
	var overlay := RaceModeProfile.overlay_for("", "wheeled")
	var base := WheeledLocomotionState.DEFAULTS.duplicate(true)
	for key in parameters:
		base[key] = parameters[key]
	var effective := RaceModeProfile.apply_overlay(base, overlay.get("params", {}))
	return _race_locomotion.configure_race(effective, wheel_stations, overlay.get("assist", {}))

func set_race_mode(value: bool) -> void:
	if race_mode == value:
		return
	race_mode = value
	neutral_armed = false
	_command = Vector4.ZERO
	if _body != null and not _configure_locomotion():
		push_error("Invalid race wheeled vehicle: " + _race_locomotion.last_error)
		race_mode = false
		locomotion.configure(parameters, wheel_stations)
	locomotion.reset()
	_race_locomotion.reset()

func set_commands(throttle: float, brake: float, steer: float, drift := 0.0) -> void:
	_command = Vector4(throttle, brake, steer, drift) if Vector4(throttle, brake, steer, drift).is_finite() else Vector4(0, 1, 0, 0)

func set_enabled(value: bool) -> void:
	input_enabled = value
	if not value:
		neutral_armed = false
		_command = Vector4.ZERO

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_focused = false
		neutral_armed = false
		_command = Vector4.ZERO
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_focused = true

func _physics_process(delta: float) -> void:
	var command := _command
	if keyboard_input:
		command = read_machine_input()
	if not input_enabled or not _focused:
		neutral_armed = false
	elif Vector3(command.x, command.y, command.z).is_zero_approx():
		neutral_armed = true
	if not neutral_armed:
		command = Vector4(0, 1, 0, 0)
	var solver := _active_solver()
	solver.set_commands(command.x, command.y, command.z)
	solver.set_drift(command.w)
	var snapshot := solver.step(_body, delta, terrain_collision_mask)
	if _animator != null:
		_animator.apply_physics_snapshot(snapshot)

func get_status_snapshot() -> Dictionary:
	var result := _active_solver().get_status_snapshot()
	result["neutral_armed"] = neutral_armed
	result["race_mode"] = race_mode
	return result

## Call after the owning scene resets/teleports its body, including model switches.
func reset_motion() -> void:
	neutral_armed = false
	_command = Vector4.ZERO
	_active_solver().reset()
	if _animator != null:
		_animator.reset_animation()

## Independent wheel actions keep keyboard steering separate from tracked travel.
## Product and standalone demo share G/V/B/N. Gamepad travel remains LT/LB, RT/RB.
const INPUT_ACTIONS := {
	"wheel_forward": {"key": KEY_G, "axis": JOY_AXIS_TRIGGER_LEFT},
	"wheel_reverse": {"key": KEY_B, "button": JOY_BUTTON_LEFT_SHOULDER},
	"wheel_right": {"key": KEY_N, "axis": JOY_AXIS_TRIGGER_RIGHT},
	"wheel_left": {"key": KEY_V, "button": JOY_BUTTON_RIGHT_SHOULDER},
	"wheel_drift": {"key": KEY_SHIFT, "button": JOY_BUTTON_A},
}

static func ensure_input_actions() -> void:
	for action in INPUT_ACTIONS:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, 0.08)
		var definition: Dictionary = INPUT_ACTIONS[action]
		var key := InputEventKey.new()
		key.physical_keycode = definition.key
		InputMap.action_add_event(action, key)
		if definition.has("axis"):
			var axis := InputEventJoypadMotion.new()
			axis.axis = definition.axis
			axis.axis_value = 1.0
			InputMap.action_add_event(action, axis)
		else:
			var button := InputEventJoypadButton.new()
			button.button_index = definition.button
			InputMap.action_add_event(action, button)

static func read_machine_input() -> Vector4:
	return Vector4(
		Input.get_action_strength("wheel_forward") - Input.get_action_strength("wheel_reverse"),
		float(Input.is_physical_key_pressed(KEY_SPACE)),
		Input.get_action_strength("wheel_right") - Input.get_action_strength("wheel_left"),
		Input.get_action_strength("wheel_drift")
	)

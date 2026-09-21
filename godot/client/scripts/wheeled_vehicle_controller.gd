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
var input_enabled := true
var neutral_armed := false
var _focused := true
var _body: RigidBody3D
var _animator: WheelVisualAnimator
var _command := Vector3.ZERO

func _ready() -> void:
	ensure_input_actions()
	_body = get_parent() as RigidBody3D
	_animator = get_node_or_null(wheel_animator_path) as WheelVisualAnimator
	if _body == null or not locomotion.configure(parameters, wheel_stations):
		push_error("Invalid wheeled vehicle: " + locomotion.last_error)
		set_physics_process(false)

func set_commands(throttle: float, brake: float, steer: float) -> void:
	_command = Vector3(throttle, brake, steer) if Vector3(throttle, brake, steer).is_finite() else Vector3(0, 1, 0)

func set_enabled(value: bool) -> void:
	input_enabled = value
	if not value:
		neutral_armed = false
		_command = Vector3.ZERO

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_focused = false
		neutral_armed = false
		_command = Vector3.ZERO
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_focused = true

func _physics_process(delta: float) -> void:
	var command := _command
	if keyboard_input:
		command = read_machine_input()
	if not input_enabled or not _focused:
		neutral_armed = false
	elif command.is_zero_approx():
		neutral_armed = true
	if not neutral_armed:
		command = Vector3(0, 1, 0)
	locomotion.set_commands(command.x, command.y, command.z)
	var snapshot := locomotion.step(_body, delta, terrain_collision_mask)
	if _animator != null:
		_animator.apply_physics_snapshot(snapshot)

func get_status_snapshot() -> Dictionary:
	var result := locomotion.get_status_snapshot()
	result["neutral_armed"] = neutral_armed
	return result

## Call after the owning scene resets/teleports its body, including model switches.
func reset_motion() -> void:
	neutral_armed = false
	_command = Vector3.ZERO
	locomotion.reset()
	if _animator != null:
		_animator.reset_animation()

## Independent wheel actions keep keyboard steering separate from tracked travel.
## Product and standalone demo share G/V/B/N. Gamepad travel remains LT/LB, RT/RB.
const INPUT_ACTIONS := {
	"wheel_forward": {"key": KEY_G, "axis": JOY_AXIS_TRIGGER_LEFT},
	"wheel_reverse": {"key": KEY_B, "button": JOY_BUTTON_LEFT_SHOULDER},
	"wheel_right": {"key": KEY_N, "axis": JOY_AXIS_TRIGGER_RIGHT},
	"wheel_left": {"key": KEY_V, "button": JOY_BUTTON_RIGHT_SHOULDER},
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

static func read_machine_input() -> Vector3:
	return Vector3(
		Input.get_action_strength("wheel_forward") - Input.get_action_strength("wheel_reverse"),
		float(Input.is_physical_key_pressed(KEY_SPACE)),
		Input.get_action_strength("wheel_right") - Input.get_action_strength("wheel_left")
	)

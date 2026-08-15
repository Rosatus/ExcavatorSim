class_name TrackedLocomotionState
extends RefCounted

## Deterministic local skid-steer state. The controller owns input and scene wiring;
## this class owns only bounded motion integration and terrain support fitting.

const REQUIRED_FIELDS: Array[String] = [
	"track_gauge_m",
	"contact_length_m",
	"contact_width_m",
	"support_front_offset_m",
	"support_rear_offset_m",
	"support_left_offset_m",
	"support_right_offset_m",
	"max_speed_mps",
	"acceleration_mps2",
	"service_brake_mps2",
	"coast_drag_mps2",
	"pivot_scale",
	"max_slope_degrees",
	"slope_slip",
	"turn_slip",
	"minimum_traction",
	"support_response_hz",
]

var configured := false
var chassis_transform := Transform3D.IDENTITY
var left_speed_mps := 0.0
var right_speed_mps := 0.0
var yaw_radians := 0.0
var last_slope_degrees := 0.0
var last_traction := 1.0
var _left_command := 0.0
var _right_command := 0.0
var _support_up := Vector3.UP
var _parameters: Dictionary = {}


func configure(parameters: Dictionary) -> bool:
	if not validate_parameters(parameters):
		configured = false
		_parameters.clear()
		stop_motion()
		return false
	_parameters = parameters.duplicate(true)
	configured = true
	reset()
	return true


func set_commands(left: float, right: float) -> void:
	_left_command = clampf(left, -1.0, 1.0) if is_finite(left) else 0.0
	_right_command = clampf(right, -1.0, 1.0) if is_finite(right) else 0.0


func stop_motion() -> void:
	_left_command = 0.0
	_right_command = 0.0
	left_speed_mps = 0.0
	right_speed_mps = 0.0


func reset() -> void:
	stop_motion()
	chassis_transform = Transform3D.IDENTITY
	yaw_radians = 0.0
	last_slope_degrees = 0.0
	last_traction = 1.0
	_support_up = Vector3.UP


func step_fixed(delta: float, height_sampler: Callable) -> bool:
	if not configured or delta <= 0.0 or not is_finite(delta) or not height_sampler.is_valid():
		return false

	var current_support := _sample_support(chassis_transform.origin, yaw_radians, height_sampler)
	if not bool(current_support.get("valid", false)):
		stop_motion()
		return false

	var target_left := _left_command * float(_parameters["max_speed_mps"])
	var target_right := _right_command * float(_parameters["max_speed_mps"])
	left_speed_mps = _approach_track_speed(left_speed_mps, target_left, delta)
	right_speed_mps = _approach_track_speed(right_speed_mps, target_right, delta)

	var slope_radians := float(current_support["slope_radians"])
	var maximum_slope := deg_to_rad(float(_parameters["max_slope_degrees"]))
	var slope_ratio := clampf(slope_radians / maximum_slope, 0.0, 2.0)
	var turn_demand := absf(right_speed_mps - left_speed_mps) / maxf(
		2.0 * float(_parameters["max_speed_mps"]), 0.001
	)
	last_traction = clampf(
		1.0
		- float(_parameters["slope_slip"]) * slope_ratio * slope_ratio
		- float(_parameters["turn_slip"]) * turn_demand,
		float(_parameters["minimum_traction"]),
		1.0
	)
	last_slope_degrees = rad_to_deg(slope_radians)

	var average_speed := 0.5 * (left_speed_mps + right_speed_mps)
	var yaw_rate := (
		(right_speed_mps - left_speed_mps)
		/ float(_parameters["track_gauge_m"])
		* float(_parameters["pivot_scale"])
		* last_traction
	)
	var next_yaw := wrapf(yaw_radians + yaw_rate * delta, -PI, PI)
	var yaw_basis := Basis(Vector3.UP, next_yaw)
	var forward := -yaw_basis.z
	var next_origin := chassis_transform.origin + forward * average_speed * last_traction * delta

	var next_support := _sample_support(next_origin, next_yaw, height_sampler)
	if not bool(next_support.get("valid", false)):
		stop_motion()
		return false
	if float(next_support["slope_radians"]) > maximum_slope and absf(average_speed) > 0.001:
		left_speed_mps = move_toward(left_speed_mps, 0.0, float(_parameters["service_brake_mps2"]) * delta)
		right_speed_mps = move_toward(right_speed_mps, 0.0, float(_parameters["service_brake_mps2"]) * delta)
		return _apply_support(current_support, yaw_radians, delta)

	yaw_radians = next_yaw
	next_origin.y = float(next_support["height"])
	chassis_transform.origin.x = next_origin.x
	chassis_transform.origin.z = next_origin.z
	return _apply_support(next_support, yaw_radians, delta)


func get_status_snapshot() -> Dictionary:
	return {
		"configured": configured,
		"left_command": _left_command,
		"right_command": _right_command,
		"left_speed_mps": left_speed_mps,
		"right_speed_mps": right_speed_mps,
		"yaw_radians": yaw_radians,
		"slope_degrees": last_slope_degrees,
		"traction": last_traction,
		"transform": chassis_transform,
	}


static func validate_parameters(parameters: Dictionary) -> bool:
	if not parameters.has_all(REQUIRED_FIELDS):
		return false
	for field in REQUIRED_FIELDS:
		var value: Variant = parameters[field]
		if not (value is float or value is int) or not is_finite(float(value)):
			return false
	return (
		float(parameters["track_gauge_m"]) >= 0.5
		and float(parameters["track_gauge_m"]) <= 5.0
		and float(parameters["contact_length_m"]) >= 1.0
		and float(parameters["contact_length_m"]) <= 10.0
		and float(parameters["contact_width_m"]) >= 1.0
		and float(parameters["contact_width_m"]) <= 6.0
		and float(parameters["support_front_offset_m"]) > 0.0
		and float(parameters["support_rear_offset_m"]) > 0.0
		and float(parameters["support_left_offset_m"]) > 0.0
		and float(parameters["support_right_offset_m"]) > 0.0
		and float(parameters["support_front_offset_m"]) <= 0.5 * float(parameters["contact_length_m"])
		and float(parameters["support_rear_offset_m"]) <= 0.5 * float(parameters["contact_length_m"])
		and float(parameters["support_left_offset_m"]) <= 0.5 * float(parameters["contact_width_m"])
		and float(parameters["support_right_offset_m"]) <= 0.5 * float(parameters["contact_width_m"])
		and float(parameters["max_speed_mps"]) > 0.0
		and float(parameters["max_speed_mps"]) <= 5.0
		and float(parameters["acceleration_mps2"]) > 0.0
		and float(parameters["service_brake_mps2"]) > 0.0
		and float(parameters["coast_drag_mps2"]) > 0.0
		and float(parameters["pivot_scale"]) >= 0.1
		and float(parameters["pivot_scale"]) <= 2.0
		and float(parameters["max_slope_degrees"]) >= 1.0
		and float(parameters["max_slope_degrees"]) <= 45.0
		and float(parameters["slope_slip"]) >= 0.0
		and float(parameters["slope_slip"]) <= 1.0
		and float(parameters["turn_slip"]) >= 0.0
		and float(parameters["turn_slip"]) <= 1.0
		and float(parameters["minimum_traction"]) > 0.0
		and float(parameters["minimum_traction"]) <= 1.0
		and float(parameters["support_response_hz"]) > 0.0
		and float(parameters["support_response_hz"]) <= 30.0
	)


func _approach_track_speed(current: float, target: float, delta: float) -> float:
	var command_is_zero := is_zero_approx(target)
	var reversing := not is_zero_approx(current) and not command_is_zero and signf(current) != signf(target)
	var slowing := absf(target) < absf(current)
	var rate := float(_parameters["acceleration_mps2"])
	if command_is_zero:
		rate = float(_parameters["coast_drag_mps2"])
	elif reversing or slowing:
		rate = float(_parameters["service_brake_mps2"])
	return move_toward(current, target, rate * delta)


func _sample_support(origin: Vector3, yaw: float, height_sampler: Callable) -> Dictionary:
	var yaw_basis := Basis(Vector3.UP, yaw)
	var right := yaw_basis.x.normalized()
	var forward := (-yaw_basis.z).normalized()
	var front_offset := float(_parameters["support_front_offset_m"])
	var rear_offset := float(_parameters["support_rear_offset_m"])
	var left_offset := float(_parameters["support_left_offset_m"])
	var right_offset := float(_parameters["support_right_offset_m"])
	var center_xz := Vector2(origin.x, origin.z)
	var offsets := [
		right * -left_offset + forward * front_offset,
		right * right_offset + forward * front_offset,
		right * -left_offset - forward * rear_offset,
		right * right_offset - forward * rear_offset,
	]
	var heights: Array[float] = []
	for offset in offsets:
		var point := center_xz + Vector2((offset as Vector3).x, (offset as Vector3).z)
		var sampled: Variant = height_sampler.call(point)
		if not (sampled is float or sampled is int) or not is_finite(float(sampled)):
			return {"valid": false}
		heights.append(float(sampled))
	var front_height := 0.5 * (heights[0] + heights[1])
	var rear_height := 0.5 * (heights[2] + heights[3])
	var left_height := 0.5 * (heights[0] + heights[2])
	var right_height := 0.5 * (heights[1] + heights[3])
	var right_slope := right * (left_offset + right_offset) + Vector3.UP * (right_height - left_height)
	var forward_slope := forward * (front_offset + rear_offset) + Vector3.UP * (front_height - rear_height)
	var support_up := right_slope.cross(forward_slope).normalized()
	if support_up.y < 0.0:
		support_up = -support_up
	return {
		"valid": support_up.is_finite() and support_up.length_squared() > 0.5,
		"height": 0.25 * (heights[0] + heights[1] + heights[2] + heights[3]),
		"up": support_up,
		"slope_radians": acos(clampf(support_up.dot(Vector3.UP), -1.0, 1.0)),
	}


func _apply_support(support: Dictionary, yaw: float, delta: float) -> bool:
	var target_up: Vector3 = support["up"]
	var weight := 1.0 - exp(-float(_parameters["support_response_hz"]) * delta)
	_support_up = _support_up.lerp(target_up, clampf(weight, 0.0, 1.0)).normalized()
	var yaw_forward := -Basis(Vector3.UP, yaw).z
	var forward := yaw_forward.slide(_support_up).normalized()
	if forward.length_squared() < 0.5:
		forward = yaw_forward
	var right := forward.cross(_support_up).normalized()
	chassis_transform.basis = Basis(right, _support_up, -forward).orthonormalized()
	chassis_transform.origin.y = lerpf(
		chassis_transform.origin.y,
		float(support["height"]),
		clampf(weight, 0.0, 1.0)
	)
	last_slope_degrees = rad_to_deg(float(support["slope_radians"]))
	return true

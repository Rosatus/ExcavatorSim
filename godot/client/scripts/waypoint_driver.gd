class_name WaypointDriver
extends RefCounted

## Fixed-tick guidance only. The existing Jolt runtime remains the sole pose writer.
const ARRIVAL_RADIUS := 0.28
const TRACK_ARRIVAL_RADIUS := 0.03
const TRACK_POSITION_TOLERANCE := 0.05
const TRACK_STOP_SPEED := 0.025
const STOP_SPEED := 0.08
const CRUISE_SPEED := 3.1
const BRAKE_ACCEL := 0.45
const PIVOT_ENTER_RAD := 0.65 # About 37 degrees; retain the existing entry threshold.
const ALIGN_TOLERANCE_RAD := PI / 180.0
const ALIGN_YAW_RATE := 0.035
const ALIGN_SETTLE_S := 0.2
## Identified SY135-class tracked plant (60 Hz headless): belt speed responds
## with tau ~0.1 s and neutral braking stops 3 m/s within 0.4 s; counter-
## rotating belts deliver only ~0.55-0.8 of ideal kinematic yaw because of
## lateral slip. Profiles below use deliberately conservative fractions of
## those limits and compensate the response lag instead of crawling.
const TRACK_DECEL := 2.5
const TRACK_LAG_S := 0.2
const TRACK_TAIL_GAIN := 2.0
const PIVOT_MAX_RATE := 1.2
const PIVOT_ACCEL := 3.0
const PIVOT_LAG_S := 0.15
const PIVOT_TAIL_GAIN := 4.5
## Nominal yaw-slip feedforward; the integrator absorbs terrain variation.
const PIVOT_SLIP_GAIN := 0.6
const PIVOT_RATE_KI := 6.0
const PIVOT_TRIM_LIMIT := 0.6

var state := "idle"
var reason := ""
var points := PackedVector3Array()
var index := 0
var segment_start := Vector3.ZERO
var distance_m := 0.0
var cross_track_m := 0.0
var completed_points := 0
var wheeled := false
var reverse := false
var belt_speed := 3.1
var track_width := 2.0
var wheelbase := 2.6
var max_steer := deg_to_rad(32.0)
var _epoch := ""
var _last_tick := -1
var _stale_s := 0.0
var _unsupported_s := 0.0
var _no_progress_s := 0.0
var _best_distance := INF
var _stable_s := 0.0
var _arm_s := 0.0
var _segment_s := 0.0
var _best_heading_error := INF
var _align_stall_s := 0.0
var _aligned_s := 0.0
var _yaw_trim := 0.0


func is_active() -> bool:
	return state in ["arming", "aligning", "driving", "braking"]


func start(route: PackedVector3Array, snapshot: Dictionary, parameters: Dictionary = {}) -> bool:
	if route.is_empty() or route.size() > 256 or not _valid_snapshot(snapshot):
		return false
	for point in route:
		if not point.is_finite():
			return false
	var next_wheeled := String(snapshot.get("locomotion_mode", "tracked")) == "wheeled"
	var next_belt := float(parameters.get("max_belt_speed_m_s", 3.1))
	var next_gauge := float(parameters.get("gauge_m", 2.0))
	var next_wheelbase := float(parameters.get("wheelbase_m", 2.6))
	var next_steer := deg_to_rad(float(parameters.get("max_steer_degrees", 32.0)))
	if not is_finite(next_belt) or next_belt <= 0 or not is_finite(next_gauge) or next_gauge <= 0 or not is_finite(next_wheelbase) or next_wheelbase <= 0 or not is_finite(next_steer) or next_steer <= 0 or next_steer >= PI * 0.5:
		return false
	if next_wheeled:
		for i in range(1, route.size()):
			if Vector2(route[i].x - route[i - 1].x, route[i].z - route[i - 1].z).length() < next_wheelbase / tan(next_steer) * 2.16:
				return false
	wheeled = next_wheeled
	reverse = bool(parameters.get("reverse", false)) and not wheeled
	belt_speed = next_belt
	track_width = next_gauge
	wheelbase = next_wheelbase
	max_steer = next_steer
	points = route.duplicate()
	index = 0
	completed_points = 0
	segment_start = (snapshot.body_transform as Transform3D).origin
	_epoch = String(snapshot.authority_epoch)
	_last_tick = -1
	reason = ""
	_reset_segment()
	state = "arming"
	return true


func pause(why: String) -> void:
	if is_active():
		state = "paused"
		reason = why


func resume(snapshot: Dictionary) -> bool:
	if state != "paused" or not _valid_snapshot(snapshot) or String(snapshot.authority_epoch) != _epoch:
		return false
	reason = ""
	_reset_segment()
	state = "arming"
	return true


func cancel(why := "cancelled") -> void:
	state = "cancelled"
	reason = why
	points.clear()


func _fail(why: String) -> void:
	state = "failed"
	reason = why


func _reset_segment() -> void:
	_stable_s = 0.0
	_arm_s = 0.0
	_no_progress_s = 0.0
	_best_distance = INF
	_unsupported_s = 0.0
	_stale_s = 0.0
	_segment_s = 0.0
	_best_heading_error = INF
	_align_stall_s = 0.0
	_aligned_s = 0.0
	_yaw_trim = 0.0


func step(delta: float, snapshot: Dictionary) -> Vector3:
	# tracked: x/y = left/right. wheeled: x/y/z = throttle/brake/steer.
	var stopped := Vector3(0, 1, 0) if wheeled else Vector3.ZERO
	if not is_active():
		return stopped
	if not is_finite(delta) or delta <= 0.0:
		_fail("invalid_state")
		return stopped
	_segment_s += delta
	if _segment_s > 120.0:
		_fail("no_progress")
		return stopped
	if not _valid_snapshot(snapshot) or String(snapshot.authority_epoch) != _epoch:
		_fail("invalid_state")
		return stopped
	var tick := int(snapshot.physics_tick)
	if tick <= _last_tick:
		_stale_s += delta
		if _stale_s > 0.25:
			_fail("stale_state")
		return stopped
	_last_tick = tick
	_stale_s = 0.0
	if not bool(snapshot.get("grounded", false)):
		_unsupported_s += delta
		if _unsupported_s > 0.5:
			_fail("unsupported")
		return stopped
	_unsupported_s = 0.0
	if state == "arming":
		# The wheel runtime explicitly requires all-zero commands, including brake.
		_arm_s += delta
		if _arm_s >= 0.1:
			state = "driving" if wheeled else "aligning"
		return Vector3.ZERO
	var position := (snapshot.body_transform as Transform3D).origin
	var p := Vector2(position.x, position.z)
	var target := Vector2(points[index].x, points[index].z)
	var start_xz := Vector2(segment_start.x, segment_start.z)
	var offset := target - p
	distance_m = offset.length()
	var velocity: Vector3 = snapshot.linear_velocity
	var speed := Vector2(velocity.x, velocity.z).length()
	var forward_3d: Vector3 = snapshot.vehicle_forward_world
	var forward := Vector2(forward_3d.x, forward_3d.z).normalized()
	if reverse:
		forward = -forward
	var right := Vector2(-forward.y, forward.x)
	var line := target - start_xz
	var along := clampf((p - start_xz).dot(line) / maxf(line.length_squared(), 0.0001), 0, 1)
	var nearest := start_xz + along * line
	cross_track_m = p.distance_to(nearest)
	if wheeled and index + 1 < points.size() and distance_m < _wheel_lookahead() * 0.96:
		# Intermediate vertices are pass-through corners; Ackermann cannot pivot.
		completed_points += 1
		segment_start = points[index]
		index += 1
		_reset_segment()
		return _wheel_command(snapshot, p, forward, right, speed)
	if distance_m < _best_distance - 0.04:
		_best_distance = distance_m
		_no_progress_s = 0.0
	elif state != "aligning":
		_no_progress_s += delta
	if _no_progress_s > (35.0 if wheeled else 12.0):
		_fail("no_progress")
		return stopped
	var arrival_radius := ARRIVAL_RADIUS if wheeled else TRACK_ARRIVAL_RADIUS
	var stop_speed := STOP_SPEED if wheeled else TRACK_STOP_SPEED
	if distance_m <= arrival_radius:
		state = "braking"
	if state == "braking":
		# Never advance the waypoint after coasting outside the precision window.
		# A missed corner needs an explicit restart, not a pivot beside the edge.
		if not wheeled and distance_m > TRACK_POSITION_TOLERANCE and speed < stop_speed:
			_fail("position_tolerance")
			return stopped
		if distance_m > ARRIVAL_RADIUS + 0.25 and speed < STOP_SPEED:
			state = "driving" if wheeled else "aligning"
			_stable_s = 0.0
			return stopped
		if speed < stop_speed and absf((snapshot.angular_velocity as Vector3).y) < 0.06:
			_stable_s += delta
		else:
			_stable_s = 0.0
		if _stable_s > 0.35:
			completed_points += 1
			if index + 1 == points.size():
				state = "completed"
			else:
				segment_start = points[index]
				index += 1
				_reset_segment()
				state = "driving" if wheeled else "aligning"
		return stopped
	var lookahead := 1.2
	var aim := start_xz + minf(line.length(), along * line.length() + lookahead) * line.normalized()
	var direction := (aim - p).normalized() if distance_m > lookahead else offset.normalized()
	var error := atan2(right.dot(direction), forward.dot(direction))
	var yaw_right := -(snapshot.angular_velocity as Vector3).y
	if not wheeled:
		# Pivot toward the fixed segment bearing, not the lateral lookahead
		# correction. Arrival tolerance can leave us beside the next segment.
		var segment_direction := line.normalized() if line.length_squared() > 0.0001 else offset.normalized()
		var segment_error := atan2(right.dot(segment_direction), forward.dot(segment_direction))
		if state != "aligning" and absf(segment_error) > PIVOT_ENTER_RAD:
			state = "aligning"
			_best_heading_error = INF
			_align_stall_s = 0.0
			_aligned_s = 0.0
		if state == "aligning":
			error = segment_error
			if speed >= STOP_SPEED:
				_aligned_s = 0.0
				return stopped
			if absf(error) <= ALIGN_TOLERANCE_RAD and absf(yaw_right) <= ALIGN_YAW_RATE:
				_aligned_s += delta
			else:
				_aligned_s = 0.0
			if _aligned_s >= ALIGN_SETTLE_S:
				if index > 0 and cross_track_m > TRACK_POSITION_TOLERANCE:
					_fail("position_tolerance")
					return stopped
				state = "driving"
				_no_progress_s = 0.0
				return stopped # Translation starts on the following fixed tick.
			if absf(error) < _best_heading_error - 0.015:
				_best_heading_error = absf(error)
				_align_stall_s = 0.0
			else:
				_align_stall_s += delta
			if _align_stall_s > 8.0:
				_fail("no_progress")
				return stopped
		var omega := 0.0
		if state == "aligning":
			# Time-optimal pivot: brake-to-rest yaw-rate profile with lag
			# compensation, then a measured yaw-rate loop. The old pure P law
			# was capped at 0.8 rad/s request but delivered ~0.45 rad/s after
			# slip and decayed exponentially into the 1 degree window.
			var yaw_rate_target := MotionProfile.approach_rate(error, yaw_right, PIVOT_MAX_RATE, PIVOT_ACCEL, PIVOT_TAIL_GAIN, PIVOT_LAG_S)
			_yaw_trim = clampf(_yaw_trim + PIVOT_RATE_KI * (yaw_rate_target - yaw_right) * delta, -PIVOT_TRIM_LIMIT, PIVOT_TRIM_LIMIT)
			omega = yaw_rate_target / PIVOT_SLIP_GAIN + _yaw_trim
		else:
			omega = clampf(1.8 * error - 0.6 * yaw_right, -0.8, 0.8)
		# Lag-compensated braking envelope to the waypoint with a linear
		# precision tail. Measured closing speed shortens the envelope so the
		# chassis arrives at rest inside the 3 cm window instead of crawling.
		var closing := Vector2(velocity.x, velocity.z).dot(offset.normalized()) if distance_m > 0.0001 else 0.0
		var desired := MotionProfile.approach_rate(distance_m, closing, minf(CRUISE_SPEED, belt_speed), TRACK_DECEL, TRACK_TAIL_GAIN, TRACK_LAG_S)
		desired = maxf(desired, minf(0.03, distance_m))
		var travel := desired * maxf(0, cos(error)) if state == "driving" else 0.0
		var signed_travel := -travel if reverse else travel
		var left := (signed_travel + omega * track_width * 0.5) / belt_speed
		var right_command := (signed_travel - omega * track_width * 0.5) / belt_speed
		return Vector3(clampf(left, -1, 1), clampf(right_command, -1, 1), 0)
	return _wheel_command(snapshot, p, forward, right, speed)


func _wheel_lookahead() -> float:
	return wheelbase / tan(max_steer) * 1.08


func _wheel_command(_snapshot: Dictionary, p: Vector2, forward: Vector2, right: Vector2, speed: float) -> Vector3:
	var a := Vector2(segment_start.x, segment_start.z)
	var b := Vector2(points[index].x, points[index].z)
	var line := b - a
	var length := line.length()
	var projected := clampf((p - a).dot(line.normalized()), 0, length)
	var lookahead := _wheel_lookahead()
	var aim := a + minf(length, projected + lookahead) * line.normalized()
	if projected + lookahead > length and index + 1 < points.size():
		var next := Vector2(points[index + 1].x, points[index + 1].z)
		aim = b.move_toward(next, projected + lookahead - length)
	var offset := aim - p
	var curvature := 2.0 * right.dot(offset) / maxf(offset.length_squared(), 0.2)
	var steer := clampf(atan(wheelbase * curvature) / max_steer, -1, 1)
	var desired := 1.0
	if index == points.size() - 1:
		desired = minf(desired, sqrt(2.0 * BRAKE_ACCEL * maxf(p.distance_to(b) - 0.12, 0)))
	if offset.dot(forward) < -0.5:
		desired = 0.6
	var throttle := clampf(0.16 + 0.8 * (desired - speed), 0.0, 0.7)
	var brake := clampf((speed - desired - 0.1) * 1.5, 0, 1)
	return Vector3(throttle if brake == 0 else 0.0, brake, steer)


func snapshot() -> Dictionary:
	return {"state": state, "reason": reason, "index": index, "count": points.size(),
		"completed_points": completed_points, "distance_m": distance_m,
		"cross_track_m": cross_track_m, "wheeled": wheeled}


static func _valid_snapshot(value: Dictionary) -> bool:
	if not bool(value.get("configured", false)):
		return false
	for key in ["body_transform", "linear_velocity", "angular_velocity", "vehicle_forward_world", "authority_epoch", "physics_tick"]:
		if not value.has(key):
			return false
	return (value.body_transform as Transform3D).is_finite() and (value.linear_velocity as Vector3).is_finite() and (value.angular_velocity as Vector3).is_finite() and (value.vehicle_forward_world as Vector3).is_finite() and (value.vehicle_forward_world as Vector3).length_squared() > 0.5

class_name EquipmentKinematicsContext
extends RefCounted

## Per-tick derived kinematic data shared by every assist stage. The pipeline
## builds it once from the articulation's accepted state so stages never touch
## integrator internals or recompute FK. All vectors are world-space; joint
## rates are rad/s of the logical joint coordinate (same space as commands).

var delta := 0.0
var chassis_transform := Transform3D.IDENTITY
var chassis_linear_velocity := Vector3.ZERO
var chassis_angular_velocity := Vector3.ZERO
var cut_engagement := 0.0
var motion_load_factor := 1.0
var external: Dictionary = {}

var joint_positions: Dictionary = {}
var joint_velocities: Dictionary = {}
var joint_accelerations: Dictionary = {}
var joint_accel_limits: Dictionary = {}
var joint_axis_world: Dictionary = {}
var joint_pivot_world: Dictionary = {}
var joint_ceiling: Dictionary = {}
var joint_limits: Dictionary = {}

var cutting_edge_available := true
var bucket_edge_half_world := Vector3.ZERO
var tool_point_velocity := Vector3.ZERO
var exterior_points: Array[Vector3] = []
var exterior_mount_velocities: Array[Vector3] = []
var bucket_link := Transform3D.IDENTITY
var bucket_ref_world := Vector3.ZERO
var bucket_ref_dir_world := Vector3.FORWARD
var hinge_normal := Vector3.RIGHT
var horizontal := Vector3.FORWARD
var up := Vector3.UP


## Lowest solid contact along a plane normal, used to latch level guidance.
func surface_contact(normal: Vector3) -> Dictionary:
	var point := bucket_ref_world
	var velocity := tool_point_velocity
	var lowest := INF
	for index in exterior_points.size():
		var distance := normal.dot(exterior_points[index])
		if distance < lowest:
			lowest = distance
			point = exterior_points[index]
			velocity = exterior_mount_velocities[index]
	return {"point": point, "mount_velocity": velocity}


## Per-joint world linear-velocity columns: axis x (point - pivot).
func rate_columns(point: Vector3, joint_names: Array) -> Dictionary:
	var columns := {}
	for joint_name in joint_names:
		var axis := joint_axis_world.get(joint_name, Vector3.ZERO) as Vector3
		var pivot := joint_pivot_world.get(joint_name, Vector3.ZERO) as Vector3
		columns[joint_name] = axis.cross(point - pivot)
	return columns


## Signed contribution of a joint rate to bucket pitch about the shared hinge.
func pitch_coeff(joint_name: String) -> float:
	return (joint_axis_world.get(joint_name, Vector3.ZERO) as Vector3).dot(hinge_normal)


## The fraction of a commanded joint rate that the integrator is predicted to
## honor this tick: dig-direction rates lose to cut engagement, and both
## directions fade inside the limit margin. Mirrors propose_step exactly so a
## stage can pre-compensate instead of leaking constraint error.
func predicted_motion_scale(joint_name: String, rate: float) -> float:
	var scale := 1.0
	if joint_name != "swing_joint" and cut_engagement > 0.0 and rate < 0.0:
		scale *= lerpf(1.0, KinematicArticulationState.MIN_CUT_SPEED_SCALE, cut_engagement)
	if joint_limits.has(joint_name):
		var limits := joint_limits[joint_name] as Vector2
		var position := float(joint_positions.get(joint_name, 0.0))
		var margin := KinematicArticulationState.JOINT_LIMIT_MARGIN_RAD
		if rate < 0.0 and position < limits.x + margin:
			scale *= clampf((position - limits.x) / margin, 0.0, 1.0)
		elif rate > 0.0 and position > limits.y - margin:
			scale *= clampf((limits.y - position) / margin, 0.0, 1.0)
	return scale


## Bucket pitch against the ground plane, measured in the arm working plane
## spanned by `horizontal` and `up`.
func bucket_attitude_rad() -> float:
	return atan2(bucket_ref_dir_world.dot(up), bucket_ref_dir_world.dot(horizontal))


## World-space transport velocity the chassis alone imparts to a rigid point:
## v_body + omega_body x (point - chassis_origin). A stage subtracts this from
## its desired task velocity so the held pose stays ground-relative while the
## chassis rocks — same-tick rejection instead of one-tick-late feedback.
func chassis_point_velocity(point: Vector3) -> Vector3:
	return chassis_linear_velocity + chassis_angular_velocity.cross(point - chassis_transform.origin)


## Chassis angular rate projected onto the shared hinge axis (rad/s).
func chassis_hinge_rate() -> float:
	return chassis_angular_velocity.dot(hinge_normal)


## The max desired_velocity a +-1 command can deliver in a direction:
## vmax x load x the integrator's cut/limit multipliers.
func effective_ceiling(joint_name: String, direction: float) -> float:
	return float(joint_ceiling.get(joint_name, 0.0)) * predicted_motion_scale(joint_name, signf(direction))


## Max |delta_v| the integrator's accel/jerk chain can deliver this tick in
## the given direction. Mirrors propose_step's move_toward chain:
## a_next = move_toward(a_prev, +-a_max, jerk*dt); reach = |a_next|*dt.
func velocity_step_bound(joint_name: String, direction: float) -> float:
	if delta <= 0.0 or direction == 0.0:
		return 0.0
	var limits := joint_accel_limits.get(joint_name, Vector2.ZERO) as Vector2
	var target := signf(direction) * limits.x
	var accel := float(joint_accelerations.get(joint_name, 0.0))
	return absf(move_toward(accel, target, limits.y * delta)) * delta


## Exact command response of propose_step, including its absolute-acceleration
## move_toward rule. Needed for relaxed bounded control during reversals.
func velocity_for_command(joint_name: String, command: float) -> float:
	var current := float(joint_velocities.get(joint_name, 0.0))
	if delta <= 0.0:
		return current
	var desired := command * effective_ceiling(joint_name, command)
	var limits := joint_accel_limits.get(joint_name, Vector2.ZERO) as Vector2
	var acceleration := move_toward(
		float(joint_accelerations.get(joint_name, 0.0)),
		clampf((desired - current) / delta, -limits.x, limits.x), limits.y * delta,
	)
	return move_toward(current, desired, maxf(absf(acceleration), 0.000001) * delta)


## Bracket inversion is also valid when the response has a local extremum
## inside the interval (the acceleration can cross zero on a reversal).
func command_for_velocity(joint_name: String, velocity: float) -> float:
	var low := -1.0
	var high := 1.0
	for iteration in 24:
		var middle := (low + high) * 0.5
		if velocity_for_command(joint_name, middle) < velocity:
			low = middle
		else:
			high = middle
	return (low + high) * 0.5

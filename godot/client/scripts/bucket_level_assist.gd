extends "res://scripts/equipment_assist_stage.gd"
class_name BucketLevelAssist

## Task-space resolved-rate assist (modulator): while enabled, the stage owns
## boom/arm/bucket outright — operator boom and bucket input is overridden —
## and the arm channel is reinterpreted as the bucket reference point's
## horizontal speed (W pushes out along the radial direction, S pulls in).
## A damped-least-squares solve finds joint rates realizing the desired task
## velocity; a bounded proportional term tracks latched height/attitude
## setpoints so integrator nonlinearities cannot accumulate drift. When the
## arm input sits inside the deadband the stage outputs zero and relatches
## the setpoints to the current pose, preserving neutral-rearm semantics.
## A required joint that cannot move in the solved direction stops all three
## work joints for that tick. The cause decides the setpoint policy: a real
## kinematic bound (limit edge, faded ceiling, braking distance) reports
## `level_assist_infeasible` and relatches so reversing stays reachable; pure
## residual momentum reports `level_assist_reversing` and holds setpoints so
## feedback pulls the coast excursion back instead of ratifying it. Neither
## state latches — every tick is re-judged, there is no freeze latch.

const WORK_JOINTS := ["boom_joint", "arm_joint", "bucket_joint"]
const SINGULAR_EPS := 0.0001
const RATE_EPS := 0.000001
## Braking-law safety margin for the soft limit arrival: the ideal v <=
## sqrt(2 a_max d) bound is discounted because the jerk chain takes extra
## ticks to build deceleration. 0.6 keeps arrival velocity ~0 without
## perceptible early slowing.
const LIMIT_APPROACH_SAFETY := 0.6
## Solved-rate norm beyond which the task is treated as ill-conditioned. A
## healthy solve stays under ~1 rad/s per joint norm; near a kinematic
## singularity DLS rates explode toward 5-10 rad/s — executing them at
## ceiling speed means arriving at the toggle point with enough momentum to
## coast visibly off-pose. Scaling the executed vector by this cap makes the
## machine creep through the degenerate region so a required direction
## reversal starts from nearly zero velocity.
const SOLVED_RATE_NORM_CAP := 1.5
## Rate damping on the held (height/attitude) task channels, dimensionless:
## 0 reproduces the pure-P limit cycle observed near kinematic toggles, 1
## approaches critical damping. 0.5 damps the ring without slowing recovery.
const VELOCITY_DAMPING := 0.5

var horizontal_speed_m_s := 1.0
var input_deadband := 0.05
var height_gain_hz := 4.0
var attitude_gain_hz := 5.0
var max_height_error_m := 0.25
var max_attitude_error_rad := 0.35
var max_height_correction_m_s := 0.5
var max_attitude_correction_rad_s := 0.6
var dls_lambda := 0.08

var _height_ref := 0.0
var _attitude_ref := 0.0
var _active := false
var _solve_count := 0
var _last_scale := 1.0
var _last_error_m := 0.0
var _last_attitude_error_rad := 0.0
var _last_flags: Array = []
## Diagnostic snapshot of the latest rate->command conversion; consumed by
## headless tests when dissecting infeasible transitions.
var _debug_rates := Vector3.ZERO
var _debug_lo := Vector3.ZERO
var _debug_hi := Vector3.ZERO
var _debug_v0 := Vector3.ZERO
var _debug_blocked := ""


func configure(_descriptor: Dictionary, _soil_contract: Dictionary, params: Dictionary) -> bool:
	stage_name = "bucket_level"
	writes_mask = MASK_WORK_EQUIPMENT
	holds_at_neutral = false
	for field in [
		"horizontal_speed_m_s",
		"height_gain_hz", "attitude_gain_hz", "max_height_correction_m_s",
		"max_attitude_correction_rad_s", "dls_lambda",
	]:
		var value := float(params.get(field, -1.0))
		if not is_finite(value) or value <= 0.0:
			configured = false
			return false
		set(field, value)
	for field in ["input_deadband", "max_height_error_m", "max_attitude_error_rad"]:
		var value := float(params.get(field, -1.0))
		if not is_finite(value) or value <= 0.0:
			configured = false
			return false
		set(field, value)
	configured = true
	reset("configured")
	return true


func reset(_reason := "reset") -> void:
	_active = false
	_last_scale = 1.0
	_last_error_m = 0.0
	_last_attitude_error_rad = 0.0
	_last_flags = []


func step(ctx: RefCounted, commands: Vector4) -> Dictionary:
	if not enabled or not configured:
		return {"commands": commands, "scale": 1.0, "flags": []}
	var out := commands
	var flags: Array = []
	# While the assist owns the work equipment, only the arm channel carries
	# operator intent (W pushes out, S pulls in); swing passes through via the
	# pipeline mask and boom/bucket operator input is fully overridden.
	var intent := commands.z
	if absf(intent) <= input_deadband:
		_latch(ctx)
		_active = false
		out.y = 0.0
		out.z = 0.0
		out.w = 0.0
		_last_flags = []
		return {"commands": out, "scale": 1.0, "flags": flags}
	# Rising edge (fresh enable or input returning from deadband): latch the
	# setpoints to the current pose so a held key never starts with a stale
	# reference and plunges the bucket.
	if not _active:
		_latch(ctx)
	_active = true
	# The setpoints are static while driving. Bounding them to the measured
	# pose keeps the feedback bounded and lets the references follow when the
	# task is genuinely infeasible — the assist degrades instead of sticking.
	_height_ref = clampf(
		_height_ref,
		ctx.bucket_ref_world.y - max_height_error_m,
		ctx.bucket_ref_world.y + max_height_error_m,
	)
	_attitude_ref = clampf(
		_attitude_ref,
		ctx.bucket_attitude_rad() - max_attitude_error_rad,
		ctx.bucket_attitude_rad() + max_attitude_error_rad,
	)
	var height_error := clampf(_height_ref - ctx.bucket_ref_world.y, -max_height_error_m, max_height_error_m)
	var attitude_error := clampf(_attitude_ref - ctx.bucket_attitude_rad(), -max_attitude_error_rad, max_attitude_error_rad)
	_last_error_m = height_error
	_last_attitude_error_rad = attitude_error
	var columns: Dictionary = ctx.rate_columns(ctx.bucket_ref_world, WORK_JOINTS)
	# Rate damping on the held channels: the joints' current task-space
	# velocity is subtracted so the correction behaves like PD instead of P.
	# Without it, the stiffness term builds momentum that overshoots at every
	# kinematic toggle and rings as a ~1 Hz limit cycle through the
	# degenerate zone. The horizontal (intent) channel is left undamped —
	# damping it would fight the operator's commanded speed.
	var v_task_up := 0.0
	var v_task_pitch := 0.0
	for joint_name in WORK_JOINTS:
		var v0 := float(ctx.joint_velocities.get(joint_name, 0.0))
		v_task_up += (columns[joint_name] as Vector3).dot(ctx.up) * v0
		v_task_pitch += ctx.pitch_coeff(joint_name) * v0
	# Chassis transport feedforward: the edge's world velocity includes the
	# rigid-body term the joints cannot see, so the solve must counter it in
	# the same tick — otherwise the held pose chases chassis rocking through
	# the feedback path a tick late.
	var chassis: Vector3 = ctx.chassis_point_velocity(ctx.bucket_ref_world)
	var desired := Vector3(
		clampf(height_gain_hz * height_error, -max_height_correction_m_s, max_height_correction_m_s) - chassis.dot(ctx.up) - VELOCITY_DAMPING * v_task_up,
		intent * horizontal_speed_m_s - chassis.dot(ctx.horizontal),
		clampf(attitude_gain_hz * attitude_error, -max_attitude_correction_rad_s, max_attitude_correction_rad_s) - ctx.chassis_hinge_rate() - VELOCITY_DAMPING * v_task_pitch
	)
	var jacobian := [
		[
			(columns["boom_joint"] as Vector3).dot(ctx.up),
			(columns["arm_joint"] as Vector3).dot(ctx.up),
			(columns["bucket_joint"] as Vector3).dot(ctx.up),
		],
		[
			(columns["boom_joint"] as Vector3).dot(ctx.horizontal),
			(columns["arm_joint"] as Vector3).dot(ctx.horizontal),
			(columns["bucket_joint"] as Vector3).dot(ctx.horizontal),
		],
		[
			ctx.pitch_coeff("boom_joint"),
			ctx.pitch_coeff("arm_joint"),
			ctx.pitch_coeff("bucket_joint"),
		],
	]
	var rates := _solve_dls(jacobian, desired)
	_solve_count += 1
	var commands_out := _rates_to_commands(rates, ctx, flags)
	if "level_assist_infeasible" in flags:
		# Stopping at a real kinematic bound must not deadlock the corner:
		# relatching collapses the correction terms to zero, so the next solve
		# is pure feedforward and reversing the stick flips every joint rate —
		# the direction that led here always stays reachable. Momentum blocks
		# (`level_assist_reversing`) deliberately keep the setpoints so the
		# coast excursion is recovered by feedback rather than adopted.
		_latch(ctx)
	out.y = commands_out.x
	out.z = commands_out.y
	out.w = commands_out.z
	_last_flags = flags
	return {"commands": out, "scale": 1.0, "flags": flags}


func get_status_snapshot() -> Dictionary:
	var snapshot := super.get_status_snapshot()
	snapshot["active"] = _active
	snapshot["height_ref_m"] = _height_ref
	snapshot["attitude_ref_rad"] = _attitude_ref
	snapshot["height_error_m"] = _last_error_m
	snapshot["attitude_error_rad"] = _last_attitude_error_rad
	snapshot["feasible_scale"] = _last_scale
	snapshot["solve_count"] = _solve_count
	snapshot["flags"] = _last_flags.duplicate()
	return snapshot


func set_height_ref_m(value: float) -> void:
	if is_finite(value):
		_height_ref = value


func set_attitude_ref_rad(value: float) -> void:
	if is_finite(value):
		_attitude_ref = value


func _latch(ctx: RefCounted) -> void:
	_height_ref = ctx.bucket_ref_world.y
	_attitude_ref = ctx.bucket_attitude_rad()


## Damped least squares: q_rate = J^T (J J^T + lambda^2 I)^-1 desired. The
## damping keeps near-singular directions attenuated instead of blowing up.
func _solve_dls(jacobian: Array, desired: Vector3) -> Vector3:
	var lambda_sq := dls_lambda * dls_lambda
	var m := [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
	for r in 3:
		for c in 3:
			m[r][c] = float(jacobian[r][0]) * float(jacobian[c][0]) + float(jacobian[r][1]) * float(jacobian[c][1]) + float(jacobian[r][2]) * float(jacobian[c][2])
		m[r][r] += lambda_sq
	var w := _solve3x3(m, desired)
	return Vector3(
		float(jacobian[0][0]) * w.x + float(jacobian[1][0]) * w.y + float(jacobian[2][0]) * w.z,
		float(jacobian[0][1]) * w.x + float(jacobian[1][1]) * w.y + float(jacobian[2][1]) * w.z,
		float(jacobian[0][2]) * w.x + float(jacobian[1][2]) * w.y + float(jacobian[2][2]) * w.z,
	)


## Exact inverse of a symmetric positive definite 3x3 via the adjugate; the
## damping term guarantees a non-zero determinant.
func _solve3x3(m: Array, rhs: Vector3) -> Vector3:
	var a := float(m[0][0])
	var b := float(m[0][1])
	var c := float(m[0][2])
	var d := float(m[1][1])
	var e := float(m[1][2])
	var f := float(m[2][2])
	var cof_a := d * f - e * e
	var cof_b := c * e - b * f
	var cof_c := b * e - c * d
	var det := a * cof_a + b * cof_b + c * cof_c
	if absf(det) < 1e-12:
		return Vector3.ZERO
	var inv_det := 1.0 / det
	return Vector3(
		(cof_a * rhs.x + cof_b * rhs.y + cof_c * rhs.z) * inv_det,
		(cof_b * rhs.x + (a * f - c * c) * rhs.y + (b * c - a * e) * rhs.z) * inv_det,
		(cof_c * rhs.x + (b * c - a * e) * rhs.y + (a * d - b * b) * rhs.z) * inv_det,
	)


## Convert desired joint rates to normalized commands by exact integrator
## inversion. For each joint this tick's executable velocity lives in an
## interval bounded by the accel/jerk reach (move_toward chain), the
## cut/limit-scaled rate ceiling, and the hard position limit; the whole
## triplet is uniformly scaled so every joint's target velocity stays inside
## its interval — the executed step then matches the commanded direction
## exactly rather than leaking constraint error through asymmetric actuator
## lag. If a required joint cannot move in the solved direction the tick
## stops all three work joints — but the response depends on *why* it is
## blocked. A kinematic bound (position limit, faded ceiling) is reported as
## `level_assist_infeasible` and step() relatches the setpoints so reversing
## stays reachable. Pure momentum (the joint still carries velocity opposite
## to the solved direction and cannot cross zero within one tick) is
## `level_assist_reversing`: the same zero output brakes it, but the
## setpoints are held so the pose excursion is pulled back by feedback once
## the joint swings through — ratifying the coast drift would accumulate
## visible jumps at every kinematic toggle point.
func _rates_to_commands(rates: Vector3, ctx: RefCounted, flags: Array) -> Vector3:
	var rate_list := [rates.x, rates.y, rates.z]
	var lo := [0.0, 0.0, 0.0]
	var hi := [0.0, 0.0, 0.0]
	var scale := 1.0
	var active := false
	var limit_blocked := false
	var momentum_blocked := false
	# Ill-conditioning damping: when the solve inflates joint rates far past
	# what the task velocity needs, the per-joint velocity ceilings shrink
	# proportionally. The machine then creeps through the degenerate zone
	# instead of charging a kinematic toggle point at ceiling speed and
	# coasting visibly off-pose through the forced reversal.
	var rate_norm := rates.length()
	var condition := minf(1.0, SOLVED_RATE_NORM_CAP / rate_norm) if rate_norm > 0.0 else 1.0
	for index in 3:
		var joint_name: String = WORK_JOINTS[index]
		var v0 := float(ctx.joint_velocities.get(joint_name, 0.0))
		var step_neg: float = ctx.velocity_step_bound(joint_name, -1.0)
		var step_pos: float = ctx.velocity_step_bound(joint_name, 1.0)
		# Kinematic bounds independent of the joint's current momentum: rate
		# ceilings and position/braking distance. If these already forbid a
		# direction the joint is truly at a limit; otherwise a sign conflict
		# is only residual velocity working through the jerk chain.
		var kin_lo: float = -ctx.effective_ceiling(joint_name, -1.0) * condition
		var kin_hi: float = ctx.effective_ceiling(joint_name, 1.0) * condition
		if ctx.delta > 0.0 and ctx.joint_limits.has(joint_name):
			var limits := ctx.joint_limits[joint_name] as Vector2
			var position := float(ctx.joint_positions.get(joint_name, 0.0))
			kin_lo = maxf(kin_lo, (limits.x - position) / ctx.delta)
			kin_hi = minf(kin_hi, (limits.y - position) / ctx.delta)
			var accel_max := (ctx.joint_accel_limits.get(joint_name, Vector2.ZERO) as Vector2).x
			if accel_max > 0.0:
				var brake := LIMIT_APPROACH_SAFETY * sqrt(2.0 * accel_max)
				kin_lo = maxf(kin_lo, -brake * sqrt(maxf(position - limits.x, 0.0)))
				kin_hi = minf(kin_hi, brake * sqrt(maxf(limits.y - position, 0.0)))
		var lo_v: float = maxf(v0 - step_neg, kin_lo)
		var hi_v: float = minf(v0 + step_pos, kin_hi)
		lo[index] = lo_v
		hi[index] = hi_v
		var rate := float(rate_list[index])
		if absf(rate) <= RATE_EPS:
			continue
		active = true
		var reach: float = hi_v / rate if rate > 0.0 else lo_v / rate
		if reach <= 0.0:
			scale = 0.0
			_debug_blocked = joint_name
			if rate > 0.0 and kin_hi <= RATE_EPS or rate < 0.0 and kin_lo >= -RATE_EPS:
				limit_blocked = true
			else:
				momentum_blocked = true
			continue
		scale = minf(scale, reach)
	_debug_rates = rates
	_debug_lo = Vector3(lo[0], lo[1], lo[2])
	_debug_hi = Vector3(hi[0], hi[1], hi[2])
	_debug_v0 = Vector3(
		float(ctx.joint_velocities.get("boom_joint", 0.0)),
		float(ctx.joint_velocities.get("arm_joint", 0.0)),
		float(ctx.joint_velocities.get("bucket_joint", 0.0)),
	)
	var result := Vector3.ZERO
	if not active or scale <= SINGULAR_EPS:
		if momentum_blocked and not limit_blocked:
			flags.append("level_assist_reversing")
		else:
			flags.append("level_assist_infeasible")
		_last_scale = 0.0
		return result
	_last_scale = scale
	for index in 3:
		# lo/hi can invert when the joint already moves faster than the
		# conditioned ceiling; clamping against the sorted pair then commands
		# the capped velocity, which is the fastest reachable deceleration.
		var v_exec := clampf(
			scale * float(rate_list[index]),
			minf(float(lo[index]), float(hi[index])),
			maxf(float(lo[index]), float(hi[index])),
		)
		if absf(v_exec) <= RATE_EPS:
			continue
		var ceiling: float = ctx.effective_ceiling(WORK_JOINTS[index], v_exec)
		if ceiling <= RATE_EPS:
			continue
		result[index] = clampf(v_exec / ceiling, -1.0, 1.0)
	return result

class_name AssistRateSolver
extends RefCounted

## Pure-mechanics engine shared by guided-surface assist stages: a damped
## least-squares task-space solve plus exact inversion of the
## KinematicArticulationState execution model. The solver owns no task
## semantics — callers hand it a 3x3 Jacobian and a desired task velocity,
## and it returns either the normalized per-joint commands or a structured
## block classification the stage translates into its own flag names.

const BLOCKED_NONE := 0
const BLOCKED_MOMENTUM := 1
const BLOCKED_KINEMATIC := 2

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


## Damped least-squares step for a square task map J (rows x joints):
## rates = J^T (J J^T + lambda^2 I)^-1 desired.
static func solve_dls(jacobian: Array, desired: Vector3, lambda: float) -> Vector3:
	var m := [
		[0.0, 0.0, 0.0],
		[0.0, 0.0, 0.0],
		[0.0, 0.0, 0.0],
	]
	for row in 3:
		for col in 3:
			for k in 3:
				m[row][col] += float(jacobian[row][k]) * float(jacobian[col][k])
	for index in 3:
		m[index][index] += lambda * lambda
	var w := _solve3x3(m, desired)
	# rates = J^T w: each joint's rate is the dot of its Jacobian column with w.
	var j0 := [float(jacobian[0][0]), float(jacobian[1][0]), float(jacobian[2][0])]
	var j1 := [float(jacobian[0][1]), float(jacobian[1][1]), float(jacobian[2][1])]
	var j2 := [float(jacobian[0][2]), float(jacobian[1][2]), float(jacobian[2][2])]
	return Vector3(
		j0[0] * w.x + j0[1] * w.y + j0[2] * w.z,
		j1[0] * w.x + j1[1] * w.y + j1[2] * w.z,
		j2[0] * w.x + j2[1] * w.y + j2[2] * w.z,
	)


## Rectangular fallback for relaxed assists: J is 2x3 (vertical + intent
## rows; the pitch constraint is dropped), so (J J^T + lambda^2 I) is 2x2
## and inverted directly. Same DLS form: rates = J^T w.
static func solve_dls_2x3(jacobian: Array, desired: Vector2, lambda: float) -> Vector3:
	var a := 0.0
	var b := 0.0
	var c := 0.0
	for k in 3:
		var r0 := float(jacobian[0][k])
		var r1 := float(jacobian[1][k])
		a += r0 * r0
		b += r0 * r1
		c += r1 * r1
	a += lambda * lambda
	c += lambda * lambda
	var det := a * c - b * b
	if absf(det) < 1e-12:
		return Vector3.ZERO
	var inv := 1.0 / det
	var w0 := (c * desired.x - b * desired.y) * inv
	var w1 := (-b * desired.x + a * desired.y) * inv
	return Vector3(
		float(jacobian[0][0]) * w0 + float(jacobian[1][0]) * w1,
		float(jacobian[0][1]) * w0 + float(jacobian[1][1]) * w1,
		float(jacobian[0][2]) * w0 + float(jacobian[1][2]) * w1,
	)


## Exact inverse of a symmetric positive definite 3x3 via the adjugate; the
## damping term guarantees a non-zero determinant.
static func _solve3x3(m: Array, rhs: Vector3) -> Vector3:
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
## reports a block: a kinematic bound (position limit, faded ceiling,
## braking distance) is BLOCKED_KINEMATIC — the stage should relatch any
## latchable setpoints so reversing stays reachable — while pure momentum
## (the joint still carries velocity opposite the solved direction and
## cannot cross zero within one tick) is BLOCKED_MOMENTUM — the same zero
## output brakes it, but setpoints must be held so the pose excursion is
## pulled back by feedback instead of ratified.
static func rates_to_commands(rates: Vector3, ctx: RefCounted, work_joints: Array) -> Dictionary:
	var rate_list := [rates.x, rates.y, rates.z]
	var lo := [0.0, 0.0, 0.0]
	var hi := [0.0, 0.0, 0.0]
	var kin_lo_v := [0.0, 0.0, 0.0]
	var kin_hi_v := [0.0, 0.0, 0.0]
	var scale := 1.0
	var active := false
	var limit_blocked := false
	var momentum_blocked := false
	var blocked_joint := ""
	# Ill-conditioning damping: when the solve inflates joint rates far past
	# what the task velocity needs, the per-joint velocity ceilings shrink
	# proportionally. The machine then creeps through the degenerate zone
	# instead of charging a kinematic toggle point at ceiling speed and
	# coasting visibly off-pose through the forced reversal.
	var rate_norm := rates.length()
	var condition := minf(1.0, SOLVED_RATE_NORM_CAP / rate_norm) if rate_norm > 0.0 else 1.0
	for index in 3:
		var joint_name: String = work_joints[index]
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
		kin_lo_v[index] = kin_lo
		kin_hi_v[index] = kin_hi
		var rate := float(rate_list[index])
		if absf(rate) <= RATE_EPS:
			continue
		active = true
		var reach: float = hi_v / rate if rate > 0.0 else lo_v / rate
		if reach <= 0.0:
			scale = 0.0
			blocked_joint = joint_name
			if rate > 0.0 and kin_hi <= RATE_EPS or rate < 0.0 and kin_lo >= -RATE_EPS:
				limit_blocked = true
			else:
				momentum_blocked = true
			continue
		scale = minf(scale, reach)
	var debug := {
		"rates": rates,
		"lo": Vector3(lo[0], lo[1], lo[2]),
		"hi": Vector3(hi[0], hi[1], hi[2]),
		"kin_lo": Vector3(kin_lo_v[0], kin_lo_v[1], kin_lo_v[2]),
		"kin_hi": Vector3(kin_hi_v[0], kin_hi_v[1], kin_hi_v[2]),
		"v0": Vector3(
			float(ctx.joint_velocities.get(work_joints[0], 0.0)),
			float(ctx.joint_velocities.get(work_joints[1], 0.0)),
			float(ctx.joint_velocities.get(work_joints[2], 0.0)),
		),
		"blocked_joint": blocked_joint,
	}
	var result := Vector3.ZERO
	if not active or scale <= SINGULAR_EPS:
		return {
			"commands": result,
			"scale": 0.0,
			"blocked": BLOCKED_MOMENTUM if momentum_blocked and not limit_blocked else BLOCKED_KINEMATIC,
			"debug": debug,
		}
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
		var ceiling: float = ctx.effective_ceiling(work_joints[index], v_exec)
		if ceiling <= RATE_EPS:
			continue
		result[index] = clampf(v_exec / ceiling, -1.0, 1.0)
	return {"commands": result, "scale": scale, "blocked": BLOCKED_NONE, "debug": debug}

extends "res://scripts/equipment_assist_stage.gd"
class_name GuidedProfileStage

const Solver := preload("res://scripts/assist_rate_solver.gd")

## Abstract mid-layer for "ride a target surface" assists (level grading,
## slope finishing, future trench/floor guides). It owns the full per-tick
## control law — deadband/rising-edge latching, bounded reference drift,
## the 3x3 task Jacobian (vertical / horizontal / pitch), task-space
## velocity damping on the held channels, chassis transport feedforward,
## the shared rate solver, and the block policy (kinematic bound relatches
## latchable setpoints so reversing stays reachable; pure momentum holds
## them so the coast excursion is pulled back by feedback). Concrete stages
## only declare *which* surface to track through _surface_target, which
## extra channels to silence, and which latchable state they carry.

const WORK_JOINTS := ["boom_joint", "arm_joint", "bucket_joint"]
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
## Flag namespace emitted by this stage ("level_assist", "slope_assist");
## concrete stages set it in configure before calling super.
var flag_prefix := "assist"
## Relaxed mode tracks the cutting edge from the first tick, with no pitch task.
var relaxed_attitude := false

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
var _edge_plane_span_m := 0.0


func configure(_descriptor: Dictionary, _soil_contract: Dictionary, params: Dictionary) -> bool:
	holds_at_neutral = false
	profile_params = params.duplicate(true)
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


## Shared runtime knobs pushed via set_stage_params; slope adds its
## confirmed profile on top of these.
func apply_params(params: Dictionary) -> bool:
	if params.has("relaxed_attitude"):
		var requested := bool(params.get("relaxed_attitude"))
		if requested != relaxed_attitude:
			relaxed_attitude = requested
			reset("tracking_mode_changed")
	return true


func reset(_reason := "reset") -> void:
	_active = false
	_last_scale = 1.0
	_last_error_m = 0.0
	_last_attitude_error_rad = 0.0
	_last_flags = []
	_edge_plane_span_m = 0.0


## --- Concrete-stage hooks -------------------------------------------------

## Target surface at the current tooth position: {"height", "grade"} where
## grade = dh/ds along the intent axis (0 for flat reference surfaces).
func _surface_target(_ctx: RefCounted) -> Dictionary:
	return {"height": 0.0, "grade": 0.0}


## The horizontal task axis: direction of operator intent and the second
## Jacobian row. Flat guidance tracks the live outward direction; a
## confirmed slope profile returns its frozen anchor axis instead, so
## chassis settling cannot rotate the task frame mid-pass.
func _intent_axis(ctx: RefCounted) -> Vector3:
	return ctx.horizontal


## Stage-specific latchable state beyond the shared attitude reference; the
## level stage latches a scalar height, the slope stage keeps its profile
## frozen externally and latches nothing here.
func _latch_payload(_ctx: RefCounted) -> void:
	pass


## Extra command indices this stage must silence every tick (slope claims
## the swing channel and writes it to zero). Indices index into Vector4.
func _extra_locked_channels() -> Array:
	return []


## --------------------------------------------------------------------------

func step(ctx: RefCounted, commands: Vector4) -> Dictionary:
	if not enabled or not configured:
		return {"commands": commands, "scale": 1.0, "flags": []}
	var out := commands
	for index in _extra_locked_channels():
		out[int(index)] = 0.0
	if not ctx.cutting_edge_available:
		_active = false
		_last_flags = ["%s_no_cutting_edge" % flag_prefix]
		out.y = 0.0
		out.z = 0.0
		out.w = 0.0
		return {"commands": out, "scale": 1.0, "flags": _last_flags}
	var flags: Array = []
	# While the assist owns the work equipment, only the arm channel carries
	# operator intent (W pushes out, S pulls in); boom/bucket operator input
	# is fully overridden and any locked extra channel is silenced above.
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
	_attitude_ref = clampf(
		_attitude_ref,
		ctx.bucket_attitude_rad() - max_attitude_error_rad,
		ctx.bucket_attitude_rad() + max_attitude_error_rad,
	)
	if not relaxed_attitude:
		_clamp_refs(ctx)
	var target := _surface_target(ctx)
	var height_error := clampf(
		float(target.get("height", 0.0)) - ctx.bucket_ref_world.y,
		-max_height_error_m, max_height_error_m,
	)
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
	var chassis: Vector3 = ctx.chassis_point_velocity(ctx.bucket_ref_world) + ctx.tool_point_velocity
	var axis := _intent_axis(ctx)
	var intent_speed := intent * horizontal_speed_m_s
	var desired := Vector3(
		clampf(height_gain_hz * height_error, -max_height_correction_m_s, max_height_correction_m_s)
			+ float(target.get("grade", 0.0)) * intent_speed
			- chassis.dot(ctx.up) - VELOCITY_DAMPING * v_task_up,
		intent_speed - chassis.dot(axis),
		clampf(attitude_gain_hz * attitude_error, -max_attitude_correction_rad_s, max_attitude_correction_rad_s)
			- ctx.chassis_hinge_rate() - VELOCITY_DAMPING * v_task_pitch
	)
	var jacobian := [
		[
			(columns["boom_joint"] as Vector3).dot(ctx.up),
			(columns["arm_joint"] as Vector3).dot(ctx.up),
			(columns["bucket_joint"] as Vector3).dot(ctx.up),
		],
		[
			(columns["boom_joint"] as Vector3).dot(axis),
			(columns["arm_joint"] as Vector3).dot(axis),
			(columns["bucket_joint"] as Vector3).dot(axis),
		],
		[
			ctx.pitch_coeff("boom_joint"),
			ctx.pitch_coeff("arm_joint"),
			ctx.pitch_coeff("bucket_joint"),
		],
	]
	var solved: Dictionary
	if relaxed_attitude:
		# Solve the surface-normal velocity, not an absolute vertical demand
		# based on requested travel: actual travel may be actuator-limited.
		var grade := float(target.get("grade", 0.0))
		var normal: Vector3 = ctx.up - grade * axis
		_edge_plane_span_m = 2.0 * absf(normal.dot(ctx.bucket_edge_half_world)) / normal.length()
		if _edge_plane_span_m > 0.02:
			flags.append("%s_edge_tilt" % flag_prefix)
		var normal_row := Vector3.ZERO
		var tangent_row := Vector3.ZERO
		for index in 3:
			normal_row[index] = (columns[WORK_JOINTS[index]] as Vector3).dot(normal)
			tangent_row[index] = (columns[WORK_JOINTS[index]] as Vector3).dot(axis)
		var normal_speed := clampf(height_gain_hz * height_error, -max_height_correction_m_s, max_height_correction_m_s) - chassis.dot(normal)
		solved = Solver.solve_surface(normal_row, tangent_row, normal_speed, intent_speed - chassis.dot(axis), dls_lambda, ctx, WORK_JOINTS)
		_attitude_ref = ctx.bucket_attitude_rad()
		_last_attitude_error_rad = 0.0
		flags.append("%s_relaxed" % flag_prefix)
	else:
		var rates := Solver.solve_dls(jacobian, desired, dls_lambda)
		solved = Solver.rates_to_commands(rates, ctx, WORK_JOINTS)
	_solve_count += 1
	var debug := solved.get("debug", {}) as Dictionary
	_debug_rates = debug.get("rates", Vector3.ZERO)
	_debug_lo = debug.get("lo", Vector3.ZERO)
	_debug_hi = debug.get("hi", Vector3.ZERO)
	_debug_v0 = debug.get("v0", Vector3.ZERO)
	_debug_blocked = String(debug.get("blocked_joint", ""))
	var blocked := int(solved.get("blocked", Solver.BLOCKED_NONE))
	if blocked != Solver.BLOCKED_NONE:
		# Stopping at a real kinematic bound must not deadlock the corner:
		# relatching collapses the correction terms to zero, so the next solve
		# is pure feedforward and reversing the stick flips every joint rate —
		# the direction that led here always stays reachable. Momentum blocks
		# deliberately keep the setpoints so the coast excursion is recovered
		# by feedback rather than adopted.
		flags.append(
			"%s_reversing" % flag_prefix
			if blocked == Solver.BLOCKED_MOMENTUM
			else "%s_infeasible" % flag_prefix
		)
		if blocked == Solver.BLOCKED_KINEMATIC and not relaxed_attitude:
			_latch(ctx)
		_last_scale = 0.0
		_last_flags = flags
		out.y = 0.0
		out.z = 0.0
		out.w = 0.0
		return {"commands": out, "scale": 1.0, "flags": flags}
	_last_scale = float(solved.get("scale", 1.0))
	var commands_out := solved.get("commands", Vector3.ZERO) as Vector3
	out.y = commands_out.x
	out.z = commands_out.y
	out.w = commands_out.z
	_last_flags = flags
	return {"commands": out, "scale": 1.0, "flags": flags}


func _latch(ctx: RefCounted) -> void:
	_attitude_ref = ctx.bucket_attitude_rad()
	_latch_payload(ctx)


func set_attitude_ref_rad(value: float) -> void:
	if is_finite(value):
		_attitude_ref = value


## Stage-specific reference bounding; the level stage clamps its scalar
## height ref to the measured-pose window, fixed-profile stages have nothing
## latchable and leave this empty.
func _clamp_refs(_ctx: RefCounted) -> void:
	pass


func get_status_snapshot() -> Dictionary:
	var snapshot := super.get_status_snapshot()
	snapshot["active"] = _active
	snapshot["attitude_ref_rad"] = _attitude_ref
	snapshot["height_error_m"] = _last_error_m
	snapshot["attitude_error_rad"] = _last_attitude_error_rad
	snapshot["feasible_scale"] = _last_scale
	snapshot["flags"] = _last_flags.duplicate()
	snapshot["solve_count"] = _solve_count
	snapshot["edge_plane_span_m"] = _edge_plane_span_m
	return snapshot

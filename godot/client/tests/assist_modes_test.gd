extends "res://tests/voxel_excavation_authority_test.gd"

## Advanced assist modes contract:
## - relaxed assist: the guided stages drop the held bucket-pitch row when the
##   3x3 solve hits a kinematic bound, so surface tracking keeps extending
##   while the bucket angle floats free (flag "<stage>_relaxed"). Strict mode
##   stays the default and keeps reporting "<stage>_infeasible" with zeroed
##   commands at the same pose.
## - simple digging: the authority's dump gate is held closed, so no dump
##   proposal is admitted under any opening orientation while cutting and the
##   capacity-clipped overflow path keep working unchanged.

const Pipeline = preload("res://scripts/equipment_assist_pipeline.gd")
const KCtx = preload("res://scripts/equipment_kinematics_context.gd")
const Solver = preload("res://scripts/assist_rate_solver.gd")

const STAGE_DT := 1.0 / 60.0


func _run() -> void:
	var failures: Array[String] = []
	_check_relaxed_assist_contracts(failures)
	_check_relaxed_assist_at_bound(failures)
	_check_relaxed_propagation(failures)
	await _check_simple_digging(failures)
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("assist_modes_test: PASS")
	quit(0 if failures.is_empty() else 1)


## --- relaxed assist ---------------------------------------------------------

## Stage plumbing and solver math need no rig pose: the shared apply_params
## knob, the 2x3 fallback solve, and slope's pass-through params.
func _check_relaxed_assist_contracts(failures: Array[String]) -> void:
	var fixture := _standalone_fixture("sy135")
	if fixture.is_empty():
		_expect(false, "relaxed: standalone pipeline fixture unavailable", failures)
		return
	var pipeline := fixture["pipeline"] as EquipmentAssistPipeline
	var level := pipeline.get_stage("bucket_level")
	var slope := pipeline.get_stage("slope_grade")
	_expect(level != null and not level.relaxed_attitude, "relaxed: strict is the default", failures)
	_expect(
		pipeline.set_stage_params("bucket_level", {"relaxed_attitude": true}) and level.relaxed_attitude,
		"relaxed: bucket_level accepts the shared knob",
		failures,
	)
	# Slope must accept a relaxed-only push without consuming a profile.
	_expect(
		pipeline.set_stage_params("slope_grade", {"relaxed_attitude": true}) and slope.relaxed_attitude,
		"relaxed: slope_grade accepts params without requiring a profile",
		failures,
	)
	# 2x3 DLS fallback: J with unit row gains returns J^T w == desired exactly.
	var rates := Solver.solve_dls_2x3(
		[[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]], Vector2(0.4, -0.7), 0.001
	)
	_expect(
		rates.distance_to(Vector3(0.4, -0.7, 0.0)) < 0.01,
		"relaxed: 2x3 solve maps a full-rank task to exact rates (got %s)" % str(rates),
		failures,
	)
	# A rank-impossible ask still returns finite least-norm rates, never NaN.
	var degenerate := Solver.solve_dls_2x3(
		[[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]], Vector2(1.0, 1.0), 0.08
	)
	_expect(
		degenerate.is_finite(),
		"relaxed: 2x3 solve stays finite on a degenerate Jacobian",
		failures,
	)


## Behavioral contract at the kinematic bound: teleport the work joints to a
## pose where holding bucket pitch while tracking the surface over-demands the
## remaining joint range. Strict must stall (infeasible flag, zeroed commands);
## relaxed must keep producing non-zero output along the surface with a
## progressively drifting attitude instead of a snap.
func _check_relaxed_assist_at_bound(failures: Array[String]) -> void:
	var strict := _drive_at_bound(failures, false)
	var relaxed := _drive_at_bound(failures, true)
	if strict.is_empty() or relaxed.is_empty():
		return
	_expect(
		bool(strict.get("saw_infeasible", false)),
		"relaxed: strict assist stalls at the shared bound (%s)" % JSON.stringify(strict),
		failures,
	)
	_expect(
		bool(relaxed.get("saw_relaxed", false)),
		"relaxed: relaxed assist flags the pitch release (%s)" % JSON.stringify(relaxed),
		failures,
	)
	_expect(
		float(relaxed.get("progress_m", 0.0)) > float(strict.get("progress_m", 0.0)) + 0.02,
		"relaxed: relaxed extends surface travel past the strict stall (%.3f m vs %.3f m)" % [
			float(relaxed.get("progress_m", 0.0)), float(strict.get("progress_m", 0.0)),
		],
		failures,
	)
	_expect(
		float(relaxed.get("attitude_drift_rad", 0.0)) > 0.01,
		"relaxed: bucket angle actually floats once released (%.4f rad)" % float(relaxed.get("attitude_drift_rad", 0.0)),
		failures,
	)
	_expect(
		float(relaxed.get("max_attitude_step_rad", 1.0)) < 0.08,
		"relaxed: attitude release is progressive, not a snap (%.4f rad/tick)" % float(relaxed.get("max_attitude_step_rad", 1.0)),
		failures,
	)


## Drive the bucket_level stage outward from a pose seated at the arm
## extension bound, on the standalone articulation. Returns measured stats.
func _drive_at_bound(failures: Array[String], relaxed: bool) -> Dictionary:
	var fixture := _standalone_fixture("sy135")
	if fixture.is_empty():
		_expect(false, "relaxed drive: fixture unavailable", failures)
		return {}
	var pipeline := fixture["pipeline"] as EquipmentAssistPipeline
	var articulation := fixture["articulation"] as KinematicArticulationState
	var chassis := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))
	# Park the bucket just above its full-curl bound with the arm mid-range:
	# pushing out while holding pitch first crawls through the starvation band
	# (the braking law squeezes the reachable window without a hard block),
	# then hits the position bound — the classic corner the relaxed mode
	# exists for. Boom/arm stay mid-range so the 2x3 fallback retains a
	# feasible height+intent combination.
	var positions := {
		"swing_joint": 0.0,
		"boom_joint": 0.0,
		"arm_joint": -0.4,
		"bucket_joint": _joint_position_at_fraction(articulation, "bucket_joint", 0.005),
	}
	_teleport(articulation, chassis, positions)
	# Arm the integrator's neutral handshake: proposals stay stationary until
	# a zero-command tick is accepted, mirroring the runtime's rearm contract.
	articulation.set_commands(Vector4.ZERO)
	articulation.accept_step(articulation.propose_step(STAGE_DT, chassis, true), 1.0)
	pipeline.set_stage_params("bucket_level", {"relaxed_attitude": relaxed})
	pipeline.set_stage_enabled("bucket_level", true)
	var stats := {
		"saw_infeasible": false,
		"saw_relaxed": false,
		"progress_m": 0.0,
		"attitude_drift_rad": 0.0,
		"max_attitude_step_rad": 0.0,
	}
	var start_ctx := pipeline.build_context(articulation, chassis, STAGE_DT, {}) as KCtx
	var start_ref := start_ctx.bucket_ref_world
	var start_attitude := start_ctx.bucket_attitude_rad()
	var last_attitude := start_attitude
	var start_s := (start_ref - Vector3.ZERO).dot(start_ctx.horizontal)
	for tick in 240:
		var stepped := pipeline.step(Vector4(0.0, 0.0, 0.8, 0.0), articulation, chassis, STAGE_DT, {})
		var commands := stepped.get("commands", Vector4.ZERO) as Vector4
		for flag in stepped.get("flags", []):
			if String(flag) == "level_assist_infeasible":
				stats["saw_infeasible"] = true
			elif String(flag) == "level_assist_relaxed":
				stats["saw_relaxed"] = true
		articulation.set_commands(commands, tick)
		articulation.accept_step(articulation.propose_step(STAGE_DT, chassis, true), 1.0)
		var ctx := pipeline.build_context(articulation, chassis, STAGE_DT, {}) as KCtx
		var s: float = (ctx.bucket_ref_world - Vector3.ZERO).dot(ctx.horizontal)
		stats["progress_m"] = maxf(float(stats["progress_m"]), s - start_s)
		var attitude := ctx.bucket_attitude_rad()
		stats["attitude_drift_rad"] = absf(attitude - start_attitude)
		stats["max_attitude_step_rad"] = maxf(float(stats["max_attitude_step_rad"]), absf(attitude - last_attitude))
		last_attitude = attitude
	return stats


## Propagation contract: the chassis flag must persist even while the Jolt
## runtime is absent so the runtime-rebuild path can re-inject it, and
## ProductSession must keep the requested value instead of reading back a
## cleared flag. A bare chassis has no runtime — the setter returns false but
## the flag stays set for the next configure().
func _check_relaxed_propagation(failures: Array[String]) -> void:
	var chassis := TrackedChassisController.new()
	var set_result := chassis.set_relaxed_assist_enabled(true)
	_expect(not set_result, "relaxed: chassis reports no live runtime to inject", failures)
	_expect(
		chassis.relaxed_assist_enabled,
		"relaxed: chassis flag persists across runtime-less calls",
		failures,
	)
	_expect(
		chassis.set_relaxed_assist_enabled(false) or not chassis.relaxed_assist_enabled,
		"relaxed: chassis flag clears on disable",
		failures,
	)
	chassis.free()
	var session := ProductSession.new()
	_expect(
		session.request_relaxed_assist(true) and session.relaxed_assist_enabled,
		"relaxed: session keeps the enabled state without a chassis",
		failures,
	)
	_expect(
		session.request_simple_digging(true) and session.simple_digging_enabled,
		"simple digging: session keeps the enabled state without a world",
		failures,
	)
	session.free()


func _joint_position_at_fraction(articulation: KinematicArticulationState, joint_name: String, fraction: float) -> float:
	var limits := articulation.effective_joint_limits(joint_name)
	return lerpf(float(limits[0]), float(limits[1]), fraction)


func _teleport(articulation: KinematicArticulationState, chassis: Transform3D, positions: Dictionary) -> void:
	var zero := {}
	for joint_name in positions.keys():
		zero[joint_name] = 0.0
	articulation.accept_step({
		"positions": positions.duplicate(true),
		"velocities": zero.duplicate(true),
		"accelerations": zero.duplicate(true),
		"targets": positions.duplicate(true),
		"frames": articulation.frames_for_positions(chassis, positions),
	}, 1.0)


func _standalone_fixture(model_id: String) -> Dictionary:
	var descriptor := PhysicsRigDescriptor.load_for_model(model_id)
	if descriptor == null:
		return {}
	var soil: Variant = JSON.parse_string(
		FileAccess.get_file_as_string("res://resources/models/%s_soil_contract.json" % model_id)
	)
	if not soil is Dictionary:
		return {}
	var pipeline := Pipeline.new() as EquipmentAssistPipeline
	if not pipeline.configure(descriptor.to_dictionary(), soil as Dictionary, model_id):
		return {}
	var articulation := KinematicArticulationState.new()
	if not articulation.configure(descriptor.to_dictionary(), Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))):
		return {}
	return {"pipeline": pipeline, "articulation": articulation}


## --- simple digging ---------------------------------------------------------

func _check_simple_digging(failures: Array[String]) -> void:
	var zone := WorkZone.new()
	zone.name = "SimpleDiggingTestZone"
	root.add_child(zone)
	_expect(await _wait_initial_ready(zone), "simple digging terrain ready", failures)
	var descriptor := SoilContractDescriptor.load_for_model("sy135")
	_expect(descriptor != null and descriptor.is_valid_for("sy135"), "simple digging contract loads", failures)
	if descriptor == null or not descriptor.is_valid_for("sy135"):
		zone.queue_free()
		await process_frame
		return
	var contract := descriptor.to_dictionary()
	var authority := Authority.new()
	var generation := zone.readiness.generation
	_expect(authority.configure(zone, contract, generation), "simple digging authority configures", failures)
	authority.material_field.credit_bucket_mass_for_test(authority.material_field.mass_q_for_volume(0.02))
	var stock := authority.material_field.bucket_mass_q
	var tick := 1
	# Positive control: with the gate enabled a downward opening dumps.
	var open_pose := _dump_pose(contract, Vector3(6.0, 1.5, 24.0), "simple:control")
	authority.submit_pose(open_pose, _identity(generation, tick, tick), Authority.DUMP_GATE_CONFIRMATION_S * 0.6)
	tick += 1
	var control := authority.submit_pose(open_pose, _identity(generation, tick, tick), Authority.DUMP_GATE_CONFIRMATION_S * 0.6)
	tick += 1
	_expect(
		bool(control.get("accepted", false)) and String(control.get("operation", "")) == "dump",
		"simple digging control: open mouth still dumps with the gate enabled",
		failures,
	)
	# Mode on: no opening orientation can ever stage a release. The setter
	# itself cancels any uncommitted dump staged by the control above.
	authority.set_dump_gate_enabled(false)
	authority.material_field.credit_bucket_mass_for_test(authority.material_field.mass_q_for_volume(0.02))
	stock = authority.material_field.bucket_mass_q
	var held_revision := authority.data_revision
	for sample in [Vector3.DOWN, Vector3(0.3, -0.9, 0.2).normalized(), Vector3(0.0, -1.0, -0.2).normalized()]:
		for hold in 3:
			var rejected := authority.submit_pose(
				_dump_pose_with_normal(contract, Vector3(6.0, 1.5, 24.0), sample, "simple:%d" % tick),
				_identity(generation, tick, tick),
				Authority.DUMP_GATE_CONFIRMATION_S,
			)
			tick += 1
			authority.step_fixed(0.12)
			_expect(
				not bool(rejected.get("accepted", false)),
				"simple digging never admits a release (normal=%s)" % str(sample),
				failures,
			)
	var held_status := authority.get_status_snapshot()
	_expect(authority.material_field.bucket_mass_q == stock, "simple digging preserves bucket mass", failures)
	_expect(authority.data_revision == held_revision, "simple digging preserves voxel revision", failures)
	_expect(int(held_status.get("pending_dump_count", -1)) == 0, "simple digging stages no pending dump", failures)
	_expect(not bool(held_status.get("dump_gate_active", true)), "simple digging reports the gate held closed", failures)
	# Cutting still commits — and stays committed at full capacity via the
	# existing overflow sink, so a full bucket never blocks a cut.
	var cut := authority.submit_pose(
		_pose(contract, Vector3(0.0, _bucket_origin_y(contract, -0.03), 18.0), Vector3(0.0, -0.04, 0.06), "simple:cut"),
		_identity(generation, tick, tick),
	)
	tick += 1
	_expect(bool(cut.get("accepted", false)), "simple digging still queues a cut", failures)
	var cut_commit := authority.flush_for_test()
	_expect(bool(cut_commit.get("changed", false)), "simple digging cut commits", failures)
	_expect(
		int(authority.get_payload_snapshot().get("bucket_mass_q", -1)) > stock,
		"simple digging cut captures mass",
		failures,
	)
	var capacity_q := int(authority.get_status_snapshot().get("bucket_capacity_mass_q", 0))
	if capacity_q > 0:
		# Top the bucket off to capacity; the credit helper refuses mass beyond
		# remaining capacity, so seed exactly up to the cap rather than past it.
		var credited := authority.material_field.credit_bucket_mass_for_test(
			capacity_q - int(authority.material_field.bucket_mass_q)
		)
		_expect(credited, "simple digging fills the bucket to capacity", failures)
		var full_cut := authority.submit_pose(
			_pose(contract, Vector3(2.0, _bucket_origin_y(contract, -0.03), 18.0), Vector3(0.0, -0.04, 0.06), "simple:full"),
			_identity(generation, tick, tick),
		)
		tick += 1
		_expect(bool(full_cut.get("accepted", false)), "simple digging queues a cut at full capacity", failures)
		var full_commit := authority.flush_for_test()
		var full_tx := full_commit.get("transaction", {}) as Dictionary
		_expect(
			bool(full_commit.get("changed", false)) and int(full_tx.get("discarded_mass_q", 0)) > 0,
			"simple digging cuts past capacity into the overflow sink",
			failures,
		)
	# Mode off restores normal dumping. The first submission is still absorbed
	# by the engaged-cut episode (the gate suppresses dumping while engaged);
	# once it clears, the confirmation hold accumulates across poses like the
	# control above.
	authority.set_dump_gate_enabled(true)
	var restored := {"accepted": false}
	for _hold in 4:
		restored = authority.submit_pose(open_pose, _identity(generation, tick, tick), Authority.DUMP_GATE_CONFIRMATION_S * 0.6)
		tick += 1
		if bool(restored.get("accepted", false)):
			break
	_expect(
		bool(restored.get("accepted", false)),
		"simple digging off restores the dump gate",
		failures,
	)
	authority.clear()
	zone.queue_free()
	await process_frame

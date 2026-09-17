extends SceneTree

## Bucket-level assist contract: while enabled the stage owns boom/arm/bucket
## outright — operator boom and bucket input is ignored — and the arm channel
## becomes horizontal in/out translation of the cutting edge with height and
## ground-relative pitch held. Covers neutral gating, passthrough when
## disabled, bounded behavior at joint limits, and recovery after reversing
## direction (a freeze latch here would read as "moves once then stalls").

const Pipeline = preload("res://scripts/equipment_assist_pipeline.gd")
const AssistStage = preload("res://scripts/equipment_assist_stage.gd")
const KCtx = preload("res://scripts/equipment_kinematics_context.gd")

const DRIVE_TICKS := 90
const HEIGHT_TOL_M := 0.015
const ATTITUDE_TOL_RAD := 0.015

var failures: Array[String] = []
var _command_identity := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if ProjectSettings.get_setting("physics/3d/physics_engine") != "Jolt Physics":
		return _fail("Jolt Physics is not selected")
	_test_pipeline_contracts()
	for model_id in ["sy135", "sy205"]:
		if failures.is_empty():
			await _test_model(model_id)
	if failures.is_empty():
		print("bucket_level_assist_test: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


## Pipeline invariants that do not need a live Jolt body: channel masks,
## neutral guard, passthrough while disabled, and stage enable plumbing.
func _test_pipeline_contracts() -> void:
	var descriptor := PhysicsRigDescriptor.load_for_model("sy135")
	if descriptor == null:
		return _fail("sy135 descriptor unavailable for pipeline contract checks")
	var soil: Variant = JSON.parse_string(
		FileAccess.get_file_as_string("res://resources/models/sy135_soil_contract.json")
	)
	if not soil is Dictionary:
		return _fail("sy135 soil contract unavailable for pipeline contract checks")
	var pipeline := Pipeline.new() as EquipmentAssistPipeline
	if not pipeline.configure(descriptor.to_dictionary(), soil as Dictionary, "sy135"):
		return _fail("assist pipeline rejected the sy135 rig: %s" % pipeline.last_error)
	var articulation := KinematicArticulationState.new()
	if not articulation.configure(descriptor.to_dictionary(), Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))):
		return _fail("standalone articulation configure failed")
	var input := Vector4(0.4, 0.2, -0.3, 0.5)
	var idle := pipeline.step(input, articulation, Transform3D.IDENTITY, 0.016, {})
	if idle.get("commands", Vector4.ZERO) != input:
		failures.append("disabled pipeline did not pass commands through untouched")
	pipeline.set_stage_enabled("bucket_level", true)
	var neutral := pipeline.step(Vector4.ZERO, articulation, Transform3D.IDENTITY, 0.016, {})
	if (neutral.get("commands", Vector4.ONE) as Vector4).length_squared() > 0.0000001:
		failures.append("neutral operator input produced non-zero assist output")
	var swing_only := pipeline.step(Vector4(0.8, 0.0, 0.0, 0.0), articulation, Transform3D.IDENTITY, 0.016, {})
	var swing_out := swing_only.get("commands", Vector4.ZERO) as Vector4
	if not is_equal_approx(swing_out.x, 0.8) or absf(swing_out.y) > 0.0001 or absf(swing_out.z) > 0.0001 or absf(swing_out.w) > 0.0001:
		failures.append("assist stage wrote channels outside its mask or ate the swing axis")
	var stage := pipeline.get_stage("bucket_level")
	if stage == null or stage.writes_mask != AssistStage.MASK_WORK_EQUIPMENT or stage.holds_at_neutral:
		failures.append("bucket_level stage declared an unexpected channel contract")


func _test_model(model_id: String) -> void:
	var fixture := await _create_fixture(model_id)
	if fixture.is_empty():
		return
	var runtime := fixture["runtime"] as JoltChassisTrackRuntime
	var spawn := fixture["spawn"] as Transform3D
	if not runtime.set_equipment_assist_enabled("bucket_level", true):
		failures.append("%s rejected the bucket_level assist stage" % model_id)
		runtime.teardown()
		(fixture["host"] as Node3D).queue_free()
		return
	_command_identity = 0

	# Arm drive holds height and attitude while the bucket translates. Track
	# the peak error across the whole stroke — exact integrator inversion is
	# meant to pin the edge even through accel transients, not just converge
	# at the endpoint.
	runtime.reset(spawn)
	await _settle(runtime, 60)
	var before := _measure(runtime)
	var peak_height_error := 0.0
	var peak_attitude_error := 0.0
	for frame in DRIVE_TICKS:
		_drive(runtime, Vector4(0.0, 0.0, 0.5, 0.0))
		await physics_frame
		var probe := _measure(runtime)
		peak_height_error = maxf(peak_height_error, absf((probe["ref"] as Vector3).y - (before["ref"] as Vector3).y))
		peak_attitude_error = maxf(peak_attitude_error, absf(float(probe["attitude"]) - float(before["attitude"])))
	var after := _measure(runtime)
	var travel := Vector2(after["ref"].x - before["ref"].x, after["ref"].z - before["ref"].z).length()
	if travel < 0.3:
		failures.append("%s assisted arm drive did not translate the bucket (%.3f m)" % [model_id, travel])
	if peak_height_error > HEIGHT_TOL_M:
		failures.append("%s cutting-edge height drifted %.4f m during arm drive" % [model_id, peak_height_error])
	if peak_attitude_error > ATTITUDE_TOL_RAD:
		failures.append("%s bucket pitch drifted %.4f rad during arm drive" % [model_id, peak_attitude_error])
	print("%s drive: travel=%.3f m, peak height err=%.4f m, peak pitch err=%.5f rad" % [model_id, travel, peak_height_error, peak_attitude_error])

	# Boom and bucket operator input are fully owned by the assist: they must
	# not move any joint while enabled.
	runtime.reset(spawn)
	await _settle(runtime, 60)
	var override_before := _joint_positions(runtime)
	for frame in 60:
		_drive(runtime, Vector4(0.0, 0.6, 0.0, -0.6))
		await physics_frame
	var override_after := _joint_positions(runtime)
	for joint_name in ["boom_joint", "arm_joint", "bucket_joint"]:
		if absf(
			float(override_after.get(joint_name, 0.0)) - float(override_before.get(joint_name, 0.0))
		) > 0.005:
			failures.append("%s %s moved on ignored boom/bucket input" % [model_id, joint_name])

	# Near joint limits the assist must stay finite, bounded, and must resume
	# when the operator reverses — a permanent freeze reads as a dead control.
	runtime.reset(spawn)
	await _settle(runtime, 60)
	var limit_before := _measure(runtime)
	# No single-tick pose jump: the reported defect was a sudden height/attitude
	# step when a joint hit a limit or a kinematic toggle point. Residual
	# velocity must play out, but it decelerates smoothly — the observed bug
	# produced ~9 mm / ~5 mrad steps; anything under 4 mm / 4 mrad is the
	# clean deceleration window, not a discontinuity.
	var prev_pose := limit_before
	var peak_step_h := 0.0
	var peak_step_a := 0.0
	for frame in DRIVE_TICKS * 3:
		_drive(runtime, Vector4(0.0, 0.0, -0.8, 0.0))
		await physics_frame
		var pose := _measure(runtime)
		peak_step_h = maxf(peak_step_h, absf((pose["ref"] as Vector3).y - (prev_pose["ref"] as Vector3).y))
		peak_step_a = maxf(peak_step_a, absf(float(pose["attitude"]) - float(prev_pose["attitude"])))
		prev_pose = pose
	var limit_after := _measure(runtime)
	var limit_status := runtime.get_status_snapshot()
	for state_value in limit_status.get("joints", []):
		var state := state_value as Dictionary
		if not is_finite(float(state.get("position_rad", NAN))) or not is_finite(float(state.get("velocity_rad_s", NAN))):
			failures.append("%s assist produced non-finite joint state near limits" % model_id)
	if not (limit_after["ref"] as Vector3).is_finite() or not is_finite(float(limit_after["attitude"])):
		failures.append("%s assist reference became non-finite near limits" % model_id)
	if absf((limit_after["ref"] as Vector3).y - (limit_before["ref"] as Vector3).y) > 0.8:
		failures.append("%s height drifted %.3f m without bound at the limit" % [model_id, (limit_after["ref"] as Vector3).y - (limit_before["ref"] as Vector3).y])
	print("%s limit drive: peak step h=%.4f m, a=%.4f rad" % [model_id, peak_step_h, peak_step_a])
	if peak_step_h > 0.004:
		failures.append("%s sudden %.4f m height step near the limit" % [model_id, peak_step_h])
	if peak_step_a > 0.004:
		failures.append("%s sudden %.4f rad attitude step near the limit" % [model_id, peak_step_a])
	# Recovery must start promptly, but the deep-retract zone is genuinely
	# ill-conditioned: achievable horizontal speed there is ~3 cm/s, so the
	# displacement bar is measured over a longer window rather than treating
	# the physics-imposed crawl as a stall.
	for frame in 120:
		_drive(runtime, Vector4(0.0, 0.0, 0.8, 0.0))
		await physics_frame
	var recover := _measure(runtime)
	var recover_travel := Vector2(
		(recover["ref"] as Vector3).x - (limit_after["ref"] as Vector3).x,
		(recover["ref"] as Vector3).z - (limit_after["ref"] as Vector3).z,
	).length()
	print("%s recover travel=%.4f m after reverse" % [model_id, recover_travel])
	if recover_travel < 0.05:
		failures.append("%s assist did not resume motion after reversing the arm input" % model_id)

	# Disabled assist is a passthrough: arm input no longer moves the boom.
	runtime.set_equipment_assist_enabled("bucket_level", false)
	runtime.reset(spawn)
	await _settle(runtime, 60)
	var joints_before := _joint_positions(runtime)
	for frame in 40:
		_drive(runtime, Vector4(0.0, 0.0, 0.5, 0.0))
		await physics_frame
	var joints_after := _joint_positions(runtime)
	if absf(float(joints_after.get("arm_joint", 0.0)) - float(joints_before.get("arm_joint", 0.0))) < 0.05:
		failures.append("%s disabled assist blocked the raw arm command" % model_id)
	if absf(float(joints_after.get("boom_joint", 0.0)) - float(joints_before.get("boom_joint", 0.0))) > 0.02:
		failures.append("%s disabled assist still compensated through the boom" % model_id)

	runtime.teardown()
	(fixture["host"] as Node3D).queue_free()
	await physics_frame
	await physics_frame


func _drive(runtime: JoltChassisTrackRuntime, commands: Vector4) -> void:
	_command_identity += 1
	runtime.set_equipment_commands(commands, _command_identity)


## Idle ticks with gravity on so the chassis settles onto the terrain before a
## measurement baseline is latched.
func _settle(runtime: JoltChassisTrackRuntime, ticks: int) -> void:
	for _tick in ticks:
		_drive(runtime, Vector4.ZERO)
		await physics_frame


func _measure(runtime: JoltChassisTrackRuntime) -> Dictionary:
	var ctx := runtime._assist_pipeline.build_context(
		runtime._articulation,
		runtime._body.global_transform,
		0.0,
		{},
	) as KCtx
	return {"ref": ctx.bucket_ref_world, "attitude": ctx.bucket_attitude_rad()}


func _joint_positions(runtime: JoltChassisTrackRuntime) -> Dictionary:
	var positions := {}
	for state_value in runtime.get_status_snapshot().get("joints", []):
		var state := state_value as Dictionary
		positions[String(state.get("name", ""))] = float(state.get("position_rad", 0.0))
	return positions


func _create_fixture(model_id: String) -> Dictionary:
	var host := Node3D.new()
	host.name = "BucketLevelAssist_%s" % model_id
	root.add_child(host)
	var terrain_world := TerrainWorld.new()
	terrain_world.name = "TerrainWorld"
	host.add_child(terrain_world)
	var terrain_collider := TerrainCollider.new()
	terrain_collider.name = "TerrainCollider"
	terrain_collider.enabled = true
	host.add_child(terrain_collider)
	await process_frame
	if not terrain_collider.queue_snapshot(terrain_world.terrain_state.surface_snapshot()) or not terrain_collider.apply_pending():
		failures.append("%s terrain fixture failed" % model_id)
		host.queue_free()
		return {}
	await physics_frame
	var descriptor := PhysicsRigDescriptor.load_for_model(model_id)
	if descriptor == null or not descriptor.is_valid_for(model_id, descriptor.model_version()):
		failures.append("%s descriptor fixture failed" % model_id)
		host.queue_free()
		return {}
	var runtime := JoltChassisTrackRuntime.new()
	runtime.name = "JoltChassisTrackRuntime"
	host.add_child(runtime)
	var spawn := _spawn_transform(descriptor, terrain_world)
	if not runtime.configure(descriptor, terrain_world, terrain_collider, spawn):
		failures.append("%s runtime configure failed: %s" % [model_id, runtime.contract_error])
		host.queue_free()
		return {}
	return {"host": host, "runtime": runtime, "spawn": spawn}


func _spawn_transform(descriptor: PhysicsRigDescriptor, terrain_world: TerrainWorld) -> Transform3D:
	var chassis := descriptor.bodies()[0] as Dictionary
	var shape := chassis["shape"] as Dictionary
	var center := _vector3(shape["center_m"])
	var size := _vector3(shape["size_m"])
	var clearance := float(descriptor.chassis_dynamics()["ground_clearance_m"])
	var surface_y := terrain_world.terrain_state.sample_surface_bilinear_at(Vector2.ZERO)
	return Transform3D(Basis.IDENTITY, Vector3(0.0, surface_y - (center.y - 0.5 * size.y) + clearance, 0.0))


func _vector3(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


func _fail(message: String) -> void:
	failures.append(message)
	push_error(message)
	quit(1)

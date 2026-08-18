extends SceneTree

const JOINT_NAMES := ["swing_joint", "boom_joint", "arm_joint", "bucket_joint"]
const COMMAND_FRAMES := 60

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if ProjectSettings.get_setting("physics/3d/physics_engine") != "Jolt Physics":
		return _fail("Jolt Physics is not selected")
	for model_id in ["sy205", "sy135"]:
		await _test_model(model_id)
		if not failures.is_empty():
			break
	if failures.is_empty():
		print("jolt_articulated_equipment_test: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _test_model(model_id: String) -> void:
	var fixture := await _create_fixture(model_id)
	if fixture.is_empty():
		return
	var runtime := fixture["runtime"] as JoltChassisTrackRuntime
	var descriptor := fixture["descriptor"] as PhysicsRigDescriptor
	var spawn := fixture["spawn"] as Transform3D
	_set_zero_gravity(runtime)
	await physics_frame
	var initial := runtime.get_status_snapshot()
	if (
		(initial.get("bodies", []) as Array).size() != 1
		or (initial.get("kinematic_frames", []) as Array).size() != 4
		or (initial.get("joints", []) as Array).size() != 4
	):
		failures.append("%s did not construct a one-body/four-joint hybrid rig" % model_id)
	if not runtime._joints.is_empty() or runtime._bodies.size() != 1 or not runtime._bodies.has("chassis"):
		failures.append("%s retained dynamic work-equipment bodies or physics joints" % model_id)
	if String(initial.get("rig_version", "")).is_empty():
		failures.append("%s snapshot omitted rig identity" % model_id)

	runtime.reset(spawn)
	_set_zero_gravity(runtime)
	runtime.set_equipment_commands(Vector4(1.0, 0.0, 0.0, 0.0), 10)
	await physics_frame
	if bool(runtime.get_status_snapshot().get("neutral_armed", true)):
		failures.append("%s accepted equipment effort before neutral re-arm" % model_id)
	runtime.set_equipment_commands(Vector4.ZERO, 11)
	await physics_frame
	if not bool(runtime.get_status_snapshot().get("neutral_armed", false)):
		failures.append("%s did not re-arm after neutral input" % model_id)
	runtime.set_equipment_commands(Vector4(1.0, 0.0, 0.0, 0.0), 9)
	await physics_frame
	if int(runtime.get_status_snapshot().get("command_identity", -1)) != 11:
		failures.append("%s accepted a stale equipment command identity" % model_id)

	for joint_index in JOINT_NAMES.size():
		var positive := await _drive_joint(runtime, spawn, joint_index, 1.0)
		var negative := await _drive_joint(runtime, spawn, joint_index, -1.0)
		var joint_name: String = JOINT_NAMES[joint_index]
		if positive.is_empty() or negative.is_empty():
			failures.append("%s %s telemetry was unavailable" % [model_id, joint_name])
			continue
		if float(positive["target_position_rad"]) <= float(negative["target_position_rad"]):
			failures.append("%s %s target did not respond in both directions" % [model_id, joint_name])
		if float(positive["position_rad"]) <= float(negative["position_rad"]) + 0.005:
			failures.append("%s %s actual pose did not respond in both directions: +%s -%s" % [model_id, joint_name, positive, negative])
		var joint_contract := descriptor.joints()[joint_index] as Dictionary
		var limits := joint_contract["limit_rad"] as Array
		for sample in [positive, negative]:
			var position := float(sample["position_rad"])
			if not is_finite(position) or position < float(limits[0]) - 0.03 or position > float(limits[1]) + 0.03:
				failures.append("%s %s escaped its descriptor limits" % [model_id, joint_name])
			if not is_finite(float(sample["velocity_rad_s"])) or not is_finite(float(sample["effort_n"])):
				failures.append("%s %s emitted non-finite telemetry" % [model_id, joint_name])
			if absf(float(sample["effort_n"])) > float((joint_contract["actuator"] as Dictionary)["max_torque_nm"]) + 0.01:
				failures.append("%s %s exceeded its effort cap" % [model_id, joint_name])

	var unloaded_boom := await _drive_joint(runtime, spawn, 1, 1.0)
	runtime.reset(spawn)
	_set_zero_gravity(runtime)
	if not runtime.set_bucket_payload(4500.0, Vector3.ZERO, 1):
		failures.append("%s rejected the bounded heavy-load fixture" % model_id)
	await physics_frame
	runtime.set_equipment_commands(Vector4.ZERO, 0)
	await physics_frame
	var boom_command := Vector4(0.0, 1.0, 0.0, 0.0)
	for frame in COMMAND_FRAMES:
		runtime.set_equipment_commands(boom_command, frame + 1)
		await physics_frame
	var loaded_boom := _joint_state(runtime.get_status_snapshot(), "boom_joint")
	if absf(float(loaded_boom.get("position_rad", 0.0))) >= absf(float(unloaded_boom.get("position_rad", 0.0))) * 0.95:
		failures.append("%s heavy payload did not slow boom response" % model_id)

	runtime.reset(spawn)
	_set_zero_gravity(runtime)
	runtime.set_equipment_commands(Vector4.ZERO, 0)
	await physics_frame
	var mixed := Vector4(0.55, 0.55, -0.55, 0.55)
	for frame in COMMAND_FRAMES:
		runtime.set_equipment_commands(mixed, frame + 1)
		await physics_frame
	var mixed_status := runtime.get_status_snapshot()
	var expected_signs := [1.0, 1.0, -1.0, 1.0]
	for index in JOINT_NAMES.size():
		var state := _joint_state(mixed_status, JOINT_NAMES[index])
		if signf(float(state.get("target_position_rad", 0.0))) != expected_signs[index]:
			failures.append("%s mixed-axis target sign drifted for %s" % [model_id, JOINT_NAMES[index]])
	if not (mixed_status.get("angular_velocity", Vector3.ZERO) as Vector3).is_finite():
		failures.append("%s mixed-axis chassis reaction became non-finite" % model_id)
	if (mixed_status.get("angular_velocity", Vector3.ZERO) as Vector3).length() > 0.00001:
		failures.append("%s free kinematic equipment injected an uncapped chassis reaction" % model_id)
	runtime.set_equipment_commands(Vector4.ZERO, COMMAND_FRAMES + 1)
	for _frame in 60:
		await physics_frame
	for state_value in runtime.get_status_snapshot().get("joints", []):
		var held := state_value as Dictionary
		if not is_finite(float(held.get("position_rad", NAN))) or not is_finite(float(held.get("effort_n", NAN))):
			failures.append("%s hold state became non-finite" % model_id)

	var chassis_base_mass := float(runtime._body.mass)
	if not runtime.set_bucket_payload(850.0, Vector3.ZERO, 42):
		failures.append("%s rejected a valid bucket payload" % model_id)
	await physics_frame
	var loaded := runtime.get_status_snapshot()
	var payload := loaded.get("payload", {}) as Dictionary
	if int(payload.get("identity", -1)) != 42 or not is_equal_approx(float(payload.get("mass_kg", 0.0)), 850.0):
		failures.append("%s did not apply payload identity at the tick boundary" % model_id)
	if float(payload.get("motion_load_factor", 1.0)) >= 1.0:
		failures.append("%s payload did not reduce the kinematic motion load factor" % model_id)
	if runtime.set_bucket_payload(100.0, Vector3.ZERO, 41):
		failures.append("%s accepted a stale payload identity" % model_id)
	if runtime.set_bucket_payload(100.0, Vector3(100.0, 100.0, 100.0), 43):
		failures.append("%s accepted a payload COM outside the bucket proxy" % model_id)
	await physics_frame
	payload = runtime.get_status_snapshot().get("payload", {}) as Dictionary
	if int(payload.get("identity", -1)) != 42 or not is_equal_approx(float(payload.get("mass_kg", 0.0)), 850.0):
		failures.append("%s invalid payload changed applied mass properties" % model_id)
	if not is_equal_approx(runtime._body.mass, chassis_base_mass) or runtime._bodies.has("bucket"):
		failures.append("%s payload mutated dynamic mass or created a bucket body" % model_id)

	var accepted_frames := runtime._articulation.accepted_frames()
	var candidate_frames := accepted_frames.duplicate(true)
	runtime._queued_support_wrench.clear()
	var candidate_bucket := candidate_frames["bucket_link"] as Transform3D
	candidate_bucket.origin += Vector3(0.0, -0.2, 0.0)
	candidate_frames["bucket_link"] = candidate_bucket
	runtime._bucket_query = {
		"contacts": [{
			"proxy_role": "rear_support",
			"point_world": runtime._body.global_position + Vector3(0.0, 0.0, -1.0),
			"normal_world": Vector3.UP,
			"initial_overlap": false,
		}],
	}
	runtime._queue_support_wrench(accepted_frames, candidate_frames, 0.25)
	var queued_wrench := runtime._queued_support_wrench.duplicate(true)
	if queued_wrench.is_empty() or int(queued_wrench.get("eligible_apply_tick", -1)) != runtime._physics_tick + 1:
		failures.append("%s support evidence did not queue a next-tick chassis wrench" % model_id)
	else:
		if (queued_wrench.get("requested_force", Vector3.ZERO) as Vector3).length() > JoltChassisTrackRuntime.MAX_SUPPORT_FORCE_DELTA_N_PER_TICK + 0.01:
			failures.append("%s first support request exceeded its force rate cap" % model_id)
		if (queued_wrench.get("requested_torque", Vector3.ZERO) as Vector3).length() > JoltChassisTrackRuntime.MAX_SUPPORT_TORQUE_DELTA_NM_PER_TICK + 0.01:
			failures.append("%s first support request exceeded its torque rate cap" % model_id)
		runtime._physics_tick = int(queued_wrench["eligible_apply_tick"])
		runtime._apply_queued_support_wrench()
		if runtime._applied_support_wrench.is_empty() or not runtime._queued_support_wrench.is_empty():
			failures.append("%s eligible support wrench was not applied exactly once" % model_id)
		elif (
			(runtime._applied_support_wrench.get("applied_force", Vector3.ZERO) as Vector3).length() > JoltChassisTrackRuntime.MAX_SUPPORT_FORCE_N + 0.01
			or (runtime._applied_support_wrench.get("applied_torque", Vector3.ZERO) as Vector3).length() > JoltChassisTrackRuntime.MAX_SUPPORT_TORQUE_NM + 0.01
		):
			failures.append("%s applied support wrench exceeded its caps" % model_id)
		runtime._queued_support_wrench = queued_wrench.duplicate(true)
		runtime._apply_queued_support_wrench()
		if not (runtime._quality_flags as Array).has("support_wrench_duplicate_rejected"):
			failures.append("%s duplicate support request identity was not rejected" % model_id)

	runtime._reset_support_response(true)
	runtime._queued_support_wrench.clear()
	runtime._bucket_query = {
		"contacts": [{
			"proxy_role": "shell",
			"point_world": runtime._body.global_position + Vector3.RIGHT,
			"normal_world": Vector3.RIGHT,
			"initial_overlap": false,
		}],
	}
	if runtime._queue_support_wrench(accepted_frames, candidate_frames, 0.25):
		failures.append("%s lateral shell scrape was misclassified as support" % model_id)
	runtime._bucket_query = {
		"contacts": [{
			"proxy_role": "rear_support",
			"point_world": runtime._body.global_position + Vector3(0.0, 0.0, -1.0),
			"normal_world": Vector3.UP,
			"initial_overlap": false,
		}],
	}
	runtime._support_contact_ticks = JoltChassisTrackRuntime.MAX_SUPPORT_DURATION_TICKS
	if runtime._queue_support_wrench(accepted_frames, candidate_frames, 0.25):
		failures.append("%s continuous support exceeded its duration cap" % model_id)
	if not runtime._support_contact_observed:
		failures.append("%s duration-capped support did not stay locked until contact loss" % model_id)
	runtime._support_contact_observed = false
	if not runtime._queued_support_wrench.is_empty():
		failures.append("%s duration-capped support queued an unexpected wrench" % model_id)
	runtime._reset_support_response()
	if runtime._support_contact_ticks != 0 or runtime._support_contact_observed:
		failures.append("%s support state did not reset after contact loss" % model_id)

	runtime.teardown()
	await physics_frame
	await physics_frame
	if runtime.has_body() or not runtime._bodies.is_empty() or not runtime._joints.is_empty():
		failures.append("%s teardown retained hybrid physics ownership" % model_id)
	(fixture["host"] as Node3D).queue_free()
	await physics_frame
	await physics_frame


func _drive_joint(runtime: JoltChassisTrackRuntime, spawn: Transform3D, joint_index: int, direction: float) -> Dictionary:
	runtime.reset(spawn)
	_set_zero_gravity(runtime)
	runtime.set_equipment_commands(Vector4.ZERO, 0)
	await physics_frame
	var command := Vector4.ZERO
	command[joint_index] = direction
	for frame in COMMAND_FRAMES:
		runtime.set_equipment_commands(command, frame + 1)
		await physics_frame
	return _joint_state(runtime.get_status_snapshot(), JOINT_NAMES[joint_index])


func _joint_state(status: Dictionary, joint_name: String) -> Dictionary:
	for value in status.get("joints", []):
		if value is Dictionary and String((value as Dictionary).get("name", "")) == joint_name:
			return (value as Dictionary).duplicate(true)
	return {}


func _set_zero_gravity(runtime: JoltChassisTrackRuntime) -> void:
	for body_value in runtime._bodies.values():
		(body_value as RigidBody3D).gravity_scale = 0.0


func _create_fixture(model_id: String) -> Dictionary:
	var host := Node3D.new()
	host.name = "JoltArticulatedEquipment_%s" % model_id
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
		failures.append("%s articulated runtime configure failed: %s" % [model_id, runtime.contract_error])
		host.queue_free()
		return {}
	return {"host": host, "runtime": runtime, "descriptor": descriptor, "spawn": spawn}


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

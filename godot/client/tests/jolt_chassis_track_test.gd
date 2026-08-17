extends SceneTree

const SETTLE_FRAMES := 120
const DRIVE_FRAMES := 180

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
		await _test_slope_and_obstacle()
	if failures.is_empty():
		await _test_controller_authority_lifecycle()
	if failures.is_empty():
		print("jolt_chassis_track_test: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _test_model(model_id: String) -> void:
	var host := Node3D.new()
	host.name = "JoltChassisTest_%s" % model_id
	root.add_child(host)
	var terrain_world := TerrainWorld.new()
	terrain_world.name = "TerrainWorld"
	host.add_child(terrain_world)
	var terrain_collider := TerrainCollider.new()
	terrain_collider.name = "TerrainCollider"
	terrain_collider.enabled = true
	host.add_child(terrain_collider)
	await process_frame
	var terrain_snapshot := terrain_world.terrain_state.surface_snapshot()
	if not terrain_collider.queue_snapshot(terrain_snapshot) or not terrain_collider.apply_pending():
		failures.append("%s terrain collider setup failed" % model_id)
		host.queue_free()
		return
	await physics_frame
	var descriptor := PhysicsRigDescriptor.load_for_model(model_id)
	if descriptor == null:
		failures.append("%s descriptor missing" % model_id)
		host.queue_free()
		return
	var model_version := descriptor.model_version()
	if not descriptor.is_valid_for(model_id, model_version):
		failures.append("%s descriptor invalid: %s" % [model_id, descriptor.validation_error()])
		host.queue_free()
		return
	var runtime := JoltChassisTrackRuntime.new()
	runtime.name = "JoltChassisTrackRuntime"
	host.add_child(runtime)
	var spawn := _spawn_transform(descriptor, terrain_world)
	if not runtime.configure(descriptor, terrain_world, terrain_collider, spawn):
		failures.append("%s runtime configure failed: %s" % [model_id, runtime.contract_error])
		host.queue_free()
		return
	runtime._body.linear_velocity = Vector3(NAN, 0.0, 0.0)
	runtime._body.angular_velocity = Vector3(0.0, NAN, 0.0)
	runtime._clamp_body_velocity()
	var sanitized := runtime.get_status_snapshot()
	if not (sanitized["linear_velocity"] as Vector3).is_zero_approx() or not (sanitized["angular_velocity"] as Vector3).is_zero_approx():
		failures.append("%s non-finite body velocity was not cleared" % model_id)
	if not (sanitized["quality_flags"] as Array).has("invalid_linear_velocity_cleared") or not (sanitized["quality_flags"] as Array).has("invalid_angular_velocity_cleared"):
		failures.append("%s non-finite body velocity did not report quality flags" % model_id)
	runtime.reset(spawn)
	for _frame in SETTLE_FRAMES:
		await physics_frame
	var settled := runtime.get_status_snapshot()
	if not bool(settled["terrain_identity_valid"]):
		failures.append("%s did not accept current terrain identity" % model_id)
	if int(settled["left_contact_count"]) == 0 or int(settled["right_contact_count"]) == 0:
		failures.append("%s did not settle on both tracks: %s" % [model_id, settled])
	var start := runtime.get_body_global_transform()
	runtime.set_commands(1.0, 1.0)
	for _frame in DRIVE_FRAMES:
		await physics_frame
	var driven := runtime.get_status_snapshot()
	var moved := runtime.get_body_global_transform().origin - start.origin
	if moved.dot(-start.basis.z) < 0.15:
		failures.append("%s straight drive did not move forward: %s" % [model_id, moved])
	var max_speed := float(descriptor.chassis_dynamics()["max_linear_speed_m_s"])
	if (driven["linear_velocity"] as Vector3).length() > max_speed + 0.01:
		failures.append("%s exceeded the configured speed bound" % model_id)
	if int(driven["peak_step_usec"]) > 10000:
		failures.append("%s track force step exceeded 10 ms: %s" % [model_id, driven["peak_step_usec"]])
	var speed_before_brake := (driven["linear_velocity"] as Vector3).length()
	runtime.set_commands(0.0, 0.0)
	for _frame in 120:
		await physics_frame
	var speed_after_brake := (runtime.get_status_snapshot()["linear_velocity"] as Vector3).length()
	if speed_after_brake >= speed_before_brake:
		failures.append("%s braking did not reduce chassis speed" % model_id)

	runtime.reset(spawn)
	for _frame in 30:
		await physics_frame
	var pivot_start := runtime.get_body_global_transform()
	runtime.set_commands(-1.0, 1.0)
	for _frame in DRIVE_FRAMES:
		await physics_frame
	var pivot_end := runtime.get_body_global_transform()
	var heading_change := (-pivot_start.basis.z).angle_to(-pivot_end.basis.z)
	if heading_change < 0.08:
		failures.append(
			"%s differential track force did not pivot (heading=%.4f angular=%s status=%s)"
			% [model_id, heading_change, runtime.get_status_snapshot()["angular_velocity"], runtime.get_status_snapshot()]
		)
	if pivot_end.origin.distance_to(pivot_start.origin) > 1.0:
		failures.append("%s pivot translated excessively" % model_id)

	terrain_world.terrain_state.enqueue_brush(1, Vector2.ZERO, 1.0, 0.1)
	terrain_world.terrain_state.step_fixed()
	for _frame in 3:
		await physics_frame
	var stale := runtime.get_status_snapshot()
	if bool(stale["terrain_identity_valid"]):
		failures.append("%s accepted a stale terrain collider" % model_id)
	if not (stale["quality_flags"] as Array).has("terrain_collider_unavailable"):
		failures.append("%s stale terrain did not report degraded quality" % model_id)

	runtime.teardown()
	if runtime.has_body():
		failures.append("%s teardown retained its body" % model_id)
	host.queue_free()
	for _frame in 3:
		await physics_frame


func _test_slope_and_obstacle() -> void:
	var host := Node3D.new()
	host.name = "JoltSlopeObstacleTest"
	root.add_child(host)
	var terrain_world := TerrainWorld.new()
	terrain_world.name = "TerrainWorld"
	host.add_child(terrain_world)
	await process_frame
	var state := terrain_world.terrain_state
	for row in state.rows:
		var z := state.origin_xz.y + float(row) * state.spacing_m
		var slope_height := -0.08 * z
		var mound_distance := absf(z + 2.0)
		var mound_height := (
			0.1 * (0.5 + 0.5 * cos(PI * mound_distance / 2.0))
			if mound_distance < 2.0
			else 0.0
		)
		for column in state.columns:
			state.stable_heights[row * state.columns + column] = slope_height + mound_height
	state.terrain_revision += 1
	var terrain_collider := TerrainCollider.new()
	terrain_collider.name = "TerrainCollider"
	terrain_collider.enabled = true
	host.add_child(terrain_collider)
	if not terrain_collider.queue_snapshot(state.surface_snapshot()) or not terrain_collider.apply_pending():
		failures.append("slope/obstacle collider setup failed")
		host.queue_free()
		return
	await physics_frame
	var descriptor := PhysicsRigDescriptor.load_for_model("sy205")
	var runtime := JoltChassisTrackRuntime.new()
	runtime.name = "JoltChassisTrackRuntime"
	host.add_child(runtime)
	var spawn := _spawn_transform(descriptor, terrain_world)
	if not runtime.configure(descriptor, terrain_world, terrain_collider, spawn):
		failures.append("slope/obstacle runtime configure failed: %s" % runtime.contract_error)
		host.queue_free()
		return
	for _frame in SETTLE_FRAMES:
		await physics_frame
	var start := runtime.get_body_global_transform()
	runtime.set_commands(1.0, 1.0)
	for _frame in 360:
		await physics_frame
	var finish := runtime.get_body_global_transform()
	var status := runtime.get_status_snapshot()
	var forward_distance := (finish.origin - start.origin).dot(-start.basis.z)
	if forward_distance < 2.4:
		failures.append("slope/obstacle traversal stalled at %.3f m" % forward_distance)
	if finish.origin.y < start.origin.y + 0.08:
		failures.append("slope traversal did not gain height")
	if int(status["left_contact_count"]) == 0 or int(status["right_contact_count"]) == 0:
		failures.append("slope traversal lost a complete track contact set")
	var max_speed := float(descriptor.chassis_dynamics()["max_linear_speed_m_s"])
	if (status["linear_velocity"] as Vector3).length() > max_speed + 0.01:
		failures.append("slope traversal exceeded the configured energy bound")
	runtime.teardown()
	host.queue_free()
	for _frame in 3:
		await physics_frame


func _test_controller_authority_lifecycle() -> void:
	var host := Node3D.new()
	host.name = "JoltControllerAuthorityTest"
	root.add_child(host)
	var terrain_root := Node3D.new()
	terrain_root.name = "TerrainRoot"
	host.add_child(terrain_root)
	var terrain_world := TerrainWorld.new()
	terrain_world.name = "TerrainWorld"
	terrain_root.add_child(terrain_world)
	var terrain_collider := TerrainCollider.new()
	terrain_collider.name = "TerrainCollider"
	terrain_root.add_child(terrain_collider)
	var chassis := TrackedChassisController.new()
	chassis.name = "ChassisMotionRoot"
	chassis.use_project_authority_profile = false
	chassis.authority_profile = AuthorityProfile.JOLT_AUTHORITATIVE
	chassis.controller_enabled = true
	host.add_child(chassis)
	var presentation_root := Node3D.new()
	presentation_root.name = "PresentationRoot"
	chassis.add_child(presentation_root)
	var client := MotionClient.new()
	client.name = "MotionClient"
	client.auto_connect = false
	client.auto_reconnect = false
	host.add_child(client)
	var presentation := MotionPresentation.new()
	presentation.name = "MotionPresentation"
	presentation.presentation_root_path = NodePath("../ChassisMotionRoot/PresentationRoot")
	presentation.use_project_authority_profile = false
	presentation.authority_profile = AuthorityProfile.JOLT_AUTHORITATIVE
	host.add_child(presentation)
	for _frame in 3:
		await process_frame
	for _frame in SETTLE_FRAMES:
		await physics_frame
	var initial := chassis.get_status_snapshot()
	if not bool(initial.get("configured", false)) or initial.get("model_id") != "sy205":
		failures.append("authoritative controller did not build the SY205 rig: %s" % initial)
		host.queue_free()
		return
	var start := chassis.global_transform
	chassis.set_commands_for_test(1.0, 1.0)
	for _frame in 120:
		await physics_frame
	if (chassis.global_position - start.origin).dot(-start.basis.z) < 0.08:
		failures.append("authoritative controller did not follow the Jolt body")
	chassis.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await physics_frame
	var unfocused := chassis.get_status_snapshot()
	if not is_zero_approx(float(unfocused["left_command"])) or not is_zero_approx(float(unfocused["right_command"])):
		failures.append("focus loss did not disarm authoritative tracks")
	chassis.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	chassis.set_equipment_commands_for_test(Vector4(0.0, 0.0, 0.0, 1.0))
	for _frame in 60:
		await physics_frame
	chassis.clear_equipment_commands_for_test()
	var linkage := presentation.get_passive_linkage_snapshot_for_test()
	if not bool(linkage.get("reachable", false)) or not presentation.get_pivot_diagnostics_for_test().is_empty():
		failures.append("authoritative SY205 physical bucket broke visual pivot/linkage invariants")
	if not presentation.activate_model_for_test("sy135"):
		failures.append("authoritative SY135 model rebuild failed: %s" % chassis.contract_error)
	else:
		for _frame in 3:
			await physics_frame
		var switched := chassis.get_status_snapshot()
		if switched.get("model_id") != "sy135" or switched.get("rig_version") != "sy135-jolt-rig-v3":
			failures.append("model switch retained the wrong dynamic rig: %s" % switched)
		var runtime_count := 0
		for child in host.get_children():
			if child is JoltChassisTrackRuntime:
				runtime_count += 1
		if runtime_count != 1:
			failures.append("model switch left %d Jolt runtimes" % runtime_count)
	client.pose_cleared.emit(2, "transport_replaced")
	var cleared := chassis.get_status_snapshot()
	if not (cleared["linear_velocity"] as Vector3).is_zero_approx() or not (cleared["angular_velocity"] as Vector3).is_zero_approx():
		failures.append("pose clear retained Jolt body momentum")
	await physics_frame
	terrain_world.reset_for_test()
	for _frame in 3:
		await physics_frame
	if not bool(chassis.get_status_snapshot()["terrain_identity_valid"]):
		failures.append("world reset did not rebuild authoritative terrain identity")

	var publisher := SimulationTruthPublisher.new()
	publisher.name = "SimulationTruthPublisher"
	publisher.use_project_authority_profile = false
	publisher.authority_profile = AuthorityProfile.JOLT_AUTHORITATIVE
	host.add_child(publisher)
	for _frame in 3:
		await physics_frame
	var truth := publisher.get_last_snapshot()
	if truth.get("authority_profile") != AuthorityProfile.JOLT_AUTHORITATIVE:
		failures.append("authoritative truth snapshot was not produced: %s" % truth)
	else:
		var tracks := truth.get("tracks", {}) as Dictionary
		if not tracks.has_all(["left_contact_count", "right_contact_count", "left_slip_ratio", "right_slip_ratio", "terrain_identity_valid"]):
			failures.append("authoritative truth omitted track telemetry")
		if truth.get("identity", {}).get("rig_version") != "sy135-jolt-rig-v3":
			failures.append("authoritative truth retained stale rig identity")
		if not (truth.get("quality_flags", []) as Array).has("jolt_articulated_authority"):
			failures.append("authoritative truth did not declare articulated authority")
		if (truth.get("quality_flags", []) as Array).has("work_equipment_frozen_phase1"):
			failures.append("authoritative truth retained the Phase 1 frozen-equipment flag")
		if (truth.get("bodies", []) as Array).size() != 5 or (truth.get("joints", []) as Array).size() != 4:
			failures.append("authoritative truth omitted articulated body or joint state")
		for joint_value in truth.get("joints", []):
			if not (joint_value as Dictionary).has_all(["target_position_rad", "target_velocity_rad_s", "position_rad", "velocity_rad_s", "effort_n"]):
				failures.append("authoritative truth omitted target/actual/effort joint telemetry")
		if not (truth.get("quality_flags", []) as Array).has("jolt_contact_manifold_unavailable"):
			failures.append("authoritative ray contacts did not declare unavailable manifold values")
	var publisher_status := publisher.get_status_snapshot()
	if not bool(publisher_status.get("publishing", false)) or bool(publisher_status.get("transport_publishing", true)):
		failures.append("authoritative truth publisher exposed the wrong local/transport status")
	client.connection_state = MotionClient.STATE_READY
	client.negotiated_optional_capabilities = ["simulation_truth_shadow_v1"]
	publisher._physics_process(0.0)
	if bool(client.get_status_snapshot().get("shadow_truth_pending", false)):
		failures.append("authoritative truth was queued onto the shadow transport")
	var first_epoch := String(publisher.get_last_snapshot().get("authority_epoch", ""))
	client.authority_changed.emit("new-session", "new-simulation", 7)
	var rotated := publisher.build_snapshot()
	if rotated == null:
		failures.append("authoritative truth did not rebuild after authority rotation")
	else:
		var rotated_data := rotated.to_dictionary()
		if String(rotated_data.get("authority_epoch", "")) == first_epoch or int(rotated_data.get("sequence", -1)) != 0:
			failures.append("authority rotation did not start a fresh truth epoch/sequence")

	chassis.set_controller_enabled(false)
	await physics_frame
	if not bool(chassis.get_status_snapshot().get("configured", false)):
		failures.append("disabling input destroyed the physics authority body")
	if chassis._configure_model("unknown-model"):
		failures.append("unknown model unexpectedly configured a Jolt runtime")
	await physics_frame
	if bool(chassis.get_status_snapshot().get("configured", false)):
		failures.append("failed model switch retained an active Jolt runtime")
	host.queue_free()
	for _frame in 4:
		await physics_frame


func _spawn_transform(descriptor: PhysicsRigDescriptor, terrain_world: TerrainWorld) -> Transform3D:
	var data := descriptor.to_dictionary()
	var dynamics := data["chassis_dynamics"] as Dictionary
	var minimum_bottom := 0.0
	for shape in dynamics["compound_shapes"]:
		var center := _vector3(shape["center_m"])
		var size := _vector3(shape["size_m"])
		minimum_bottom = minf(minimum_bottom, center.y - 0.5 * size.y)
	var clearance := float(dynamics["ground_clearance_m"])
	var surface_y := terrain_world.terrain_state.sample_surface_bilinear_at(Vector2.ZERO)
	return Transform3D(Basis.IDENTITY, Vector3(0.0, surface_y - minimum_bottom + clearance, 0.0))


func _vector3(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


func _fail(message: String) -> void:
	failures.append(message)
	push_error(message)
	quit(1)

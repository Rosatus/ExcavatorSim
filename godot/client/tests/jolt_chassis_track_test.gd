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
	var legacy_data := descriptor.to_dictionary()
	var legacy_tracks := (legacy_data["tracks"] as Dictionary).duplicate(true)
	for field in ["drive_effort_slew_n_per_tick", "brake_effort_slew_n_per_tick", "acceleration_window_s", "brake_stop_window_s", "local_forward_axis"]:
		legacy_tracks.erase(field)
	legacy_data["tracks"] = legacy_tracks
	var legacy_dynamics := (legacy_data["chassis_dynamics"] as Dictionary).duplicate(true)
	legacy_dynamics.erase("spawn_yaw_rad")
	legacy_data["chassis_dynamics"] = legacy_dynamics
	var legacy_descriptor := PhysicsRigDescriptor.from_dictionary_for_test(legacy_data)
	if not legacy_descriptor.is_valid_for(model_id, model_version):
		failures.append("%s physics-rig-v1 compatibility rejected a descriptor without optional response fields: %s" % [model_id, legacy_descriptor.validation_error()])
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
	var settle_heave_sq_sum := 0.0
	var settle_tilt_sq_sum := 0.0
	var settle_min_y := INF
	var settle_max_y := -INF
	var settle_samples := 0
	for frame in SETTLE_FRAMES:
		await physics_frame
		if frame >= SETTLE_FRAMES / 2:
			var sample := runtime.get_status_snapshot()
			var sample_linear := sample["linear_velocity"] as Vector3
			var sample_angular := sample["angular_velocity"] as Vector3
			var sample_y := (sample["body_transform"] as Transform3D).origin.y
			settle_heave_sq_sum += sample_linear.y * sample_linear.y
			settle_tilt_sq_sum += sample_angular.x * sample_angular.x + sample_angular.z * sample_angular.z
			settle_min_y = minf(settle_min_y, sample_y)
			settle_max_y = maxf(settle_max_y, sample_y)
			settle_samples += 1
	var settled := runtime.get_status_snapshot()
	var settle_heave_rms := sqrt(settle_heave_sq_sum / float(settle_samples))
	var settle_tilt_rms := sqrt(settle_tilt_sq_sum / float(settle_samples))
	print(
		"jolt_chassis_track_test: %s settle heave_rms=%.4f tilt_rms=%.4f height_span=%.4f switches=%d support=(%.1f, %.1f) posture=%.3fdeg clearance=%.4f"
		% [
			model_id,
			settle_heave_rms,
			settle_tilt_rms,
			settle_max_y - settle_min_y,
			int(settled.get("hull_collision_switch_count", -1)),
			float(settled.get("left_support_load_n", 0.0)),
			float(settled.get("right_support_load_n", 0.0)),
			rad_to_deg(float(settled.get("posture_error_rad", 0.0))),
			float(settled.get("lowest_clearance_m", 0.0)),
		]
	)
	if settle_heave_rms > 0.08 or settle_tilt_rms > 0.08 or settle_max_y - settle_min_y > 0.08:
		failures.append(
			"%s did not settle without visible heave/pitch jitter: heave=%.4f tilt=%.4f span=%.4f"
			% [model_id, settle_heave_rms, settle_tilt_rms, settle_max_y - settle_min_y]
		)
	if int(settled.get("hull_collision_switch_count", 0)) > 1:
		failures.append("%s hull/probe support ownership oscillated during settle" % model_id)
	if not bool(settled["terrain_identity_valid"]):
		failures.append("%s did not accept current terrain identity" % model_id)
	if int(settled["left_contact_count"]) == 0 or int(settled["right_contact_count"]) == 0:
		failures.append("%s did not settle on both tracks: %s" % [model_id, settled])
	var expected_forward_axis := "+Z" if model_id == "sy205" else "-Z"
	if String(settled.get("local_forward_axis", "")) != expected_forward_axis:
		failures.append("%s did not expose its declared vehicle-forward axis" % model_id)
	var settled_body := settled["body_transform"] as Transform3D
	var vehicle_right := _vehicle_forward(descriptor, settled_body).cross(settled_body.basis.y.normalized()).normalized()
	var observed_sides := {"left": false, "right": false}
	for contact_value in settled.get("contacts", []):
		var contact := contact_value as Dictionary
		var side := String(contact.get("track_side", ""))
		if side not in ["left", "right"]:
			continue
		observed_sides[side] = true
		var side_distance := ((contact.get("point", settled_body.origin) as Vector3) - settled_body.origin).dot(vehicle_right)
		if (side == "left" and side_distance >= -0.2) or (side == "right" and side_distance <= 0.2):
			failures.append("%s %s track probes crossed the visual vehicle side: %.3f" % [model_id, side, side_distance])
	if not bool(observed_sides["left"]) or not bool(observed_sides["right"]):
		failures.append("%s did not publish both semantic track-side probe sets" % model_id)
	var expected_weight := float(descriptor.chassis_dynamics()["mass_kg"]) * 9.80665
	var support_load := float(settled.get("left_support_load_n", 0.0)) + float(settled.get("right_support_load_n", 0.0))
	if support_load < expected_weight * 0.65 or support_load > expected_weight * 1.35:
		failures.append("%s distributed support load is not near chassis weight: %.1f vs %.1f" % [model_id, support_load, expected_weight])
	var posture_error_deg := rad_to_deg(float(settled.get("posture_error_rad", INF)))
	var clearance := float(settled.get("lowest_clearance_m", NAN))
	var configured_clearance := float(descriptor.chassis_dynamics()["ground_clearance_m"])
	if not is_finite(posture_error_deg) or posture_error_deg > 2.0:
		failures.append("%s reset posture did not follow terrain normal: %.3f deg" % [model_id, posture_error_deg])
	if not is_finite(clearance) or absf(clearance - configured_clearance) > 0.02:
		failures.append("%s reset clearance missed configured ground clearance: %.4f vs %.4f" % [model_id, clearance, configured_clearance])
	for telemetry_value in [
		float(settled.get("left_support_load_n", NAN)),
		float(settled.get("right_support_load_n", NAN)),
		float(settled.get("left_slip_ratio", NAN)),
		float(settled.get("right_slip_ratio", NAN)),
	]:
		if not is_finite(telemetry_value):
			failures.append("%s reset emitted non-finite support/slip telemetry" % model_id)
	var neutral_probe_start := runtime.get_body_global_transform().origin
	runtime.set_commands(1.0, 1.0)
	for _frame in 10:
		await physics_frame
	if runtime.get_body_global_transform().origin.distance_to(neutral_probe_start) > 0.02:
		failures.append("%s moved before neutral track re-arm" % model_id)
	var start := runtime.get_body_global_transform()
	# Reset/model activation requires one explicit neutral track sample before motion.
	runtime.set_commands(0.0, 0.0)
	runtime.set_commands(1.0, 1.0)
	var drive_heave_sq_sum := 0.0
	var drive_tilt_sq_sum := 0.0
	var drive_min_y := INF
	var drive_max_y := -INF
	var drive_samples := 0
	for frame in DRIVE_FRAMES:
		await physics_frame
		if frame >= DRIVE_FRAMES - 60:
			var sample := runtime.get_status_snapshot()
			var sample_linear := sample["linear_velocity"] as Vector3
			var sample_angular := sample["angular_velocity"] as Vector3
			var sample_y := (sample["body_transform"] as Transform3D).origin.y
			drive_heave_sq_sum += sample_linear.y * sample_linear.y
			drive_tilt_sq_sum += sample_angular.x * sample_angular.x + sample_angular.z * sample_angular.z
			drive_min_y = minf(drive_min_y, sample_y)
			drive_max_y = maxf(drive_max_y, sample_y)
			drive_samples += 1
	var driven := runtime.get_status_snapshot()
	var drive_heave_rms := sqrt(drive_heave_sq_sum / float(drive_samples))
	var drive_tilt_rms := sqrt(drive_tilt_sq_sum / float(drive_samples))
	print(
		"jolt_chassis_track_test: %s drive heave_rms=%.4f tilt_rms=%.4f height_span=%.4f switches=%d velocity=%s"
		% [
			model_id,
			drive_heave_rms,
			drive_tilt_rms,
			drive_max_y - drive_min_y,
			int(driven.get("hull_collision_switch_count", -1)),
			driven["linear_velocity"],
		]
	)
	if drive_heave_rms > 0.12 or drive_tilt_rms > 0.12 or drive_max_y - drive_min_y > 0.12:
		failures.append(
			"%s straight drive retained visible heave/pitch jitter: heave=%.4f tilt=%.4f span=%.4f"
			% [model_id, drive_heave_rms, drive_tilt_rms, drive_max_y - drive_min_y]
		)
	if int(driven.get("hull_collision_switch_count", 0)) > 1:
		failures.append("%s hull/probe support ownership oscillated during straight drive" % model_id)
	var moved := runtime.get_body_global_transform().origin - start.origin
	if moved.dot(_vehicle_forward(descriptor, start)) < 0.15:
		failures.append("%s straight drive did not move forward: %s" % [model_id, moved])
	var max_speed := float(descriptor.chassis_dynamics()["max_linear_speed_m_s"])
	if (driven["linear_velocity"] as Vector3).length() > max_speed + 0.01:
		failures.append("%s exceeded the configured speed bound" % model_id)
	var track_tuning := descriptor.tracks()
	var acceleration_time := float(driven.get("acceleration_time_s", -1.0))
	if acceleration_time <= 0.0 or acceleration_time > float(track_tuning["acceleration_window_s"]):
		failures.append("%s acceleration missed its descriptor window: %.3f s" % [model_id, acceleration_time])
	if (driven["quality_flags"] as Array).has("linear_speed_clamped"):
		failures.append("%s acceleration relied on the linear velocity safety clamp" % model_id)
	if int(driven["peak_step_usec"]) > 10000:
		failures.append("%s track force step exceeded 10 ms: %s" % [model_id, driven["peak_step_usec"]])
	print("jolt_chassis_track_test: %s peak fixed step=%d usec" % [model_id, int(driven["peak_step_usec"])])
	var speed_before_brake := (driven["linear_velocity"] as Vector3).length()
	runtime.set_commands(0.0, 0.0)
	var previous_forward_speed := absf(float(driven.get("forward_speed_m_s", 0.0)))
	var previous_signed_speed := float(driven.get("forward_speed_m_s", 0.0))
	var brake_pitch_sq_sum := 0.0
	var brake_pitch_samples := 0
	var brake_pitch_sign_reversals := 0
	var previous_pitch_rate_sign := 0
	var brake_speed_violation := false
	for _frame in int(ceil(float(track_tuning["brake_stop_window_s"]) * 60.0)) + 15:
		await physics_frame
		var brake_sample := runtime.get_status_snapshot()
		var signed_forward_speed := float(brake_sample.get("forward_speed_m_s", 0.0))
		var current_forward_speed := absf(signed_forward_speed)
		if current_forward_speed > previous_forward_speed + 0.03:
			brake_speed_violation = true
		if signed_forward_speed < -0.02:
			brake_speed_violation = true
		previous_forward_speed = current_forward_speed
		if previous_signed_speed > 0.02 and signed_forward_speed < -0.02:
			brake_speed_violation = true
		previous_signed_speed = signed_forward_speed
		var brake_body := runtime.get_body_global_transform()
		var brake_forward := _vehicle_forward(descriptor, brake_body)
		var pitch := atan2(brake_forward.y, maxf(Vector2(brake_forward.x, brake_forward.z).length(), 0.001))
		var pitch_rate := float((brake_sample.get("angular_velocity", Vector3.ZERO) as Vector3).dot(brake_body.basis.x))
		brake_pitch_sq_sum += pitch * pitch
		brake_pitch_samples += 1
		var pitch_rate_sign := signi(pitch_rate) if absf(pitch_rate) > 0.02 else 0
		if pitch_rate_sign != 0 and previous_pitch_rate_sign != 0 and pitch_rate_sign != previous_pitch_rate_sign:
			brake_pitch_sign_reversals += 1
		if pitch_rate_sign != 0:
			previous_pitch_rate_sign = pitch_rate_sign
	if brake_speed_violation:
		failures.append("%s braking speed was not monotonic or crossed into reverse" % model_id)
	var brake_status := runtime.get_status_snapshot()
	var speed_after_brake := (brake_status["linear_velocity"] as Vector3).length()
	print(
		"jolt_chassis_track_test: %s brake speed %.4f -> %.4f linear=%s angular=%s contacts=(%d,%d) support=(%.1f,%.1f) switches=%d"
		% [
			model_id,
			speed_before_brake,
			speed_after_brake,
			brake_status["linear_velocity"],
			brake_status["angular_velocity"],
			int(brake_status["left_contact_count"]),
			int(brake_status["right_contact_count"]),
			float(brake_status["left_support_load_n"]),
			float(brake_status["right_support_load_n"]),
			int(brake_status.get("hull_collision_switch_count", -1)),
		]
	)
	if speed_after_brake >= speed_before_brake:
		failures.append("%s braking did not reduce chassis speed" % model_id)
	var brake_stop_time := float(brake_status.get("brake_stop_time_s", -1.0))
	if brake_stop_time <= 0.0 or brake_stop_time > float(track_tuning["brake_stop_window_s"]):
		failures.append("%s braking missed its descriptor stop window: %.3f s" % [model_id, brake_stop_time])
	var brake_stop_distance := float(brake_status.get("brake_stop_distance_m", NAN))
	if not is_finite(brake_stop_distance) or brake_stop_distance > maxf(0.2, speed_before_brake * float(track_tuning["brake_stop_window_s"]) * 1.5):
		failures.append("%s braking stop distance was unbounded: %.3f m" % [model_id, brake_stop_distance])
	if float(brake_status.get("peak_pitch_angle_rad", INF)) > 0.12 or float(brake_status.get("peak_pitch_rate_rad_s", INF)) > 0.65:
		failures.append("%s hard braking exceeded pitch response bounds" % model_id)
	var brake_pitch_rms := sqrt(brake_pitch_sq_sum / float(maxi(brake_pitch_samples, 1)))
	if brake_pitch_rms > 0.06 or brake_pitch_sign_reversals > 2:
		failures.append("%s hard braking had sustained/repeating pitch response: rms=%.4f reversals=%d" % [model_id, brake_pitch_rms, brake_pitch_sign_reversals])
	# Reverse must first brake the existing forward motion through a bounded zero crossing.
	runtime.set_commands(0.0, 0.0)
	runtime.set_commands(1.0, 1.0)
	for _frame in 60:
		await physics_frame
	var previous_reverse_speed := float(runtime.get_status_snapshot().get("forward_speed_m_s", 0.0))
	var reverse_crossed_zero := false
	runtime.set_commands(-1.0, -1.0)
	for _frame in 120:
		await physics_frame
		var reverse_speed := float(runtime.get_status_snapshot().get("forward_speed_m_s", 0.0))
		if not reverse_crossed_zero and reverse_speed < -0.05 and previous_reverse_speed > 0.05:
			failures.append("%s reversed through zero without a bounded transition" % model_id)
		if absf(reverse_speed) <= 0.05:
			reverse_crossed_zero = true
		previous_reverse_speed = reverse_speed
	if not reverse_crossed_zero:
		failures.append("%s reverse transition never observed the bounded zero-crossing window" % model_id)
	if float(runtime.get_status_snapshot().get("forward_speed_m_s", 0.0)) > -0.3:
		failures.append("%s reverse command did not complete its bounded zero crossing" % model_id)

	runtime.reset(spawn)
	for _frame in 30:
		await physics_frame
	var pivot_start := runtime.get_body_global_transform()
	runtime.set_commands(0.0, 0.0)
	runtime.set_commands(-1.0, 1.0)
	for _frame in DRIVE_FRAMES:
		await physics_frame
	var pivot_end := runtime.get_body_global_transform()
	var heading_change := _vehicle_forward(descriptor, pivot_start).angle_to(_vehicle_forward(descriptor, pivot_end))
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
	var slope_settled := runtime.get_status_snapshot()
	if float(slope_settled.get("terrain_normal_alignment_deg", INF)) > 3.0:
		failures.append("slope reset posture did not follow TerrainState normal")
	if int(slope_settled.get("hull_collision_switch_count", 0)) > 1:
		failures.append("slope reset oscillated hull/probe support ownership")
	var start := runtime.get_body_global_transform()
	runtime.set_commands(0.0, 0.0)
	runtime.set_commands(1.0, 1.0)
	var partial_support_observed := false
	for _frame in 360:
		await physics_frame
		var slope_sample := runtime.get_status_snapshot()
		if int(slope_sample.get("left_contact_count", 0)) < 4 or int(slope_sample.get("right_contact_count", 0)) < 4:
			partial_support_observed = true
		for telemetry_value in [float(slope_sample.get("left_slip_ratio", NAN)), float(slope_sample.get("right_slip_ratio", NAN)), float(slope_sample.get("left_support_load_n", NAN)), float(slope_sample.get("right_support_load_n", NAN))]:
			if not is_finite(telemetry_value):
				failures.append("slope traversal emitted non-finite partial-support telemetry")
	if not partial_support_observed:
		print("jolt_chassis_track_test: slope did not expose a partial contact tick; bilateral support remained available")
	var finish := runtime.get_body_global_transform()
	var status := runtime.get_status_snapshot()
	var forward_distance := (finish.origin - start.origin).dot(_vehicle_forward(descriptor, start))
	print(
		"jolt_chassis_track_test: slope start=%s finish=%s forward=%.3f linear=%s angular=%s contacts=(%d,%d) support=(%.1f,%.1f) switches=%d flags=%s"
		% [
			start.origin,
			finish.origin,
			forward_distance,
			status["linear_velocity"],
			status["angular_velocity"],
			int(status["left_contact_count"]),
			int(status["right_contact_count"]),
			float(status["left_support_load_n"]),
			float(status["right_support_load_n"]),
			int(status.get("hull_collision_switch_count", -1)),
			status["quality_flags"],
		]
	)
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
	if (-start.basis.z).dot(Vector3.BACK) < 0.99:
		failures.append("SY205 authoritative spawn did not apply its 180-degree heading: %s" % start.basis)
	chassis.set_commands_for_test(1.0, 1.0)
	for _frame in 120:
		await physics_frame
	var controller_forward := initial.get("vehicle_forward_world", Vector3.FORWARD) as Vector3
	if (chassis.global_position - start.origin).dot(controller_forward) < 0.08:
		failures.append("authoritative controller did not follow the Jolt body")
	chassis.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await physics_frame
	var unfocused := chassis.get_status_snapshot()
	if not is_zero_approx(float(unfocused["left_command"])) or not is_zero_approx(float(unfocused["right_command"])):
		failures.append("focus loss did not disarm authoritative tracks")
	chassis.set_test_input_focus_bypass_for_test(true)
	chassis.set_commands_for_test(0.7, 0.7)
	chassis.set_equipment_commands_for_test(Vector4(0.0, 0.0, 0.0, 1.0))
	for _frame in 20:
		await physics_frame
	var automated := chassis.get_status_snapshot()
	if not is_equal_approx(float(automated["left_command"]), 0.7) or not is_equal_approx(float(automated["right_command"]), 0.7):
		failures.append("focus-independent automation did not retain authoritative track commands")
	var automated_joints := automated.get("joints", []) as Array
	if automated_joints.size() != 4 or float((automated_joints[3] as Dictionary).get("target_position_rad", 0.0)) <= 0.0:
		failures.append("focus-independent automation did not retain equipment commands")
	chassis.set_test_input_focus_bypass_for_test(false)
	await physics_frame
	var bypass_disabled := chassis.get_status_snapshot()
	if not is_zero_approx(float(bypass_disabled["left_command"])) or not is_zero_approx(float(bypass_disabled["right_command"])):
		failures.append("disabling the automation focus bypass did not restore focus safety")
	chassis.clear_commands_for_test()
	chassis.clear_equipment_commands_for_test()
	chassis.set_commands_for_test(0.7, 0.7)
	await physics_frame
	var setter_after_cleanup := chassis.get_status_snapshot()
	if not is_zero_approx(float(setter_after_cleanup["left_command"])) or not is_zero_approx(float(setter_after_cleanup["right_command"])):
		failures.append("test setters bypassed focus safety after automation cleanup")
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
		var switch_start := chassis.global_position
		var switch_forward := switched.get("vehicle_forward_world", Vector3.FORWARD) as Vector3
		chassis.set_commands_for_test(1.0, 1.0)
		for _frame in 10:
			await physics_frame
		if (chassis.global_position - switch_start).dot(switch_forward) > 0.02:
			failures.append("model switch allowed motion before neutral re-arm")
		chassis.set_commands_for_test(0.0, 0.0)
		chassis.set_commands_for_test(1.0, 1.0)
		for _frame in 60:
			await physics_frame
		if (chassis.global_position - switch_start).dot(switch_forward) < 0.04:
			failures.append("model switch neutral re-arm did not restore movement")
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
		if not (truth.get("quality_flags", []) as Array).has("jolt_chassis_kinematic_articulation_authority"):
			failures.append("authoritative truth did not declare hybrid authority")
		if (truth.get("quality_flags", []) as Array).has("work_equipment_frozen_phase1"):
			failures.append("authoritative truth retained the Phase 1 frozen-equipment flag")
		if (
			(truth.get("bodies", []) as Array).size() != 1
			or (truth.get("kinematic_frames", []) as Array).size() != 4
			or (truth.get("joints", []) as Array).size() != 4
		):
			failures.append("authoritative truth omitted hybrid body, frame, or joint state")
		for joint_value in truth.get("joints", []):
			if not (joint_value as Dictionary).has_all(["target_position_rad", "target_velocity_rad_s", "position_rad", "velocity_rad_s", "effort_n"]):
				failures.append("authoritative truth omitted target/actual/effort joint telemetry")
		if not (truth.get("quality_flags", []) as Array).has("bucket_query_contact_evidence"):
			failures.append("authoritative truth did not identify query-only bucket contacts")
		var truth_query := truth.get("bucket_query", {}) as Dictionary
		if not truth_query.has_all([
			"accepted_fraction", "previous_bucket_transform", "candidate_bucket_transform",
			"accepted_bucket_transform", "authority_epoch", "physics_tick", "motion_sequence",
			"terrain_generation", "terrain_revision",
		]):
			failures.append("authoritative truth omitted bucket motion/query identity")
		elif (
			String(truth_query.get("authority_epoch", "")) != String(truth.get("authority_epoch", ""))
			or int(truth_query.get("physics_tick", -1)) != int(truth.get("physics_tick", -2))
		):
			failures.append("authoritative truth bucket query does not share the post-step epoch/tick")
		var truth_payload := truth.get("payload", {}) as Dictionary
		if not truth_payload.has("motion_load_factor"):
			failures.append("authoritative truth omitted payload motion load factor")
		if not truth.has_all(["soil_interaction_batch", "queued_chassis_wrench", "applied_chassis_wrench"]):
			failures.append("authoritative truth omitted soil batch or support wrench state")
	var publisher_status := publisher.get_status_snapshot()
	if not bool(publisher_status.get("publishing", false)) or bool(publisher_status.get("transport_publishing", true)):
		failures.append("authoritative truth publisher exposed the wrong local/transport status")
	client.connection_state = MotionClient.STATE_READY
	client.negotiated_optional_capabilities = ["simulation_truth_shadow_v1"]
	publisher._physics_process(0.0)
	if bool(client.get_status_snapshot().get("shadow_truth_pending", false)):
		failures.append("authoritative truth was queued onto the shadow transport")
	var first_truth := publisher.get_last_snapshot()
	var first_epoch := String(first_truth.get("authority_epoch", ""))
	var first_sequence := int(first_truth.get("sequence", -1))
	client.authority_changed.emit("new-session", "new-simulation", 7)
	var unchanged := publisher.build_snapshot()
	if unchanged == null:
		failures.append("authoritative truth did not survive an observational Python authority change")
	else:
		var unchanged_data := unchanged.to_dictionary()
		if (
			String(unchanged_data.get("authority_epoch", "")) != first_epoch
			or int(unchanged_data.get("sequence", -1)) <= first_sequence
		):
			failures.append("Python authority change reset the local Jolt epoch/sequence")
	client.pose_cleared.emit(8, "authoritative_runtime_reset")
	await physics_frame
	var rotated_data := publisher.get_last_snapshot()
	if rotated_data.is_empty():
		failures.append("authoritative truth did not rebuild after a Jolt runtime reset")
	elif String(rotated_data.get("authority_epoch", "")) == first_epoch or int(rotated_data.get("sequence", -1)) != 0:
		failures.append("Jolt runtime reset did not start a fresh truth epoch/sequence")

	chassis.set_controller_enabled(false)
	await physics_frame
	if not bool(chassis.get_status_snapshot().get("configured", false)):
		failures.append("disabling input destroyed the physics authority body")
	if chassis._configure_model("unknown-model"):
		failures.append("unknown model unexpectedly configured a Jolt runtime")
	await physics_frame
	if bool(chassis.get_status_snapshot().get("configured", false)):
		failures.append("failed model switch retained an active Jolt runtime")
	if not chassis._configure_model("sy205"):
		failures.append("controller teardown fixture could not restore a Jolt runtime")
		host.queue_free()
		return
	for _frame in 3:
		await physics_frame
	var retiring_runtime: JoltChassisTrackRuntime = null
	for child in host.get_children():
		if child is JoltChassisTrackRuntime:
			retiring_runtime = child
			break
	if retiring_runtime == null:
		failures.append("controller teardown fixture did not create a Jolt runtime")
		host.queue_free()
		return
	root.remove_child(host)
	for _frame in 3:
		await process_frame
	if is_instance_valid(retiring_runtime):
		failures.append("controller parent removal retained the deferred Jolt runtime")
	host.queue_free()
	for _frame in 4:
		await physics_frame


func _spawn_transform(descriptor: PhysicsRigDescriptor, terrain_world: TerrainWorld) -> Transform3D:
	var data := descriptor.to_dictionary()
	var dynamics := data["chassis_dynamics"] as Dictionary
	var state := terrain_world.terrain_state
	var spacing := state.spacing_m
	var left_height := state.sample_surface_bilinear_at(Vector2(-spacing, 0.0))
	var right_height := state.sample_surface_bilinear_at(Vector2(spacing, 0.0))
	var rear_height := state.sample_surface_bilinear_at(Vector2(0.0, -spacing))
	var front_height := state.sample_surface_bilinear_at(Vector2(0.0, spacing))
	var terrain_normal := Vector3((left_height - right_height) / (2.0 * spacing), 1.0, (rear_height - front_height) / (2.0 * spacing)).normalized()
	var forward := Vector3.FORWARD.slide(terrain_normal).normalized()
	var basis := Basis(forward.cross(terrain_normal).normalized(), terrain_normal, -forward).orthonormalized()
	var spawn_yaw := float(dynamics.get("spawn_yaw_rad", 0.0))
	basis = (basis * Basis(Vector3.UP, spawn_yaw)).orthonormalized()
	var clearance := float(dynamics["ground_clearance_m"])
	var surface_y := terrain_world.terrain_state.sample_surface_bilinear_at(Vector2.ZERO)
	var tracks := data["tracks"] as Dictionary
	var stiffness := float(tracks.get("support_stiffness_n_per_m", 0.0))
	var probe_count := maxi(1, int(tracks.get("traction_points_per_side", 1)) * 2)
	var support_sag := clampf(float(dynamics["mass_kg"]) * 9.80665 / (stiffness * float(probe_count)), 0.0, 0.12) if stiffness > 0.0 else 0.0
	var minimum_bottom := INF
	var required_origin_y := -INF
	for shape in dynamics["compound_shapes"]:
		var center := _vector3(shape["center_m"])
		var half := 0.5 * _vector3(shape["size_m"])
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					var offset := basis * (center + Vector3(sx * half.x, sy * half.y, sz * half.z))
					minimum_bottom = minf(minimum_bottom, offset.y)
					var corner_ground := state.sample_surface_bilinear_at(Vector2(offset.x, offset.z))
					if is_finite(corner_ground):
						required_origin_y = maxf(required_origin_y, corner_ground + clearance + support_sag - offset.y)
	return Transform3D(basis, Vector3(0.0, required_origin_y if not is_inf(required_origin_y) else surface_y - minimum_bottom + clearance + support_sag, 0.0))


func _vehicle_forward(descriptor: PhysicsRigDescriptor, body_transform: Transform3D) -> Vector3:
	var local_axis := String(descriptor.tracks().get("local_forward_axis", "-Z"))
	return (body_transform.basis.z if local_axis == "+Z" else -body_transform.basis.z).normalized()


func _vector3(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


func _fail(message: String) -> void:
	failures.append(message)
	push_error(message)
	quit(1)

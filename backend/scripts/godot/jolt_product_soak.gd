extends SceneTree

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const READY_TIMEOUT_SECONDS := 20.0
const QUALITY_PROFILES := ["low", "balanced", "high"]
const REPORT_SCHEMA_VERSION := "excavator-sim-jolt-product-soak-godot-v2"

var _model_id := "sy205"
var _quality_profile := "balanced"
var _endpoint := "ws://127.0.0.1:8765/ws"
var _report_path := "user://jolt-product-soak.json"
var _duration_seconds := 90.0
var _warmup_seconds := 15.0
var _allow_incomplete_scenario := false
var _failures: Array[String] = []


func _init() -> void:
	if not _parse_arguments():
		quit(2)
		return
	call_deferred("_run")


func _run() -> void:
	var packed := load(MAIN_SCENE_PATH) as PackedScene
	if packed == null:
		_finish({}, "main scene is unavailable")
		return
	var scene := packed.instantiate() as Node3D
	var client := scene.get_node("MotionClient") as MotionClient
	var chassis := scene.get_node("ChassisMotionRoot") as TrackedChassisController
	var quality := scene.get_node_or_null("VisualQualityController") as VisualQualityController
	if quality == null:
		_finish({}, "visual quality controller is unavailable")
		return
	client.endpoint = _endpoint
	client.desired_model_id = _model_id
	chassis.set_test_input_focus_bypass_for_test(true)
	quality.profile = _quality_profile
	root.add_child(scene)
	DisplayServer.window_set_title("ExcavatorSim soak - %s/%s" % [_model_id, _quality_profile])
	DisplayServer.window_set_size(Vector2i(1280, 720))
	# Measure renderer throughput rather than the display's 60 Hz wait interval.
	# Product VSync settings remain untouched because this script runs in its own process.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	if not await _wait_until_ready(scene, client):
		_finish({}, "product scene did not become ready")
		return
	var quality_snapshot := quality.get_quality_snapshot()
	var quality_contract_clean := (
		String(quality_snapshot.get("profile", "")) == _quality_profile
		and bool(quality_snapshot.get("applied", false))
		and String(quality_snapshot.get("last_error", "")).is_empty()
	)
	if not quality_contract_clean:
		_failures.append("visual quality contract mismatch: %s" % quality_snapshot)
	var excavation := scene.get_node("TerrainRoot/ExcavationWorld") as ExcavationWorld
	var terrain_world := scene.get_node("TerrainRoot/TerrainWorld") as TerrainWorld
	var presentation := scene.get_node("MotionPresentation") as MotionPresentation
	client.request_start()
	await _wait_for_lifecycle(client, "running")
	var started_usec := Time.get_ticks_usec()
	var previous_frame_usec := started_usec
	var last_physics_tick := -1
	var render_samples: Array[float] = []
	var fixed_samples: Array[float] = []
	var interaction_counts := {}
	var maximum_payload_mass_kg := 0.0
	var support_frames := 0
	var maximum_runtime_count := 0
	var start_transform := chassis.global_transform
	var maximum_track_displacement_m := 0.0
	var maximum_joint_motion := 0.0
	var minimum_cutting_clearance_m := INF
	var maximum_query_contacts := 0
	var blocked_reasons := {}
	var query_quality_counts := {}
	var runtime_quality_counts := {}
	var contact_role_counts := {}
	var initial_overlap_role_counts := {}
	var classification_counts := {}
	var maximum_cutting_sweep_m := 0.0
	var maximum_cutting_sweep_with_contact_m := 0.0
	var maximum_cutting_descent_with_contact_m := 0.0
	var phase_diagnostics := {}
	var initial_joints: Array = []
	var joint_extrema := {}
	var joints_at_minimum_clearance: Array = []
	var cutting_position_at_minimum_clearance := Vector3.ZERO
	var reset_completed := false
	var reconnect_completed := false
	var reset_started := false
	var reconnect_started := false
	while float(Time.get_ticks_usec() - started_usec) / 1_000_000.0 < _duration_seconds:
		var elapsed := float(Time.get_ticks_usec() - started_usec) / 1_000_000.0
		var phase_name := _scenario_phase_name(elapsed)
		if not phase_diagnostics.has(phase_name):
			phase_diagnostics[phase_name] = {
				"frames": 0, "interactions": {}, "query_valid_frames": 0,
				"quality_flags": {}, "runtime_quality_flags": {},
				"contact_roles": {}, "initial_overlap_roles": {},
				"maximum_cutting_sweep_m": 0.0, "maximum_valid_cutting_contact_sweep_m": 0.0,
				"maximum_valid_cutting_contact_descent_m": 0.0, "minimum_cutting_clearance_m": INF,
				"minimum_accepted_fraction": 1.0, "support_contact_samples": [],
				"runtime_support_diagnostics": [],
				"maximum_opening_down_dot": -INF, "last_joints": [],
			}
		var phase_diag := phase_diagnostics[phase_name] as Dictionary
		phase_diag["frames"] = int(phase_diag["frames"]) + 1
		_apply_scenario(chassis, elapsed)
		if not reset_started and elapsed >= _duration_seconds * 0.45:
			reset_started = true
			client.request_reset()
			excavation.reset_for_test()
			await physics_frame
			chassis.set_equipment_commands_for_test(Vector4.ZERO)
			await physics_frame
			client.request_start()
			reset_completed = await _wait_for_lifecycle(client, "running")
			previous_frame_usec = Time.get_ticks_usec()
		if not reconnect_started and elapsed >= _duration_seconds * 0.72:
			reconnect_started = true
			client.disconnect_from_service()
			await create_timer(0.5).timeout
			client.reconnect_now()
			reconnect_completed = await _wait_until_ready(scene, client)
			if reconnect_completed:
				chassis.set_equipment_commands_for_test(Vector4.ZERO)
				await physics_frame
				client.request_start()
				await _wait_for_lifecycle(client, "running")
			previous_frame_usec = Time.get_ticks_usec()
		await process_frame
		var now_usec := Time.get_ticks_usec()
		if elapsed >= _warmup_seconds:
			render_samples.append(float(now_usec - previous_frame_usec) / 1000.0)
		var status := chassis.get_status_snapshot()
		maximum_track_displacement_m = maxf(maximum_track_displacement_m, chassis.global_position.distance_to(start_transform.origin))
		var physics_tick := int(status.get("physics_tick", -1))
		if elapsed >= _warmup_seconds and physics_tick >= 0 and physics_tick != last_physics_tick:
			fixed_samples.append(float(status.get("last_step_usec", 0)) / 1000.0)
		last_physics_tick = physics_tick
		previous_frame_usec = now_usec
		var soil := excavation.get_status_snapshot()
		var interaction := String(soil.get("interaction_state", "idle"))
		interaction_counts[interaction] = int(interaction_counts.get(interaction, 0)) + 1
		var phase_interactions := phase_diag["interactions"] as Dictionary
		phase_interactions[interaction] = int(phase_interactions.get(interaction, 0)) + 1
		var batch := soil.get("soil_interaction_batch", {}) as Dictionary
		for classification_value in batch.get("classifications", []):
			var classification := String((classification_value as Dictionary).get("classification", "unknown"))
			classification_counts[classification] = int(classification_counts.get(classification, 0)) + 1
		if interaction == "blocked":
			var blocked_reason := "classification"
			if not bool(batch.get("query_identity_valid", false)):
				blocked_reason = "query_identity"
			elif bool(batch.get("duplicate", false)):
				blocked_reason = "duplicate"
			blocked_reasons[blocked_reason] = int(blocked_reasons.get(blocked_reason, 0)) + 1
		var query := status.get("bucket_query", {}) as Dictionary
		var runtime_support_diagnostics := phase_diag["runtime_support_diagnostics"] as Array
		for diagnostic_value in query.get("support_diagnostics", []):
			if runtime_support_diagnostics.size() >= 32:
				break
			runtime_support_diagnostics.append((diagnostic_value as Dictionary).duplicate(true))
		phase_diag["minimum_accepted_fraction"] = minf(
			float(phase_diag["minimum_accepted_fraction"]), float(query.get("accepted_fraction", 1.0))
		)
		for flag_value in status.get("quality_flags", []):
			var flag := String(flag_value)
			runtime_quality_counts[flag] = int(runtime_quality_counts.get(flag, 0)) + 1
			var phase_runtime_flags := phase_diag["runtime_quality_flags"] as Dictionary
			phase_runtime_flags[flag] = int(phase_runtime_flags.get(flag, 0)) + 1
		if bool(query.get("valid", false)):
			phase_diag["query_valid_frames"] = int(phase_diag["query_valid_frames"]) + 1
		var query_contacts := query.get("contacts", []) as Array
		maximum_query_contacts = maxi(maximum_query_contacts, query_contacts.size())
		for flag_value in query.get("quality_flags", []):
			var flag := String(flag_value)
			query_quality_counts[flag] = int(query_quality_counts.get(flag, 0)) + 1
			var phase_flags := phase_diag["quality_flags"] as Dictionary
			phase_flags[flag] = int(phase_flags.get(flag, 0)) + 1
		for contact_value in query_contacts:
			var contact := contact_value as Dictionary
			var role := String(contact.get("proxy_role", "unknown"))
			contact_role_counts[role] = int(contact_role_counts.get(role, 0)) + 1
			var phase_roles := phase_diag["contact_roles"] as Dictionary
			phase_roles[role] = int(phase_roles.get(role, 0)) + 1
			if bool(contact.get("initial_overlap", false)):
				initial_overlap_role_counts[role] = int(initial_overlap_role_counts.get(role, 0)) + 1
				var phase_overlaps := phase_diag["initial_overlap_roles"] as Dictionary
				phase_overlaps[role] = int(phase_overlaps.get(role, 0)) + 1
		var joints := status.get("joints", []) as Array
		phase_diag["last_joints"] = joints.duplicate(true)
		_update_joint_extrema(joint_extrema, joints)
		var bucket_pose := soil.get("bucket_pose", {}) as Dictionary
		if bool(bucket_pose.get("valid", false)):
			var opening_normal := bucket_pose.get("opening_normal_world", Vector3.UP) as Vector3
			phase_diag["maximum_opening_down_dot"] = maxf(
				float(phase_diag["maximum_opening_down_dot"]), opening_normal.dot(Vector3.DOWN)
			)
			var previous_pose := bucket_pose.get("previous", {}) as Dictionary
			var current_pose := bucket_pose.get("current", {}) as Dictionary
			for contact_value in query_contacts:
				var contact := contact_value as Dictionary
				var role := String(contact.get("proxy_role", ""))
				if (
					["shell", "rear_support"].has(role)
					and not bool(contact.get("initial_overlap", false))
					and previous_pose.has(role) and current_pose.has(role)
				):
					var normal := contact.get("normal_world", Vector3.UP) as Vector3
					var movement := (current_pose[role] as Transform3D).origin - (previous_pose[role] as Transform3D).origin
					var support_samples := phase_diag["support_contact_samples"] as Array
					if support_samples.size() < 16:
						support_samples.append({
							"role": role,
							"travel_fraction": float(contact.get("travel_fraction", 1.0)),
							"accepted_fraction": float(query.get("accepted_fraction", 1.0)),
							"normal_up_dot": normal.normalized().dot(Vector3.UP),
							"motion_into_surface_m": -movement.dot(normal.normalized()),
						})
			if previous_pose.has("cutting_edge") and current_pose.has("cutting_edge"):
				var previous_cutting := previous_pose["cutting_edge"] as Transform3D
				var cutting := current_pose["cutting_edge"] as Transform3D
				var cutting_movement := cutting.origin - previous_cutting.origin
				maximum_cutting_sweep_m = maxf(maximum_cutting_sweep_m, cutting_movement.length())
				phase_diag["maximum_cutting_sweep_m"] = maxf(float(phase_diag["maximum_cutting_sweep_m"]), cutting_movement.length())
				var has_cutting_contact := false
				for contact_value in query_contacts:
					var contact := contact_value as Dictionary
					if String(contact.get("proxy_role", "")) == "cutting_edge" and not bool(contact.get("initial_overlap", false)):
						has_cutting_contact = true
						break
				if has_cutting_contact:
					maximum_cutting_sweep_with_contact_m = maxf(maximum_cutting_sweep_with_contact_m, cutting_movement.length())
					maximum_cutting_descent_with_contact_m = maxf(maximum_cutting_descent_with_contact_m, -cutting_movement.y)
					if bool(query.get("valid", false)):
						phase_diag["maximum_valid_cutting_contact_sweep_m"] = maxf(
							float(phase_diag["maximum_valid_cutting_contact_sweep_m"]), cutting_movement.length()
						)
						phase_diag["maximum_valid_cutting_contact_descent_m"] = maxf(
							float(phase_diag["maximum_valid_cutting_contact_descent_m"]), -cutting_movement.y
						)
				var surface_y := terrain_world.terrain_state.sample_surface_bilinear_at(Vector2(cutting.origin.x, cutting.origin.z))
				if not is_nan(surface_y):
					var clearance := cutting.origin.y - surface_y
					phase_diag["minimum_cutting_clearance_m"] = minf(float(phase_diag["minimum_cutting_clearance_m"]), clearance)
					if clearance < minimum_cutting_clearance_m:
						minimum_cutting_clearance_m = clearance
						joints_at_minimum_clearance = joints.duplicate(true)
						cutting_position_at_minimum_clearance = cutting.origin
		maximum_payload_mass_kg = maxf(maximum_payload_mass_kg, float(soil.get("payload_mass_kg", 0.0)))
		support_frames = maxi(support_frames, int(status.get("support_wrench_apply_count", 0)))
		maximum_runtime_count = maxi(maximum_runtime_count, _runtime_count(scene))
		if initial_joints.is_empty() and not joints.is_empty():
			initial_joints = joints.duplicate(true)
		elif joints.size() == initial_joints.size():
			for index in joints.size():
				maximum_joint_motion = maxf(
					maximum_joint_motion,
					absf(float((joints[index] as Dictionary).get("position_rad", 0.0)) - float((initial_joints[index] as Dictionary).get("position_rad", 0.0)))
				)
		var last_error := client.get_status_snapshot().get("last_error", {}) as Dictionary
		if not last_error.is_empty():
			_failures.append("motion client error: %s" % last_error)
			break
	chassis.clear_commands_for_test()
	chassis.clear_equipment_commands_for_test()
	var final_status := chassis.get_status_snapshot()
	var final_contract_clean := (
		String(final_status.get("authority_profile", "")) == AuthorityProfile.JOLT_AUTHORITATIVE
		and String(final_status.get("model_id", "")) == _model_id
		and String(final_status.get("contract_error", "")).is_empty()
		and presentation.get_active_model_id() == _model_id
		and quality_contract_clean
	)
	var contract_report := {
		"clean": final_contract_clean and _failures.is_empty(),
		"authority_profile": final_status.get("authority_profile", ""),
		"active_model_id": presentation.get_active_model_id(),
		"maximum_runtime_count": maximum_runtime_count,
		"failures": _failures.duplicate(),
	}
	var report := {
		"schema_version": REPORT_SCHEMA_VERSION,
		"model_id": _model_id,
		"requested_quality_profile": _quality_profile,
		"observed_quality_profile": String(quality_snapshot.get("profile", "")),
		"quality": quality_snapshot,
		"duration_seconds": _duration_seconds,
		"warmup_seconds": _warmup_seconds,
		"metrics": {
			"fixed_step_p95_ms": _percentile(fixed_samples, 0.95),
			"fixed_step_peak_ms": _maximum(fixed_samples),
			"render_frame_p95_ms": _percentile(render_samples, 0.95),
			"render_frame_p99_ms": _percentile(render_samples, 0.99),
			"render_sample_count": render_samples.size(),
			"fixed_sample_count": fixed_samples.size(),
			"engine_fps": Performance.get_monitor(Performance.TIME_FPS),
			"static_memory_bytes": Performance.get_monitor(Performance.MEMORY_STATIC),
			"node_count": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			"physics_active_objects": Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
			"physics_collision_pairs": Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS),
		},
		"contract": contract_report,
		"scenario": {
			"interaction_counts": interaction_counts,
			"cut_frames": int(interaction_counts.get("cut", 0)),
			"dump_frames": int(interaction_counts.get("dump", 0)) + int(interaction_counts.get("spill", 0)),
			"support_frames": support_frames,
			"blocked_reasons": blocked_reasons,
			"query_quality_counts": query_quality_counts,
			"runtime_quality_counts": runtime_quality_counts,
			"contact_role_counts": contact_role_counts,
			"initial_overlap_role_counts": initial_overlap_role_counts,
			"classification_counts": classification_counts,
			"maximum_cutting_sweep_m": maximum_cutting_sweep_m,
			"maximum_cutting_sweep_with_contact_m": maximum_cutting_sweep_with_contact_m,
			"maximum_cutting_descent_with_contact_m": maximum_cutting_descent_with_contact_m,
			"phase_diagnostics": phase_diagnostics,
			"maximum_query_contacts": maximum_query_contacts,
			"minimum_cutting_clearance_m": minimum_cutting_clearance_m,
			"cutting_position_at_minimum_clearance": _vector3_array(cutting_position_at_minimum_clearance),
			"joints_at_minimum_clearance": joints_at_minimum_clearance,
			"joint_extrema_rad": joint_extrema,
			"maximum_payload_mass_kg": maximum_payload_mass_kg,
			"track_motion_observed": maximum_track_displacement_m > 0.1,
			"maximum_track_displacement_m": maximum_track_displacement_m,
			"articulation_observed": maximum_joint_motion > 0.05,
			"maximum_joint_motion_rad": maximum_joint_motion,
			"reset_completed": reset_completed,
			"reconnect_completed": reconnect_completed,
		},
	}
	if not _allow_incomplete_scenario:
		for required in ["cut", "dump"]:
			if int(interaction_counts.get(required, 0)) == 0 and not (required == "dump" and int(interaction_counts.get("spill", 0)) > 0):
				_failures.append("scenario did not observe %s" % required)
		if maximum_payload_mass_kg <= 0.0:
			_failures.append("scenario never carried a payload")
		if support_frames == 0:
			_failures.append("scenario never applied a support wrench")
		contract_report["failures"] = _failures.duplicate()
		contract_report["clean"] = final_contract_clean and _failures.is_empty()
	_finish(report)


func _wait_until_ready(scene: Node3D, client: MotionClient) -> bool:
	var deadline := Time.get_ticks_msec() + int(READY_TIMEOUT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var chassis := scene.get_node("ChassisMotionRoot") as TrackedChassisController
		var status := chassis.get_status_snapshot()
		if (
			client.connection_state == MotionClient.STATE_READY
			and client.active_model_id == _model_id
			and bool(status.get("configured", false))
			and String(status.get("model_id", "")) == _model_id
		):
			return true
	return false


func _wait_for_lifecycle(client: MotionClient, expected: String) -> bool:
	var deadline := Time.get_ticks_msec() + int(READY_TIMEOUT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if client.confirmed_lifecycle == expected:
			return true
	return false


func _apply_scenario(chassis: TrackedChassisController, elapsed: float) -> void:
	var phase := fmod(elapsed, 34.0)
	var tracks := Vector2.ZERO
	var target_pose := Vector4.ZERO
	if phase < 2.0:
		pass
	elif phase < 4.2:
		target_pose = _scenario_pose("approach_arm")
	elif phase < 5.6:
		target_pose = _scenario_pose("approach_bucket")
	elif phase < 8.0:
		target_pose = _scenario_pose("approach")
	elif phase < 11.0:
		target_pose = _scenario_pose("cut")
	elif phase < 14.0:
		target_pose = _scenario_pose("recovery_clear")
	elif phase < 19.0:
		target_pose = _scenario_pose("carry")
	elif phase < 23.0:
		target_pose = _scenario_pose("dump")
	elif phase < 26.0:
		target_pose = _scenario_pose("support_clear")
	elif phase < 29.0:
		target_pose = _scenario_pose("support")
	elif phase < 32.0:
		tracks = Vector2(0.6, 0.6)
	elif phase < 34.0:
		tracks = Vector2(0.45, -0.45)
	chassis.set_commands_for_test(tracks.x, tracks.y)
	chassis.set_equipment_commands_for_test(_commands_toward(chassis, target_pose))


func _scenario_phase_name(elapsed: float) -> String:
	var phase := fmod(elapsed, 34.0)
	if phase < 2.0: return "neutral"
	if phase < 8.0: return "approach"
	if phase < 11.0: return "cut"
	if phase < 19.0: return "carry"
	if phase < 23.0: return "dump"
	if phase < 26.0: return "support_clear"
	if phase < 29.0: return "support"
	if phase < 32.0: return "track_drive"
	return "track_turn"


func _scenario_pose(name: String) -> Vector4:
	if _model_id == "sy135":
		match name:
			"approach_arm": return Vector4(0.0, 0.0, -0.5127, 0.0)
			"approach_bucket": return Vector4(0.0, 0.0, -0.5127, 0.589)
			"approach": return Vector4(0.0, -0.1666, -0.5127, 0.589)
			"cut": return Vector4(0.0, -0.2166, -0.5877, 0.739)
			"recovery_clear": return Vector4(0.0, -0.1745, -0.5984, 0.7293)
			"carry": return Vector4(0.0, 0.2, 0.4, 0.5)
			"dump": return Vector4(0.0, -0.1309, -0.1309, -0.1745)
			"support_clear": return Vector4.ZERO
			"support": return Vector4(0.0, -0.2618, -0.1309, -0.4363)
	match name:
		"approach_arm": return Vector4(0.0, 0.0, -0.6763, 0.0)
		"approach_bucket": return Vector4(0.0, 0.0, -0.6763, -0.1964)
		"approach": return Vector4(0.0, 0.3094, -0.6763, -0.1964)
		"cut": return Vector4(0.0, 0.3344, -0.5513, -0.4964)
		"carry": return Vector4.ZERO
		"dump": return Vector4(0.0, 0.1, 0.2, 0.785)
		"support_clear": return Vector4.ZERO
		"support": return Vector4(0.0, 0.611, -0.1305, 0.628)
	return Vector4.ZERO


func _commands_toward(chassis: TrackedChassisController, target: Vector4) -> Vector4:
	var positions := Vector4.ZERO
	var velocities := Vector4.ZERO
	var joints := (chassis.get_status_snapshot().get("joints", []) as Array)
	for joint_value in joints:
		var joint := joint_value as Dictionary
		match String(joint.get("name", "")):
			"swing_joint":
				positions.x = float(joint.get("position_rad", 0.0))
				velocities.x = float(joint.get("velocity_rad_s", 0.0))
			"boom_joint":
				positions.y = float(joint.get("position_rad", 0.0))
				velocities.y = float(joint.get("velocity_rad_s", 0.0))
			"arm_joint":
				positions.z = float(joint.get("position_rad", 0.0))
				velocities.z = float(joint.get("velocity_rad_s", 0.0))
			"bucket_joint":
				positions.w = float(joint.get("position_rad", 0.0))
				velocities.w = float(joint.get("velocity_rad_s", 0.0))
	var error := target - positions
	var maximum_velocities := Vector4(0.6, 0.35, 0.45, 0.55)
	var commands := Vector4.ZERO
	for index in 4:
		if absf(error[index]) < 0.004 and absf(velocities[index]) < 0.01:
			commands[index] = 0.0
		else:
			commands[index] = clampf(
				error[index] * 12.0 - velocities[index] * 3.0 / maximum_velocities[index],
				-1.0,
				1.0,
			)
	return commands


func _runtime_count(scene: Node3D) -> int:
	var count := 0
	for child in scene.get_children():
		if child is JoltChassisTrackRuntime:
			count += 1
	return count


func _update_joint_extrema(extrema: Dictionary, joints: Array) -> void:
	for joint_value in joints:
		var joint := joint_value as Dictionary
		var name := String(joint.get("name", ""))
		var position := float(joint.get("position_rad", 0.0))
		if name.is_empty():
			continue
		if not extrema.has(name):
			extrema[name] = {"minimum": position, "maximum": position}
			continue
		var bounds := extrema[name] as Dictionary
		bounds["minimum"] = minf(float(bounds.get("minimum", position)), position)
		bounds["maximum"] = maxf(float(bounds.get("maximum", position)), position)


func _vector3_array(value: Vector3) -> Array[float]:
	return [value.x, value.y, value.z]


func _percentile(values: Array[float], percentile: float) -> float:
	if values.is_empty():
		return INF
	var sorted := values.duplicate()
	sorted.sort()
	var index := clampi(int(ceil(percentile * float(sorted.size()))) - 1, 0, sorted.size() - 1)
	return sorted[index]


func _maximum(values: Array[float]) -> float:
	var result := 0.0
	for value in values:
		result = maxf(result, value)
	return result if not values.is_empty() else INF


func _finish(report: Dictionary, error := "") -> void:
	if not error.is_empty():
		_failures.append(error)
		report = {
			"schema_version": REPORT_SCHEMA_VERSION,
			"model_id": _model_id,
			"requested_quality_profile": _quality_profile,
			"observed_quality_profile": "",
			"quality": {},
			"metrics": {},
			"scenario": {},
			"contract": {"clean": false, "maximum_runtime_count": 0, "failures": _failures.duplicate()},
		}
	var file := FileAccess.open(_report_path, FileAccess.WRITE)
	if file == null:
		push_error("could not write soak report: %s" % _report_path)
		quit(2)
		return
	file.store_string(JSON.stringify(report, "  ") + "\n")
	file.close()
	quit(0 if bool((report.get("contract", {}) as Dictionary).get("clean", false)) else 1)


func _parse_arguments() -> bool:
	var arguments := OS.get_cmdline_user_args()
	var index := 0
	while index < arguments.size():
		var argument := String(arguments[index])
		if argument == "--allow-incomplete-scenario":
			_allow_incomplete_scenario = true
			index += 1
			continue
		if index + 1 >= arguments.size():
			push_error("missing value for %s" % argument)
			return false
		var value := String(arguments[index + 1])
		match argument:
			"--model": _model_id = value
			"--quality-profile": _quality_profile = value
			"--endpoint": _endpoint = value
			"--report": _report_path = value
			"--duration-seconds": _duration_seconds = value.to_float()
			"--warmup-seconds": _warmup_seconds = value.to_float()
			_:
				push_error("unknown soak argument: %s" % argument)
				return false
		index += 2
	return (
		["sy205", "sy135"].has(_model_id)
		and QUALITY_PROFILES.has(_quality_profile)
		and _duration_seconds > 0.0
		and _warmup_seconds >= 0.0
		and _warmup_seconds < _duration_seconds
	)

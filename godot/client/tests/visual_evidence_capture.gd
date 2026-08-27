extends RefCounted

const SCHEMA_VERSION := "excavator-sim-visual-evidence-v2"
const MODELS := ["sy205", "sy135"]
const QUALITY_PROFILES := ["low", "balanced", "high"]
const CORE_CHECKPOINTS := ["carry", "dump", "terrain", "support"]
const BALANCED_CHECKPOINTS := [
	"startup", "controls-visible", "travel", "dig", "carry", "dump", "terrain", "support",
	"reset",
]
const JOINT_NAMES := ["swing_joint", "boom_joint", "arm_joint", "bucket_joint"]
const MAXIMUM_VELOCITIES := Vector4(0.6, 0.35, 0.45, 0.55)
const SETTLE_FRAMES := 120
const CAPTURE_WIDTH := 1920
const CAPTURE_HEIGHT := 1080


func expected_checkpoints(quality_profile: String) -> Array[String]:
	var checkpoints: Array[String] = []
	if quality_profile == "balanced":
		checkpoints.append_array(BALANCED_CHECKPOINTS)
	else:
		checkpoints.append_array(CORE_CHECKPOINTS)
	return checkpoints


func expected_matrix_capture_count() -> int:
	var count := 0
	for _model_id in MODELS:
		for quality_profile in QUALITY_PROFILES:
			count += expected_checkpoints(quality_profile).size()
	return count


func configure_product_for_capture(
	scene: Node3D, model_id: String, quality_profile: String
) -> Dictionary:
	if not MODELS.has(model_id) or not QUALITY_PROFILES.has(quality_profile):
		return {"ok": false, "reason": "unsupported_model_or_quality"}
	var nodes := _required_nodes(scene)
	if not bool(nodes.get("ok", false)):
		return nodes
	var session := nodes["session"] as ProductSession
	var client := nodes["client"] as MotionClient
	var chassis := nodes["chassis"] as TrackedChassisController
	var quality := nodes["quality"] as VisualQualityController
	var presentation := nodes["presentation"] as MotionPresentation
	if session.gateway_enabled:
		return {"ok": false, "reason": "offline_product_session_required"}
	if client.connection_state != MotionClient.STATE_DISCONNECTED:
		return {"ok": false, "reason": "offline_transport_must_remain_disconnected"}
	if not session.request_model_switch(model_id):
		return {
			"ok": false,
			"reason": "model_switch_failed",
			"session": session.get_status_snapshot(),
		}
	if presentation.get_active_model_id() != model_id or not quality.apply_profile(quality_profile):
		return {"ok": false, "reason": "model_or_quality_mismatch"}
	var camera := scene.get_node_or_null("Camera3D") as CameraRig
	if camera != null:
		camera.distance_m = minf(12.0, camera.max_distance_m)
	chassis.set_test_input_focus_bypass_for_test(true)
	if not session.request_reset():
		return {"ok": false, "reason": "offline_reset_failed"}
	session.set_focused(true)
	for _frame in SETTLE_FRAMES:
		await scene.get_tree().physics_frame
	chassis.set_commands_for_test(0.0, 0.0)
	chassis.set_equipment_commands_for_test(Vector4.ZERO)
	await scene.get_tree().physics_frame
	var session_snapshot := session.get_status_snapshot()
	var quality_snapshot := quality.get_quality_snapshot()
	var configuration_ok := (
		String(session_snapshot.get("lifecycle", "")) == ProductSession.LIFECYCLE_STOPPED
		and String(session_snapshot.get("active_model_id", "")) == model_id
		and String(session_snapshot.get("session_id", "")) == ProductSession.LOCAL_SESSION_ID
		and not bool(session_snapshot.get("gateway_enabled", true))
		and String(quality_snapshot.get("profile", "")) == quality_profile
		and bool(quality_snapshot.get("applied", false))
		and String(quality_snapshot.get("last_error", "")).is_empty()
	)
	return {
		"ok": configuration_ok,
		"reason": "" if configuration_ok else "offline_product_configuration_mismatch",
		"session": session_snapshot,
		"quality": quality_snapshot,
		"authority": chassis.get_status_snapshot(),
	}


func release_product_after_capture(scene: Node3D) -> void:
	var chassis := scene.get_node_or_null("ChassisMotionRoot") as TrackedChassisController
	var session := scene.get_node_or_null("ProductSession") as ProductSession
	if chassis != null:
		chassis.clear_commands_for_test()
		chassis.clear_equipment_commands_for_test()
		chassis.set_test_input_focus_bypass_for_test(false)
	if session != null:
		session.request_reset()


func capture(
	scene: Node3D,
	model_id: String,
	quality_profile: String,
	output_dir: String,
	run_context: Dictionary = {},
) -> Dictionary:
	var directory_error := DirAccess.make_dir_recursive_absolute(output_dir)
	if directory_error != OK:
		return {
			"ok": false,
			"reason": "output_directory_failed",
			"error": error_string(directory_error),
		}
	var configured := await configure_product_for_capture(scene, model_id, quality_profile)
	if not bool(configured.get("ok", false)):
		release_product_after_capture(scene)
		return configured
	var session := scene.get_node("ProductSession") as ProductSession
	var chassis := scene.get_node("ChassisMotionRoot") as TrackedChassisController
	var excavation := scene.get_node("TerrainRoot/ExcavationWorld") as ExcavationWorld
	var quality := scene.get_node("VisualQualityController") as VisualQualityController
	var evidence_phase := String(run_context.get("evidence_phase", "before"))
	var checkpoints: Array[Dictionary] = []
	var journey_trace: Array[Dictionary] = []

	if quality_profile == "balanced":
		var startup_window := _begin_performance_window()
		await _wait_physics(scene, 30)
		var startup_checkpoint := (
			await _capture_checkpoint(
				scene, output_dir, model_id, quality_profile, "startup", startup_window,
				excavation.get_status_snapshot()
			)
		)
		startup_checkpoint["state_achieved"] = (
			String((startup_checkpoint.get("session", {}) as Dictionary).get("lifecycle", ""))
			== ProductSession.LIFECYCLE_STOPPED
		)
		checkpoints.append(startup_checkpoint)
		var controls_status := await controls_visible_status(scene)
		var controls_window := _begin_performance_window()
		await _wait_process(scene, 5)
		var controls_checkpoint := (
			await _capture_checkpoint(
				scene, output_dir, model_id, quality_profile, "controls-visible", controls_window,
				excavation.get_status_snapshot()
			)
		)
		controls_checkpoint["controls"] = controls_status
		controls_checkpoint["state_achieved"] = bool(controls_status.get("achieved", false))
		if not bool(controls_checkpoint["state_achieved"]):
			controls_checkpoint["finding"] = String(
				controls_status.get("finding", "essential operator controls are not discoverable")
			)
		checkpoints.append(controls_checkpoint)

	if not session.request_start():
		release_product_after_capture(scene)
		return {"ok": false, "reason": "offline_start_failed"}
	session.set_focused(true)
	await _wait_physics(scene, 30)

	if quality_profile == "balanced":
		var travel_window := _begin_performance_window()
		var travel_origin := chassis.global_position
		chassis.set_commands_for_test(0.4, 0.4)
		await _wait_physics(scene, 45)
		var travel_checkpoint := (
			await _capture_checkpoint(
				scene, output_dir, model_id, quality_profile, "travel", travel_window,
				excavation.get_status_snapshot()
			)
		)
		travel_checkpoint["travel_distance_m"] = chassis.global_position.distance_to(travel_origin)
		travel_checkpoint["state_achieved"] = (
			float(travel_checkpoint["travel_distance_m"]) >= 0.05
		)
		checkpoints.append(travel_checkpoint)
		chassis.set_commands_for_test(0.0, 0.0)
		await _wait_physics(scene, 20)

	var dig_window := _begin_performance_window()
	var terrain_status_before_dig := excavation.get_status_snapshot()
	var terrain_revision_before_dig := int(
		(terrain_status_before_dig.get("terrain_commit", {}) as Dictionary).get(
			"last_flush_revision", -1
		)
	)
	await _move_to(scene, chassis, _pose(model_id, "approach_arm"), 100)
	journey_trace.append(_journey_sample(chassis, excavation, "approach_arm"))
	await _move_to(scene, chassis, _pose(model_id, "approach_bucket"), 100)
	journey_trace.append(_journey_sample(chassis, excavation, "approach_bucket"))
	await _move_to(scene, chassis, _pose(model_id, "approach"), 120)
	journey_trace.append(_journey_sample(chassis, excavation, "approach"))
	var contact_outcome := await _move_to_ground_contact(
		scene, chassis, excavation, model_id, -0.04, 180
	)
	journey_trace.append(_journey_sample(chassis, excavation, "ground_contact"))
	if quality_profile == "balanced":
		var dig_checkpoint := (
			await _capture_checkpoint(
				scene, output_dir, model_id, quality_profile, "dig", dig_window,
				excavation.get_status_snapshot()
			)
		)
		var dig_status := dig_checkpoint.get("simulation", {}) as Dictionary
		dig_checkpoint["state_achieved"] = (
			bool(contact_outcome.get("achieved", false))
			and (
			String(dig_status.get("interaction_state", "")) in ["cut", "side_cut", "scrape", "grade"]
			or int(dig_status.get("terrain_revision", -1)) > terrain_revision_before_dig
			)
		)
		dig_checkpoint["ground_contact"] = contact_outcome
		checkpoints.append(dig_checkpoint)

	var capture_outcome := await _wait_for_payload_capture(
		scene, chassis, excavation, _pose(model_id, "scoop"), 180
	)
	journey_trace.append(_journey_sample(chassis, excavation, "capture_wait"))

	var carry_window := _begin_performance_window()
	await _move_to(scene, chassis, _pose(model_id, "carry"), 240)
	journey_trace.append(_journey_sample(chassis, excavation, "carry"))
	var carry_checkpoint := (
		await _capture_checkpoint(
			scene, output_dir, model_id, quality_profile, "carry", carry_window,
			excavation.get_status_snapshot()
		)
	)
	carry_checkpoint["capture_outcome"] = capture_outcome
	carry_checkpoint["state_achieved"] = (
		float((carry_checkpoint.get("simulation", {}) as Dictionary).get("payload_mass_kg", 0.0))
		> 0.1
	)
	if not bool(carry_checkpoint["state_achieved"]):
		carry_checkpoint["finding"] = "dig attempt did not produce a visible carried payload"
	checkpoints.append(carry_checkpoint)

	var dump_window := _begin_performance_window()
	var payload_before_dump := float(
		(carry_checkpoint.get("simulation", {}) as Dictionary).get("payload_mass_kg", 0.0)
	)
	var dump_status := await _move_until_dump(
		scene, chassis, excavation, _pose(model_id, "dump"), 300, payload_before_dump
	)
	journey_trace.append(_journey_sample(chassis, excavation, "dump"))
	var dump_checkpoint := (
		await _capture_checkpoint(
			scene, output_dir, model_id, quality_profile, "dump", dump_window, dump_status
		)
	)
	var payload_after_dump := float(
		(dump_checkpoint.get("simulation", {}) as Dictionary).get("payload_mass_kg", 0.0)
	)
	dump_checkpoint["payload_before_dump_kg"] = payload_before_dump
	dump_checkpoint["state_achieved"] = (
		payload_before_dump > 0.1
		and payload_after_dump < payload_before_dump - 0.1
	)
	if not bool(dump_checkpoint["state_achieved"]):
		dump_checkpoint["finding"] = "dump stage lacked a nonzero payload-to-release transition"
	checkpoints.append(dump_checkpoint)

	var terrain_window := _begin_performance_window()
	await _move_to(scene, chassis, _pose(model_id, "dump"), 120)
	await _move_to(scene, chassis, _pose(model_id, "support_clear"), 180)
	var terrain_checkpoint := (
		await _capture_checkpoint(
			scene, output_dir, model_id, quality_profile, "terrain", terrain_window,
			excavation.get_status_snapshot()
		)
	)
	terrain_checkpoint["state_achieved"] = (
		int((terrain_checkpoint.get("simulation", {}) as Dictionary).get("terrain_revision", -1))
		> terrain_revision_before_dig
	)
	if not bool(terrain_checkpoint["state_achieved"]):
		terrain_checkpoint["finding"] = "dig journey produced no persistent terrain revision"
	checkpoints.append(terrain_checkpoint)

	var support_window := _begin_performance_window()
	var support_wrench := await _move_until_support(
		scene, chassis, _pose(model_id, "support"), 240
	)
	var support_status := excavation.get_status_snapshot()
	var support_checkpoint := await _capture_checkpoint(
		scene, output_dir, model_id, quality_profile, "support", support_window, support_status
	)
	support_checkpoint["support_wrench"] = support_wrench
	support_checkpoint["support_case"] = "bucket-ground support/contact transfer"
	support_checkpoint["state_achieved"] = (
		not support_wrench.is_empty()
		or not (
			(support_checkpoint.get("simulation", {}) as Dictionary).get("support_contact", {})
			as Dictionary
		).is_empty()
	)
	if not bool(support_checkpoint["state_achieved"]):
		support_checkpoint["finding"] = "support pose produced no support contact or wrench"
	checkpoints.append(support_checkpoint)

	if quality_profile == "balanced":
		var reset_window := _begin_performance_window()
		session.request_reset()
		await _wait_physics(scene, SETTLE_FRAMES)
		var reset_checkpoint := (
			await _capture_checkpoint(
				scene, output_dir, model_id, quality_profile, "reset", reset_window,
				excavation.get_status_snapshot()
			)
		)
		reset_checkpoint["state_achieved"] = (
			String((reset_checkpoint.get("session", {}) as Dictionary).get("lifecycle", ""))
			== ProductSession.LIFECYCLE_STOPPED
		)
		checkpoints.append(reset_checkpoint)

	var quality_snapshot := quality.get_quality_snapshot()
	var authority_snapshot := chassis.get_status_snapshot()
	var expected := expected_checkpoints(quality_profile)
	var observed: Array[String] = []
	var capture_errors: Array[String] = []
	var scenario_findings: Array[Dictionary] = []
	for checkpoint in checkpoints:
		var checkpoint_name := String(checkpoint.get("checkpoint", ""))
		observed.append(checkpoint_name)
		if not bool(checkpoint.get("ok", false)):
			var validation_errors := checkpoint.get("validation_errors", []) as Array
			if validation_errors.is_empty():
				capture_errors.append(checkpoint_name)
			else:
				for validation_error in validation_errors:
					capture_errors.append("%s:%s" % [checkpoint_name, validation_error])
		if not bool(checkpoint.get("state_achieved", false)):
			scenario_findings.append({
				"checkpoint": checkpoint_name,
				"finding": checkpoint.get("finding", "checkpoint state was not achieved"),
			})
	for checkpoint_name in expected:
		if not observed.has(checkpoint_name):
			capture_errors.append("missing:%s" % checkpoint_name)
	var evidence_ok := (
		capture_errors.is_empty()
		and bool(quality_snapshot.get("applied", false))
		and String(quality_snapshot.get("profile", "")) == quality_profile
		and String(quality_snapshot.get("last_error", "")) == ""
		and String(authority_snapshot.get("authority_profile", "")) == "jolt_authoritative"
		and String(session.get_status_snapshot().get("session_id", ""))
		== ProductSession.LOCAL_SESSION_ID
	)
	if evidence_phase == "after" and not scenario_findings.is_empty():
		evidence_ok = false
	var result := {
		"schema_version": SCHEMA_VERSION,
		"ok": evidence_ok,
		"reason": "" if evidence_ok else "capture_contract_failed",
		"evidence_phase": evidence_phase,
		"capture_errors": capture_errors,
		"all_scenarios_achieved": scenario_findings.is_empty(),
		"scenario_findings": scenario_findings,
		"model_id": model_id,
		"quality_profile": quality_profile,
		"expected_checkpoints": expected,
		"artifact_count": checkpoints.size(),
		"authority_profile": authority_snapshot.get("authority_profile", ""),
		"soil_authority_mode": _compact_status(
			excavation.get_status_snapshot()
		).get("soil_authority_mode", "unknown"),
		"session": _compact_session(session.get_status_snapshot()),
		"quality": quality_snapshot,
		"run": _run_metadata(scene, run_context),
		"journey_trace": journey_trace,
		"checkpoints": checkpoints,
	}
	var metadata_path := "%s/%s-%s.json" % [output_dir, model_id, quality_profile]
	result["metadata_path"] = metadata_path
	if not write_json_file(metadata_path, result):
		result["ok"] = false
		result["reason"] = "metadata_write_failed"
	release_product_after_capture(scene)
	return result


func write_json_file(path: String, payload: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(payload, "  ") + "\n")
	var write_error := file.get_error()
	file.close()
	return write_error == OK


func validate_artifact_metadata(
	artifact: Dictionary,
	expected_width: int = CAPTURE_WIDTH,
	expected_height: int = CAPTURE_HEIGHT,
) -> Array[String]:
	var errors: Array[String] = []
	if not bool(artifact.get("saved", false)):
		errors.append("png_write_failed")
	if int(artifact.get("width", -1)) != expected_width:
		errors.append("width_mismatch")
	if int(artifact.get("height", -1)) != expected_height:
		errors.append("height_mismatch")
	if String(artifact.get("sha256", "")).is_empty():
		errors.append("sha256_missing")
	if not bool(artifact.get("visual_content", false)):
		errors.append("blank_or_uniform_render")
	return errors


func controls_visible_status(scene: Node3D) -> Dictionary:
	var ui := scene.get_node_or_null("OperatorUI") as MotionOperatorUI
	if ui == null:
		return {"achieved": false, "finding": "production operator UI is unavailable"}
	var guide := ui.get_node_or_null("GuidePanel") as Control
	var hint := ui.get_node_or_null("StatusPanel/Margin/VBox/ControlHint") as Label
	ui.show_control_guide()
	await scene.get_tree().process_frame
	var copy := _visible_label_copy(ui)
	var required := ["WASD", "IJKL", "R/F", "Y/H", "Tracks", "boom", "bucket", "Camera", "F8"]
	var missing: Array[String] = []
	for token in required:
		if token not in copy:
			missing.append(token)
	var achieved := (
		guide != null
		and guide.is_visible_in_tree()
		and hint != null
		and not hint.text.is_empty()
		and missing.is_empty()
	)
	return {
		"achieved": achieved,
		"guide_visible": guide != null and guide.is_visible_in_tree(),
		"prompt": hint.text if hint != null else "",
		"missing_tokens": missing,
		"finding": "" if achieved else "operator onboarding is missing: %s" % ", ".join(missing),
	}


func _visible_label_copy(node: Node) -> String:
	var values := PackedStringArray()
	_collect_visible_labels(node, values)
	return "\n".join(values)


func _collect_visible_labels(node: Node, values: PackedStringArray) -> void:
	if node is Label and (node as Label).is_visible_in_tree():
		values.append((node as Label).text)
	for child in node.get_children():
		_collect_visible_labels(child, values)


func _required_nodes(scene: Node3D) -> Dictionary:
	var session := scene.get_node_or_null("ProductSession") as ProductSession
	var client := scene.get_node_or_null("MotionClient") as MotionClient
	var chassis := scene.get_node_or_null("ChassisMotionRoot") as TrackedChassisController
	var excavation := scene.get_node_or_null("TerrainRoot/ExcavationWorld") as ExcavationWorld
	var quality := scene.get_node_or_null("VisualQualityController") as VisualQualityController
	var presentation := scene.get_node_or_null("MotionPresentation") as MotionPresentation
	if (
		session == null
		or client == null
		or chassis == null
		or excavation == null
		or quality == null
		or presentation == null
	):
		return {"ok": false, "reason": "required_product_node_missing"}
	return {
		"ok": true,
		"session": session,
		"client": client,
		"chassis": chassis,
		"excavation": excavation,
		"quality": quality,
		"presentation": presentation,
	}


func _capture_checkpoint(
	scene: Node3D,
	output_dir: String,
	model_id: String,
	quality_profile: String,
	label: String,
	performance_window: Dictionary,
	status: Dictionary,
) -> Dictionary:
	var performance := _finish_performance_window(performance_window)
	var artifact := await _save_frame(scene, output_dir, model_id, quality_profile, label)
	var simulation := _compact_status(status)
	var teeth := (simulation.get("tool_regions", {}) as Dictionary).get(
		"teeth_main_edge", {}
	) as Dictionary
	var teeth_center := teeth.get("center_world", Vector3.ZERO) as Vector3
	var chassis := scene.get_node_or_null("ChassisMotionRoot") as TrackedChassisController
	if chassis != null and not teeth.is_empty():
		var surface_y := chassis.sample_terrain_height_for_test(Vector2(teeth_center.x, teeth_center.z))
		simulation["teeth_surface_y"] = surface_y
		simulation["teeth_clearance_m"] = teeth_center.y - surface_y if is_finite(surface_y) else NAN
	return {
		"ok": bool(artifact.get("ok", false)),
		"validation_errors": artifact.get("validation_errors", []),
		"checkpoint": label,
		"artifact": artifact,
		"performance": performance,
		"session": _compact_session(
			(scene.get_node("ProductSession") as ProductSession).get_status_snapshot()
		),
		"simulation": simulation,
	}


func _begin_performance_window() -> Dictionary:
	return {
		"started_usec": Time.get_ticks_usec(),
		"render_frame": Engine.get_process_frames(),
		"physics_frame": Engine.get_physics_frames(),
	}


func _finish_performance_window(window: Dictionary) -> Dictionary:
	var elapsed_s := maxf(
		float(Time.get_ticks_usec() - int(window.get("started_usec", Time.get_ticks_usec())))
		/ 1_000_000.0,
		0.000001,
	)
	var render_frames := maxi(
		Engine.get_process_frames() - int(window.get("render_frame", Engine.get_process_frames())), 0
	)
	var physics_frames := maxi(
		Engine.get_physics_frames() - int(window.get("physics_frame", Engine.get_physics_frames())), 0
	)
	return {
		"sampling_window_s": elapsed_s,
		"render_frames": render_frames,
		"physics_frames": physics_frames,
		"mean_render_fps": float(render_frames) / elapsed_s,
		"mean_render_frame_ms": elapsed_s * 1000.0 / float(maxi(render_frames, 1)),
		"engine_fps": Performance.get_monitor(Performance.TIME_FPS),
		"process_time_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_process_time_ms": (
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		),
		"static_memory_bytes": Performance.get_monitor(Performance.MEMORY_STATIC),
		"node_count": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
	}


func _run_metadata(scene: Node3D, run_context: Dictionary) -> Dictionary:
	var viewport_size := scene.get_viewport().get_visible_rect().size
	return {
		"captured_at_utc": Time.get_datetime_string_from_system(true, false),
		"commit": String(run_context.get("commit", "unrecorded")),
		"capture_command": String(run_context.get("capture_command", "unrecorded")),
		"run_id": String(run_context.get("run_id", "unrecorded")),
		"evidence_phase": String(run_context.get("evidence_phase", "before")),
		"error_log_path": String(run_context.get("error_log_path", "unrecorded")),
		"godot": Engine.get_version_info(),
		"os": {"name": OS.get_name(), "version": OS.get_version()},
		"hardware": {
			"processor": OS.get_processor_name(),
			"video_adapter": RenderingServer.get_video_adapter_name(),
		},
		"resolution": [int(viewport_size.x), int(viewport_size.y)],
	}


func _move_to(
	scene: Node3D, chassis: TrackedChassisController, target: Vector4, frames: int
) -> void:
	for _frame in frames:
		chassis.set_equipment_commands_for_test(_equipment_commands_toward(chassis, target))
		await scene.get_tree().physics_frame


func _equipment_commands_toward(
	chassis: TrackedChassisController, target: Vector4
) -> Vector4:
	var positions := Vector4.ZERO
	var velocities := Vector4.ZERO
	for joint_value in chassis.get_status_snapshot().get("joints", []):
		var joint := joint_value as Dictionary
		var index := JOINT_NAMES.find(String(joint.get("name", "")))
		if index >= 0:
			positions[index] = float(joint.get("position_rad", 0.0))
			velocities[index] = float(joint.get("velocity_rad_s", 0.0))
	var error := target - positions
	var commands := Vector4.ZERO
	for index in 4:
		commands[index] = (
			0.0
			if absf(error[index]) < 0.004 and absf(velocities[index]) < 0.01
			else clampf(
				error[index] * 12.0
				- velocities[index] * 3.0 / MAXIMUM_VELOCITIES[index],
				-1.0,
				1.0,
			)
		)
	return commands


func _move_until_dump(
	scene: Node3D,
	chassis: TrackedChassisController,
	excavation: ExcavationWorld,
	target: Vector4,
	frames: int,
	payload_before_dump_kg: float,
) -> Dictionary:
	for _frame in frames:
		await _move_to(scene, chassis, target, 1)
		var status := excavation.get_status_snapshot()
		var payload_mass_kg := float(status.get("payload_mass_kg", payload_before_dump_kg))
		var bucket_position := _joint_position(chassis, "bucket_joint")
		if (
			payload_mass_kg <= maxf(0.1, payload_before_dump_kg * 0.1)
			and absf(bucket_position - target.w) <= 0.08
		):
			return status
	return excavation.get_status_snapshot()


func _joint_position(chassis: TrackedChassisController, joint_name: String) -> float:
	for value in chassis.get_status_snapshot().get("joints", []):
		var joint := value as Dictionary
		if String(joint.get("name", "")) == joint_name:
			return float(joint.get("position_rad", 0.0))
	return NAN


func _wait_for_payload_capture(
	scene: Node3D,
	chassis: TrackedChassisController,
	excavation: ExcavationWorld,
	target: Vector4,
	frames: int,
) -> Dictionary:
	for frame in frames:
		await _move_to(scene, chassis, target, 1)
		var status := excavation.get_status_snapshot()
		var payload_mass_kg := float(status.get("payload_mass_kg", 0.0))
		var bucket_position := _joint_position(chassis, "bucket_joint")
		if payload_mass_kg >= 1.0 and absf(bucket_position - target.w) <= 0.05:
			return {
				"achieved": true,
				"frames": frame + 1,
				"payload_mass_kg": payload_mass_kg,
				"interaction_state": status.get("interaction_state", ""),
			}
	var final_status := excavation.get_status_snapshot()
	return {
		"achieved": false,
		"frames": frames,
		"payload_mass_kg": final_status.get("payload_mass_kg", 0.0),
		"interaction_state": final_status.get("interaction_state", ""),
		"diagnostic": "active-soil capture timeout during the real scoop stroke",
	}


func _move_to_ground_contact(
	scene: Node3D,
	chassis: TrackedChassisController,
	excavation: ExcavationWorld,
	model_id: String,
	target_clearance_m: float,
	frames: int,
) -> Dictionary:
	var descent_sign := -1.0 if model_id == "sy135" else 1.0
	var target := _pose(model_id, "contact")
	for frame in frames:
		var clearance := _tooth_clearance(chassis, excavation)
		if is_finite(clearance) and absf(clearance - target_clearance_m) <= 0.02:
			chassis.set_equipment_commands_for_test(Vector4.ZERO)
			await scene.get_tree().physics_frame
			return {"achieved": true, "frames": frame + 1, "clearance_m": clearance}
		var commands := _equipment_commands_toward(chassis, target)
		var clearance_error := clearance - target_clearance_m
		commands.y = (
			descent_sign
			* signf(clearance_error)
			* clampf(absf(clearance_error) * 0.8, 0.18, 0.72)
		)
		chassis.set_equipment_commands_for_test(commands)
		await scene.get_tree().physics_frame
	var final_clearance := _tooth_clearance(chassis, excavation)
	return {
		"achieved": is_finite(final_clearance) and absf(final_clearance - target_clearance_m) <= 0.03,
		"frames": frames,
		"clearance_m": final_clearance,
	}


func _tooth_clearance(
	chassis: TrackedChassisController, excavation: ExcavationWorld
) -> float:
	var status := excavation.get_status_snapshot()
	var tool := ((status.get("bucket_pose", {}) as Dictionary).get("soil_tool", {}) as Dictionary)
	for value in tool.get("regions", []):
		var region := value as Dictionary
		if String(region.get("region_id", "")) != "teeth_main_edge":
			continue
		var center := region.get("current_center_world", Vector3.ZERO) as Vector3
		var surface := chassis.sample_terrain_height_for_test(Vector2(center.x, center.z))
		return center.y - surface if is_finite(surface) else NAN
	return NAN


func _move_until_support(
	scene: Node3D, chassis: TrackedChassisController, target: Vector4, frames: int
) -> Dictionary:
	for _frame in frames:
		await _move_to(scene, chassis, target, 1)
		var status := chassis.get_status_snapshot()
		var applied := status.get("applied_chassis_wrench", {}) as Dictionary
		var queued := status.get("queued_chassis_wrench", {}) as Dictionary
		if not applied.is_empty() or not queued.is_empty():
			return applied if not applied.is_empty() else queued
	return {}


func _save_frame(
	scene: Node3D, output_dir: String, model_id: String, quality_profile: String, label: String
) -> Dictionary:
	await RenderingServer.frame_post_draw
	var image := scene.get_viewport().get_texture().get_image()
	var path := "%s/%s-%s-%s.png" % [output_dir, model_id, quality_profile, label]
	var error := image.save_png(path)
	var artifact := {
		"saved": error == OK,
		"path": path,
		"error": "" if error == OK else error_string(error),
		"sha256": FileAccess.get_sha256(path) if error == OK else "",
		"width": image.get_width(),
		"height": image.get_height(),
		"visual_content": _image_has_visual_content(image),
	}
	var validation_errors := validate_artifact_metadata(artifact)
	artifact["validation_errors"] = validation_errors
	artifact["ok"] = validation_errors.is_empty()
	return artifact


func _image_has_visual_content(image: Image) -> bool:
	if image == null or image.is_empty() or image.get_width() <= 0 or image.get_height() <= 0:
		return false
	var step_x := maxi(image.get_width() / 32, 1)
	var step_y := maxi(image.get_height() / 32, 1)
	var minimum_luminance := INF
	var maximum_luminance := -INF
	var opaque_samples := 0
	for y in range(0, image.get_height(), step_y):
		for x in range(0, image.get_width(), step_x):
			var color := image.get_pixel(x, y)
			if color.a <= 0.01:
				continue
			opaque_samples += 1
			var luminance := color.get_luminance()
			minimum_luminance = minf(minimum_luminance, luminance)
			maximum_luminance = maxf(maximum_luminance, luminance)
	return opaque_samples > 0 and maximum_luminance - minimum_luminance >= 0.01


func _wait_physics(scene: Node3D, frames: int) -> void:
	for _frame in frames:
		await scene.get_tree().physics_frame


func _wait_process(scene: Node3D, frames: int) -> void:
	for _frame in frames:
		await scene.get_tree().process_frame


func _compact_session(status: Dictionary) -> Dictionary:
	return {
		"session_id": status.get("session_id", ""),
		"authority_epoch": status.get("authority_epoch", ""),
		"generation": status.get("generation", -1),
		"lifecycle": status.get("lifecycle", ""),
		"focused": status.get("focused", false),
		"active_model_id": status.get("active_model_id", ""),
		"gateway_enabled": status.get("gateway_enabled", true),
		"last_error": status.get("last_error", {}),
	}


func _compact_status(status: Dictionary) -> Dictionary:
	var terrain_commit := status.get("terrain_commit", {}) as Dictionary
	var active_patch := status.get("active_soil_patch", {}) as Dictionary
	var lifecycle := status.get("soil_lifecycle_active", {}) as Dictionary
	var tool_snapshot := (status.get("bucket_pose", {}) as Dictionary).get("soil_tool", {}) as Dictionary
	var tool_classification := (
		status.get("soil_interaction_batch", {}) as Dictionary
	).get("soil_tool_classification", {}) as Dictionary
	var soil_authority_mode := String(status.get("soil_authority_mode", ""))
	if soil_authority_mode.is_empty():
		soil_authority_mode = (
			"legacy_analytic_parcel"
			if bool(status.get("automatic_soil_enabled", false))
			else "legacy_manual_or_disabled"
		)
	return {
		"soil_authority_mode": soil_authority_mode,
		"interaction_state": status.get("interaction_state", ""),
		"payload_mass_kg": status.get("payload_mass_kg", 0.0),
		"bucket_volume_m3": status.get("bucket_volume_m3", 0.0),
		"active_patch": {
			"representative_count": active_patch.get("representative_count", 0),
			"contained_count": active_patch.get("contained_count", 0),
			"contained_volume_m3": active_patch.get("contained_volume_m3", 0.0),
			"active_volume_m3": active_patch.get("active_volume_m3", 0.0),
		},
		"soil_lifecycle": {
			"compartments_m3": lifecycle.get("compartments_m3", {}),
			"last_transaction": lifecycle.get("last_transaction", {}),
			"journal_size": lifecycle.get("journal_size", 0),
			"invariant_failure_count": lifecycle.get("invariant_failure_count", 0),
		},
		"tool_regions": _compact_tool_regions(tool_snapshot),
		"tool_classification": _compact_tool_classification(tool_classification),
		"terrain_revision": terrain_commit.get("last_flush_revision", -1),
		"support_contact": status.get("support_contact", {}),
	}


func _compact_tool_regions(tool_snapshot: Dictionary) -> Dictionary:
	var result := {}
	for value in tool_snapshot.get("regions", []):
		var region := value as Dictionary
		var region_id := String(region.get("region_id", ""))
		if region_id not in ["teeth_main_edge", "inner_shell", "opening"]:
			continue
		result[region_id] = {
			"center_world": region.get("current_center_world", Vector3.ZERO),
			"outward_normal_world": region.get("outward_normal_world", Vector3.UP),
		}
	return result


func _compact_tool_classification(classification: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value in classification.get("candidates", []):
		var candidate := value as Dictionary
		if String(candidate.get("classification", "none")) == "none":
			continue
		result.append({
			"region_id": candidate.get("region_id", ""),
			"classification": candidate.get("classification", "none"),
			"role_scope": candidate.get("role_scope", "none"),
			"penetration_m": candidate.get("penetration_m", 0.0),
			"motion_m": candidate.get("motion_m", 0.0),
		})
	return result


func _journey_sample(
	chassis: TrackedChassisController, excavation: ExcavationWorld, stage: String
) -> Dictionary:
	var simulation := _compact_status(excavation.get_status_snapshot())
	var teeth := (simulation.get("tool_regions", {}) as Dictionary).get(
		"teeth_main_edge", {}
	) as Dictionary
	var teeth_center := teeth.get("center_world", Vector3.ZERO) as Vector3
	var surface_y := chassis.sample_terrain_height_for_test(Vector2(teeth_center.x, teeth_center.z))
	return {
		"stage": stage,
		"teeth_surface_y": surface_y,
		"teeth_clearance_m": teeth_center.y - surface_y if is_finite(surface_y) else NAN,
		"chassis": _compact_chassis(chassis.get_status_snapshot()),
		"simulation": simulation,
	}


func _compact_chassis(status: Dictionary) -> Dictionary:
	var joints := {}
	for value in status.get("joints", []):
		var joint := value as Dictionary
		joints[String(joint.get("name", ""))] = {
			"position_rad": joint.get("position_rad", 0.0),
			"velocity_rad_s": joint.get("velocity_rad_s", 0.0),
			"target_velocity_rad_s": joint.get("target_velocity_rad_s", 0.0),
		}
	return {
		"enabled": status.get("enabled", false),
		"neutral_rearm_required": status.get("neutral_rearm_required", false),
		"joints": joints,
	}


func _pose(model_id: String, name: String) -> Vector4:
	if model_id == "sy135":
		match name:
			"approach_arm": return Vector4(0.0, 0.0, -0.5127, 0.0)
			"approach_bucket": return Vector4(0.0, 0.0, -0.5127, 0.589)
			"approach": return Vector4(0.0, -0.1666, -0.5127, 0.589)
			"contact": return Vector4(0.0, -0.1666, -0.5127, 0.589)
			"cut": return Vector4(0.0, -0.2166, -0.5877, 0.739)
			"scoop": return Vector4(0.0, 0.0, -0.2, 0.739)
			"carry": return Vector4(0.0, 0.2, 0.4, 0.5)
			"dump": return Vector4(0.0, -0.1309, -0.1309, -0.1745)
			"support_clear": return Vector4.ZERO
			"support": return Vector4(0.0, -0.2618, -0.1309, -0.4363)
	match name:
		"approach_arm": return Vector4(0.0, 0.0, -0.6763, 0.0)
		"approach_bucket": return Vector4(0.0, 0.0, -0.6763, -0.1964)
		"approach": return Vector4(0.0, 0.3094, -0.6763, -0.1964)
		"contact": return Vector4(0.0, 0.3094, -0.6763, -0.1964)
		"cut": return Vector4(0.0, 0.3344, -0.5513, -0.4964)
		"scoop": return Vector4(0.0, 0.28, -0.45, 0.45)
		"carry": return Vector4(0.0, 0.0, 0.0, 0.35)
		"support_clear": return Vector4.ZERO
		"dump": return Vector4(0.0, 0.1, 0.2, -1.57)
		"support": return Vector4(0.0, 0.611, -0.1305, 0.628)
	return Vector4.ZERO

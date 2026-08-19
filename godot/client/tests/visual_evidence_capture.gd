extends RefCounted

const JOINT_NAMES := ["swing_joint", "boom_joint", "arm_joint", "bucket_joint"]
const MAXIMUM_VELOCITIES := Vector4(0.6, 0.35, 0.45, 0.55)


func capture(scene: Node3D, model_id: String, quality_profile: String, output_dir: String) -> Dictionary:
	var client := scene.get_node("MotionClient") as MotionClient
	var chassis := scene.get_node("ChassisMotionRoot") as TrackedChassisController
	var excavation := scene.get_node("TerrainRoot/ExcavationWorld") as ExcavationWorld
	var quality := scene.get_node("VisualQualityController") as VisualQualityController
	var presentation := scene.get_node("MotionPresentation") as MotionPresentation
	if presentation.get_active_model_id() != model_id or not quality.apply_profile(quality_profile):
		return {"ok": false, "reason": "model_or_quality_mismatch"}
	DirAccess.make_dir_recursive_absolute(output_dir)
	var camera := scene.get_node_or_null("Camera3D") as CameraRig
	if camera != null:
		camera.distance_m = 12.0
	chassis.set_test_input_focus_bypass_for_test(true)
	client.request_reset()
	excavation.reset_for_test()
	for _frame in 120:
		await scene.get_tree().physics_frame
	chassis.set_equipment_commands_for_test(Vector4.ZERO)
	await scene.get_tree().physics_frame
	client.request_start()
	await scene.get_tree().create_timer(0.5).timeout

	await _move_to(scene, chassis, _pose(model_id, "approach_arm"), 100)
	await _move_to(scene, chassis, _pose(model_id, "approach_bucket"), 100)
	await _move_to(scene, chassis, _pose(model_id, "approach"), 120)
	await _move_to(scene, chassis, _pose(model_id, "cut"), 180)
	await _move_to(scene, chassis, _pose(model_id, "carry"), 240)
	var carry_status := excavation.get_status_snapshot()
	await _save_frame(scene, output_dir, model_id, quality_profile, "carry")

	var dump_status := await _move_until_dump(scene, chassis, excavation, _pose(model_id, "dump"), 240)
	await _save_frame(scene, output_dir, model_id, quality_profile, "dump")
	await _move_to(scene, chassis, _pose(model_id, "dump"), 120)
	await _move_to(scene, chassis, _pose(model_id, "support_clear"), 180)
	var terrain_status := excavation.get_status_snapshot()
	await _save_frame(scene, output_dir, model_id, quality_profile, "terrain")

	var support_wrench := await _move_until_support(scene, chassis, _pose(model_id, "support"), 240)
	var support_status := excavation.get_status_snapshot()
	await _save_frame(scene, output_dir, model_id, quality_profile, "support")
	var quality_snapshot := quality.get_quality_snapshot()
	var authority_snapshot := chassis.get_status_snapshot()
	var evidence_ok := (
		bool(quality_snapshot.get("applied", false))
		and String(quality_snapshot.get("profile", "")) == quality_profile
		and String(quality_snapshot.get("last_error", "")) == ""
		and String(authority_snapshot.get("authority_profile", "")) == "jolt_authoritative"
	)
	chassis.clear_commands_for_test()
	chassis.clear_equipment_commands_for_test()
	chassis.set_test_input_focus_bypass_for_test(false)
	var result := {
		"ok": evidence_ok,
		"model_id": model_id,
		"authority_profile": chassis.get_status_snapshot().get("authority_profile", ""),
		"quality": quality_snapshot,
		"carry": _compact_status(carry_status),
		"dump": _compact_status(dump_status),
		"terrain": _compact_status(terrain_status),
		"support": _compact_status(support_status),
		"support_wrench": support_wrench,
	}
	var metadata := FileAccess.open(
		"%s/%s-%s.json" % [output_dir, model_id, quality_profile], FileAccess.WRITE
	)
	if metadata != null:
		metadata.store_string(JSON.stringify(result, "  ") + "\n")
		metadata.close()
	return result


func _move_to(scene: Node3D, chassis: TrackedChassisController, target: Vector4, frames: int) -> void:
	for _frame in frames:
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
					error[index] * 12.0 - velocities[index] * 3.0 / MAXIMUM_VELOCITIES[index],
					-1.0,
					1.0,
				)
			)
		chassis.set_equipment_commands_for_test(commands)
		await scene.get_tree().physics_frame


func _move_until_dump(
	scene: Node3D,
	chassis: TrackedChassisController,
	excavation: ExcavationWorld,
	target: Vector4,
	frames: int,
) -> Dictionary:
	for _frame in frames:
		await _move_to(scene, chassis, target, 1)
		var status := excavation.get_status_snapshot()
		if String(status.get("interaction_state", "")) in ["dump", "spill"]:
			return status
	return excavation.get_status_snapshot()


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
) -> void:
	await RenderingServer.frame_post_draw
	var image := scene.get_viewport().get_texture().get_image()
	var path := "%s/%s-%s-%s.png" % [output_dir, model_id, quality_profile, label]
	if image.save_png(path) != OK:
		push_error("visual evidence capture failed: %s" % path)


func _compact_status(status: Dictionary) -> Dictionary:
	return {
		"interaction_state": status.get("interaction_state", ""),
		"payload_mass_kg": status.get("payload_mass_kg", 0.0),
		"terrain_revision": status.get("terrain_revision", -1),
		"support_contact": status.get("support_contact", {}),
	}


func _pose(model_id: String, name: String) -> Vector4:
	if model_id == "sy135":
		match name:
			"approach_arm": return Vector4(0.0, 0.0, -0.5127, 0.0)
			"approach_bucket": return Vector4(0.0, 0.0, -0.5127, 0.589)
			"approach": return Vector4(0.0, -0.1666, -0.5127, 0.589)
			"cut": return Vector4(0.0, -0.2166, -0.5877, 0.739)
			"carry": return Vector4(0.0, 0.2, 0.4, 0.5)
			"dump": return Vector4(0.0, -0.1309, -0.1309, -0.1745)
			"support_clear": return Vector4.ZERO
			"support": return Vector4(0.0, -0.2618, -0.1309, -0.4363)
	match name:
		"approach_arm": return Vector4(0.0, 0.0, -0.6763, 0.0)
		"approach_bucket": return Vector4(0.0, 0.0, -0.6763, -0.1964)
		"approach": return Vector4(0.0, 0.3094, -0.6763, -0.1964)
		"cut": return Vector4(0.0, 0.3344, -0.5513, -0.4964)
		"carry", "support_clear": return Vector4.ZERO
		"dump": return Vector4(0.0, 0.1, 0.2, 0.785)
		"support": return Vector4(0.0, 0.611, -0.1305, 0.628)
	return Vector4.ZERO

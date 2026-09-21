extends SceneTree

## SY80U activation smoke: catalog-driven presentation activation, the
## presentation-local boom-offset axis (E/U), soil contract wiring, and
## model-switch reset behavior.

const FIXTURE := "res://tests/fixtures/sy80u_frame_parity_cases.json"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := Node3D.new()
	get_root().add_child(host)
	var presentation_root := Node3D.new()
	presentation_root.name = "PresentationRoot"
	host.add_child(presentation_root)
	var client := MotionClient.new()
	client.name = "MotionClient"
	client.auto_connect = false
	client.auto_reconnect = false
	client.desired_model_id = "sy135"
	host.add_child(client)
	var presentation := MotionPresentation.new()
	presentation.name = "MotionPresentation"
	host.add_child(presentation)
	await process_frame

	if _check(presentation.get_contract_error().is_empty(), presentation.get_contract_error()) != 0:
		return _finish(host, 1)
	if _check(presentation.set_authority_profile_for_test(AuthorityProfile.PYTHON_KINEMATIC), "smoke test selects Python compatibility profile") != 0:
		return _finish(host, 1)

	# Shared model-keyed chassis-side profiles must accept the SY80U id.
	var shaper := DiggingResponseShaper.new()
	if _check(shaper.configure("sy80u"), "digging response profile rejects sy80u") != 0:
		return _finish(host, 1)
	var mapper := EquipmentCommandMapper.new()
	if _check(mapper.configure_model("sy80u"), "equipment command mapper rejects sy80u") != 0:
		return _finish(host, 1)
	if _check(mapper.get_model_id() == "sy80u", "equipment command mapper lost the requested model id") != 0:
		return _finish(host, 1)
	if _check(mapper.to_joint_axes(Vector4.ONE).is_equal_approx(Vector4(-1.0, 1.0, 1.0, -1.0)),
			"sy80u inherited the wrong joint signs") != 0:
		return _finish(host, 1)

	# Activate SY80U and verify the presentation contract plus the local axis.
	client.model_changed.emit("sy80u")
	await process_frame
	if _check(presentation.get_active_model_id() == "sy80u", "SY80U did not activate") != 0:
		return _finish(host, 1)
	if _check(presentation.get_contract_error().is_empty(), "SY80U activation raised a contract error: %s" % presentation.get_contract_error()) != 0:
		return _finish(host, 1)
	if _check(_visible_model_count(presentation_root) == 1, "SY80U activation is not singular") != 0:
		return _finish(host, 1)
	if _check(presentation.get_soil_contract().get("model_id", "") == "sy80u", "SY80U soil contract is unavailable") != 0:
		return _finish(host, 1)
	if _check(presentation.get_bucket_contact_world() is Vector3, "SY80U bucket-tip contact is unavailable") != 0:
		return _finish(host, 1)

	var axis_state := presentation.get_local_axis_state_for_test()
	if _check(axis_state.has("boom_swing"), "SY80U boom-swing local axis is missing") != 0:
		return _finish(host, 1)
	var boom_swing: Dictionary = axis_state["boom_swing"]
	if _check(is_equal_approx(float(boom_swing["max_deg"]), 65.0)
			and is_equal_approx(float(boom_swing["min_deg"]), -51.0),
			"SY80U boom-swing limits drifted: %s" % boom_swing) != 0:
		return _finish(host, 1)

	var tip := _find_descendant(presentation.get_frame_node("bucket_link"), "REF_BUCKET_TIP")
	if _check(tip != null, "SY80U REF_BUCKET_TIP is unavailable under bucket_link") != 0:
		return _finish(host, 1)
	var tip_rest := tip.global_position

	# Direct angle writes: positive swings the tip toward machine left (-X),
	# negative toward right (+X), and limits clamp.
	if _check(presentation.set_local_axis_angle_for_test("boom_swing", 30.0),
			"SY80U boom-swing angle write was rejected") != 0:
		return _finish(host, 1)
	await process_frame
	if _check(tip.global_position.x < tip_rest.x - 0.1,
			"SY80U positive boom swing did not move the tip left") != 0:
		return _finish(host, 1)
	if _check(presentation.set_local_axis_angle_for_test("boom_swing", -30.0),
			"SY80U negative boom-swing angle write was rejected") != 0:
		return _finish(host, 1)
	await process_frame
	if _check(tip.global_position.x > tip_rest.x + 0.1,
			"SY80U negative boom swing did not move the tip right") != 0:
		return _finish(host, 1)
	presentation.set_local_axis_angle_for_test("boom_swing", 200.0)
	await process_frame
	var clamped := float(presentation.get_local_axis_state_for_test()["boom_swing"]["angle_deg"])
	if _check(is_equal_approx(clamped, 65.0), "SY80U boom-swing upper clamp failed: %s" % clamped) != 0:
		return _finish(host, 1)
	presentation.set_local_axis_angle_for_test("boom_swing", -200.0)
	await process_frame
	clamped = float(presentation.get_local_axis_state_for_test()["boom_swing"]["angle_deg"])
	if _check(is_equal_approx(clamped, -51.0), "SY80U boom-swing lower clamp failed: %s" % clamped) != 0:
		return _finish(host, 1)

	# Integrated input: positive input accumulates toward the left limit and
	# holds when the input releases.
	presentation.set_local_axis_input_for_test(1.0)
	for i in range(240):
		await physics_frame
	presentation.set_local_axis_input_for_test(0.0)
	await physics_frame
	var integrated := float(presentation.get_local_axis_state_for_test()["boom_swing"]["angle_deg"])
	if _check(integrated > 0.0 and integrated <= 65.0,
			"SY80U boom-swing integration misbehaved: %s" % integrated) != 0:
		return _finish(host, 1)
	presentation.clear_local_axis_input_for_test()

	# Authority poses still drive the four protocol frames while the local
	# swing stays composed underneath them.
	var fixture := _read_json(FIXTURE)
	for pose_name in ["zero", "swing_positive_90", "boom_only", "arm_only", "bucket_only", "asymmetric"]:
		if _check(presentation.apply_pose_for_test(fixture["poses"][pose_name]), "SY80U pose failed: %s" % pose_name) != 0:
			return _finish(host, 1)
	presentation.restore_rest_pose_for_test()
	await process_frame
	var after_rest := float(presentation.get_local_axis_state_for_test()["boom_swing"]["angle_deg"])
	if _check(is_zero_approx(after_rest), "SY80U boom swing did not reset with the rest pose") != 0:
		return _finish(host, 1)

	# Switch away and back: local axes belong to the SY80U contract only.
	client.model_changed.emit("sy135")
	await process_frame
	if _check(presentation.get_active_model_id() == "sy135", "SY135 did not reactivate after SY80U") != 0:
		return _finish(host, 1)
	if _check(presentation.get_local_axis_state_for_test().is_empty(), "SY135 unexpectedly gained a local axis") != 0:
		return _finish(host, 1)
	presentation.set_local_axis_angle_for_test("boom_swing", 30.0)
	client.model_changed.emit("sy80u")
	await process_frame
	if _check(presentation.get_active_model_id() == "sy80u", "SY80U did not reactivate") != 0:
		return _finish(host, 1)
	if _check(_visible_model_count(presentation_root) == 1, "SY80U reactivation left multiple visuals") != 0:
		return _finish(host, 1)
	var reactivated := float(presentation.get_local_axis_state_for_test()["boom_swing"]["angle_deg"])
	if _check(is_zero_approx(reactivated), "SY80U boom swing was not reset on reactivation") != 0:
		return _finish(host, 1)

	print("SY80U activation smoke passed.")
	_finish(host, 0)


func _find_descendant(node: Node, target_name: String) -> Node3D:
	if node.name == target_name and node is Node3D:
		return node as Node3D
	for child in node.get_children():
		var found := _find_descendant(child, target_name)
		if found != null:
			return found
	return null


func _visible_model_count(root: Node3D) -> int:
	var count := 0
	for child in root.get_children():
		if child is Node3D and (child as Node3D).visible:
			count += 1
	return count


func _read_json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}


func _check(condition: bool, message: String) -> int:
	if condition:
		return 0
	push_error(message)
	return 1


func _finish(host: Node, code: int) -> void:
	host.queue_free()
	await process_frame
	quit(code)

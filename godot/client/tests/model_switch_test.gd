extends SceneTree

const SY135_FIXTURE := "res://tests/fixtures/sy135_frame_parity_cases.json"


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
	if _check(presentation.set_authority_profile_for_test(AuthorityProfile.PYTHON_KINEMATIC), "model switching parity test selects Python compatibility profile") != 0:
		return _finish(host, 1)
	if _check(presentation.get_active_model_id() == "sy135", "SY135 did not activate") != 0:
		return _finish(host, 1)
	if _check(_visible_model_count(presentation_root) == 1, "SY135 activation is not singular") != 0:
		return _finish(host, 1)
	var fixture := _read_json(SY135_FIXTURE)
	for pose_name in ["zero", "swing_positive_90", "boom_only", "arm_only", "bucket_only", "asymmetric"]:
		if _check(presentation.apply_pose_for_test(fixture["poses"][pose_name]), "SY135 pose failed: %s" % pose_name) != 0:
			return _finish(host, 1)
	if _check(presentation.get_bucket_contact_world() is Vector3, "SY135 bucket-tip contact is unavailable") != 0:
		return _finish(host, 1)
	if _check(presentation.get_soil_contract().get("model_id", "") == "sy135", "SY135 soil contract is unavailable") != 0:
		return _finish(host, 1)
	var first_soil_pose := presentation.sample_bucket_pose_fixed(0, 0)
	var second_soil_pose := presentation.sample_bucket_pose_fixed(0, 0)
	if _check(not bool(first_soil_pose.get("valid", false)) and bool(second_soil_pose.get("valid", false)), "fixed-step bucket pose history does not gate the first sweep") != 0:
		return _finish(host, 1)
	if _check((second_soil_pose.get("current", {}) as Dictionary).has("cavity"), "SY135 bucket pose omits cavity proxy") != 0:
		return _finish(host, 1)
	presentation.set_soil_debug_visible(true)
	var debug_root := presentation.get_node_or_null("SoilProxyDebug") as Node3D
	if _check(debug_root != null and debug_root.visible, "soil proxy overlay is unavailable") != 0:
		return _finish(host, 1)
	for proxy_name in ["cutting_edge", "top_edge", "opening", "cavity", "rear_support"]:
		var proxy_mesh := debug_root.get_node_or_null(proxy_name) as MeshInstance3D
		if _check(proxy_mesh != null, "soil proxy overlay omits %s" % proxy_name) != 0:
			return _finish(host, 1)
		var expected: Transform3D = (second_soil_pose["current"] as Dictionary)[proxy_name]
		if _check(proxy_mesh.global_transform.origin.is_equal_approx(expected.origin), "soil proxy overlay drifts for %s" % proxy_name) != 0:
			return _finish(host, 1)
		if proxy_name == "opening" or proxy_name == "cavity":
			var proxy_contract: Dictionary = ((presentation.get_soil_contract()["proxies"] as Dictionary)[proxy_name] as Dictionary)
			var raw_up: Array = proxy_contract.get("up_godot", [])
			var local_up := Vector3(float(raw_up[0]), float(raw_up[1]), float(raw_up[2])).normalized()
			var frame := presentation.get_frame_node(String(proxy_contract["frame"]))
			var expected_up := (frame.global_transform.basis * local_up).normalized()
			if _check(expected.basis.y.normalized().is_equal_approx(expected_up), "%s proxy ignores its declared orientation" % proxy_name) != 0:
				return _finish(host, 1)
	var identity_break := presentation.sample_bucket_pose_fixed(1, 0)
	if _check(not bool(identity_break.get("valid", false)) and identity_break.get("reason", "") == "history_unavailable", "world identity change does not reset the bucket sweep") != 0:
		return _finish(host, 1)
	presentation.sample_bucket_pose_fixed(1, 0)
	presentation_root.position += Vector3(3.0, 0.0, 0.0)
	var teleport := presentation.sample_bucket_pose_fixed(1, 0)
	if _check(not bool(teleport.get("valid", false)) and teleport.get("reason", "") == "discontinuous_pose", "bucket teleport is not rejected") != 0:
		return _finish(host, 1)
	presentation_root.position -= Vector3(3.0, 0.0, 0.0)
	presentation.clear_bucket_pose_history()

	client.model_changed.emit("sy205")
	await process_frame
	if _check(presentation.get_active_model_id() == "sy205", "SY205 did not activate") != 0:
		return _finish(host, 1)
	if _check(_visible_model_count(presentation_root) == 1, "SY205 activation is not singular") != 0:
		return _finish(host, 1)
	if _check(presentation.get_soil_contract().get("model_id", "") == "sy205", "SY205 soil contract is unavailable") != 0:
		return _finish(host, 1)
	client.model_changed.emit("sy135")
	await process_frame
	await process_frame
	if _check(presentation.get_active_model_id() == "sy135", "SY135 did not reactivate") != 0:
		return _finish(host, 1)
	if _check(_visible_model_count(presentation_root) == 1, "reactivation left multiple visuals") != 0:
		return _finish(host, 1)

	print("SY205/SY135 presentation switching contract passed.")
	_finish(host, 0)


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

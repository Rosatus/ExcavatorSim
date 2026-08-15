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

	client.model_changed.emit("sy205")
	await process_frame
	if _check(presentation.get_active_model_id() == "sy205", "SY205 did not activate") != 0:
		return _finish(host, 1)
	if _check(_visible_model_count(presentation_root) == 1, "SY205 activation is not singular") != 0:
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

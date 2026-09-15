extends SceneTree

## SY135-NEO activation smoke: catalog-driven presentation activation, per-model
## material override, soil contract wiring, and the shared chassis-side profiles.

const NEO_FIXTURE := "res://tests/fixtures/sy135neo_frame_parity_cases.json"


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

	# Shared model-keyed chassis-side profiles must accept the NEO id.
	var shaper := DiggingResponseShaper.new()
	if _check(shaper.configure("sy135neo"), "digging response profile rejects sy135neo") != 0:
		return _finish(host, 1)
	var mapper := EquipmentCommandMapper.new()
	if _check(mapper.configure_model("sy135neo"), "equipment command mapper rejects sy135neo") != 0:
		return _finish(host, 1)
	if _check(mapper.get_model_id() == "sy135neo", "equipment command mapper lost the requested model id") != 0:
		return _finish(host, 1)

	# Activate NEO from the atlas model and verify the presentation contract.
	client.model_changed.emit("sy135neo")
	await process_frame
	if _check(presentation.get_active_model_id() == "sy135neo", "SY135-NEO did not activate") != 0:
		return _finish(host, 1)
	if _check(presentation.get_contract_error().is_empty(), "SY135-NEO activation raised a contract error") != 0:
		return _finish(host, 1)
	if _check(_visible_model_count(presentation_root) == 1, "SY135-NEO activation is not singular") != 0:
		return _finish(host, 1)
	if not _check_bucket_material(presentation):
		return _finish(host, 1)
	if _check(presentation.get_soil_contract().get("model_id", "") == "sy135neo", "SY135-NEO soil contract is unavailable") != 0:
		return _finish(host, 1)
	if _check(presentation.get_bucket_contact_world() is Vector3, "SY135-NEO bucket-tip contact is unavailable") != 0:
		return _finish(host, 1)
	var fixture := _read_json(NEO_FIXTURE)
	for pose_name in ["zero", "swing_positive_90", "boom_only", "arm_only", "bucket_only", "asymmetric"]:
		if _check(presentation.apply_pose_for_test(fixture["poses"][pose_name]), "SY135-NEO pose failed: %s" % pose_name) != 0:
			return _finish(host, 1)

	# Round-trip back to SY135 and forward again: both must stay singular.
	client.model_changed.emit("sy135")
	await process_frame
	if _check(presentation.get_active_model_id() == "sy135", "SY135 did not reactivate after NEO") != 0:
		return _finish(host, 1)
	if _check(_visible_model_count(presentation_root) == 1, "SY135 reactivation left multiple visuals") != 0:
		return _finish(host, 1)
	client.model_changed.emit("sy135neo")
	await process_frame
	if _check(presentation.get_active_model_id() == "sy135neo", "SY135-NEO did not reactivate") != 0:
		return _finish(host, 1)
	if _check(_visible_model_count(presentation_root) == 1, "SY135-NEO reactivation left multiple visuals") != 0:
		return _finish(host, 1)

	print("SY135-NEO activation smoke passed.")
	_finish(host, 0)


func _check_bucket_material(presentation: MotionPresentation) -> bool:
	var bucket := presentation.get_frame_node("bucket_link").get_node("bucket") as MeshInstance3D
	for surface in bucket.mesh.get_surface_count():
		var source := bucket.mesh.surface_get_material(surface) as StandardMaterial3D
		var active := bucket.get_active_material(surface) as StandardMaterial3D
		if source.albedo_color.get_luminance() < 0.1:
			if _check(active != source and active.albedo_color.get_luminance() > source.albedo_color.get_luminance() * 2.0
					and active.roughness > 0.7,
					"SY135-NEO dark paint did not receive the lit steel override") != 0:
				return false
		elif _check(active == source,
				"SY135-NEO readable detail material was mutated") != 0:
			return false
	return true


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

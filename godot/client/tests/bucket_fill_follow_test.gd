extends SceneTree


class RejectingPresentation extends MotionPresentation:
	var reject_contract := false

	func _load_mapping_contract(model_id: String) -> bool:
		return false if reject_contract else super._load_mapping_contract(model_id)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := Node3D.new()
	root.add_child(host)
	var visual_root := Node3D.new()
	visual_root.name = "PresentationRoot"
	host.add_child(visual_root)
	var presentation := RejectingPresentation.new()
	presentation.name = "MotionPresentation"
	host.add_child(presentation)
	var effects := SoilEffects.new()
	effects.excavation_world_path = NodePath()
	effects.max_clods = 0
	effects.max_visual_mounds = 0
	host.add_child(effects)
	await process_frame
	var mesh_id := effects._fill_array_mesh.get_instance_id()
	for model in ["sy135", "sy205", "sy135"]:
		if not presentation.activate_model_for_test(model):
			return _finish(host, "model activation failed")
		await process_frame # Let the old imported model actually be freed.
		if effects._fill_mesh.visible:
			return _finish(host, "model activation retained old inventory")
		var contract := presentation.get_soil_contract()
		var frame := presentation.get_frame_node("bucket_link")
		var local := presentation.get_soil_proxy_local_transform("cavity")
		var stale := {"cavity": frame.global_transform * local}
		var other_model := "sy205" if model == "sy135" else "sy135"
		var old_contract: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://resources/models/%s_soil_contract.json" % other_model))
		effects.apply_visual_snapshot_for_test({"material_generation": effects._generation,
			"fill_ratio": 0.5, "bucket_pose": {"current": stale, "contract": old_contract}})
		if effects._fill_mesh.visible:
			return _finish(host, "old-model snapshot restored mismatched fill")
		effects._update_fill({"fill_ratio": 0.5}, stale, contract)
		var rebuilds := effects._fill_rebuild_count
		if not effects._fill_mesh.visible or effects._fill_mesh.get_parent() != frame:
			return _finish(host, "fill is not attached to the actual bucket")
		# No fresh soil snapshots, even while every ancestor and the bucket move.
		# Exercise movement between physics ticks too (compatibility render poses).
		for step in 48:
			var sign_value := 1.0 if step < 24 else -1.0
			visual_root.position += Vector3(0.031 * sign_value, 0.0, -0.023)
			visual_root.rotate_y(0.013 * sign_value)
			frame.rotate_x(0.007 * sign_value)
			if step % 7 == 0:
				effects._update_fill({"fill_ratio": 0.5}, stale, contract)
			var expected := frame.global_transform * local
			if not effects._fill_mesh.global_transform.is_equal_approx(expected):
				return _finish(host, "moving bucket and fill diverged or old snapshot pulled it back")
			await process_frame
		if effects._fill_rebuild_count != rebuilds or effects._fill_array_mesh.get_instance_id() != mesh_id:
			return _finish(host, "rigid following rebuilt or replaced geometry")
		effects.clear_for_generation(10)
		if effects._fill_mesh.visible or effects._fill_mesh.get_parent() != effects:
			return _finish(host, "reset did not reclaim and hide attachment")
		effects._update_fill({"fill_ratio": 0.5}, stale, contract)
		if not effects._fill_mesh.global_transform.is_equal_approx(frame.global_transform * local):
			return _finish(host, "refill after reset used stale pose")
		effects._update_fill({"fill_ratio": 0.0}, stale, contract)
		if effects._fill_mesh.visible:
			return _finish(host, "empty bucket retained fill")
		effects._update_fill({"fill_ratio": 0.5}, stale, contract)
	# Failure after a candidate loads must reclaim the previous bucket attachment.
	presentation.reject_contract = true
	if presentation.activate_model_for_test("sy205"):
		return _finish(host, "test candidate unexpectedly accepted")
	if effects._fill_mesh.visible or effects._fill_mesh.get_parent() != effects:
		return _finish(host, "failed candidate retained attachment on old model")
	presentation.reject_contract = false
	if not presentation.activate_model_for_test("sy135"):
		return _finish(host, "model failed to recover after rejected candidate")
	effects._update_fill({"fill_ratio": 0.5}, {"cavity": Transform3D.IDENTITY}, presentation.get_soil_contract())
	var detached_mesh := effects._fill_mesh
	effects.queue_free()
	await process_frame
	await process_frame
	if is_instance_valid(detached_mesh):
		return _finish(host, "destroyed effects leaked the attached mesh")
	# Reverse teardown order: imported frames disappear before their observer.
	var survivor := SoilEffects.new()
	survivor.excavation_world_path = NodePath()
	survivor.max_clods = 0
	survivor.max_visual_mounds = 0
	host.add_child(survivor)
	var final_contract := presentation.get_soil_contract()
	var final_pose := {"cavity": Transform3D.IDENTITY}
	survivor._update_fill({"fill_ratio": 0.5}, final_pose, final_contract)
	presentation.free()
	visual_root.free()
	if survivor.get_effect_snapshot()["fill_visible"]:
		return _finish(host, "freed model left a visible fill reference")
	survivor._update_fill({"fill_ratio": 0.5}, final_pose, final_contract)
	if survivor._fill_mesh.visible:
		return _finish(host, "missing presentation fell back to stale world pose")
	host.free()
	print("bucket_fill_follow_test: PASS")
	quit(0)


func _finish(host: Node, message: String) -> void:
	push_error(message)
	host.queue_free()
	quit(1)

extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var effects := SoilEffects.new()
	effects.max_visual_mounds = 2
	effects.max_clods = 4
	effects.excavation_world_path = NodePath()
	root.add_child(effects)
	await process_frame
	var first := _snapshot("dump:1", Vector3(1.0, 0.0, 2.0), 0.4)
	effects.apply_visual_snapshot_for_test(first)
	if int(effects.get_effect_snapshot().get("active_visual_mounds", 0)) != 1:
		return _fail("first visual mound was not presented")
	effects.apply_visual_snapshot_for_test(first)
	if int(effects.get_effect_snapshot().get("active_visual_mounds", 0)) != 1:
		return _fail("duplicate dump event spawned another mound")
	effects.apply_visual_snapshot_for_test(_snapshot("dump:2", Vector3.ZERO, 0.8))
	effects.apply_visual_snapshot_for_test(_snapshot("dump:3", Vector3(3.0, 0.0, 1.0), 1.0))
	var status := effects.get_effect_snapshot()
	if int(status.get("active_visual_mounds", 0)) != 2 or int(status.get("visual_mound_cap", 0)) != 2:
		return _fail("bounded visual mound pool did not recycle at capacity")
	var rejected := _snapshot("dump:3", Vector3(3.0, 0.0, 1.0), 1.0)
	rejected["rejected_dump_event_id"] = "dump-rejected:1"
	rejected["rejected_dump_world"] = Vector3(5.0, 0.0, 5.0)
	effects.apply_visual_snapshot_for_test(rejected)
	effects.apply_visual_snapshot_for_test(rejected)
	status = effects.get_effect_snapshot()
	if int(status.get("rejected_dump_effect_count", 0)) != 1 or int(status.get("active_visual_mounds", 0)) != 2:
		return _fail("rejected dump feedback was not deduplicated or changed authoritative mound presentation")
	for child in effects.get_children():
		if String(child.name).begins_with("VisualSoilMound") and (child is CollisionObject3D or child is CollisionShape3D):
			return _fail("visual mound pool introduced a physics node")
	effects.clear_for_generation(7)
	if int(effects.get_effect_snapshot().get("active_visual_mounds", -1)) != 0:
		return _fail("generation reset retained visual mounds")
	var fill_first := _fill_snapshot(0.40)
	effects.apply_visual_snapshot_for_test(fill_first)
	var fill_status := effects.get_effect_snapshot()
	var fill_mesh_id := effects._fill_mesh.mesh.get_instance_id()
	if int(fill_status.get("fill_rebuild_count", 0)) != 1:
		return _fail("first visible fill did not build exactly once")
	effects._fill_update_accumulator_s = 0.2
	effects.apply_visual_snapshot_for_test(_fill_snapshot(0.42))
	if int(effects.get_effect_snapshot().get("fill_rebuild_count", 0)) != 1:
		return _fail("sub-quantum fill change rebuilt the mesh")
	effects._fill_update_accumulator_s = 0.2
	effects.apply_visual_snapshot_for_test(_fill_snapshot(0.46))
	fill_status = effects.get_effect_snapshot()
	if int(fill_status.get("fill_rebuild_count", 0)) != 2:
		return _fail("five-point fill change did not rebuild after the 10 Hz gate")
	if effects._fill_mesh.mesh.get_instance_id() != fill_mesh_id:
		return _fail("fill update replaced the reusable ArrayMesh resource")
	if not is_equal_approx(float(fill_status.get("fill_update_hz", 0.0)), 10.0) \
			or not is_equal_approx(float(fill_status.get("fill_ratio_quantum", 0.0)), 0.05):
		return _fail("fill cadence diagnostics do not expose the bounded contract")
	var clod_snapshot := _fill_snapshot(0.5)
	clod_snapshot["interaction_state"] = "dump"
	clod_snapshot["flow_volume_m3"] = 0.1
	if not effects._spawn_clod(clod_snapshot, "dump") or effects._active_clod_count() != 1:
		return _fail("clod free list did not activate one pooled body")
	effects._reset_clod_pool()
	if effects._active_clod_count() != 0 or effects._free_clods.size() != effects.max_clods:
		return _fail("clod free list did not reset without duplicate entries")
	effects.queue_free()
	print("soil_effects_visual_mound_test: PASS")
	quit(0)


func _snapshot(event_id: String, release_world: Vector3, ratio: float) -> Dictionary:
	return {
		"accepted_dump_event_id": event_id,
		"dump_release_world": release_world,
		"dump_released_fill_ratio": ratio,
		"bucket_pose": {},
	}


func _fill_snapshot(ratio: float) -> Dictionary:
	return {
		"material_generation": 7,
		"fill_ratio": ratio,
		"fill_profile": PackedFloat32Array(),
		"cell_grid": [2, 1, 2],
		"bucket_pose": {
			"current": {
				"cavity": Transform3D.IDENTITY,
				"opening": Transform3D.IDENTITY,
			},
			"contract": {"proxies": {"cavity": {"size_m": [1.0, 0.8, 0.9]}}},
			"opening_normal_world": Vector3.DOWN,
		},
	}


func _fail(message: String) -> void:
	push_error(message)
	quit(1)

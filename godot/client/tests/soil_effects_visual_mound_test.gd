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
	var moved_cavity := Transform3D(Basis.IDENTITY, Vector3(2.0, 3.0, 4.0))
	effects.apply_visual_snapshot_for_test(_fill_snapshot(0.46, moved_cavity))
	if not effects._fill_mesh.global_transform.is_equal_approx(moved_cavity):
		return _fail("contained fill did not remain stable in the moving cavity frame")
	var fill_arrays := effects._fill_array_mesh.surface_get_arrays(0)
	var fill_vertices := fill_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	if fill_vertices.size() <= 6:
		return _fail("bucket fill remained an open top surface")
	for vertex in fill_vertices:
		if absf(vertex.x) > 0.5 or absf(vertex.z) > 0.45 or vertex.y < -0.4 or vertex.y > 0.4:
			return _fail("closed bucket fill escaped the cavity bounds")
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
	var cut_snapshot := _fill_snapshot(0.5)
	cut_snapshot["interaction_state"] = "cut"
	cut_snapshot["flow_volume_m3"] = 0.1
	effects.apply_visual_snapshot_for_test(cut_snapshot)
	if effects._flow_particles.emitting or effects._spawn_clod(cut_snapshot, "cut"):
		return _fail("cut incorrectly emitted falling soil or a rigid clod")
	var frozen_release := _fill_snapshot(0.5)
	frozen_release["accepted_dump_event_id"] = "release:frozen"
	frozen_release["accepted_dump_event"] = _release_event("release:frozen", Vector3(3.0, 2.0, 4.0), 0.08)
	var live_pose := frozen_release["bucket_pose"] as Dictionary
	var live_current := live_pose["current"] as Dictionary
	live_current["opening"] = Transform3D(Basis.IDENTITY, Vector3(100.0, 100.0, 100.0))
	effects.apply_visual_snapshot_for_test(frozen_release)
	# Stable-release decoration starts 5 cm outside the frozen opening.
	if not effects._flow_particles.global_position.is_equal_approx(Vector3(3.0, 1.95, 4.0)):
		return _fail("delayed release presentation reconstructed the source from the live bucket pose")
	var release_status := effects.get_effect_snapshot()
	var release_ttl := float(release_status.get("release_event_ttl_s", 0.0))
	effects.advance_release_visual_for_test(release_ttl + 0.01)
	if not String(effects.get_effect_snapshot().get("active_release_event_id", "")).is_empty() or effects._flow_particles.emitting:
		return _fail("release event did not expire after its bounded TTL")
	effects.apply_visual_snapshot_for_test(frozen_release)
	if not String(effects.get_effect_snapshot().get("active_release_event_id", "")).is_empty():
		return _fail("an idle duplicate replayed an expired release event")
	effects.queue_free()
	print("soil_effects_visual_mound_test: PASS")
	quit(0)


func _snapshot(event_id: String, release_world: Vector3, ratio: float) -> Dictionary:
	return {
		"accepted_dump_event_id": event_id,
		"accepted_dump_event": _release_event(event_id, release_world, maxf(0.01, ratio * 0.1)),
		"dump_release_world": release_world,
		"dump_released_fill_ratio": ratio,
		"bucket_pose": {},
	}


func _release_event(event_id: String, release_world: Vector3, volume_m3: float) -> Dictionary:
	return {
		"schema_version": "voxel-soil-release-event-v1",
		"event_id": event_id,
		"accepted_volume_m3": volume_m3,
		"release_transform_world": Transform3D(Basis.IDENTITY, release_world),
		"release_world": release_world,
		"opening_normal_world": Vector3.DOWN,
		"direction_world": Vector3.DOWN,
		"fill_ratio": 0.5,
	}


func _fill_snapshot(ratio: float, cavity_transform: Transform3D = Transform3D.IDENTITY) -> Dictionary:
	return {
		"material_generation": 7,
		"fill_ratio": ratio,
		"fill_profile": PackedFloat32Array(),
		"cell_grid": [2, 1, 2],
		"bucket_pose": {
			"current": {
				"cavity": cavity_transform,
				"opening": Transform3D.IDENTITY,
			},
			"contract": {"proxies": {"cavity": {"size_m": [1.0, 0.8, 0.9]}}},
			"opening_normal_world": Vector3.DOWN,
		},
	}


func _fail(message: String) -> void:
	push_error(message)
	quit(1)

extends "res://tests/voxel_excavation_authority_test.gd"

func _run() -> void:
	var failures: Array[String] = []
	var catalog = root.get_node("MapCatalog")
	catalog.active_map_id = "construction"
	catalog.retained_model_id = "sy135"
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	var zone = scene.get_node("TerrainRoot/VoxelWorkZone")
	_expect(zone.terrain != null, "construction has voxel terrain", failures)
	if zone.terrain == null:
		_finish(failures)
		return
	_expect(await _wait_initial_ready(zone), "construction voxel collision is ready", failures)
	var center: Vector3 = zone.layout.ORIGIN_WORLD
	var space = scene.get_world_3d().direct_space_state
	var ray := PhysicsRayQueryParameters3D.create(center + Vector3.UP * 2, center - Vector3.UP * 2, 1)
	var hit: Dictionary = space.intersect_ray(ray)
	_expect(not hit.is_empty() and absf(hit.position.y - center.y) < 0.1, "level soil replaces hard map ground", failures)
	var editable: AABB = zone.layout.editable_world_bounds(zone.voxel_scale_m)
	var map_rid: RID = scene.get_node("StaticMap/Ground").collision.get_rid()
	var hard_remnants := 0
	var off_profile_samples := 0
	var generator = zone.terrain.generator
	for z in range(ceili(editable.position.z), floori(editable.end.z)):
		for x in range(ceili(editable.position.x), floori(editable.end.x)):
			var interior_ray := PhysicsRayQueryParameters3D.create(Vector3(x, 1, z), Vector3(x, -5, z), 1)
			var interior_hit: Dictionary = space.intersect_ray(interior_ray)
			if interior_hit.is_empty() or interior_hit.get("rid", RID()) == map_rid:
				hard_remnants += 1
			else:
				var expected_y: float = center.y + generator.surface_height_m(x - center.x, z - center.z)
				if absf(interior_hit.position.y - expected_y) > 0.35:
					off_profile_samples += 1
	_expect(hard_remnants == 0, "editable interior has no missing soil or retained Terrain3D collision", failures)
	_expect(off_profile_samples == 0, "initial soil matches the starter foundation-pit profile", failures)
	_expect(zone.layout.owns_world_position(center) and not zone.layout.owns_world_position(Vector3(0, 0, 24)), "map owns only translated zone", failures)
	_expect(scene.get_node("StaticMap/WorkArea/ExcavationArea").get_child_count() == 4, "only ground warning lines remain", failures)
	var excavation = scene.get_node("TerrainRoot/ExcavationWorld")
	_expect(excavation.is_soil_runtime_ready(), "product excavation authority is enabled", failures)
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	var authority := Authority.new()
	_expect(authority.configure(zone, contract, zone.readiness.generation), "translated authority configures", failures)
	var pose := _pose(contract, Vector3(center.x, _bucket_origin_y(contract, center.y - 0.05), center.z + 4.0), Vector3(0, -0.04, 0.06), "construction-cut")
	var submitted := authority.submit_pose(pose, _identity(zone.readiness.generation, 10, 1))
	var result := authority.flush_for_test()
	print("CONSTRUCTION_CUT accepted=", submitted.get("accepted", false), " volume=", result.get("transaction", {}).get("accepted_volume_m3", 0))
	_expect(bool(result.get("changed", false)), "translated real bucket sweep cuts native soil", failures)
	var payload := authority.get_payload_snapshot()
	_expect(int(payload.get("bucket_mass_q", 0)) > 0, "cut credits bucket mass", failures)
	_expect(int(payload.get("conservation_error_q", 1)) == 0, "cut conserves mass", failures)
	var dump_pose := _dump_pose(contract, Vector3(center.x + 4, 0.8, center.z + 4.0), "construction-dump")
	for tick in 3:
		authority.submit_pose(dump_pose, _identity(zone.readiness.generation, 20 + tick, 2 + tick), 0.06)
	for tick in 8:
		authority.step_fixed(0.05)
		authority.flush_for_test()
	_expect(int(authority.get_status_snapshot().get("operation_counts", {}).get("deposit", 0)) > 0, "translated dump creates stable soil", failures)
	_expect(int(authority.get_payload_snapshot().get("bucket_mass_q", 0)) < int(payload.get("bucket_mass_q", 0)), "deposit debits bucket", failures)
	_expect(int(authority.get_payload_snapshot().get("conservation_error_q", 1)) == 0, "dump conserves mass", failures)
	authority.clear()
	var chassis = scene.get_node("ChassisMotionRoot")
	chassis.map_spawn_position = center + Vector3(0, 0, 4.0)
	chassis.reset_for_test()
	for frame in 120:
		await physics_frame
	var support: Dictionary = chassis._jolt_runtime.get_post_step_snapshot()
	_expect(int(support.get("track_support_source_counts", {}).get("voxel_terrain", 0)) > 0, "tracks accept voxel soil inside static map", failures)
	_expect(chassis.global_position.y > -1.0, "chassis does not fall through pit", failures)
	var generation: int = zone.readiness.generation
	_expect(scene.get_node("ProductSession").request_reset(), "product reset accepts voxel map", failures)
	_expect(await _wait_initial_ready(zone), "reset rebuilds level soil collision", failures)
	_expect(zone.readiness.generation > generation, "reset retires old voxel generation", failures)
	var reset_hit: Dictionary = space.intersect_ray(ray)
	_expect(not reset_hit.is_empty() and absf(reset_hit.position.y - center.y) < 0.1, "reset restores level soil without hard ground", failures)
	# Exercise the real operator -> Jolt query -> automatic ExcavationWorld
	# path. Direct Authority.submit_pose above cannot catch map-identity gates.
	chassis.map_spawn_position = Vector3(center.x, center.y, center.z + 5.5)
	chassis.reset_for_test()
	chassis.set_test_input_focus_bypass_for_test(true)
	_expect(scene.get_node("ProductSession").request_start(), "resume after product reset", failures)
	for frame in 120:
		await physics_frame
	var automatic_authority = excavation._voxel_authority
	var mass_before := int(automatic_authority.get_payload_snapshot().get("bucket_mass_q", 0))
	chassis.set_equipment_commands_for_test(Vector4(0, -1, 0, 0))
	for frame in 120:
		await physics_frame
	chassis.set_equipment_commands_for_test(Vector4.ZERO)
	var automatic_payload: Dictionary = automatic_authority.get_payload_snapshot()
	print("AUTOMATIC_CUT volume=", automatic_payload.get("bucket_volume_m3", 0.0))
	_expect(int(automatic_payload.get("bucket_mass_q", 0)) > mass_before + 1000, "operator boom command cuts through automatic product path", failures)
	_expect(int(automatic_payload.get("conservation_error_q", 1)) == 0, "automatic cut conserves mass", failures)
	var automatic_query: Dictionary = chassis.get_status_snapshot().get("bucket_query", {})
	_expect(bool(automatic_query.get("valid", false)), "map bucket query uses map collision identity", failures)
	var stale_query: Dictionary = chassis._jolt_runtime._post_step_snapshot["bucket_query"]
	var saved_revision: int = stale_query.terrain_revision
	stale_query.terrain_revision = saved_revision + 1
	_expect(excavation._voxel_fixed_identity(excavation._last_pose_snapshot).is_empty(), "stale map query remains rejected", failures)
	stale_query.terrain_revision = saved_revision
	_expect(catalog.select_map("training", "sy135"), "return to training succeeds", failures)
	await process_frame
	await process_frame
	var training_zone = current_scene.get_node("TerrainRoot/VoxelWorkZone")
	_expect(training_zone.layout.ORIGIN_WORLD == WorkZoneConfig.ORIGIN_WORLD, "training layout remains independent", failures)
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	current_scene.queue_free()
	await process_frame
	await process_frame
	for failure in failures:
		push_error(failure)
	print("construction_voxel_test: ", "PASS" if failures.is_empty() else "FAIL", " ", failures)
	quit(0 if failures.is_empty() else 1)

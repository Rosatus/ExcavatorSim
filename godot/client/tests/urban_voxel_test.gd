extends "res://tests/voxel_excavation_authority_test.gd"

func _run() -> void:
	var failures: Array[String] = []
	var catalog = root.get_node("MapCatalog")
	catalog.active_map_id = "urban"
	catalog.retained_model_id = "sy135"
	var scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	var zone = scene.get_node("TerrainRoot/VoxelWorkZone")
	_expect(zone.terrain != null, "urban map initializes finite voxel terrain", failures)
	if zone.terrain == null:
		_finish(failures)
		return
	_expect(await _wait_initial_ready(zone), "urban voxel collision is ready", failures)
	var center: Vector3 = zone.layout.ORIGIN_WORLD
	_expect(center.is_equal_approx(Vector3(31.7, 1.3, 30.225)), "voxel zone sits on the cleared sidewalk strip", failures)
	_expect(zone.layout.SIZE_WORLD_M.is_equal_approx(Vector3(15.8, 10.0, 5.55)), "voxel volume spans curb to under the foundations", failures)
	var space = scene.get_world_3d().direct_space_state
	var map_rid: RID = scene.get_node("StaticMap/Ground").collision.get_rid()
	var generator = zone.terrain.generator
	# Whole editable interior: voxel collision only, matching the dug profile.
	var editable: AABB = zone.layout.editable_world_bounds(zone.voxel_scale_m)
	var hard_remnants := 0
	var off_profile_samples := 0
	for z in range(ceili(editable.position.z), floori(editable.end.z)):
		for x in range(ceili(editable.position.x), floori(editable.end.x)):
			var interior_ray := PhysicsRayQueryParameters3D.create(Vector3(x, 4, z), Vector3(x, -5, z), 1)
			var interior_hit: Dictionary = space.intersect_ray(interior_ray)
			if interior_hit.is_empty() or interior_hit.get("rid", RID()) == map_rid:
				hard_remnants += 1
			else:
				var expected_y: float = center.y + generator.surface_height_m(x - center.x, z - center.z)
				if absf(interior_hit.position.y - expected_y) > 0.35:
					off_profile_samples += 1
	_expect(hard_remnants == 0, "editable interior has no missing soil or retained slab collision", failures)
	_expect(off_profile_samples == 0, "initial soil matches the municipal trench profile", failures)
	# The pipe-trench half dug along -X; the +X half waits at grade.
	var pit_ray := PhysicsRayQueryParameters3D.create(Vector3(28.0, 4.0, 30.0), Vector3(28.0, -5.0, 30.0), 1)
	var pit_hit: Dictionary = space.intersect_ray(pit_ray)
	_expect(not pit_hit.is_empty() and absf(pit_hit.position.y - (center.y - 2.5)) < 0.3, "west half starts as a 2.5 m trench", failures)
	var grade_ray := PhysicsRayQueryParameters3D.create(Vector3(35.5, 4.0, 30.2), Vector3(35.5, -5.0, 30.2), 1)
	var grade_hit: Dictionary = space.intersect_ray(grade_ray)
	_expect(not grade_hit.is_empty() and absf(grade_hit.position.y - center.y) < 0.15, "east half waits at grade", failures)
	var face_hit: Dictionary = space.intersect_ray(
		PhysicsRayQueryParameters3D.create(Vector3(31.35, 4.0, 30.2), Vector3(31.35, -5.0, 30.2), 1))
	_expect(not face_hit.is_empty() and face_hit.position.y < center.y - 0.5, "midline work front is a steep cut face", failures)
	# The ground slab hands the strip to voxel soil only while enabled.
	var ground: StaticBody3D = scene.get_node("StaticMap/Ground")
	_expect(ground.get("excavation_enabled") == true, "urban ground sees the voxel opt-in", failures)
	_expect(ground.get_node("Box0").disabled, "whole-map slab releases the strip", failures)
	for edge in ["HoleSouth", "HoleNorth", "HoleWest", "HoleEast"]:
		_expect(not ground.get_node(edge).disabled, "hole frame collision %s active" % edge, failures)
	var road_ray := PhysicsRayQueryParameters3D.create(Vector3(31.7, 4.0, 26.0), Vector3(31.7, -2.0, 26.0), 1)
	_expect(not space.intersect_ray(road_ray).is_empty(), "road surface still collides outside the zone", failures)
	_expect(scene.get_node("StaticMap/WorkArea/ExcavationArea").get_child_count() == 4, "only ground warning lines remain", failures)
	var excavation = scene.get_node("TerrainRoot/ExcavationWorld")
	_expect(excavation.is_soil_runtime_ready(), "product excavation authority is enabled", failures)
	# A real bucket sweep cuts the waiting east half of the strip.
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	var authority := Authority.new()
	_expect(authority.configure(zone, contract, zone.readiness.generation), "translated authority configures", failures)
	var pose := _pose(contract, Vector3(34.8, _bucket_origin_y(contract, center.y - 0.05), 30.7), Vector3(0.08, -0.05, 0.0), "urban-cut")
	var submitted := authority.submit_pose(pose, _identity(zone.readiness.generation, 10, 1))
	var result := authority.flush_for_test()
	print("URBAN_CUT accepted=", submitted.get("accepted", false), " volume=", result.get("transaction", {}).get("accepted_volume_m3", 0))
	_expect(bool(submitted.get("accepted", false)) and bool(result.get("changed", false)), "bucket sweep cuts native urban soil", failures)
	_expect(int(authority.get_payload_snapshot().get("bucket_mass_q", 0)) > 0, "cut credits bucket mass", failures)
	authority.clear()
	# Tracks accept voxel soil as support inside the static map.
	var chassis = scene.get_node("ChassisMotionRoot")
	chassis.map_spawn_position = Vector3(35.5, center.y + 0.2, 30.2)
	chassis.reset_for_test()
	for frame in 120:
		await physics_frame
	var support: Dictionary = chassis._jolt_runtime.get_post_step_snapshot()
	_expect(int(support.get("track_support_source_counts", {}).get("voxel_terrain", 0)) > 0, "tracks accept voxel soil inside the strip", failures)
	_expect(chassis.global_position.y > center.y - 2.0, "chassis does not fall through the strip", failures)
	# Product reset restores the designed half-dug surface.
	var generation: int = zone.readiness.generation
	_expect(scene.get_node("ProductSession").request_reset(), "product reset accepts voxel map", failures)
	_expect(await _wait_initial_ready(zone), "reset rebuilds soil collision", failures)
	_expect(zone.readiness.generation > generation, "reset retires old voxel generation", failures)
	var reset_hit: Dictionary = space.intersect_ray(grade_ray)
	_expect(not reset_hit.is_empty() and absf(reset_hit.position.y - center.y) < 0.15, "reset restores the waiting half at grade", failures)
	_expect(catalog.select_map("training", "sy135"), "return to training succeeds", failures)
	await process_frame
	await process_frame
	_expect(current_scene.get_node("TerrainRoot/VoxelWorkZone").layout.ORIGIN_WORLD == WorkZoneConfig.ORIGIN_WORLD, "training layout remains independent", failures)
	_finish(failures)

func _finish(failures: Array[String]) -> void:
	current_scene.queue_free()
	await process_frame
	await process_frame
	for failure in failures:
		push_error(failure)
	print("urban_voxel_test: ", "PASS" if failures.is_empty() else "FAIL", " ", failures)
	quit(0 if failures.is_empty() else 1)

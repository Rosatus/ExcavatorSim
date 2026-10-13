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
	_expect(center.is_equal_approx(Vector3(55.4, 1.1, 30.225)), "voxel zone extends behind the -X-facing spawn", failures)
	_expect(zone.layout.SIZE_WORLD_M.is_equal_approx(Vector3(63.2, 10.0, 5.55)), "voxel strip adds three original lengths at unchanged width", failures)
	var space = scene.get_world_3d().direct_space_state
	var map_rid: RID = scene.get_node("StaticMap/Ground").collision.get_rid()
	var generator = zone.terrain.generator
	_check_extended_map_assets(scene.get_node("StaticMap"), failures)
	# Whole editable interior: voxel collision only, level with surrounding grade.
	var editable: AABB = zone.layout.editable_world_bounds(zone.voxel_scale_m)
	var hard_remnants := 0
	var off_profile_samples := 0
	var terrain_hits := 0
	for z in range(ceili(editable.position.z), floori(editable.end.z)):
		for x in range(ceili(editable.position.x), floori(editable.end.x)):
			var interior_ray := PhysicsRayQueryParameters3D.create(Vector3(x, 4, z), Vector3(x, -5, z), 1)
			var interior_hit: Dictionary = space.intersect_ray(interior_ray)
			if interior_hit.is_empty() or interior_hit.get("rid", RID()) == map_rid:
				hard_remnants += 1
			else:
				# Authored props (cones, fences, plinths) may stand inside the
				# strip; only voxel-terrain hits prove the soil profile.
				var hit_body := instance_from_id(interior_hit.get("collider_id", 0)) as Node
				var hit_is_terrain: bool = hit_body == zone.terrain \
					or (hit_body != null and zone.terrain.is_ancestor_of(hit_body))
				if not hit_is_terrain:
					continue
				terrain_hits += 1
				var expected_y: float = center.y + generator.surface_height_m(x - center.x, z - center.z)
				if absf(interior_hit.position.y - expected_y) > 0.35:
					off_profile_samples += 1
	_expect(terrain_hits > 0, "editable interior probes reach voxel soil", failures)
	_expect(hard_remnants == 0, "editable interior has no missing soil or retained slab collision", failures)
	_expect(off_profile_samples == 0, "initial soil matches the level urban profile", failures)
	# Road-facing corridor stays continuous across the original/extended join.
	for x in range(39, 87):
		for z in [28.2, 29.2]:
			var corridor_hit: Dictionary = space.intersect_ray(PhysicsRayQueryParameters3D.create(
				Vector3(x, 3, z), Vector3(x, -2, z), 1))
			var corridor_body: Node = corridor_hit.get("collider")
			_expect(corridor_body == zone.terrain or (corridor_body != null and zone.terrain.is_ancestor_of(corridor_body)),
				"cleared corridor reaches voxel soil at (%s, %s)" % [x, z], failures)
	for edge in [Vector3(86.85, 4, 29.2), Vector3(87.15, 4, 29.2),
			Vector3(70, 4, 27.3), Vector3(70, 4, 27.6)]:
		var edge_hit: Dictionary = space.intersect_ray(PhysicsRayQueryParameters3D.create(edge, edge - Vector3(0, 6, 0), 1))
		_expect(not edge_hit.is_empty(), "extended seam has ground support at %s" % edge, failures)
	# Both halves start filled to grade, including the former trench and cut face.
	var pit_ray := PhysicsRayQueryParameters3D.create(Vector3(28.0, 4.0, 30.0), Vector3(28.0, -5.0, 30.0), 1)
	var pit_hit: Dictionary = space.intersect_ray(pit_ray)
	_expect(not pit_hit.is_empty() and absf(pit_hit.position.y - center.y) < 0.15, "former west trench starts filled to grade", failures)
	var grade_ray := PhysicsRayQueryParameters3D.create(Vector3(35.5, 4.0, 30.2), Vector3(35.5, -5.0, 30.2), 1)
	var grade_hit: Dictionary = space.intersect_ray(grade_ray)
	_expect(not grade_hit.is_empty() and absf(grade_hit.position.y - center.y) < 0.15, "east half waits at grade", failures)
	var face_hit: Dictionary = space.intersect_ray(
		PhysicsRayQueryParameters3D.create(Vector3(31.35, 4.0, 30.2), Vector3(31.35, -5.0, 30.2), 1))
	_expect(not face_hit.is_empty() and absf(face_hit.position.y - center.y) < 0.15, "former midline cut face is level with grade", failures)
	# The ground slab hands the strip to voxel soil only while enabled.
	var ground: StaticBody3D = scene.get_node("StaticMap/Ground")
	_expect(ground.get("excavation_enabled") == true, "urban ground sees the voxel opt-in", failures)
	_expect(ground.get_node("Box0").disabled, "whole-map slab releases the strip", failures)
	for edge in ["HoleSouth", "HoleNorth", "HoleWest", "HoleEast"]:
		_expect(not ground.get_node(edge).disabled, "hole frame collision %s active" % edge, failures)
	var road_ray := PhysicsRayQueryParameters3D.create(Vector3(31.7, 4.0, 26.0), Vector3(31.7, -2.0, 26.0), 1)
	_expect(not space.intersect_ray(road_ray).is_empty(), "road surface still collides outside the zone", failures)
	_expect(scene.get_node("StaticMap/WorkArea/ExcavationArea").get_child_count() == 0, "voxel strip carries no warning-line geometry", failures)
	var excavation = scene.get_node("TerrainRoot/ExcavationWorld")
	_expect(excavation.is_soil_runtime_ready(), "product excavation authority is enabled", failures)
	# A real bucket sweep cuts soil well inside the new extension.
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	var authority := Authority.new()
	_expect(authority.configure(zone, contract, zone.readiness.generation), "translated authority configures", failures)
	var pose := _pose(contract, Vector3(79.8, _bucket_origin_y(contract, center.y - 0.05), 30.7), Vector3(0.08, -0.05, 0.0), "urban-cut")
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
	# The live automatic path: real chassis pose sampling must reach the voxel
	# authority, so digging can never silently stall on no_pose/identity gates.
	var live_status: Dictionary = excavation.get_status_snapshot()
	var live_pose := live_status.get("bucket_pose", {}) as Dictionary
	_expect(bool(live_pose.get("valid", false)), "live bucket pose samples for automatic digging", failures)
	var live_state := String(live_status.get("interaction_state", ""))
	print("URBAN_LIVE pose_valid=%s state=%s" % [live_pose.get("valid", false), live_state])
	_expect(live_state != "no_pose" and live_state != "voxel_identity_rejected"
		and live_state != "voxel_authority_unavailable",
		"automatic interaction reaches the authority, got %s" % live_state, failures)
	# Product reset restores the fully filled surface.
	var generation: int = zone.readiness.generation
	_expect(scene.get_node("ProductSession").request_reset(), "product reset accepts voxel map", failures)
	_expect(await _wait_initial_ready(zone), "reset rebuilds soil collision", failures)
	_expect(zone.readiness.generation > generation, "reset retires old voxel generation", failures)
	var reset_hit: Dictionary = space.intersect_ray(grade_ray)
	_expect(not reset_hit.is_empty() and absf(reset_hit.position.y - center.y) < 0.15, "reset restores the waiting half at grade", failures)
	var reset_pit_hit: Dictionary = space.intersect_ray(pit_ray)
	_expect(not reset_pit_hit.is_empty() and absf(reset_pit_hit.position.y - center.y) < 0.15, "reset keeps the former trench filled to grade", failures)
	_expect(catalog.select_map("training", "sy135"), "return to training succeeds", failures)
	await process_frame
	await process_frame
	_expect(current_scene.get_node("TerrainRoot/VoxelWorkZone").layout.ORIGIN_WORLD == WorkZoneConfig.ORIGIN_WORLD, "training layout remains independent", failures)
	_finish(failures)

func _check_extended_map_assets(map: Node3D, failures: Array[String]) -> void:
	_expect(map.find_children("prp_roadworkBarrier*", "Node3D", false, false).size() == 65,
		"forty matching roadwork barriers extend the existing row", failures)
	var last_barrier := map.get_node("prp_roadworkBarrier65") as Node3D
	_expect(last_barrier.position.is_equal_approx(Vector3(88.9655, 1.32463, 19.2705)),
		"barrier row extends exactly 47.4 m from its previous endpoint", failures)
	for name in ["Flg_hedge_Tall107", "Flg_hedge_Tall91", "gardenPlanter_B7", "gardenPlanter_E10", "flg_grass_57"]:
		_expect(map.get_node_or_null(name) == null, "cleared sidewalk obstacle removed: " + name, failures)
	var plinths := map.get_node("BuildingPlinths") as MultiMeshInstance3D
	_expect(plinths.multimesh.instance_count == 378, "building foundations remain intact", failures)
	for child in map.get_node("Foliage").get_children():
		if child is MultiMeshInstance3D:
			for index in child.multimesh.instance_count:
				var p: Vector3 = child.global_transform * child.multimesh.get_instance_transform(index).origin
				_expect(not (p.x >= 39.6 and p.x <= 87 and p.z >= 27.45 and p.z <= 33 and p.y < 4),
					"extension has no leftover planted foliage", failures)
	# Check the packed mesh itself, including triangles that cross a cut edge.
	var pavement := map.get_node("sidewalk_Straight_Splines_0/Mesh") as MeshInstance3D
	var arrays := pavement.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var cut := PackedVector2Array([Vector2(39.6, 27.45), Vector2(87, 27.45), Vector2(87, 33), Vector2(39.6, 33)])
	var leftover_area := 0.0
	for i in range(0, indices.size(), 3):
		var triangle := PackedVector2Array()
		for k in 3:
			var p := pavement.global_transform * vertices[indices[i + k]]
			triangle.append(Vector2(p.x, p.z))
		if absf((triangle[1] - triangle[0]).cross(triangle[2] - triangle[0])) < 0.00001:
			continue
		for polygon in Geometry2D.intersect_polygons(triangle, cut):
			var twice_area := 0.0
			for j in polygon.size():
				twice_area += polygon[j].cross(polygon[(j + 1) % polygon.size()])
			leftover_area += absf(twice_area) * 0.5
	_expect(leftover_area < 0.001, "packed sidewalk has no triangles covering extended soil", failures)

func _finish(failures: Array[String]) -> void:
	current_scene.queue_free()
	await process_frame
	await process_frame
	for failure in failures:
		push_error(failure)
	print("urban_voxel_test: ", "PASS" if failures.is_empty() else "FAIL", " ", failures)
	quit(0 if failures.is_empty() else 1)

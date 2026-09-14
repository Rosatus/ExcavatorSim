extends SceneTree

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)

func run() -> void:
	var catalog := root.get_node("MapCatalog")
	if not catalog.construction_available():
		push_error("Build godot/dist/maps/construction.pck before this test")
		quit(1)
		return
	catalog.active_map_id = "construction"
	catalog.retained_model_id = "sy135"
	var start_usec := Time.get_ticks_usec()
	var scene := load("res://scenes/main.tscn").instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	var load_ms := (Time.get_ticks_usec() - start_usec) / 1000
	await process_frame
	var first_draw_ms := -1
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		first_draw_ms = (Time.get_ticks_usec() - start_usec) / 1000
	print("CONSTRUCTION_LOAD ", JSON.stringify({"load_ms": load_ms, "first_draw_ms": first_draw_ms,
		"texture_memory_bytes": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED),
		"video_memory_bytes": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)}))
	for frame in 5:
		await physics_frame
	var map := scene.get_node("ConstructionMap") as Node3D
	var spawn_point := map.get_node("WorkArea/SpawnPoint") as Node3D
	var excavation_area := map.get_node("WorkArea/ExcavationArea") as Node3D
	check(spawn_point.position.is_equal_approx(Vector3(38.301582, -0.02, 31.119902)), "Saved construction spawn changed")
	check((-spawn_point.global_basis.z).dot(Vector3.BACK) > 0.99999, "Saved construction heading is not +Z")
	var area_size: Vector2 = excavation_area.get_meta("size_m")
	check(area_size == Vector2(18, 28), "Construction work area dimensions changed")
	var near_edge := excavation_area.get_node("NearEdge") as Node3D
	check(is_equal_approx(near_edge.global_position.z, 39.5), "Construction work area near edge changed")
	check(absf(near_edge.global_basis.x.dot(-spawn_point.global_basis.z)) < 0.00001, "Near edge is not perpendicular to spawn heading")
	var ground := map.get_node("Ground") as Terrain3D
	check(ground != null, "Map ground is not Terrain3D")
	check(ground.data.get_region_count() == 16, "PCK lost Terrain3D regions")
	check(ground.assets.get_texture_count() == 1, "PCK lost terrain textures")
	check(is_equal_approx(ground.data.get_height(Vector3.ZERO), -0.02), "Terrain grade changed")
	check(ground.material.world_background == Terrain3DMaterial.NONE, "Unexpected infinite background terrain")
	check(map.get_node_or_null("WorldEnvironment") == null, "Map duplicates product environment")
	check(scene.get_node("WorldEnvironment") is Sky3D, "Product Sky3D unavailable")
	var bodies := map.find_children("*", "StaticBody3D", true, false).size()
	var world := map.get_world_3d()
	var area_shape := BoxShape3D.new()
	area_shape.size = Vector3(area_size.x, 6, area_size.y)
	var area_query := PhysicsShapeQueryParameters3D.new()
	area_query.shape = area_shape
	area_query.transform = Transform3D(Basis.IDENTITY, Vector3(excavation_area.global_position.x, 3.05, excavation_area.global_position.z))
	area_query.collision_mask = 1
	check(world.direct_space_state.intersect_shape(area_query, 1).is_empty(), "Construction work area overlaps a solid obstacle")
	var area_bounds := AABB(Vector3(excavation_area.global_position.x - area_size.x / 2, -0.15, 39.5), Vector3(area_size.x, 6, area_size.y))
	for mesh_node in map.find_children("*", "MeshInstance3D", true, false):
		if map.get_node("WorkArea").is_ancestor_of(mesh_node):
			continue
		check(not (mesh_node.global_transform * mesh_node.get_aabb()).intersects(area_bounds), "Construction work area overlaps a model: %s" % mesh_node.get_path())
	for point in [Vector3(0, 0, 0), Vector3(200, 0, 200), Vector3(-200, 0, -300)]:
		var ray := PhysicsRayQueryParameters3D.create(point + Vector3.UP * 1.0, point - Vector3.UP * 1.0, 1)
		var hit := world.direct_space_state.intersect_ray(ray)
		check(not hit.is_empty(), "Map ground collision missing at %s" % point)
		if not hit.is_empty():
			print("MAP_RAY ", point, " -> ", hit.get("position"), " owner=", hit.get("collider"))
	var chassis := scene.get_node("ChassisMotionRoot") as TrackedChassisController
	chassis.set_test_input_focus_bypass_for_test(true)
	chassis.set_commands_for_test(0, 0)
	for frame in 90:
		await physics_frame
	var before := chassis.global_position
	check(Vector2(before.x, before.z).distance_to(Vector2(spawn_point.global_position.x, spawn_point.global_position.z)) < 0.05, "Real map did not use the saved spawn")
	check((-chassis.global_basis.z).dot(Vector3.BACK) > 0.9999, "Real map did not use the snapped heading")
	var snapshot := chassis._jolt_runtime.get_post_step_snapshot()
	check(snapshot.get("grounded", false), "Real map has no track support")
	check(snapshot.get("track_support_source_counts", {}).get("static_map", 0) > 0, "Real map ground owner was rejected")
	chassis.set_commands_for_test(1, 1)
	for frame in 120:
		await physics_frame
	var distance := chassis.global_position.distance_to(before)
	check(distance > 0.3, "Cannot drive at construction spawn")
	check(absf(chassis.global_position.y - before.y) < 1.0, "Chassis fell or spawned inside obstacle")
	check(not scene.get_node("TerrainRoot/TerrainCollider").enabled, "Training collisions active on real map")
	check(scene.get_node("TerrainRoot/VoxelWorkZone").terrain != null, "Construction voxel soil is missing")
	# Open terrain away from source prop colliders must supply native RID support.
	chassis.map_spawn_position = Vector3(200, 0, 200)
	chassis.reset_for_test()
	chassis.set_test_input_focus_bypass_for_test(true)
	chassis.set_commands_for_test(0, 0)
	for frame in 90:
		await physics_frame
	check(chassis._jolt_runtime.get_post_step_snapshot().get("grounded", false), "Terrain3D RID does not support tracks")
	var open_start := chassis.global_position
	chassis.set_commands_for_test(1, 1)
	for frame in 90:
		await physics_frame
	check(chassis.global_position.distance_to(open_start) > 0.3, "Cannot drive on open Terrain3D")
	check(absf(chassis.global_position.y - open_start.y) < 0.5, "Vehicle fell through open Terrain3D")
	if DisplayServer.get_name() != "headless":
		var draw_calls := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		check(draw_calls > 0, "Rendered validation did not draw any geometry")
		print("CONSTRUCTION_RENDER ", JSON.stringify({"draw_calls": draw_calls,
			"texture_memory_bytes": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED),
			"video_memory_bytes": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)}))
	print("CONSTRUCTION_EVIDENCE ", JSON.stringify({"load_ms": load_ms, "static_bodies": bodies, "travel_m": distance, "start": before, "end": chassis.global_position, "failures": failures}))
	current_scene = null
	scene.queue_free()
	await process_frame
	await process_frame
	if failures.is_empty():
		print("construction_pack_test: PASS")
		quit()
	else:
		for message in failures:
			push_error(message)
		quit(1)

extends SceneTree

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)

func run() -> void:
	var catalog := root.get_node("MapCatalog")
	if not catalog.urban_available():
		push_error("Build godot/dist/maps/urban.pck before this test")
		quit(1)
		return
	catalog.active_map_id = "urban"
	catalog.retained_model_id = "sy135"
	for shader_name in ["Flag_Inst", "Foliage_01_Inst", "prp_tarp_mat"]:
		var wind := load("res://maps/urban/Shaders/%s.tres" % shader_name) as VisualShader
		check(wind != null, "Urban pack lost wind shader: " + shader_name)
		if wind != null:
			var code := wind.get_code()
			check(not code.contains("INV_VIEW_MATRIX * vec4( VERTEX") and code.contains("MODEL_MATRIX * vec4( VERTEX"),
				"Packed wind phase depends on camera: " + shader_name)
	var start_usec := Time.get_ticks_usec()
	var scene := load("res://scenes/main.tscn").instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	var load_ms := (Time.get_ticks_usec() - start_usec) / 1000
	await process_frame
	for frame in 5:
		await physics_frame
	var map := scene.get_node("StaticMap") as Node3D
	var spawn_point := map.get_node("WorkArea/SpawnPoint") as Node3D
	check(spawn_point != null, "Urban map lost the spawn marker")
	check(map.get_node_or_null("WorkArea/ExcavationArea") != null, "Urban map lost its voxel work-zone marker")
	check(map.get_node_or_null("WorldEnvironment") == null, "Urban map duplicates product environment")
	check(scene.get_node("WorldEnvironment") is Sky3D, "Product Sky3D unavailable")
	var sky := scene.get_node("WorldEnvironment") as Sky3D
	check(is_equal_approx(sky.current_time, 12.0), "Urban map did not pin the noon sun")
	check(sky.sky != null and sky.sky.sun_altitude < deg_to_rad(19.5), "Urban noon sun stayed at or below the 10:30 height (polar %.1f deg)" % rad_to_deg(sky.sky.sun_altitude if sky.sky != null else -1.0))
	for light in map.find_children("*", "DirectionalLight3D"):
		check(not light.visible, "Urban map directional light stayed enabled")
	check(not scene.get_node("TerrainRoot/TerrainCollider").enabled, "Training collider leaked into urban map")
	var zone = scene.get_node("TerrainRoot/VoxelWorkZone")
	check(zone.terrain != null, "Urban voxel work zone did not initialize")
	if zone.terrain != null:
		var ready_frames := 0
		while not zone.readiness.is_ready(zone.initial_ticket) and ready_frames < 1200:
			await physics_frame
			ready_frames += 1
		check(zone.readiness.is_ready(zone.initial_ticket), "Urban voxel collision never became ready")
	var bodies := map.find_children("*", "StaticBody3D", true, false).size()
	check(bodies > 0, "Urban map lost its static collisions")
	var world := map.get_world_3d()
	var ray := PhysicsRayQueryParameters3D.create(spawn_point.global_position + Vector3.UP * 4.0, spawn_point.global_position - Vector3.UP * 4.0, 1)
	check(not world.direct_space_state.intersect_ray(ray).is_empty(), "Urban ground collision missing under spawn")
	var holes := 0
	var supported := 0
	var probed := 0
	for gx in range(-110, 81, 20):
		for gz in range(-70, 91, 20):
			probed += 1
			var probe := PhysicsRayQueryParameters3D.create(Vector3(gx, 8.0, gz), Vector3(gx, -4.0, gz), 1)
			var hit: Dictionary = world.direct_space_state.intersect_ray(probe)
			if hit.is_empty():
				holes += 1
			elif hit.position.y <= 3.0:
				supported += 1
	check(holes == 0, "Urban ground has %d/%d collision holes" % [holes, probed])
	check(supported * 100 >= probed * 60, "Urban ground coverage too low: %d/%d" % [supported, probed])
	var chassis := scene.get_node("ChassisMotionRoot") as TrackedChassisController
	chassis.set_test_input_focus_bypass_for_test(true)
	chassis.set_commands_for_test(0, 0)
	for frame in 90:
		await physics_frame
	var before := chassis.global_position
	check(Vector2(before.x, before.z).distance_to(Vector2(spawn_point.global_position.x, spawn_point.global_position.z)) < 0.5, "Urban map did not use the spawn marker")
	var snapshot := chassis._jolt_runtime.get_post_step_snapshot()
	check(snapshot.get("grounded", false), "Urban map has no track support")
	check(snapshot.get("track_support_source_counts", {}).get("static_map", 0) > 0, "Urban ground owner was rejected")
	chassis.set_commands_for_test(1, 1)
	for frame in 120:
		await physics_frame
	var distance := chassis.global_position.distance_to(before)
	check(distance > 0.3, "Cannot drive at urban spawn")
	check(absf(chassis.global_position.y - before.y) < 1.0, "Chassis fell or spawned inside obstacle")
	print("URBAN_EVIDENCE ", JSON.stringify({"load_ms": load_ms, "static_bodies": bodies, "travel_m": distance, "start": before, "end": chassis.global_position, "failures": failures}))
	current_scene = null
	scene.queue_free()
	await process_frame
	await process_frame
	if failures.is_empty():
		print("urban_pack_test: PASS")
		quit()
	else:
		for message in failures:
			push_error(message)
		quit(1)

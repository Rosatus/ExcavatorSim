extends SceneTree

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)

func run() -> void:
	var detached_chassis := TrackedChassisController.new()
	var detached_status := detached_chassis.get_status_snapshot()
	check(not detached_status.configured and not detached_status.terrain_identity_valid, "Detached chassis exposed valid runtime state")
	detached_chassis.free()
	var catalog := root.get_node("MapCatalog")
	check(not catalog.construction_available(), "Missing pack unexpectedly available; run with --without-map-packs")
	check(not catalog.select_map("construction", "sy135"), "Missing pack accepted")
	check(catalog.active_map_id == "training", "Missing pack mutated active map")
	var packer := PCKPacker.new()
	var path := "user://map_switch_fixture.pck"
	check(packer.pck_start(path) == OK, "Could not start fixture pack")
	check(packer.add_file(catalog.CONSTRUCTION_SCENE, "res://tests/fixtures/static_map.tscn") == OK, "Could not add fixture scene")
	check(packer.flush() == OK, "Could not flush fixture pack")
	check(ProjectSettings.load_resource_pack(path, false), "Fixture pack mount failed")
	check(catalog.construction_available(), "Mounted scene not discovered")
	catalog.active_map_id = "construction"
	catalog.retained_model_id = "sy135"
	var scene := load("res://scenes/main.tscn").instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	await process_frame
	await physics_frame
	var session := scene.get_node("ProductSession") as ProductSession
	check(session.bucket_ground_mode == BucketGroundInteractionMode.NORMAL, "Construction did not default to normal bucket mode")
	var chassis := scene.get_node("ChassisMotionRoot") as TrackedChassisController
	var spawn_point := scene.get_node("StaticMap/WorkArea/SpawnPoint") as Node3D
	check(chassis.map_spawn_position.is_equal_approx(spawn_point.global_position), "Map spawn marker was not applied")
	var ui := scene.get_node("OperatorUI") as MotionOperatorUI
	var selector := ui.get_control_for_test("map_selector") as OptionButton
	check(selector != null and selector.selected == 1, "Menu does not reflect active map")
	check(selector.get_item_text(1) == "地图：土方工地" and selector.get_item_text(2) == "地图：市政施工（未安装）", "Map names do not match product labels")
	ui._set_panel_collapsed(false)
	ui._on_map_selected(0)
	check(ui._confirmation.visible and catalog.active_map_id == "construction", "Map changed before confirmation")
	ui._confirmation.hide()
	ui._on_destructive_canceled()
	check(selector.selected == 1, "Canceled map selection was not restored")
	ui._set_panel_collapsed(true)
	check(session.active_model_id == "sy135", "Map switch lost selected model")
	check(session.lifecycle == "running", "Driving map did not start")
	check(scene.get_node("TerrainRoot/VoxelWorkZone").terrain == null, "Driving map created voxel collisions")
	check(not scene.get_node("TerrainRoot/TerrainCollider").enabled, "Training collider leaked into static map")
	check(not scene.get_node("TerrainRoot/ExcavationWorld").is_soil_runtime_ready(), "Driving map enabled excavation")
	chassis.set_test_input_focus_bypass_for_test(true)
	chassis.set_commands_for_test(0, 0)
	for frame in 90:
		await physics_frame
	check(Vector2(chassis.global_position.x, chassis.global_position.z).distance_to(Vector2(38.301582, 31.119902)) < 0.05, "Map did not spawn at the saved position")
	check((-chassis.global_basis.z).dot(Vector3.BACK) > 0.9999, "Map did not spawn facing +Z")
	check(chassis._jolt_runtime != null, "No static-map Jolt runtime")
	if chassis._jolt_runtime != null:
		var snapshot := chassis._jolt_runtime.get_post_step_snapshot()
		check(bool(snapshot.get("grounded", false)), "Static-map track support missing")
		check(int(snapshot.get("track_support_source_counts", {}).get("static_map", 0)) > 0, "Tracks did not use static-map collision owner")
		var start := chassis.global_position
		chassis.set_commands_for_test(1, 1)
		for frame in 120:
			await physics_frame
		check(chassis.global_position.distance_to(start) > 0.3, "Static-map chassis did not drive")
		check(absf(chassis.global_position.y - start.y) < 1, "Static-map chassis fell through ground")
	check(session.request_reset(), "Static-map reset failed")
	await physics_frame
	check(Vector2(chassis.global_position.x, chassis.global_position.z).distance_to(Vector2(38.301582, 31.119902)) < 0.05, "Map reset lost the saved spawn")
	check((-chassis.global_basis.z).dot(Vector3.BACK) > 0.9999, "Map reset lost the saved heading")
	check(not scene.get_node("TerrainRoot/TerrainCollider").enabled, "Reset resurrected training collider")
	check(session.request_model_switch("sy205"), "Model switch on driving map failed")
	check(not scene.get_node("TerrainRoot/TerrainCollider").enabled, "Model switch resurrected training collider")
	check(session.request_model_switch("sy135"), "Return to SY135 on driving map failed")
	check(catalog.select_map("training", "sy135"), "Return to training rejected")
	await process_frame
	await process_frame
	await physics_frame
	check(current_scene != scene, "Map did not reload scene")
	check(current_scene.get_node_or_null("StaticMap") == null, "Construction instance leaked into training")
	check(current_scene.get_node("ProductSession").active_model_id == "sy135", "Return to training lost model")
	check(current_scene.get_node("TerrainRoot/VoxelWorkZone").terrain != null, "Training voxel terrain not restored")
	await physics_frame
	check(current_scene.get_node("ProductSession").bucket_ground_mode == BucketGroundInteractionMode.PASSTHROUGH, "Return to training did not enable pass-through")
	check(catalog.select_map("construction", "sy135"), "Switch from training to construction rejected")
	await process_frame
	await process_frame
	await physics_frame
	await physics_frame
	check(current_scene.get_node("ProductSession").bucket_ground_mode == BucketGroundInteractionMode.NORMAL, "Switch to construction retained training pass-through")
	var construction_ui := current_scene.get_node("OperatorUI") as MotionOperatorUI
	check(not (construction_ui.get_control_for_test("bucket_passthrough") as CheckButton).button_pressed, "Construction toggle remained enabled")
	var bridge := root.get_node("CanTelemetryBridge")
	bridge._resolve_once()
	check(bridge._presentation == current_scene.get_node("MotionPresentation"), "CAN retained retired map frames")
	current_scene.queue_free()
	await process_frame
	DirAccess.remove_absolute(path)
	if failures.is_empty():
		print("map_switch_test: PASS")
		quit(0)
	else:
		for message in failures:
			push_error(message)
		quit(1)

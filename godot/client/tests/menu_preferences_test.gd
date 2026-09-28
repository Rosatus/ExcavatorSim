extends SceneTree

var failures: Array[String] = []
var saved_bytes := PackedByteArray()
var had_config := false

func _init() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	if not ok:
		failures.append(label)

func run() -> void:
	var path := MotionOperatorUI.CONFIG_PATH
	had_config = FileAccess.file_exists(path)
	if had_config:
		saved_bytes = FileAccess.get_file_as_bytes(path)
	var config := ConfigFile.new()
	config.save(path)
	var catalog := root.get_node("MapCatalog")
	catalog.active_map_id = "training"
	catalog.retained_model_id = "sy135"
	var scene := load("res://scenes/main.tscn").instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	for i in 10:
		await process_frame
		await physics_frame
	var ui := scene.get_node("OperatorUI") as MotionOperatorUI
	check(ui._feedback.is_muted() and ui._mute_audio_button.button_pressed, "fresh config defaults muted")
	ui._mute_audio_button.button_pressed = false
	ui._save_video_config(MotionOperatorUI.WINDOW_MODE_WINDOWED, 120)
	ui._on_test_graphics_toggled(true)
	ui._on_cutting_diagnostics_toggled(true)
	ui._on_unlimited_bucket_toggled(true)
	ui._on_level_assist_toggled(true)
	ui._on_bucket_passthrough_toggled(false)
	ui._camera.set_mode(CameraRig.MODE_CAB)
	ui._product_session.request_model_switch("sy155w")
	for i in 5:
		await physics_frame
	verify(scene, "model")
	ui.set_ui_theme_for_test("industrial")
	check(not ui._mute_audio_button.button_pressed, "theme rebuild preserves mute checkbox")
	scene.queue_free()
	await process_frame
	# Recreate the same main scene exactly as map reload does; use the real pack.
	check(catalog.construction_available(), "construction map pack available")
	catalog.active_map_id = "construction"
	catalog.retained_model_id = "sy155w"
	scene = load("res://scenes/main.tscn").instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	for i in 10:
		await process_frame
		await physics_frame
	verify(scene, "map")
	ui = scene.get_node("OperatorUI") as MotionOperatorUI
	ui._on_bucket_passthrough_toggled(true)
	await physics_frame
	scene.queue_free()
	await process_frame
	# Explicit passthrough must override construction's normal default too.
	scene = load("res://scenes/main.tscn").instantiate() as Node3D
	root.add_child(scene)
	for i in 5:
		await physics_frame
	check(scene.get_node("ProductSession").bucket_ground_mode == BucketGroundInteractionMode.PASSTHROUGH, "explicit bucket policy wins over map default")
	scene.queue_free()
	await process_frame
	if had_config:
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_buffer(saved_bytes)
		file.close()
	else:
		DirAccess.remove_absolute(path)
	for failure in failures:
		push_error(failure)
	print("menu_preferences_test: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

func verify(scene: Node3D, label: String) -> void:
	var ui := scene.get_node("OperatorUI") as MotionOperatorUI
	check(not ui._feedback.is_muted() and not ui._mute_audio_button.button_pressed, label + " audio")
	check(ui._visual_quality.profile == "test", label + " graphics")
	check(Engine.max_fps == 120, label + " graphics preserves FPS preference")
	check(ui._excavation_world.voxel_diagnostics_enabled, label + " diagnostics")
	check(ui._excavation_world.voxel_unlimited_bucket_for_testing, label + " capacity")
	check(ui._chassis.level_assist_enabled, label + " level assist")
	check(ui._product_session.bucket_ground_mode == BucketGroundInteractionMode.NORMAL, label + " ground policy")
	check(ui._camera.get_mode() == CameraRig.MODE_CAB, label + " camera")

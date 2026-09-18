extends SceneTree
## Throwaway visual check: capture the menu and driving overlay in both
## UI themes. Run windowed (not headless) so CanvasItem shaders render.


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute("E:/projects/ExcavatorSim/output/ui_theme")
	var scene := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for i in 240:
		await process_frame
	var ui := scene.get_node_or_null("OperatorUI")
	if ui == null:
		push_error("OperatorUI missing")
		quit(1)
		return
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	ui.set_ui_theme_for_test("debug")
	ui._input(esc)
	for i in 40:
		await process_frame
	_shot("debug_menu")
	ui.set_ui_theme_for_test("industrial")
	for i in 40:
		await process_frame
	_shot("industrial_menu")
	ui.set_ui_theme_for_test("sany")
	for i in 40:
		await process_frame
	_shot("sany_menu")
	ui._input(esc)
	for i in 40:
		await process_frame
	_shot("sany_drive")
	# Driving-time assist overlays under the sany console theme.
	if ui._chassis != null:
		ui._chassis.set_assist_menu_open(true)
		for i in 30:
			await process_frame
		_shot("sany_assist_menu")
		ui._chassis.set_assist_menu_open(false)
	ui._slope_side_view.set_view(_fake_assist_view())
	for attempt in 8:
		ui._slope_side_view.visible = true
		await process_frame
		if ui._slope_side_view.visible:
			break
	_shot("sany_slope_view")
	ui._slope_side_view.visible = false
	ui.set_ui_theme_for_test("industrial")
	for i in 40:
		await process_frame
	_shot("industrial_drive")
	ui.set_ui_theme_for_test("debug")
	for i in 40:
		await process_frame
	_shot("debug_drive")
	scene.queue_free()
	await process_frame
	quit(0)


func _shot(tag: String) -> void:
	var path := "E:/projects/ExcavatorSim/output/ui_theme/%s.png" % tag
	var err := root.get_viewport().get_texture().get_image().save_png(path)
	print("shot ", tag, " -> ", err)


## Fabricated slope_assist.view snapshot for the side-view chrome check: a
## preview grade with a plausible machine figure, terrain and tooth offset.
func _fake_assist_view() -> Dictionary:
	return {
		"origin_xz": Vector2.ZERO,
		"axis": Vector2.RIGHT,
		"toe_s": 4.0,
		"toe_h": -0.4,
		"grade": -0.35,
		"s_min": 0.5,
		"s_max": 6.5,
		"joints": {
			"swing_joint": Vector3(0.0, 1.2, 0.0),
			"boom_joint": Vector3(1.7, 1.9, 0.0),
			"arm_joint": Vector3(4.6, 3.0, 0.0),
			"bucket_joint": Vector3(6.9, 1.8, 0.0),
		},
		"tooth": Vector3(7.7, 0.6, 0.0),
		"terrain": PackedVector2Array([
			Vector2(-5.0, 0.0), Vector2(-2.0, 0.15), Vector2(0.5, 0.0),
			Vector2(2.5, 0.35), Vector2(4.5, 0.3), Vector2(6.0, 0.5), Vector2(8.0, 0.45),
		]),
		"knee_w": 0.6,
		"mode": "preview",
		"distance_m": 4.0,
		"angle_deg": -19.0,
		"volume_m3": 0.42,
		"tooth_err": 0.06,
	}

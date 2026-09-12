extends SceneTree

var failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene := load("res://scenes/main.tscn").instantiate() as Node3D
	root.add_child(scene)
	await process_frame
	await physics_frame
	var ui := scene.get_node("OperatorUI") as MotionOperatorUI
	var session := scene.get_node("ProductSession") as ProductSession
	var camera := scene.get_node("Camera3D") as CameraRig
	check(session.lifecycle == "running", "product did not auto-start")
	check(ui.is_panel_collapsed_for_test() and not paused, "menu blocks initial drive")
	check(not ui._guide_panel.visible, "onboarding blocks initial drive")
	var recorder := scene.get_node("PerformanceCapture")
	check(ui.get_control_for_test("performance_capture") != null, "capture menu entry missing")
	check(not recorder.recording, "capture must default off")
	key(ui, KEY_F12)
	check(recorder.recording and ui._capture_badge.visible and not paused, "F12 did not start a nonblocking capture")
	check(ui._cutting_diagnostics_button.disabled, "diagnostic toggle can interfere with capture")
	for index in 4:
		await physics_frame
		await process_frame
	check(not recorder._frames.is_empty(), "capture has no runtime frame samples")
	var observed_soil := false
	for frame in recorder._frames:
		observed_soil = observed_soil or frame[17] > 0.0
	check(observed_soil, "real excavation world did not publish soil timing")
	key(ui, KEY_F10)
	check(recorder.marker_count == 1, "F10 marker missing")
	key(ui, KEY_F12)
	check(not recorder.recording and not ui._capture_badge.visible and FileAccess.file_exists(recorder.last_path), "F12 stop did not save capture")
	check(not ui._cutting_diagnostics_button.disabled, "capture did not release diagnostic toggle")
	var drag := InputEventMouseButton.new()
	drag.button_index = MOUSE_BUTTON_MIDDLE
	drag.pressed = true
	camera._unhandled_input(drag)
	check(camera._dragging, "camera drag setup failed")
	check(ui._can_output_button.is_visible_in_tree() and ui._gateway_button.is_visible_in_tree() and ui._pc001_handshake_lamp.is_visible_in_tree(), "hardware controls not persistent during driving")
	var epoch := session.authority_epoch
	key(ui, KEY_ESCAPE)
	check(paused and session.lifecycle == "paused", "menu did not pause simulation")
	check(ui._can_output_button.is_visible_in_tree() and ui._gateway_button.is_visible_in_tree() and ui._pc001_handshake_lamp.is_visible_in_tree(), "hardware controls hidden in menu")
	check(root.gui_get_focus_owner() == ui._menu["resume"], "initial menu focus missing")
	check(not camera.can_process(), "camera remains active in menu")
	check(not camera._dragging and camera._menu_input_blocked, "menu did not cancel camera drag")
	var bridge := root.get_node("CanTelemetryBridge")
	check(bridge.can_process(), "gateway supervision paused with gameplay")
	var nav := InputEventJoypadButton.new()
	nav.button_index = JOY_BUTTON_DPAD_DOWN
	nav.pressed = true
	root.push_input(nav)
	await process_frame
	check(root.gui_get_focus_owner() != ui._menu["resume"], "D-pad did not move menu focus")
	check(not ui._motion_client.get_status_snapshot().get("focused", true), "gateway input not cleared")
	for resolution in [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(2560, 1080)]:
		root.size = resolution
		root.content_scale_size = resolution
		await process_frame
		await process_frame
		var rect := ui._status_panel.get_global_rect()
		check(rect.position.x >= 0 and rect.position.y >= 0 and rect.end.x <= resolution.x and rect.end.y <= resolution.y, "menu exceeds viewport: %s" % rect)
	var joy := InputEventJoypadButton.new()
	joy.button_index = JOY_BUTTON_RIGHT_SHOULDER
	joy.pressed = true
	ui._input(joy)
	check((ui._menu["tabs"] as TabContainer).current_tab == 1, "controller tab navigation failed")
	check(ui.get_prompt_mode_for_test() == "gamepad", "controller prompt missing")
	joy.button_index = JOY_BUTTON_B
	ui._input(joy)
	check(not paused and session.lifecycle == "running", "controller back failed")
	check(session.authority_epoch == epoch, "menu changed session identity")
	joy.button_index = JOY_BUTTON_START
	ui._input(joy)
	check(paused, "controller menu failed")
	var generation := session.generation
	var prior_model := session.active_model_id
	ui._on_model_selected(1 if prior_model == "sy205" else 0)
	check(ui._confirmation.visible, "model change bypassed confirmation")
	joy.button_index = JOY_BUTTON_B
	ui._confirmation.window_input.emit(joy)
	check(not ui._confirmation.visible and session.active_model_id == prior_model and session.generation == generation and paused, "dialog B did not cancel only model change")
	ui._on_reset_pressed()
	check(ui._confirmation.visible and session.generation == generation, "reset bypassed confirmation")
	ui._confirmation.hide()
	ui._on_destructive_canceled()
	check(session.generation == generation and paused, "cancel changed world or closed menu")
	key(ui, KEY_F12)
	check(recorder.recording and paused, "capture cannot start while menu is paused")
	ui._on_reset_pressed()
	ui._confirmation.hide()
	ui._on_destructive_confirmed()
	check(session.generation == generation + 1, "reset was not exactly once")
	check(not paused and session.lifecycle == "running" and ui.is_panel_collapsed_for_test(), "reset did not return to driving")
	var excavation := scene.get_node("TerrainRoot/ExcavationWorld") as ExcavationWorld
	check(recorder.recording and excavation._voxel_authority.performance_timing_enabled, "world reset lost recording timing")
	check(not excavation.voxel_diagnostics_enabled, "recording/reset enabled full diagnostics")
	key(ui, KEY_F12)
	check(not excavation._voxel_authority.performance_timing_enabled, "recording stop left clocks enabled")
	key(ui, KEY_F6)
	key(ui, KEY_F7)
	check(not paused and session.lifecycle == "running", "retired hotkeys changed gameplay")
	session.request_pause()
	key(ui, KEY_ESCAPE)
	key(ui, KEY_ESCAPE)
	check(session.lifecycle == "paused", "menu resumed external lifecycle pause")
	session.request_start()
	key(ui, KEY_ESCAPE)
	scene.queue_free()
	await process_frame
	check(not paused, "UI teardown left scene paused")
	for failure in failures:
		push_error(failure)
	print("operator_ui_test: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

func key(ui: MotionOperatorUI, code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	ui._input(event)

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

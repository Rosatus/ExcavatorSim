extends SceneTree

const HUD_SCENE := "res://scenes/control_input_hud.tscn"
const ACTION_CONTRACT := {
	"motion_arm_positive": {"key": KEY_W, "path": "Margin/VBox/Sticks/LeftStick/Grid/W", "copy": "W\n小臂伸"},
	"motion_swing_negative": {"key": KEY_A, "path": "Margin/VBox/Sticks/LeftStick/Grid/A", "copy": "A\n左回转"},
	"motion_arm_negative": {"key": KEY_S, "path": "Margin/VBox/Sticks/LeftStick/Grid/S", "copy": "S\n小臂收"},
	"motion_swing_positive": {"key": KEY_D, "path": "Margin/VBox/Sticks/LeftStick/Grid/D", "copy": "D\n右回转"},
	"motion_boom_positive": {"key": KEY_I, "path": "Margin/VBox/Sticks/RightStick/Grid/I", "copy": "I\n大臂降"},
	"motion_bucket_negative": {"key": KEY_J, "path": "Margin/VBox/Sticks/RightStick/Grid/J", "copy": "J\n铲斗收"},
	"motion_boom_negative": {"key": KEY_K, "path": "Margin/VBox/Sticks/RightStick/Grid/K", "copy": "K\n大臂升"},
	"motion_bucket_positive": {"key": KEY_L, "path": "Margin/VBox/Sticks/RightStick/Grid/L", "copy": "L\n铲斗翻"},
	"track_left_forward": {"key": KEY_R, "path": "Margin/VBox/Tracks/LeftTrack/Keys/R", "copy": "R  前进"},
	"track_left_reverse": {"key": KEY_F, "path": "Margin/VBox/Tracks/LeftTrack/Keys/F", "copy": "F  后退"},
	"track_right_forward": {"key": KEY_Y, "path": "Margin/VBox/Tracks/RightTrack/Keys/Y", "copy": "Y  前进"},
	"track_right_reverse": {"key": KEY_H, "path": "Margin/VBox/Tracks/RightTrack/Keys/H", "copy": "H  后退"},
}

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var original_scale_size := root.content_scale_size
	var original_window_size := root.size
	_install_product_input_map()
	var packed := load(HUD_SCENE) as PackedScene
	if packed == null:
		_fail("control input HUD scene did not load")
		_finish(original_scale_size, original_window_size)
		return
	var hud := packed.instantiate() as ControlInputHUD
	root.add_child(hud)
	await process_frame
	await _check_layout(hud, Vector2i(1280, 720))
	await _check_layout(hud, Vector2i(1920, 1080))
	_check_copy_and_mouse_contract(hud)
	_check_input_feedback(hud)
	hud.queue_free()
	await process_frame
	_finish(original_scale_size, original_window_size)


func _check_layout(hud: ControlInputHUD, resolution: Vector2i) -> void:
	root.size = resolution
	root.content_scale_size = resolution
	await process_frame
	await process_frame
	var rect := hud.get_global_rect()
	if (
		rect.position.x < 0.0
		or rect.position.y < 0.0
		or rect.end.x > resolution.x
		or rect.end.y > resolution.y
	):
		_fail("control input HUD escaped %dx%d bounds: %s" % [resolution.x, resolution.y, rect])
	if absf(rect.end.x - float(resolution.x) + 16.0) > 0.1 or absf(rect.end.y - float(resolution.y) + 16.0) > 0.1:
		_fail("control input HUD lost its 16 px lower-right inset at %dx%d" % [resolution.x, resolution.y])
	var panel_style := hud.get_theme_stylebox("panel") as StyleBoxFlat
	if panel_style == null or panel_style.bg_color.a <= 0.0 or panel_style.bg_color.a >= 1.0:
		_fail("control input HUD background is not translucent")


func _check_copy_and_mouse_contract(hud: ControlInputHUD) -> void:
	if ControlInputHUD.ACTION_TILE_PATHS.size() != 12:
		_fail("control input HUD does not own all twelve actions")
	for action in ControlInputHUD.ACTION_TILE_PATHS:
		var tile := hud.get_action_tile_for_test(action)
		if tile == null:
			_fail("control input HUD is missing tile for %s" % action)
			continue
		var expected: Dictionary = ACTION_CONTRACT[action]
		if String(ControlInputHUD.ACTION_TILE_PATHS[action]) != String(expected["path"]):
			_fail("control input HUD uses the wrong tile for %s" % action)
		var label := tile.get_node_or_null("Label") as Label
		if label == null or label.text != String(expected["copy"]):
			_fail("control input HUD uses the wrong copy for %s" % action)
		var key_events: Array[InputEventKey] = []
		var joy_events: Array[InputEvent] = []
		for event in InputMap.action_get_events(action):
			if event is InputEventKey:
				key_events.append(event)
			elif event is InputEventJoypadMotion or event is InputEventJoypadButton:
				joy_events.append(event)
		if (
			key_events.size() != 1
			or key_events[0].physical_keycode != int(expected["key"])
		):
			_fail("product InputMap uses the wrong keyboard binding for %s" % action)
		if joy_events.size() != 1:
			_fail("product InputMap did not retain exactly one gamepad binding for %s" % action)
	var copy := _collect_label_copy(hud)
	for key_name in ["W", "A", "S", "D", "I", "J", "K", "L", "R", "F", "Y", "H"]:
		if key_name not in copy:
			_fail("control input HUD omitted key %s" % key_name)
	_check_mouse_ignore_recursive(hud)


func _check_input_feedback(hud: ControlInputHUD) -> void:
	Input.action_press("motion_arm_positive")
	Input.action_press("motion_swing_positive")
	hud.refresh_input_state_for_test()
	if not hud.is_action_highlighted_for_test("motion_arm_positive"):
		_fail("W/arm-out action did not highlight")
	if not hud.is_action_highlighted_for_test("motion_swing_positive"):
		_fail("D/swing-right action did not highlight simultaneously")

	Input.action_press("motion_arm_negative")
	hud.refresh_input_state_for_test()
	if (
		not hud.is_action_highlighted_for_test("motion_arm_positive")
		or not hud.is_action_highlighted_for_test("motion_arm_negative")
	):
		_fail("opposing arm directions were not both highlighted")
	if not is_zero_approx(Input.get_axis("motion_arm_negative", "motion_arm_positive")):
		_fail("opposing arm directions did not resolve motion to zero")

	Input.action_press("track_left_forward")
	Input.action_press("track_left_reverse")
	Input.action_press("track_right_reverse")
	hud.refresh_input_state_for_test()
	if (
		not hud.is_action_highlighted_for_test("track_left_forward")
		or not hud.is_action_highlighted_for_test("track_left_reverse")
		or not hud.is_action_highlighted_for_test("track_right_reverse")
	):
		_fail("independent track pedals were not highlighted together")
	if not is_zero_approx(
		Input.get_action_strength("track_left_forward")
		- Input.get_action_strength("track_left_reverse")
	):
		_fail("opposing left-track pedals did not resolve motion to zero")

	for action in ControlInputHUD.ACTION_TILE_PATHS:
		Input.action_release(action)
	hud.refresh_input_state_for_test()
	for action in ControlInputHUD.ACTION_TILE_PATHS:
		if hud.is_action_highlighted_for_test(action):
			_fail("released action remained highlighted: %s" % action)


func _install_product_input_map() -> void:
	for action in ACTION_CONTRACT:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		var stale_key := InputEventKey.new()
		stale_key.physical_keycode = KEY_Q
		InputMap.action_add_event(action, stale_key)
		var stale_axis := InputEventJoypadMotion.new()
		stale_axis.axis = JOY_AXIS_TRIGGER_RIGHT
		stale_axis.axis_value = 1.0
		InputMap.action_add_event(action, stale_axis)
	var motion_client := MotionClient.new()
	motion_client.call("_ensure_input_actions")
	motion_client.free()
	var chassis := TrackedChassisController.new()
	chassis.call("_ensure_input_actions")
	chassis.free()


func _check_mouse_ignore_recursive(node: Node) -> void:
	if node is Control and (node as Control).mouse_filter != Control.MOUSE_FILTER_IGNORE:
		_fail("HUD control intercepts mouse input: %s" % node.get_path())
	for child in node.get_children():
		_check_mouse_ignore_recursive(child)


func _collect_label_copy(node: Node) -> String:
	var values := PackedStringArray()
	_collect_labels(node, values)
	return "\n".join(values)


func _collect_labels(node: Node, values: PackedStringArray) -> void:
	if node is Label:
		values.append((node as Label).text)
	for child in node.get_children():
		_collect_labels(child, values)


func _finish(original_scale_size: Vector2i, original_window_size: Vector2i) -> void:
	root.content_scale_size = original_scale_size
	root.size = original_window_size
	if failures.is_empty():
		print("Control input HUD contract passed.")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _fail(message: String) -> void:
	failures.append(message)

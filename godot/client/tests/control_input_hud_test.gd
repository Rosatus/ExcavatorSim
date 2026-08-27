extends SceneTree

const HUD_SCENE := "res://scenes/control_input_hud.tscn"
const KEY_CONTRACT := {
	KEY_W: {"path": "Margin/VBox/Sticks/LeftStick/Grid/W", "copy": "W\n小臂伸"},
	KEY_A: {"path": "Margin/VBox/Sticks/LeftStick/Grid/A", "copy": "A\n左回转"},
	KEY_S: {"path": "Margin/VBox/Sticks/LeftStick/Grid/S", "copy": "S\n小臂收"},
	KEY_D: {"path": "Margin/VBox/Sticks/LeftStick/Grid/D", "copy": "D\n右回转"},
	KEY_I: {"path": "Margin/VBox/Sticks/RightStick/Grid/I", "copy": "I\n大臂降"},
	KEY_J: {"path": "Margin/VBox/Sticks/RightStick/Grid/J", "copy": "J\n铲斗收"},
	KEY_K: {"path": "Margin/VBox/Sticks/RightStick/Grid/K", "copy": "K\n大臂升"},
	KEY_L: {"path": "Margin/VBox/Sticks/RightStick/Grid/L", "copy": "L\n铲斗翻"},
	KEY_R: {"path": "Margin/VBox/Tracks/LeftTrack/Keys/R", "copy": "R  前进"},
	KEY_F: {"path": "Margin/VBox/Tracks/LeftTrack/Keys/F", "copy": "F  后退"},
	KEY_Y: {"path": "Margin/VBox/Tracks/RightTrack/Keys/Y", "copy": "Y  前进"},
	KEY_H: {"path": "Margin/VBox/Tracks/RightTrack/Keys/H", "copy": "H  后退"},
}
const MODEL_ACTION_KEYS := {
	"sy205": {
		"motion_swing_positive": KEY_A,
		"motion_swing_negative": KEY_D,
		"motion_boom_positive": KEY_I,
		"motion_boom_negative": KEY_K,
		"motion_arm_positive": KEY_S,
		"motion_arm_negative": KEY_W,
		"motion_bucket_positive": KEY_J,
		"motion_bucket_negative": KEY_L,
	},
	"sy135": {
		"motion_swing_positive": KEY_A,
		"motion_swing_negative": KEY_D,
		"motion_boom_positive": KEY_K,
		"motion_boom_negative": KEY_I,
		"motion_arm_positive": KEY_W,
		"motion_arm_negative": KEY_S,
		"motion_bucket_positive": KEY_L,
		"motion_bucket_negative": KEY_J,
	},
}
const TRACK_ACTION_KEYS := {
	"track_left_forward": KEY_R,
	"track_left_reverse": KEY_F,
	"track_right_forward": KEY_Y,
	"track_right_reverse": KEY_H,
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
	_check_copy_and_mouse_contract(hud, "sy205")
	_check_input_feedback(hud)
	var motion_client := MotionClient.new()
	motion_client.configure_equipment_gamepad_model("sy135")
	motion_client.free()
	hud.refresh_input_state_for_test()
	_check_model_action_tiles(hud, "sy135")
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


func _check_copy_and_mouse_contract(hud: ControlInputHUD, model_id: String) -> void:
	if ControlInputHUD.ACTION_TILE_PATHS.size() != 12 or ControlInputHUD.KEY_TILE_PATHS.size() != 12:
		_fail("control input HUD does not own all twelve actions")
	for keycode in KEY_CONTRACT:
		var expected: Dictionary = KEY_CONTRACT[keycode]
		if String(ControlInputHUD.KEY_TILE_PATHS[keycode]) != String(expected["path"]):
			_fail("control input HUD uses the wrong tile for key %s" % keycode)
		var tile := hud.get_node_or_null(ControlInputHUD.KEY_TILE_PATHS[keycode]) as PanelContainer
		if tile == null:
			_fail("control input HUD is missing tile for key %s" % keycode)
			continue
		var label := tile.get_node_or_null("Label") as Label
		if label == null or label.text != String(expected["copy"]):
			_fail("control input HUD uses the wrong copy for key %s" % keycode)
	_check_model_action_tiles(hud, model_id)
	var all_action_keys := (MODEL_ACTION_KEYS[model_id] as Dictionary).duplicate()
	all_action_keys.merge(TRACK_ACTION_KEYS)
	for action in all_action_keys:
		var expected_key := int(all_action_keys[action])
		var key_events: Array[InputEventKey] = []
		var joy_events: Array[InputEvent] = []
		for event in InputMap.action_get_events(action):
			if event is InputEventKey:
				key_events.append(event)
			elif event is InputEventJoypadMotion or event is InputEventJoypadButton:
				joy_events.append(event)
		if (
			key_events.size() != 1
			or key_events[0].physical_keycode != expected_key
		):
			_fail("product InputMap uses the wrong keyboard binding for %s" % action)
		if joy_events.size() != 1:
			_fail("product InputMap did not retain exactly one gamepad binding for %s" % action)
	var copy := _collect_label_copy(hud)
	for key_name in ["W", "A", "S", "D", "I", "J", "K", "L", "R", "F", "Y", "H"]:
		if key_name not in copy:
			_fail("control input HUD omitted key %s" % key_name)
	_check_mouse_ignore_recursive(hud)


func _check_model_action_tiles(hud: ControlInputHUD, model_id: String) -> void:
	var expected_action_keys := (MODEL_ACTION_KEYS[model_id] as Dictionary).duplicate()
	expected_action_keys.merge(TRACK_ACTION_KEYS)
	for action in expected_action_keys:
		var expected_key := int(expected_action_keys[action])
		var expected_path := ControlInputHUD.KEY_TILE_PATHS[expected_key] as NodePath
		var expected_tile := hud.get_node_or_null(expected_path) as PanelContainer
		if hud.get_action_tile_for_test(action) != expected_tile:
			_fail("%s HUD action %s did not follow key %s" % [model_id, action, expected_key])


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
	var actions := (MODEL_ACTION_KEYS["sy205"] as Dictionary).duplicate()
	actions.merge(TRACK_ACTION_KEYS)
	for action in actions:
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
	motion_client.configure_equipment_gamepad_model("sy205")
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

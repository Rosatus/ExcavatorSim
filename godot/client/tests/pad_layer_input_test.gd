extends SceneTree

## Gamepad pad-layer contract. The D-pad is a hold-modifier that redirects
## the right stick to attachment/local axes while masking the underlying
## base axis; View cycles camera presets; Y toggles the assist picker with
## D-pad/stick navigation; A/B land on ui_accept/ui_cancel. Exercises action
## registration, mapper redirection and menu nav without hardware.

var failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	# --- Action registration -------------------------------------------------
	var client := MotionClient.new()
	client._ensure_input_actions()
	for action in AttachmentInputMapper.PAD_LAYER_ACTIONS:
		var button := int(AttachmentInputMapper.PAD_LAYER_ACTIONS[action])
		_expect(_has_joy_button(action, button),
				"pad layer action missing its D-pad binding: %s" % action)
	var camera := CameraRig.new()
	camera._ensure_input_actions()
	_expect(_has_joy_button(CameraRig.CYCLE_ACTION, JOY_BUTTON_BACK),
			"camera cycle lacks the View-button binding")
	for action in CameraRig.CAMERA_ACTIONS:
		_expect(not _has_any_joy_button(action),
				"camera preset kept a joypad binding: %s" % action)
	var ui := MotionOperatorUI.new()
	ui._ensure_ui_pad_bindings()
	_expect(_has_joy_button("ui_accept", JOY_BUTTON_A), "ui_accept lacks A")
	_expect(_has_joy_button("ui_cancel", JOY_BUTTON_B), "ui_cancel lacks B")
	var chassis := TrackedChassisController.new()
	root.add_child(chassis)
	await process_frame
	_expect(_has_joy_button("operator_assist", JOY_BUTTON_Y), "assist toggle lacks Y")

	# --- Local-axis pad layer -------------------------------------------------
	var mapper := AttachmentInputMapper.new()
	mapper.configure_local_axes(["boom_swing", "boom_fold"])
	var pad_held := {}
	var axis_values := {}
	mapper.input_probe = func(kind: String, probe_name: String) -> float:
		if kind == "pad":
			return 1.0 if bool(pad_held.get(probe_name, false)) else 0.0
		if kind == "axis":
			return float(axis_values.get(probe_name, 0.0))
		return 0.0
	var base_pair := ["operator_boom_swing_right", "operator_boom_swing_left"]
	_expect(mapper.read_local_axis("boom_swing", base_pair[0], base_pair[1]) == 0.0,
			"idle local axis produced input")
	pad_held["pad_layer_dpad_left"] = true
	axis_values["operator_bucket_dump|operator_bucket_curl"] = -0.75
	_expect(is_equal_approx(mapper.read_local_axis("boom_swing", base_pair[0], base_pair[1]), -0.75),
			"D-pad-left layer did not drive boom_swing from right-stick X")
	var mask := mapper.mask_operator_axes(Vector4(0.5, -0.5, 0.25, -0.25))
	_expect(mask == Vector4(0.5, -0.5, 0.25, 0.0),
			"boom_swing layer did not mask the bucket axis: %s" % mask)
	pad_held["pad_layer_dpad_up"] = true
	axis_values["operator_boom_lower|operator_boom_raise"] = 0.6
	_expect(is_equal_approx(mapper.read_local_axis("boom_fold", base_pair[0], base_pair[1]), 0.6),
			"D-pad-up layer did not drive boom_fold from right-stick Y")
	mask = mapper.mask_operator_axes(Vector4(0.5, -0.5, 0.25, -0.25))
	_expect(mask == Vector4(0.5, 0.0, 0.25, 0.0),
			"boom_swing+boom_fold layers did not mask boom and bucket: %s" % mask)
	pad_held.clear()
	mapper.configure_local_axes([])
	pad_held["pad_layer_dpad_left"] = true
	mask = mapper.mask_operator_axes(Vector4(0.5, -0.5, 0.25, -0.25))
	_expect(mask == Vector4(0.5, -0.5, 0.25, -0.25),
			"unregistered local axis still masked a base axis")
	_expect(mapper.read_local_axis("boom_swing", base_pair[0], base_pair[1]) == 0.0,
			"cleared local layer still redirected the stick")

	# --- Assist picker D-pad nav ----------------------------------------------
	# Menu indices move one step per press; holding never repeats.
	Input.action_release("pad_layer_dpad_left")
	chassis.set_assist_menu_open(true)
	Input.action_press("pad_layer_dpad_down")
	chassis._navigate_assist_menu(0.0)
	_expect(int(chassis.assist_menu_snapshot().get("index", -1)) == 1,
			"D-pad down did not move the assist selection down")
	chassis._navigate_assist_menu(0.0)
	_expect(int(chassis.assist_menu_snapshot().get("index", -1)) == 1,
			"held D-pad repeated the assist nav")
	Input.action_release("pad_layer_dpad_down")
	chassis._navigate_assist_menu(0.0)
	Input.action_press("pad_layer_dpad_up")
	chassis._navigate_assist_menu(0.0)
	_expect(int(chassis.assist_menu_snapshot().get("index", -1)) == 0,
			"D-pad up did not move the assist selection up")
	Input.action_release("pad_layer_dpad_up")
	Input.action_release("pad_layer_dpad_down")
	Input.action_release("pad_layer_dpad_left")

	chassis.queue_free()
	ui.free()
	camera.free()
	client.free()
	await process_frame
	if failures == 0:
		print("pad_layer_input_test: PASS")
		quit(0)
	else:
		push_error("pad_layer_input_test: %d failure(s)" % failures)
		quit(1)


func _has_joy_button(action: String, button_index: int) -> bool:
	if not InputMap.has_action(action):
		return false
	for event in InputMap.action_get_events(action):
		if event is InputEventJoypadButton and (event as InputEventJoypadButton).button_index == button_index:
			return true
	return false


func _has_any_joy_button(action: String) -> bool:
	for event in InputMap.action_get_events(action):
		if event is InputEventJoypadButton:
			return true
	return false


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures += 1
		push_error("pad_layer_input_test FAIL: %s" % label)

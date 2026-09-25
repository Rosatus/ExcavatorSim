extends SceneTree

var failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var hud := load("res://scenes/control_input_hud.tscn").instantiate() as ControlInputHUD
	root.add_child(hud)
	for resolution in [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(2560, 1080)]:
		root.size = resolution
		root.content_scale_size = resolution
		await process_frame
		await process_frame
		var rect := hud.get_global_rect()
		check(rect.position.x >= 0 and rect.position.y >= 0 and rect.end.x <= resolution.x and rect.end.y <= resolution.y, "HUD exceeds viewport")
		check(absf(rect.end.x - resolution.x + 28) < 1, "HUD right safe margin")
	var up := (hud._tiles["operator_arm_extend"] as Control).get_global_rect()
	var left := (hud._tiles["operator_swing_left"] as Control).get_global_rect()
	var down := (hud._tiles["operator_arm_retract"] as Control).get_global_rect()
	check(up.position.y < left.position.y and left.position.y < down.position.y and left.position.x < up.position.x, "left controls are not cross-shaped")
	for action in ControlInputHUD.GROUP_ACTIONS[2]:
		check((hud._tiles[action] as Control).get_global_rect().end.y < up.position.y, "track key not above sticks")
	check_mouse(hud)
	# Keyboard layout: forward keys sit above their reverse keys like the
	# R/F and Y/H columns on a physical board.
	var fwd_l := (hud._tiles["track_left_forward"] as Control).get_global_rect()
	var rev_l := (hud._tiles["track_left_reverse"] as Control).get_global_rect()
	var fwd_r := (hud._tiles["track_right_forward"] as Control).get_global_rect()
	var rev_r := (hud._tiles["track_right_reverse"] as Control).get_global_rect()
	check(fwd_l.position.y < rev_l.position.y and fwd_r.position.y < rev_r.position.y,
			"keyboard travel keys are not column-shaped")
	check(fwd_l.position.x < fwd_r.position.x, "left track key not left of right track key")
	check(not hud._dpad_section.visible, "D-pad layer section shown for keyboard")
	for action in ControlInputHUD.GROUP_ACTIONS[0]:
		check(hud._captions[action].text != "", "stick tile missing function caption: " + action)
	hud.set_prompt_mode("gamepad")
	check(hud._keys["operator_arm_extend"].text == "L ↑", "gamepad prompt did not switch")
	check(hud._dpad_section.visible, "D-pad layer section hidden for gamepad")
	for action in ControlInputHUD.DPAD_TILE_ACTIONS:
		check(hud._tiles.has(action), "missing D-pad tile: " + action)
	# Held D-pad modifiers relabel the borrowed right-stick tiles.
	for action in ["pad_layer_dpad_up", "pad_layer_dpad_down"]:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
	Input.action_press("pad_layer_dpad_down")
	hud.refresh_input_state_for_test()
	check(hud.is_action_highlighted_for_test("pad_layer_dpad_down"), "D-pad tile did not highlight")
	check(hud._captions["operator_boom_lower"].text == "后倾", "D-pad-down layer did not relabel boom axis")
	check(hud._captions["operator_bucket_dump"].text == "右旋", "D-pad-down layer did not relabel bucket axis")
	Input.action_release("pad_layer_dpad_down")
	Input.action_press("pad_layer_dpad_up")
	hud.refresh_input_state_for_test()
	check(hud._captions["operator_boom_lower"].text == "展开", "D-pad-up layer did not relabel boom axis")
	check(hud._captions["operator_bucket_curl"].text == "斗收", "D-pad-up layer touched an unborrowed axis")
	Input.action_release("pad_layer_dpad_up")
	hud.refresh_input_state_for_test()
	check(hud._captions["operator_boom_lower"].text == "臂降", "captions did not restore after release")
	hud.set_prompt_mode("keyboard")
	check(hud._keys["operator_arm_extend"].text == "W", "keyboard prompt did not recover")
	for actions in ControlInputHUD.GROUP_ACTIONS:
		for action in actions:
			if not InputMap.has_action(action):
				InputMap.add_action(action)
			Input.action_press(action)
			hud.refresh_input_state_for_test()
			check(hud.is_action_highlighted_for_test(action), "missing active feedback: " + action)
			Input.action_release(action)
			hud.refresh_input_state_for_test()
			check(not hud.is_action_highlighted_for_test(action), "stuck active feedback: " + action)
	hud.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	print("control_input_hud_test: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

func check_mouse(node: Node) -> void:
	if node is Control:
		check((node as Control).mouse_filter == Control.MOUSE_FILTER_IGNORE, "HUD captures mouse")
	for child in node.get_children():
		check_mouse(child)

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

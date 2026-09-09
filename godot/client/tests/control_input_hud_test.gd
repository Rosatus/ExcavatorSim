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
	hud.set_prompt_mode("gamepad")
	check(hud._keys["operator_arm_extend"].text == "L ↑", "gamepad prompt did not switch")
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

extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"
const FORBIDDEN_DEFAULT_COPY := ["Gen:", "Rev:", "ACK", "pen=", "eng=", "boomV=", "Authority:"]

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var original_profile := String(ProjectSettings.get_setting("simulation/authority_profile"))
	var original_scale_size := root.content_scale_size
	var original_window_size := root.size
	var scene := load(MAIN_SCENE).instantiate() as Node3D
	root.add_child(scene)
	await process_frame
	await physics_frame
	var ui := scene.get_node_or_null("OperatorUI") as MotionOperatorUI
	var session := scene.get_node_or_null("ProductSession") as ProductSession
	var excavation := scene.get_node_or_null("TerrainRoot/ExcavationWorld") as ExcavationWorld
	if ui == null or session == null or excavation == null:
		_fail("main scene did not provide the operator UI integration nodes")
	else:
		_check_default_hierarchy(ui)
		await _check_layout(ui, Vector2i(1280, 720))
		await _check_layout(ui, Vector2i(1920, 1080))
		_check_prompts(ui)
		_check_guide(ui)
		_check_panel_collapse(ui)
		_check_test_graphics(ui)
		_check_reset_confirmation(ui, session)
		_check_model_confirmation(ui, session)
		_check_generation_clear(ui, session)
		_check_gateway_state(ui)
	ProjectSettings.set_setting("simulation/authority_profile", original_profile)
	root.content_scale_size = original_scale_size
	root.size = original_window_size
	scene.queue_free()
	await process_frame
	if failures.is_empty():
		print("Operator onboarding and HUD contract passed.")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _check_default_hierarchy(ui: MotionOperatorUI) -> void:
	var advanced := ui.get_node("StatusPanel/Margin/VBox/AdvancedPanel") as Control
	if advanced.visible:
		_fail("advanced diagnostics were visible by default")
	var visible_copy := _visible_label_copy(ui)
	for token in FORBIDDEN_DEFAULT_COPY:
		if token in visible_copy:
			_fail("default HUD leaked engineering token: %s" % token)
	var operation := ui.get_node("StatusPanel/Margin/VBox/Operation") as Label
	var bucket := ui.get_node("StatusPanel/Margin/VBox/BucketStatus") as Label
	var warning := ui.get_node("StatusPanel/Margin/VBox/Warning") as Label
	if operation.text.is_empty() or "Bucket" not in bucket.text or warning.text.is_empty():
		_fail("default HUD did not expose operation, bucket, and recovery state")
	var advanced_toggle := ui.get_node("StatusPanel/Margin/VBox/Tools/Advanced") as CheckButton
	advanced_toggle.button_pressed = true
	if not advanced.visible or "Gen:" not in _visible_label_copy(ui):
		_fail("advanced diagnostics did not expose generation details on request")
	advanced_toggle.button_pressed = false


func _check_layout(ui: MotionOperatorUI, resolution: Vector2i) -> void:
	root.size = resolution
	root.content_scale_size = resolution
	var guide := ui.get_node("GuidePanel") as Control
	var guide_was_visible := guide.visible
	guide.visible = true
	await process_frame
	await process_frame
	var status := ui.get_node("StatusPanel") as Control
	for control_value in [status, guide]:
		var control := control_value as Control
		var rect: Rect2 = control.get_global_rect()
		if rect.position.x < 0.0 or rect.position.y < 0.0 or rect.end.x > resolution.x or rect.end.y > resolution.y:
			_fail("%s escaped %dx%d safe bounds: %s" % [control.name, resolution.x, resolution.y, rect])
	guide.visible = guide_was_visible


func _check_prompts(ui: MotionOperatorUI) -> void:
	var hint := ui.get_node("StatusPanel/Margin/VBox/ControlHint") as Label
	var guide_controls := ui.get_node("GuidePanel/Margin/VBox/Controls") as Label
	var joy_event := InputEventJoypadButton.new()
	joy_event.button_index = JOY_BUTTON_LEFT_SHOULDER
	joy_event.pressed = true
	ui._unhandled_input(joy_event)
	if (
		ui.get_prompt_mode_for_test() != "gamepad"
		or "LT/RT" not in hint.text
		or "ISO excavator pattern" not in guide_controls.text
		or "bucket curl" not in guide_controls.text
		or "Keyboard: tracks" in guide_controls.text
	):
		_fail("gamepad prompt variant was not readable")
	var key_event := InputEventKey.new()
	key_event.physical_keycode = KEY_Q
	key_event.pressed = true
	ui._unhandled_input(key_event)
	if ui.get_prompt_mode_for_test() != "keyboard" or "Q/A" not in hint.text or "W/S" not in hint.text:
		_fail("keyboard prompt variant was not readable")


func _check_guide(ui: MotionOperatorUI) -> void:
	var guide := ui.get_node("GuidePanel") as Control
	guide.visible = false
	ui.show_control_guide()
	var copy := _visible_label_copy(guide)
	for token in ["Tracks", "boom", "bucket", "Camera", "F8", "automatically"]:
		if token not in copy:
			_fail("control guide omitted essential copy: %s" % token)
	guide.visible = false


func _check_panel_collapse(ui: MotionOperatorUI) -> void:
	var panel := ui.get_node_or_null("StatusPanel") as PanelContainer
	var toggle := ui.get_node_or_null("PanelToggle") as Button
	if panel == null or toggle == null or not panel.visible or ui.is_panel_collapsed_for_test():
		_fail("operator panel starts expanded with a persistent collapse control")
		return
	ui.set_panel_collapsed_for_test(true)
	if panel.visible or not toggle.visible or not ui.is_panel_collapsed_for_test():
		_fail("collapsed operator panel keeps its restore control visible")
	ui.set_panel_collapsed_for_test(false)
	if not panel.visible or ui.is_panel_collapsed_for_test():
		_fail("operator panel reopens after collapse")


func _check_test_graphics(ui: MotionOperatorUI) -> void:
	var quality := ui.get_node_or_null("../VisualQualityController") as VisualQualityController
	if quality == null:
		_fail("operator test-graphics control has no quality owner")
		return
	quality.apply_profile("high")
	ui.set_test_graphics_for_test(true)
	if not ui.is_test_graphics_enabled_for_test() or String(quality.get_quality_snapshot().get("profile", "")) != "test":
		_fail("operator test-graphics control did not select the test profile")
	ui.set_test_graphics_for_test(false)
	if ui.is_test_graphics_enabled_for_test() or String(quality.get_quality_snapshot().get("profile", "")) != "high":
		_fail("operator test-graphics control did not restore the prior profile")
	quality.apply_profile("balanced")


func _check_reset_confirmation(ui: MotionOperatorUI, session: ProductSession) -> void:
	var before := session.generation
	ui._on_reset_pressed()
	if session.generation != before:
		_fail("reset changed the authoritative generation before confirmation")
	ui._on_destructive_confirmed()
	ui.get_node("DestructiveConfirmation").hide()
	if session.generation != before + 1:
		_fail("confirmed reset did not advance exactly one generation")
	var completion := ui.get_node("StatusPanel/Margin/VBox/Completion") as Label
	if "reset complete" not in completion.text:
		_fail("reset completion was not reported after the authoritative transition")


func _check_model_confirmation(ui: MotionOperatorUI, session: ProductSession) -> void:
	var before := session.generation
	ui._on_model_selected(1)
	if session.active_model_id != "sy205":
		_fail("model changed before confirmation")
	ui._on_destructive_confirmed()
	ui.get_node("DestructiveConfirmation").hide()
	if session.active_model_id != "sy135" or session.generation != before + 1:
		_fail("confirmed SY135 switch was not generation-safe")
	var completion := ui.get_node("StatusPanel/Margin/VBox/Completion") as Label
	if "SANY SY135 ready" not in completion.text:
		_fail("model-switch completion was not reported")


func _check_generation_clear(ui: MotionOperatorUI, session: ProductSession) -> void:
	var before := ui.get_soil_generation_key_for_test()
	session.request_reset()
	ui._refresh()
	var after := ui.get_soil_generation_key_for_test()
	if before == after:
		_fail("soil presentation identity survived a generation reset")
	var bucket := ui.get_node("StatusPanel/Margin/VBox/BucketStatus") as Label
	if "EMPTY" not in bucket.text:
		_fail("soil payload UI did not clear at the generation boundary")


func _check_gateway_state(ui: MotionOperatorUI) -> void:
	ProjectSettings.set_setting("simulation/authority_profile", AuthorityProfile.PYTHON_KINEMATIC)
	ui._refresh()
	var warning := ui.get_node("StatusPanel/Margin/VBox/Warning") as Label
	if "gateway is unavailable" not in warning.text:
		_fail("gateway compatibility state did not expose recovery guidance")
	var advanced := ui.get_node("StatusPanel/Margin/VBox/AdvancedPanel") as Control
	var advanced_toggle := ui.get_node("StatusPanel/Margin/VBox/Tools/Advanced") as CheckButton
	advanced_toggle.button_pressed = true
	if not advanced.visible or "Connection: disconnected" not in _visible_label_copy(advanced):
		_fail("gateway diagnostics were unavailable behind Advanced")
	advanced_toggle.button_pressed = false


func _visible_label_copy(node: Node) -> String:
	var values := PackedStringArray()
	_collect_visible_labels(node, values)
	return "\n".join(values)


func _collect_visible_labels(node: Node, values: PackedStringArray) -> void:
	if node is Label and (node as Label).is_visible_in_tree():
		values.append((node as Label).text)
	for child in node.get_children():
		_collect_visible_labels(child, values)


func _fail(message: String) -> void:
	failures.append(message)

extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"
const MODE_ANCHORS := {
	CameraRig.MODE_OPERATOR: "upper_structure_link",
	CameraRig.MODE_CHASE: "base_link",
	CameraRig.MODE_WORK_TOOL: "bucket_link",
	CameraRig.MODE_INSPECTION: "base_link",
	CameraRig.MODE_CAB: "upper_structure_link",
}

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := load(MAIN_SCENE).instantiate() as Node3D
	root.add_child(scene)
	await process_frame
	await physics_frame
	var camera := scene.get_node_or_null("Camera3D") as CameraRig
	var session := scene.get_node_or_null("ProductSession") as ProductSession
	var presentation := scene.get_node_or_null("MotionPresentation") as MotionPresentation
	var ui := scene.get_node_or_null("OperatorUI") as MotionOperatorUI
	if camera == null or session == null or presentation == null or ui == null:
		_fail("main scene did not provide camera workflow integration nodes")
	else:
		_check_input_contract(camera)
		await _check_model_modes(camera, session, presentation, "sy205")
		var old_anchor_id := int(camera.get_view_snapshot_for_test()["anchor_instance_id"])
		await _check_model_modes(camera, session, presentation, "sy135")
		var new_anchor_id := int(camera.get_view_snapshot_for_test()["anchor_instance_id"])
		if old_anchor_id == new_anchor_id:
			_fail("model switch retained the previous model camera anchor")
		_check_orbit_and_reset(camera)
		_check_occlusion(camera)
		_check_quality_clamp(camera)
		_check_hud_integration(camera, ui)
		_check_generation_reset(camera, session)
		await _check_cab_lifecycle(camera, session, presentation)
	scene.queue_free()
	await process_frame
	if failures.is_empty():
		print("Camera workflow contract passed for SY205 and SY135.")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _check_input_contract(camera: CameraRig) -> void:
	for action in CameraRig.CAMERA_ACTIONS:
		var has_key := false
		var has_joy := false
		for event in InputMap.action_get_events(action):
			has_key = has_key or event is InputEventKey
			has_joy = has_joy or event is InputEventJoypadButton
		var expects_joy := int((CameraRig.CAMERA_ACTIONS[action] as Dictionary)["joy"]) >= 0
		if not has_key or (expects_joy and not has_joy):
			_fail("camera action lacks its declared bindings: %s" % action)
	var reset_events := InputMap.action_get_events(CameraRig.RESET_ACTION)
	if not reset_events.any(func(event: InputEvent) -> bool: return event is InputEventKey) or not reset_events.any(func(event: InputEvent) -> bool: return event is InputEventJoypadButton):
		_fail("camera reset lacks keyboard/gamepad bindings")
	var operator_key := InputEventKey.new()
	operator_key.keycode = KEY_1
	operator_key.pressed = true
	camera._unhandled_input(operator_key)
	if camera.get_mode() != CameraRig.MODE_OPERATOR:
		_fail("keyboard mode event did not select operator view")
	var chase_pad := InputEventJoypadButton.new()
	chase_pad.button_index = JOY_BUTTON_DPAD_RIGHT
	chase_pad.pressed = true
	camera._unhandled_input(chase_pad)
	if camera.get_mode() != CameraRig.MODE_CHASE:
		_fail("gamepad mode event did not select chase view")
	var cab_key := InputEventKey.new()
	cab_key.keycode = KEY_5
	cab_key.pressed = true
	camera._unhandled_input(cab_key)
	if camera.get_mode() != CameraRig.MODE_CAB:
		_fail("keyboard mode event did not select cab view")


func _check_model_modes(camera: CameraRig, session: ProductSession, presentation: MotionPresentation, model_id: String) -> void:
	if session.active_model_id != model_id:
		if not session.request_model_switch(model_id):
			_fail("could not activate %s for camera test" % model_id)
			return
		await process_frame
		await physics_frame
	for mode in CameraRig.MODES:
		if not camera.set_mode(mode):
			_fail("camera rejected mode %s" % mode)
			continue
		camera.force_camera_update_for_test(1.0)
		var snapshot := camera.get_view_snapshot_for_test()
		if String(snapshot.get("mode", "")) != mode or String(snapshot.get("model_id", "")) != model_id:
			_fail("%s did not retain %s mode identity" % [model_id, mode])
		if not bool(snapshot.get("finite", false)):
			_fail("%s %s produced non-finite framing" % [model_id, mode])
		var expected_anchor := presentation.get_frame_node(String(MODE_ANCHORS[mode]))
		if expected_anchor == null:
			expected_anchor = presentation.get_frame_node("base_link")
		if expected_anchor == null or int(snapshot.get("anchor_instance_id", 0)) != expected_anchor.get_instance_id():
			_fail("%s %s did not resolve its current semantic anchor" % [model_id, mode])
		var resolved_distance := float(snapshot.get("resolved_distance_m", 0.0))
		if resolved_distance < 2.9 or resolved_distance > camera.max_distance_m + 0.01:
			_fail("%s %s escaped bounded camera distance" % [model_id, mode])
		var near_clip := float(snapshot.get("near", 0.0))
		if near_clip < 0.079 or near_clip > 0.221:
			_fail("%s %s escaped near-clip safety" % [model_id, mode])
		var transparent_surfaces := int(snapshot.get("cab_transparent_surfaces", 0))
		if mode == CameraRig.MODE_CAB and transparent_surfaces <= 0:
			_fail("%s cab mode did not make its upper shell transparent" % model_id)
		elif mode != CameraRig.MODE_CAB and transparent_surfaces != 0:
			_fail("%s %s retained cab transparency" % [model_id, mode])


func _check_orbit_and_reset(camera: CameraRig) -> void:
	camera.set_mode(CameraRig.MODE_INSPECTION)
	camera.reset_view()
	var baseline := camera.get_view_snapshot_for_test()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_MIDDLE
	press.pressed = true
	camera._unhandled_input(press)
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(30.0, -12.0)
	camera._unhandled_input(motion)
	var changed := camera.get_view_snapshot_for_test()
	if is_equal_approx(float(changed["yaw"]), float(baseline["yaw"])):
		_fail("inspection orbit did not respond to middle-drag")
	camera.reset_view()
	var reset := camera.get_view_snapshot_for_test()
	if not is_equal_approx(float(reset["yaw"]), float(baseline["yaw"])) or not is_equal_approx(float(reset["distance_m"]), float(baseline["distance_m"])):
		_fail("reset view did not restore the model preset")


func _check_occlusion(camera: CameraRig) -> void:
	camera.set_quality_distance_for_test(14.0)
	camera.set_mode(CameraRig.MODE_CHASE)
	camera.set_occlusion_probe_for_test(Callable(self, "_midpoint_hit"))
	camera.force_camera_update_for_test(1.0)
	var blocked := camera.get_view_snapshot_for_test()
	var full_distance := (blocked["focus"] as Vector3).distance_to(blocked["desired_position"] as Vector3)
	if not bool(blocked.get("occluded", false)) or float(blocked.get("resolved_distance_m", full_distance)) >= full_distance:
		_fail("occlusion probe did not shorten the camera before the obstacle")
	camera.set_occlusion_probe_for_test(Callable(self, "_no_hit"))
	camera.force_camera_update_for_test(1.0)
	var clear := camera.get_view_snapshot_for_test()
	if bool(clear.get("occluded", true)) or not (clear["resolved_position"] as Vector3).is_equal_approx(clear["desired_position"] as Vector3):
		_fail("camera did not recover its unobstructed desired position")
	camera.set_occlusion_probe_for_test(Callable())


func _check_quality_clamp(camera: CameraRig) -> void:
	camera.set_quality_distance_for_test(8.0)
	camera.set_mode(CameraRig.MODE_INSPECTION)
	camera.reset_view()
	if float(camera.get_view_snapshot_for_test()["distance_m"]) > 8.001:
		_fail("low-quality distance budget did not clamp camera preset")
	camera.set_quality_distance_for_test(14.0)


func _check_hud_integration(camera: CameraRig, ui: MotionOperatorUI) -> void:
	camera.set_mode(CameraRig.MODE_WORK_TOOL)
	var selector := ui.get_node("StatusPanel/Margin/VBox/CameraRow/Selector") as OptionButton
	if String(selector.get_item_metadata(selector.selected)) != CameraRig.MODE_WORK_TOOL:
		_fail("HUD did not report the active work-tool camera mode")
	selector.select(0)
	ui._on_camera_mode_selected(0)
	if camera.get_mode() != CameraRig.MODE_OPERATOR:
		_fail("HUD selector did not switch camera mode")


func _check_generation_reset(camera: CameraRig, session: ProductSession) -> void:
	camera.set_mode(CameraRig.MODE_INSPECTION)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_MIDDLE
	press.pressed = true
	camera._unhandled_input(press)
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(24.0, 0.0)
	camera._unhandled_input(motion)
	var changed_yaw := float(camera.get_view_snapshot_for_test()["yaw"])
	session.request_reset()
	var reset_yaw := float(camera.get_view_snapshot_for_test()["yaw"])
	if is_equal_approx(changed_yaw, reset_yaw):
		_fail("authority generation reset retained transient camera orbit")


func _check_cab_lifecycle(camera: CameraRig, session: ProductSession, presentation: MotionPresentation) -> void:
	camera.set_mode(CameraRig.MODE_CAB)
	camera.force_camera_update_for_test()
	var before := camera.get_view_snapshot_for_test()
	if int(before.get("cab_transparent_surfaces", 0)) <= 0:
		_fail("cab transparency was unavailable before lifecycle checks")
	var anchor := presentation.get_frame_node("upper_structure_link")
	if anchor == null or (before["camera_position"] as Vector3).distance_to(anchor.global_position) > 3.0:
		_fail("cab camera was not placed inside the current upper structure")
	session.request_reset()
	camera.force_camera_update_for_test()
	if camera.get_mode() != CameraRig.MODE_CAB or int(camera.get_view_snapshot_for_test().get("cab_transparent_surfaces", 0)) <= 0:
		_fail("authority reset did not preserve the active cab view safely")
	camera.set_mode(CameraRig.MODE_CHASE)
	if int(camera.get_view_snapshot_for_test().get("cab_transparent_surfaces", -1)) != 0:
		_fail("leaving cab mode did not restore upper-shell materials")


func _midpoint_hit(from: Vector3, to: Vector3, _mask: int) -> Dictionary:
	return {"position": from.lerp(to, 0.5)}


func _no_hit(_from: Vector3, _to: Vector3, _mask: int) -> Dictionary:
	return {}


func _fail(message: String) -> void:
	failures.append(message)

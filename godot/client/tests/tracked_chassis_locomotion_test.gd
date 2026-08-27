extends SceneTree

const EXPECTED_TRACK_KEYS := {
	"track_left_forward": KEY_R,
	"track_left_reverse": KEY_F,
	"track_right_forward": KEY_Y,
	"track_right_reverse": KEY_H,
}

const CATALOG_PATH := "res://resources/models/model_catalog.json"
const SY205_FIXTURE := "res://tests/fixtures/sy205_frame_parity_cases.json"
const STEP := 1.0 / 60.0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var result := _test_model_contracts()
	if result == 0:
		result = _test_fixed_step_motion()
	if result == 0:
		result = _test_support_and_bounds()
	if result == 0:
		result = await _test_input_actions_and_parent_composition()
	if result == 0:
		result = await _test_jolt_hints_and_lifecycle()
	if result == 0:
		print("Tracked chassis locomotion contract passed.")
	quit(result)


func _test_model_contracts() -> int:
	var catalog := _read_json(CATALOG_PATH)
	var entries: Array = catalog.get("models", [])
	if _check(entries.size() == 2, "model catalog must contain both tracked models") != 0:
		return 1
	var values: Dictionary = {}
	for entry in entries:
		var model_id := String(entry.get("model_id", ""))
		var parameters: Variant = entry.get("tracked_locomotion")
		if _check(parameters is Dictionary, "%s tracked descriptor is missing" % model_id) != 0:
			return 1
		if _check(
			TrackedLocomotionState.validate_parameters(parameters as Dictionary),
			"%s tracked descriptor is invalid" % model_id
		) != 0:
			return 1
		values[model_id] = parameters
	if _check(values.has("sy205") and values.has("sy135"), "catalog model IDs drifted") != 0:
		return 1
	if _check(values["sy205"] != values["sy135"], "models share a fallback tracked descriptor") != 0:
		return 1
	var invalid: Dictionary = (values["sy205"] as Dictionary).duplicate(true)
	invalid.erase("support_front_offset_m")
	return _check(
		not TrackedLocomotionState.validate_parameters(invalid),
		"incomplete tracked descriptor was accepted"
	)


func _test_fixed_step_motion() -> int:
	var state := _configured_state("sy205")
	var flat := func(_point: Vector2) -> float: return 0.0
	state.set_commands(1.0, 1.0)
	for _index in 60:
		state.step_fixed(STEP, flat)
	if _check(state.chassis_transform.origin.z < -0.2, "straight command did not move forward") != 0:
		return 1
	if _check(absf(state.yaw_radians) < 0.0001, "straight command introduced yaw") != 0:
		return 1
	var forward_speed := state.left_speed_mps
	state.set_commands(0.0, 0.0)
	state.step_fixed(STEP, flat)
	if _check(
		state.left_speed_mps < forward_speed and state.left_speed_mps > 0.0,
		"coast did not reduce speed"
	) != 0:
		return 1

	state.reset()
	state.set_commands(-1.0, 1.0)
	for _index in 120:
		state.step_fixed(STEP, flat)
	if _check(
		Vector2(state.chassis_transform.origin.x, state.chassis_transform.origin.z).length() < 0.001,
		"pivot turn translated the chassis"
	) != 0:
		return 1
	if _check(absf(state.yaw_radians) > 0.2, "pivot turn did not rotate the chassis") != 0:
		return 1

	state.reset()
	state.set_commands(0.45, 1.0)
	for _index in 120:
		state.step_fixed(STEP, flat)
	if _check(
		absf(state.yaw_radians) > 0.05 and state.chassis_transform.origin.length() > 0.2,
		"differential turn did not arc"
	) != 0:
		return 1
	state.set_commands(-1.0, -1.0)
	for _index in 180:
		state.step_fixed(STEP, flat)
	return _check(
		state.left_speed_mps < 0.0 and state.right_speed_mps < 0.0,
		"direction reversal did not cross zero"
	)


func _test_support_and_bounds() -> int:
	var state := _configured_state("sy135")
	var slope := func(point: Vector2) -> float: return point.y * 0.1
	state.set_commands(0.4, 0.4)
	for _index in 60:
		state.step_fixed(STEP, slope)
	if _check(state.last_slope_degrees > 1.0, "slope support was not detected") != 0:
		return 1
	if _check(
		state.chassis_transform.basis.y.dot(Vector3.UP) < 0.9999,
		"chassis did not align to slope"
	) != 0:
		return 1
	var before := state.chassis_transform
	var outside := func(_point: Vector2) -> float: return NAN
	if _check(not state.step_fixed(STEP, outside), "invalid terrain sample was accepted") != 0:
		return 1
	if _check(state.chassis_transform.is_equal_approx(before), "invalid terrain changed chassis pose") != 0:
		return 1
	var status := state.get_status_snapshot()
	return _check(
		is_zero_approx(float(status["left_speed_mps"]))
		and is_zero_approx(float(status["right_speed_mps"])),
		"invalid terrain did not stop tracks"
	)


func _test_input_actions_and_parent_composition() -> int:
	var host := Node3D.new()
	get_root().add_child(host)
	var terrain_root := Node3D.new()
	terrain_root.name = "TerrainRoot"
	host.add_child(terrain_root)
	var terrain_world := TerrainWorld.new()
	terrain_world.name = "TerrainWorld"
	terrain_root.add_child(terrain_world)
	var chassis := TrackedChassisController.new()
	chassis.name = "ChassisMotionRoot"
	chassis.use_project_authority_profile = false
	chassis.authority_profile = AuthorityProfile.PYTHON_KINEMATIC
	host.add_child(chassis)
	var presentation_root := Node3D.new()
	presentation_root.name = "PresentationRoot"
	chassis.add_child(presentation_root)
	var client := MotionClient.new()
	client.name = "MotionClient"
	client.auto_connect = false
	client.auto_reconnect = false
	host.add_child(client)
	var presentation := MotionPresentation.new()
	presentation.name = "MotionPresentation"
	presentation.presentation_root_path = NodePath("../ChassisMotionRoot/PresentationRoot")
	presentation.use_project_authority_profile = false
	presentation.authority_profile = AuthorityProfile.PYTHON_KINEMATIC
	host.add_child(presentation)
	await process_frame
	await process_frame
	for action in TrackedChassisController.INPUT_ACTIONS:
		if _check(InputMap.has_action(action), "missing track input action: %s" % action) != 0:
			host.free()
			return 1
		var definition: Dictionary = TrackedChassisController.INPUT_ACTIONS[action]
		var key_events: Array[InputEvent] = []
		var joy_events: Array[InputEvent] = []
		for event in InputMap.action_get_events(action):
			if event is InputEventKey:
				key_events.append(event)
			elif event is InputEventJoypadMotion or event is InputEventJoypadButton:
				joy_events.append(event)
		if _check(
			key_events.size() == 1
			and (key_events[0] as InputEventKey).physical_keycode == int(EXPECTED_TRACK_KEYS[action]),
			"track input action has the wrong keyboard binding: %s" % action,
		) != 0:
			host.free()
			return 1
		var gamepad_matches := joy_events.size() == 1
		if definition.has("joy_axis"):
			gamepad_matches = gamepad_matches and joy_events[0] is InputEventJoypadMotion
			if gamepad_matches:
				var motion := joy_events[0] as InputEventJoypadMotion
				gamepad_matches = motion.axis == int(definition["joy_axis"]) and is_equal_approx(motion.axis_value, float(definition["joy_sign"]))
		else:
			gamepad_matches = gamepad_matches and joy_events[0] is InputEventJoypadButton
			if gamepad_matches:
				gamepad_matches = (joy_events[0] as InputEventJoypadButton).button_index == int(definition["joy_button"])
		if _check(gamepad_matches, "track input action has the wrong XInput binding: %s" % action) != 0:
			host.free()
			return 1
	if _check(chassis.configure_model_for_test("sy205"), chassis.contract_error) != 0:
		host.free()
		return 1
	if _check(not chassis.configure_model_for_test("unknown"), "unknown model received fallback") != 0:
		host.free()
		return 1
	if _check(chassis.configure_model_for_test("sy205"), chassis.contract_error) != 0:
		host.free()
		return 1

	var fixture := _read_json(SY205_FIXTURE)
	if _check(presentation.apply_pose_for_test(fixture["poses"]["zero"]), "zero pose failed") != 0:
		host.free()
		return 1
	var base := presentation.get_frame_node("base_link")
	var before := base.global_position
	chassis.transform = Transform3D(Basis(Vector3.UP, 0.25), Vector3(2.0, 0.5, -1.0))
	if _check(
		presentation.apply_pose_for_test(fixture["poses"]["zero"]),
		"pose after chassis move failed"
	) != 0:
		host.free()
		return 1
	var expected := chassis.global_transform * before
	if _check(
		base.global_position.distance_to(expected) < 0.001,
		"Python base update cancelled chassis parent motion"
	) != 0:
		host.free()
		return 1
	if _check(
		presentation.set_authority_profile_for_test(AuthorityProfile.JOLT_AUTHORITATIVE),
		"presentation rejected the authoritative profile"
	) != 0:
		host.free()
		return 1
	var frozen_base := base.global_transform
	if _check(
		not presentation.apply_pose_for_test(fixture["poses"]["swing_positive_90"])
		and base.global_transform.is_equal_approx(frozen_base),
		"Python pose changed the physics-owned presentation"
	) != 0:
		host.free()
		return 1
	chassis.reset_for_test()
	if _check(
		chassis.transform.is_equal_approx(Transform3D.IDENTITY),
		"controller reset did not restore identity"
	) != 0:
		host.free()
		return 1
	host.free()
	return 0


func _test_jolt_hints_and_lifecycle() -> int:
	var host := Node3D.new()
	get_root().add_child(host)
	var terrain_root := Node3D.new()
	terrain_root.name = "TerrainRoot"
	host.add_child(terrain_root)
	var terrain_world := TerrainWorld.new()
	terrain_world.name = "TerrainWorld"
	terrain_root.add_child(terrain_world)
	var terrain_collider := TerrainCollider.new()
	terrain_collider.name = "TerrainCollider"
	terrain_collider.enabled = true
	terrain_root.add_child(terrain_collider)
	var chassis := TrackedChassisController.new()
	chassis.name = "ChassisMotionRoot"
	chassis.use_project_authority_profile = false
	chassis.authority_profile = AuthorityProfile.PYTHON_KINEMATIC
	host.add_child(chassis)
	var presentation_root := Node3D.new()
	presentation_root.name = "PresentationRoot"
	chassis.add_child(presentation_root)
	var client := MotionClient.new()
	client.name = "MotionClient"
	client.auto_connect = false
	client.auto_reconnect = false
	host.add_child(client)
	var presentation := MotionPresentation.new()
	presentation.name = "MotionPresentation"
	presentation.presentation_root_path = NodePath("../ChassisMotionRoot/PresentationRoot")
	presentation.use_project_authority_profile = false
	presentation.authority_profile = AuthorityProfile.PYTHON_KINEMATIC
	host.add_child(presentation)
	await process_frame
	await process_frame
	if _check(not chassis.controller_enabled, "tracked controller must default disabled") != 0:
		host.free()
		return 1
	chassis.set_controller_enabled(true)
	if _check(chassis.configure_model_for_test("sy205"), chassis.contract_error) != 0:
		host.free()
		return 1
	var snapshot := terrain_world.terrain_state.surface_snapshot()
	if _check(
		terrain_collider.queue_snapshot(snapshot) and terrain_collider.apply_pending(),
		"Jolt terrain collider did not accept current snapshot"
	) != 0:
		host.free()
		return 1
	await physics_frame
	await physics_frame
	var point := Vector2.ZERO
	var authoritative := terrain_world.terrain_state.sample_surface_bilinear_at(point)
	var hinted := chassis.sample_terrain_height_for_test(point)
	if _check(is_equal_approx(hinted, authoritative), "Jolt hint changed authoritative height") != 0:
		host.free()
		return 1
	if _check(
		chassis.get_status_snapshot()["jolt_hint_status"] == "used",
		"matching Jolt hint was not used: %s" % chassis.get_status_snapshot()["jolt_hint_status"]
	) != 0:
		host.free()
		return 1
	chassis.use_jolt_support_hints = false
	if _check(
		is_equal_approx(chassis.sample_terrain_height_for_test(point), authoritative)
		and chassis.get_status_snapshot()["jolt_hint_status"] == "disabled",
		"Jolt-disabled heightfield fallback failed"
	) != 0:
		host.free()
		return 1
	chassis.use_jolt_support_hints = true
	terrain_world.terrain_state.enqueue_brush(1, point, 1.0, -0.1)
	terrain_world.terrain_state.step_fixed()
	var changed_height := terrain_world.terrain_state.sample_surface_bilinear_at(point)
	if _check(
		is_equal_approx(chassis.sample_terrain_height_for_test(point), changed_height)
		and chassis.get_status_snapshot()["jolt_hint_status"] == "identity_mismatch",
		"stale Jolt collider did not fail open to authoritative heightfield"
	) != 0:
		host.free()
		return 1

	var flat := func(_point: Vector2) -> float: return 0.0
	chassis.set_commands_for_test(1.0, 1.0)
	for _index in 30:
		chassis.step_fixed_for_test(STEP, flat)
	client.pose_cleared.emit(2, "transport_replaced")
	if _check(_controller_is_reset(chassis), "reconnect did not clear chassis state") != 0:
		host.free()
		return 1
	var asset_root := Node3D.new()
	presentation.model_activated.emit("sy135", asset_root)
	if _check(
		chassis.active_model_id == "sy135" and _controller_is_reset(chassis),
		"model activation did not reset and reconfigure chassis"
	) != 0:
		asset_root.free()
		host.free()
		return 1
	asset_root.free()
	chassis.set_commands_for_test(1.0, 1.0)
	chassis.step_fixed_for_test(STEP, flat)
	terrain_world.reset_for_test()
	if _check(_controller_is_reset(chassis), "world reset did not clear chassis state") != 0:
		host.free()
		return 1
	chassis.set_commands_for_test(1.0, 1.0)
	chassis.step_fixed_for_test(STEP, flat)
	chassis.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	if _check(_controller_is_stopped(chassis), "focus loss retained track input") != 0:
		host.free()
		return 1
	chassis.set_controller_enabled(false)
	if _check(_controller_is_reset(chassis), "controller disable did not restore identity") != 0:
		host.free()
		return 1
	host.free()
	return 0


func _controller_is_stopped(chassis: TrackedChassisController) -> bool:
	var status := chassis.get_status_snapshot()
	return is_zero_approx(float(status["left_speed_mps"])) and is_zero_approx(float(status["right_speed_mps"]))


func _controller_is_reset(chassis: TrackedChassisController) -> bool:
	return chassis.transform.is_equal_approx(Transform3D.IDENTITY) and _controller_is_stopped(chassis)


func _configured_state(model_id: String) -> TrackedLocomotionState:
	var catalog := _read_json(CATALOG_PATH)
	for entry in catalog.get("models", []):
		if String(entry.get("model_id", "")) == model_id:
			var state := TrackedLocomotionState.new()
			state.configure(entry["tracked_locomotion"])
			return state
	return TrackedLocomotionState.new()


func _read_json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}


func _check(condition: bool, message: String) -> int:
	if condition:
		return 0
	push_error(message)
	return 1

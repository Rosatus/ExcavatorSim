extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var descriptor := PhysicsRigDescriptor.load_for_model("sy155w")
	if descriptor == null or not descriptor.is_valid_for("sy155w", "sy155w-source-urdf-v1"):
		push_error("SY155W rig: " + ("missing" if descriptor == null else descriptor.validation_error()))
		quit(1)
		return
	var scene := load("res://scenes/main.tscn").instantiate() as Node3D
	root.add_child(scene)
	await process_frame
	await physics_frame
	var session := scene.get_node("ProductSession") as ProductSession
	var presentation := scene.get_node("MotionPresentation") as MotionPresentation
	var chassis := scene.get_node("ChassisMotionRoot") as TrackedChassisController
	var attachments := scene.get_node("AttachmentRig") as AttachmentRig
	_check(session.request_model_switch("sy155w"), "switch to SY155W: " + JSON.stringify(session.last_error))
	await process_frame
	await physics_frame
	_check(presentation.get_active_model_id() == "sy155w", "active SY155W")
	_check(presentation.get_contract_error().is_empty(), "presentation: " + presentation.get_contract_error())
	_check(bool(chassis.get_status_snapshot().get("configured", false)), "chassis configured")
	_check(chassis.get_status_snapshot().get("locomotion_mode") == "wheeled", "main scene selects wheeled locomotion")
	chassis.set_wheeled_commands_for_test(0, 0, 0)
	for tick in 120:
		await physics_frame
	chassis.set_wheeled_commands_for_test(0.5, 0, 0.4)
	for tick in 120:
		await physics_frame
	var wheel_status: Dictionary = chassis.get_status_snapshot().get("wheeled_locomotion", {})
	_check(not wheel_status.is_empty(), "main scene wheel state published")
	if not wheel_status.is_empty():
		_check(absf(float(wheel_status.speed_mps)) > 0.1, "main scene wheel input moves actual machine")
		var profile := WheeledMachineProfile.load_for_model("sy155w")
		var asset := presentation.get_frame_node("base_link").get_parent().get_parent().get_parent()
		var wheel_node := asset.get_node_or_null(profile.data.wheels[0].roll_path) as Node3D
		_check(wheel_node != null and not wheel_node.basis.is_equal_approx(Basis.IDENTITY), "main presentation animates imported wheel")
	chassis.clear_commands_for_test()
	_check(attachments.active_attachment_id() == "xtr13+gb12", "default XTR13 + GB12")
	_check(attachments.active_tool_node() != null, "default GB12 mounted")
	_check(not attachments.tool_ids().has("standard_bucket"), "source bucket is not selectable")
	_check(not attachments.request_tool("standard_bucket"), "source bucket request rejected")
	_check(attachments.active_attachment_id() == "xtr13+gb12", "rejected source bucket preserves mounted default")
	_check(presentation.get_soil_frame_node("bucket_link") == attachments.active_tool_node(), "soil follows mounted GB12")
	_check(presentation.get_soil_contract().get("fill_profile_id", "") == "gb12_s50", "GB12 soil geometry")
	# Gamepad attachment layer end-to-end: hold D-pad Down, right-stick Y must
	# drive XTR13 tilt (and right-stick X rotate) through the real
	# InputMap -> MotionClient -> ProductSession -> AttachmentRig chain while
	# the masked boom/bucket axes stay zero. Input.action_press feeds
	# is_action_pressed/get_axis exactly like the registered joypad bindings.
	_check(session.request_start(), "session start for pad tilt")
	session.set_focused(true)
	_check(InputMap.has_action("pad_layer_dpad_down"), "pad layer action not registered")
	Input.action_press("pad_layer_dpad_down")
	Input.action_press("operator_boom_raise", 1.0)
	await physics_frame
	var attachment_axes := session.get_attachment_input_axes()
	_check(attachment_axes.x > 0.5, "pad tilt axis not routed to XTR13: %s" % attachment_axes)
	var base_axes := session.get_equipment_input_axes()
	_check(absf(base_axes.y) < 0.01 and absf(base_axes.w) < 0.01, "pad tilt leaked into base axes: %s" % base_axes)
	var tilt_before := float(attachments.joint_state_for_test().get("tilt_deg", 0.0))
	for tick in 30:
		await physics_frame
	var tilt_after := float(attachments.joint_state_for_test().get("tilt_deg", 0.0))
	_check(tilt_after > tilt_before + 1.0, "XTR13 tilt did not move under pad layer: %s -> %s" % [tilt_before, tilt_after])
	Input.action_release("operator_boom_raise")
	Input.action_press("operator_bucket_dump", 1.0)
	for tick in 30:
		await physics_frame
	_check(absf(float(attachments.joint_state_for_test().get("rotate_deg", 0.0))) > 1.0, "XTR13 rotate did not move under pad layer")
	Input.action_release("operator_bucket_dump")
	Input.action_release("pad_layer_dpad_down")
	var axis: Dictionary = presentation.get_local_axis_state_for_test().get("boom_fold", {})
	_check(not axis.is_empty(), "fold axis registered")
	if axis.is_empty():
		for failure in failures:
			push_error(failure)
		scene.free()
		quit(1)
		return
	presentation.set_local_axis_input_for_test(1.0)
	presentation._physics_process(2.0)
	_check(is_equal_approx(float(presentation.get_local_axis_state_for_test().boom_fold.angle_deg), 10.0), "U unfold upper limit")
	_check(presentation.get_hydraulics_snapshot_for_test().error == "", "hydraulics after local fold: " + str(presentation.get_hydraulics_snapshot_for_test()))
	presentation.set_local_axis_input_for_test(-1.0)
	presentation._physics_process(4.0)
	_check(is_equal_approx(float(presentation.get_local_axis_state_for_test().boom_fold.angle_deg), -30.0), "E fold lower limit")
	presentation.clear_local_axis_input_for_test()
	presentation.restore_rest_pose_for_test()
	_check(is_zero_approx(float(presentation.get_local_axis_state_for_test().boom_fold.angle_deg)), "reset restores fold")
	_check(presentation.get_hydraulics_snapshot_for_test().error == "", "reset restores hydraulics")
	_check(session.request_model_switch("sy135"), "switch to SY135")
	await process_frame
	_check(presentation.get_local_axis_state_for_test().is_empty(), "no fold on SY135")
	_check(presentation.get_hydraulics_snapshot_for_test().cylinder_count == 0, "no retained SY155W hydraulic nodes")
	_check(session.request_model_switch("sy155w"), "second switch to SY155W")
	await process_frame
	await physics_frame
	_check(attachments.active_attachment_id() == "xtr13+gb12", "default attachment on second activation")
	_check(presentation.get_hydraulics_snapshot_for_test().cylinder_count == 6, "hydraulics on second activation")
	if failures.is_empty():
		print("SY155W session test passed: switch, default attachments, folding inputs/limits/reset, return to SY135.")
	else:
		for failure in failures:
			push_error(failure)
	scene.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)


func _check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)

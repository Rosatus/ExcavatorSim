extends SceneTree

## Headless contract for the coupler + tool attachment-switch feature:
## catalog hash pins, supported_couplers auto-resolution in both directions,
## mount/socket identity transforms, tilt/rotate drive ranges with
## passive-mechanism follow, soil-frame indirection, input modifier masking,
## and the model-switch remount lifecycle.

const CATALOG_PATH := "res://resources/models/attachment_catalog.json"

var _attachment_events: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := Node3D.new()
	get_root().add_child(host)
	var presentation_root := Node3D.new()
	presentation_root.name = "PresentationRoot"
	host.add_child(presentation_root)
	var client := MotionClient.new()
	client.name = "MotionClient"
	client.auto_connect = false
	client.auto_reconnect = false
	client.desired_model_id = "sy135"
	host.add_child(client)
	var presentation := MotionPresentation.new()
	presentation.name = "MotionPresentation"
	host.add_child(presentation)
	var rig := AttachmentRig.new()
	rig.name = "AttachmentRig"
	rig.motion_presentation_path = NodePath("../MotionPresentation")
	rig.product_session_path = NodePath("../ProductSession")
	rig.motion_client_path = NodePath("../MotionClient")
	host.add_child(rig)
	var session := ProductSession.new()
	session.name = "ProductSession"
	session.lifecycle_input_enabled = false
	session.motion_presentation_path = NodePath("../MotionPresentation")
	session.motion_client_path = NodePath("../MotionClient")
	session.chassis_path = NodePath("../MissingChassis")
	session.excavation_world_path = NodePath("../MissingExcavation")
	session.attachment_rig_path = NodePath("../AttachmentRig")
	host.add_child(session)
	presentation.attachment_changed.connect(_on_attachment_changed)
	await process_frame
	await process_frame

	if _check(presentation.get_contract_error().is_empty(), presentation.get_contract_error()) != 0:
		return _finish(host, 1)
	if _check(presentation.set_authority_profile_for_test(AuthorityProfile.PYTHON_KINEMATIC),
			"attachment test selects the Python compatibility profile") != 0:
		return _finish(host, 1)
	if _check(presentation.get_active_model_id() == "sy135", "SY135 did not activate") != 0:
		return _finish(host, 1)
	if _check(rig.get_catalog_error().is_empty(), "attachment catalog failed: %s" % rig.get_catalog_error()) != 0:
		return _finish(host, 1)
	if not _check_catalog_pins():
		return _finish(host, 1)
	var coupler_ids := rig.coupler_ids()
	var tool_ids := rig.tool_ids()
	if _check(coupler_ids.has("none") and coupler_ids.has("xtr13"),
			"catalog coupler ids incomplete: %s" % [coupler_ids]) != 0:
		return _finish(host, 1)
	if _check(tool_ids.has("standard_bucket") and tool_ids.has("gb12") and tool_ids.has("no_tool"),
			"catalog tool ids incomplete: %s" % [tool_ids]) != 0:
		return _finish(host, 1)
	if _check(rig.tool_supported_couplers("standard_bucket") == ["none"]
			and rig.tool_supported_couplers("gb12") == ["xtr13"]
			and rig.tool_supported_couplers("no_tool") == ["xtr13"],
			"supported_couplers declarations are wrong") != 0:
		return _finish(host, 1)
	if not _check_input_mask():
		return _finish(host, 1)

	# Tool-first switch: GB12 cannot mount on the direct pin, so the coupler
	# auto-resolves to the XTR13 the tool declares support for.
	if _check(session.request_tool_switch("gb12"), "gb12 switch rejected: %s" % [session.last_error]) != 0:
		return _finish(host, 1)
	if _check(session.active_coupler_id == "xtr13" and session.active_tool_id == "gb12",
			"gb12 did not auto-resolve the xtr13 coupler: %s+%s" % [session.active_coupler_id, session.active_tool_id]) != 0:
		return _finish(host, 1)
	if _check(session.active_attachment_id() == "xtr13+gb12", "session did not record xtr13+gb12") != 0:
		return _finish(host, 1)
	var bucket_link := presentation.get_frame_node("bucket_link")
	if _check(bucket_link != null, "bucket_link frame unavailable") != 0:
		return _finish(host, 1)
	var mount := bucket_link.get_node_or_null("AttachmentMount") as Node3D
	if _check(mount != null and mount.transform.is_equal_approx(Transform3D.IDENTITY),
			"XTR13 mount is not identity under bucket_link") != 0:
		return _finish(host, 1)
	var rotator_root := _find_named(mount, "XTR13_ROOT")
	if _check(rotator_root != null and rotator_root.transform.is_equal_approx(Transform3D.IDENTITY),
			"XTR13_ROOT is not identity under the mount") != 0:
		return _finish(host, 1)
	var socket := _find_named(rotator_root, "S50_TOOL_SOCKET")
	var tool := rig.active_tool_node()
	if _check(socket != null and tool != null and tool.get_parent() == socket,
			"GB12_ROOT is not parented to S50_TOOL_SOCKET") != 0:
		return _finish(host, 1)
	if _check(tool.transform.is_equal_approx(Transform3D.IDENTITY),
			"GB12_ROOT local transform is not identity") != 0:
		return _finish(host, 1)
	var state := rig.joint_state_for_test()
	if _check(bool(state.get("mounted", false)) and bool(state.get("tool_node", false)),
			"rig joint state does not report a mounted tool") != 0:
		return _finish(host, 1)

	# Native bucket visuals hide; soil resolves through the attachment tool.
	for visual in presentation.get_frame_visual_nodes("bucket_link"):
		if _check(not visual.visible, "native bucket visual stayed visible") != 0:
			return _finish(host, 1)
	if _check(presentation.get_soil_frame_node("bucket_link") == tool,
			"soil frame does not resolve to the mounted tool") != 0:
		return _finish(host, 1)
	var solid_mount: Variant = presentation.get_solid_tool_mount_transform()
	if _check(solid_mount is Transform3D and
			(bucket_link.global_transform * solid_mount).is_equal_approx(tool.global_transform),
			"solid geometry mount does not resolve to active tool") != 0:
		return _finish(host, 1)
	var contract := presentation.get_soil_contract()
	if _check(String(contract.get("model_id", "")) == "sy135" and not (contract.get("bucket_tool", {}) as Dictionary).is_empty(),
			"attachment soil contract is not active for sy135") != 0:
		return _finish(host, 1)
	var fixture: Dictionary = _read_json("res://tests/fixtures/sy135_frame_parity_cases.json")
	if _check(presentation.apply_pose_for_test((fixture.get("poses", {}) as Dictionary).get("zero", {})),
			"sy135 zero pose failed under the attachment") != 0:
		return _finish(host, 1)
	var first_soil := presentation.sample_bucket_pose_fixed(0, 0)
	var second_soil := presentation.sample_bucket_pose_fixed(0, 0)
	if _check(not bool(first_soil.get("valid", false)) and bool(second_soil.get("valid", false)),
			"attachment bucket sweep history did not gate correctly") != 0:
		return _finish(host, 1)

	# Drive ranges: tilt clamps at ±45°, rotate wraps inside [-180, 180).
	var tilt_node := _find_named(rotator_root, "TILT_Y")
	var rotate_node := _find_named(rotator_root, "ROTATE_Z")
	var cylinder_l := _find_named(rotator_root, "CYLINDER_L_PIVOT")
	var piston_l := _find_named(rotator_root, "Tilt cylinder | chrome piston")
	if _check(tilt_node != null and rotate_node != null and cylinder_l != null and piston_l != null,
			"rotator joint or passive nodes missing") != 0:
		return _finish(host, 1)
	if _check(rig._passive_nodes.size() == 4,
			"passive rig should drive 2 pivots + 2 pistons, got %s" % rig._passive_nodes.size()) != 0:
		return _finish(host, 1)
	var pin_l := _find_named(rotator_root, "Tilt cylinder | rod-end pin")
	var pin_r := _find_named(rotator_root, "Tilt cylinder | rod-end pin_001")
	if _check(pin_l != null and pin_r != null, "rod-end bracket pins missing") != 0:
		return _finish(host, 1)
	var rest_cylinder_quat := cylinder_l.quaternion
	var rest_piston_pos := piston_l.position
	var rest_pin_gap := minf(piston_l.global_position.distance_to(pin_l.global_position),
			piston_l.global_position.distance_to(pin_r.global_position))
	# Contact accepts the same candidate axes without another joint writer.
	rig.set_axes_for_test(Vector2(1.0, 1.0))
	rig._physics_process(1.0 / 60.0)
	var candidate_angles := rig.joint_state_for_test()
	rig.accept_solid_contact_fraction(0.25)
	var clipped_angles := rig.joint_state_for_test()
	if _check(is_equal_approx(clipped_angles.tilt_deg, candidate_angles.tilt_deg * 0.25)
			and is_equal_approx(clipped_angles.rotate_deg, candidate_angles.rotate_deg * 0.25),
			"solid contact did not constrain attachment tilt and rotation") != 0:
		return _finish(host, 1)
	rig.accept_solid_contact_fraction(0.0)
	if _check(presentation.get_solid_tool_mount_transform().is_equal_approx(solid_mount),
			"zero accepted attachment motion did not restore its complete mount") != 0:
		return _finish(host, 1)
	rig.set_axes_for_test(Vector2(1.0, 0.0))
	await _drive_frames(140)
	state = rig.joint_state_for_test()
	if _check(is_equal_approx(float(state.get("tilt_deg", 0.0)), 45.0),
			"tilt did not clamp at +45: %s" % state.get("tilt_deg")) != 0:
		return _finish(host, 1)
	if _check(tilt_node.quaternion.z > 0.0,
			"tilt joint twist sign diverges from the baked table (axis mirrored): %s" % tilt_node.quaternion.z) != 0:
		return _finish(host, 1)
	if _check(not cylinder_l.quaternion.is_equal_approx(rest_cylinder_quat),
			"passive cylinder pivot did not follow the tilt") != 0:
		return _finish(host, 1)
	if _check(not piston_l.position.is_equal_approx(rest_piston_pos),
			"chrome piston did not follow the tilt") != 0:
		return _finish(host, 1)
	# At +45° the authored clip puts the left rod end low: direction, not just motion.
	if _check(piston_l.position.y < rest_piston_pos.y - 0.1,
			"left piston extended on the wrong side at +45° (mirrored sample): %s" % piston_l.position) != 0:
		return _finish(host, 1)
	# The rod is rigid: piston-to-bracket-pin distance must stay constant.
	var pin_gap := minf(piston_l.global_position.distance_to(pin_l.global_position),
			piston_l.global_position.distance_to(pin_r.global_position))
	if _check(absf(pin_gap - rest_pin_gap) < 0.02,
			"chrome piston rod end detached from the tilting bracket: rest=%s now=%s" % [rest_pin_gap, pin_gap]) != 0:
		return _finish(host, 1)
	rig.set_axes_for_test(Vector2(-1.0, 0.0))
	await _drive_frames(140)
	state = rig.joint_state_for_test()
	if _check(is_equal_approx(float(state.get("tilt_deg", 0.0)), -45.0),
			"tilt did not clamp at -45: %s" % state.get("tilt_deg")) != 0:
		return _finish(host, 1)
	rig.set_axes_for_test(Vector2(0.0, 1.0))
	var wrapped := false
	for i in 600:
		await physics_frame
		var rot := float(rig.joint_state_for_test().get("rotate_deg", 0.0))
		if rot < -170.0 or rot > 170.0:
			wrapped = true
		if wrapped and rot > -170.0 and rot < 170.0:
			break
	state = rig.joint_state_for_test()
	var final_rot := float(state.get("rotate_deg", 0.0))
	if _check(wrapped and final_rot >= -180.0 and final_rot < 180.0,
			"rotation did not wrap through ±180: %s" % final_rot) != 0:
		return _finish(host, 1)
	rig.clear_axes_for_test()

	# Session-level attachment axes read through the injected probe.
	if _check(session.request_start(), "session did not start") != 0:
		return _finish(host, 1)
	client._attachment_input_mapper.input_probe = func(kind: String, probe_name: String) -> float:
		if kind == "key":
			return 1.0 if probe_name == "KEY_Q" else 0.0
		return 1.0 if probe_name == "operator_bucket_curl|operator_bucket_dump" else 0.0
	var axes := session.get_attachment_input_axes()
	if _check(is_equal_approx(axes.x, 1.0) and is_equal_approx(axes.y, 0.0),
			"session attachment axes did not read the tilt pair: %s" % axes) != 0:
		return _finish(host, 1)
	client._attachment_input_mapper.input_probe = Callable()

	# Model switch re-mounts the active attachment on the new host model.
	_attachment_events.clear()
	if _check(session.request_model_switch("sy205"), "model switch to sy205 failed: %s" % [session.last_error]) != 0:
		return _finish(host, 1)
	await process_frame
	await process_frame
	if _check(presentation.get_active_model_id() == "sy205", "sy205 did not activate") != 0:
		return _finish(host, 1)
	var remount_bucket := presentation.get_frame_node("bucket_link")
	var remount := remount_bucket.get_node_or_null("AttachmentMount") as Node3D if remount_bucket != null else null
	if _check(remount != null and rig.active_tool_node() != null,
			"attachment did not re-mount on sy205") != 0:
		return _finish(host, 1)
	if _check(String(presentation.get_soil_contract().get("model_id", "")) == "sy205",
			"attachment soil contract did not rebind to sy205") != 0:
		return _finish(host, 1)
	if _check(_attachment_events.has("xtr13+gb12"), "attachment_changed was not emitted on remount: %s" % [_attachment_events]) != 0:
		return _finish(host, 1)

	# Coupler-first switch: dropping the XTR13 leaves nothing the GB12 can
	# mount on, so the tool auto-resolves back to the standard bucket.
	if _check(session.request_coupler_switch("none"), "coupler release rejected") != 0:
		return _finish(host, 1)
	if _check(session.active_coupler_id == "none" and session.active_tool_id == "standard_bucket",
			"releasing the coupler did not restore the standard bucket: %s+%s" % [session.active_coupler_id, session.active_tool_id]) != 0:
		return _finish(host, 1)
	if _check(not bool(rig.joint_state_for_test().get("mounted", true)),
			"mount was not released on standard_bucket switch") != 0:
		return _finish(host, 1)
	var restored := false
	for visual in presentation.get_frame_visual_nodes("bucket_link"):
		if visual.visible:
			restored = true
	if _check(restored, "native bucket visuals were not restored") != 0:
		return _finish(host, 1)
	if _check(presentation.get_soil_frame_node("bucket_link") == presentation.get_frame_node("bucket_link"),
			"soil frame did not fall back to the native bucket_link") != 0:
		return _finish(host, 1)
	if _check(presentation.get_solid_tool_mount_transform() == Transform3D.IDENTITY,
			"native bucket collision did not restore its local frame") != 0:
		return _finish(host, 1)
	if _check(String(presentation.get_soil_contract().get("model_id", "")) == "sy205",
			"host soil contract was not restored") != 0:
		return _finish(host, 1)

	# Unknown ids fail closed on both selectors without disturbing the mount.
	if _check(not session.request_tool_switch("nonexistent_tool"),
			"unknown tool id was accepted") != 0:
		return _finish(host, 1)
	if _check(not session.request_coupler_switch("nonexistent_coupler"),
			"unknown coupler id was accepted") != 0:
		return _finish(host, 1)
	if _check(session.active_coupler_id == "none" and session.active_tool_id == "standard_bucket",
			"failed requests disturbed the active combination") != 0:
		return _finish(host, 1)

	# The bare tiltrotator: coupler XTR13 + tool "no_tool" mounts the rotator
	# with nothing under the socket and keeps the host soil contract resolved
	# at the native joint frame (documented v1 approx).
	if _check(session.request_coupler_switch("xtr13"), "xtr13 switch rejected") != 0:
		return _finish(host, 1)
	if _check(session.active_coupler_id == "xtr13" and session.active_tool_id == "gb12",
			"xtr13 coupler did not auto-resolve a compatible tool: %s+%s" % [session.active_coupler_id, session.active_tool_id]) != 0:
		return _finish(host, 1)
	if _check(session.request_tool_switch("no_tool"), "no_tool switch rejected") != 0:
		return _finish(host, 1)
	if _check(session.active_coupler_id == "xtr13" and session.active_tool_id == "no_tool",
			"no_tool did not keep the xtr13 coupler: %s+%s" % [session.active_coupler_id, session.active_tool_id]) != 0:
		return _finish(host, 1)
	if _check(presentation.get_solid_tool_mount_transform() == null,
			"no-tool selection retained a ghost bucket collision") != 0:
		return _finish(host, 1)
	state = rig.joint_state_for_test()
	if _check(bool(state.get("mounted", false)) and not bool(state.get("tool_node", true)),
			"xtr13+no_tool should mount the rotator without a tool: %s" % [state]) != 0:
		return _finish(host, 1)
	if _check(presentation.get_soil_frame_node("bucket_link") == presentation.get_frame_node("bucket_link"),
			"xtr13+no_tool soil frame should stay on the native joint") != 0:
		return _finish(host, 1)
	if _check(String(presentation.get_soil_contract().get("model_id", "")) == "sy205",
			"xtr13+no_tool should keep the host soil contract") != 0:
		return _finish(host, 1)

	print("attachment switch contract passed.")
	_finish(host, 0)


func _drive_frames(count: int) -> void:
	for i in count:
		await physics_frame


func _on_attachment_changed(attachment_id: String) -> void:
	_attachment_events.append(attachment_id)


func _check_catalog_pins() -> bool:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG_PATH))
	if _check(parsed is Dictionary, "attachment catalog is not a dictionary") != 0:
		return false
	var pairs := {
		"couplers": [["rotator_glb_path", "rotator_glb_sha256"], ["tilt_rig_path", "tilt_rig_sha256"]],
		"tools": [["tool_glb_path", "tool_glb_sha256"], ["soil_contract_path", "soil_contract_sha256"]],
	}
	for section in pairs:
		for entry_value in (parsed as Dictionary).get(section, []):
			var entry := entry_value as Dictionary
			for pair in pairs[section]:
				var path := String(entry.get(pair[0], ""))
				var expected := String(entry.get(pair[1], ""))
				if path.is_empty() and expected.is_empty():
					continue
				if _check(FileAccess.file_exists(path), "catalog resource missing: %s" % path) != 0:
					return false
				if _check(FileAccess.get_sha256(path) == expected,
						"catalog sha256 mismatch for %s" % path) != 0:
					return false
	return true


func _check_input_mask() -> bool:
	var mapper := AttachmentInputMapper.new()
	mapper.configure({
		"tilt": {"modifier_key": "KEY_Q", "negative_action": "operator_bucket_curl",
				"positive_action": "operator_bucket_dump", "masked_axis": 3,
				"pad_modifier_action": "pad_layer_dpad_down",
				"pad_negative_action": "operator_boom_lower",
				"pad_positive_action": "operator_boom_raise"},
		"rotate": {"modifier_key": "KEY_O", "negative_action": "operator_swing_left",
				"positive_action": "operator_swing_right", "masked_axis": 0,
				"pad_modifier_action": "pad_layer_dpad_down",
				"pad_negative_action": "operator_bucket_curl",
				"pad_positive_action": "operator_bucket_dump"},
	})
	if _check(mapper.is_active(), "configured mapper is not active") != 0:
		return false
	var held := {"KEY_Q": false, "KEY_O": false}
	var pad_held := {"pad_layer_dpad_down": false}
	var pressed := {"operator_bucket_curl|operator_bucket_dump": 1.0,
			"operator_swing_left|operator_swing_right": -1.0,
			"operator_boom_lower|operator_boom_raise": -0.5}
	mapper.input_probe = func(kind: String, probe_name: String) -> float:
		if kind == "key":
			return 1.0 if bool(held.get(probe_name, false)) else 0.0
		if kind == "pad":
			return 1.0 if bool(pad_held.get(probe_name, false)) else 0.0
		return float(pressed.get(probe_name, 0.0))
	var idle_axes := mapper.read_attachment_axes()
	var idle_mask := mapper.mask_operator_axes(Vector4(0.5, -0.5, 0.25, -0.25))
	if _check(idle_axes == Vector2.ZERO and idle_mask == Vector4(0.5, -0.5, 0.25, -0.25),
			"idle mapper leaked attachment axes or masked base axes") != 0:
		return false
	held["KEY_Q"] = true
	var tilt_axes := mapper.read_attachment_axes()
	var tilt_mask := mapper.mask_operator_axes(Vector4(0.5, -0.5, 0.25, -0.25))
	if _check(is_equal_approx(tilt_axes.x, 1.0) and is_equal_approx(tilt_axes.y, 0.0),
			"Q+J/L did not produce the tilt axis: %s" % tilt_axes) != 0:
		return false
	if _check(tilt_mask == Vector4(0.5, -0.5, 0.25, 0.0),
			"Q modifier masked non-bucket axes: %s" % tilt_mask) != 0:
		return false
	held["KEY_O"] = true
	var both_axes := mapper.read_attachment_axes()
	var both_mask := mapper.mask_operator_axes(Vector4(0.5, -0.5, 0.25, -0.25))
	if _check(is_equal_approx(both_axes.x, 1.0) and is_equal_approx(both_axes.y, -1.0),
			"Q+O did not combine tilt and rotate axes: %s" % both_axes) != 0:
		return false
	if _check(both_mask == Vector4(0.0, -0.5, 0.25, 0.0),
			"Q+O did not mask only swing and bucket: %s" % both_mask) != 0:
		return false
	held["KEY_Q"] = false
	held["KEY_O"] = false
	# D-pad layer: while held, right-stick pairs redirect to tilt (Y) and
	# rotate (X) and both base axes are masked.
	pad_held["pad_layer_dpad_down"] = true
	var pad_axes := mapper.read_attachment_axes()
	var pad_mask := mapper.mask_operator_axes(Vector4(0.5, -0.5, 0.25, -0.25))
	if _check(is_equal_approx(pad_axes.x, -0.5) and is_equal_approx(pad_axes.y, 1.0),
			"D-pad layer did not produce pad tilt/rotate: %s" % pad_axes) != 0:
		return false
	if _check(pad_mask == Vector4(0.5, 0.0, 0.25, 0.0),
			"D-pad layer did not mask boom and bucket: %s" % pad_mask) != 0:
		return false
	return true


func _find_named(root: Node, target: String) -> Node3D:
	var queue: Array[Node] = [root]
	while not queue.is_empty():
		var node: Node = queue.pop_front()
		if node is Node3D and node.name == target:
			return node as Node3D
		queue.append_array(node.get_children())
	return null


func _check(condition: bool, message: String) -> int:
	if condition:
		return 0
	push_error(message)
	return 1


func _read_json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}


func _finish(host: Node, code: int) -> void:
	host.queue_free()
	quit(code)

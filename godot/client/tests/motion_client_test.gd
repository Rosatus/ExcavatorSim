extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"
const FIXTURE_PATH := "res://tests/fixtures/sy205_frame_parity_cases.json"
const VERSIONS := {
	"protocol_version": "godot-pinocchio-v4",
	"state_schema_version": "godot-pinocchio-state-v2",
	"model_version": "sy205-glb-urdf-v4",
	"calibration_version": "machine-calibration-v2",
	"software_version": "0.1.0",
	"terrain_spec_version": "terrain-spec-v1",
	"terrain_algorithm_version": "terrain-algorithm-v2",
	"visual_model_version": "original-skin-v1",
}
const EXPECTED_EQUIPMENT_KEYS := {
	"operator_swing_left": KEY_A,
	"operator_swing_right": KEY_D,
	"operator_boom_lower": KEY_I,
	"operator_boom_raise": KEY_K,
	"operator_arm_extend": KEY_W,
	"operator_arm_retract": KEY_S,
	"operator_bucket_curl": KEY_J,
	"operator_bucket_dump": KEY_L,
}


class FakeTransport extends RefCounted:
	var sent: Array[String] = []
	var incoming: Array[PackedByteArray] = []
	var opened := false

	func connect_to_url(_endpoint: String) -> int:
		opened = true
		return OK

	func poll() -> void:
		pass

	func get_ready_state() -> int:
		return WebSocketPeer.STATE_OPEN if opened else WebSocketPeer.STATE_CLOSED

	func send_text(message: String) -> int:
		sent.append(message)
		return OK

	func get_available_packet_count() -> int:
		return incoming.size()

	func was_string_packet() -> bool:
		return true

	func get_packet() -> PackedByteArray:
		return incoming.pop_front()

	func enqueue(message: Dictionary) -> void:
		incoming.append(JSON.stringify(message).to_utf8_buffer())

	func close() -> void:
		opened = false


var _initial_transport: FakeTransport
var _reconnect_transport: FakeTransport


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	ProjectSettings.set_setting("motion/auto_connect", false)
	var result := _test_coordinate_conversion()
	if result == 0:
		result = await _test_motion_client()
	if result == 0:
		result = await _test_scene_presentation()
	quit(result)


func _test_coordinate_conversion() -> int:
	var translation := MotionProtocol.rows_to_transform([
		[1.0, 0.0, 0.0, 1.0],
		[0.0, 1.0, 0.0, 2.0],
		[0.0, 0.0, 1.0, 3.0],
		[0.0, 0.0, 0.0, 1.0],
	])
	if _check(translation.origin.is_equal_approx(Vector3(1.0, 3.0, -2.0)), "Z-up translation converts to Y-up") != 0:
		return 1
	var swing := MotionProtocol.rows_to_transform([
		[0.0, -1.0, 0.0, 0.0],
		[1.0, 0.0, 0.0, 0.0],
		[0.0, 0.0, 1.0, 0.0],
		[0.0, 0.0, 0.0, 1.0],
	])
	if _check(swing.basis.is_equal_approx(Basis(Vector3.UP, PI / 2.0)), "Python +Z swing becomes Godot +Y swing") != 0:
		return 1
	var work_hinge := MotionProtocol.rows_to_transform([
		[1.0, 0.0, 0.0, 0.0],
		[0.0, 0.0, -1.0, 0.0],
		[0.0, 1.0, 0.0, 0.0],
		[0.0, 0.0, 0.0, 1.0],
	])
	if _check(work_hinge.basis.is_equal_approx(Basis(Vector3.RIGHT, PI / 2.0)), "Python +X hinge remains Godot +X hinge") != 0:
		return 1
	if _check(absf(swing.basis.determinant() - 1.0) < 0.0001, "coordinate conversion preserves right-handed determinant") != 0:
		return 1
	print("Motion coordinate conversion contract passed.")
	return 0


func _test_motion_client() -> int:
	var client := MotionClient.new()
	client.auto_connect = false
	root.add_child(client)
	await process_frame
	var transport := FakeTransport.new()
	_initial_transport = transport
	client.set_transport_factory_for_test(Callable(self, "_new_initial_transport"))
	client.connect_to_service()
	client.inject_server_frame({"type": "terrain_view", "unexpected": "legacy"})
	if _check(client.get_status_snapshot()["last_error"].is_empty(), "legacy terrain frames are ignored before handshake") != 0:
		client.queue_free()
		return 1
	client.process_for_test(0.01)
	if _check(transport.sent.size() == 1, "client sends exactly one hello on socket open") != 0:
		client.queue_free()
		return 1
	var hello: Dictionary = JSON.parse_string(transport.sent[0])
	if _check(hello.get("type") == "hello", "hello has the expected type") != 0:
		client.queue_free()
		return 1
	if _check(hello.get("protocol_version") == MotionProtocol.PROTOCOL_VERSION, "hello keeps protocol version") != 0:
		client.queue_free()
		return 1
	if _check(hello.get("capabilities", []) == MotionProtocol.CAPABILITIES, "hello advertises all supported capabilities") != 0:
		client.queue_free()
		return 1

	transport.enqueue(_hello_ack("session-a", "epoch-a", "stopped"))
	client.process_for_test(0.01)
	if _check(client.get_connection_state() == MotionClient.STATE_READY, "hello_ack moves client to ready") != 0:
		client.queue_free()
		return 1
	if _check(client.request_model_switch("sy205") and client.get_connection_state() == MotionClient.STATE_READY, "selecting the active model is a no-op") != 0:
		client.queue_free()
		return 1
	if _assert_equipment_bindings(client, "sy205") != 0:
		client.queue_free()
		return 1
	if _assert_equipment_bindings(client, "sy135") != 0:
		client.queue_free()
		return 1
	if _check(
		not client.configure_equipment_model("unknown")
		and client.get_equipment_model_id().is_empty(),
		"unknown model disarms the equipment command profile",
	) != 0:
		client.queue_free()
		return 1
	client.configure_equipment_model("sy205")
	if _check(transport.sent.size() == 2, "hello_ack is followed by a zero-input arming snapshot") != 0:
		client.queue_free()
		return 1
	var arm_snapshot: Dictionary = JSON.parse_string(transport.sent[1])
	if _check(arm_snapshot.get("axes") == [0.0, 0.0, 0.0, 0.0], "arming snapshot is zeroed") != 0:
		client.queue_free()
		return 1

	var fixture := _read_fixture()
	var zero_pose: Dictionary = fixture["poses"]["zero"]
	client.inject_server_frame(_view_state(zero_pose, "epoch-a", 1, 1, 0))
	if _check(client.get_pose_buffer_size() == 1, "first view_state is accepted") != 0:
		client.queue_free()
		return 1
	client.set_input_axes(Vector4(0.25, -0.5, 0.75, -1.0))
	client.process_for_test(1.0 / MotionClient.INPUT_HZ)
	if _check(transport.sent.size() == 3, "armed client sends the next input snapshot") != 0:
		client.queue_free()
		return 1
	var input_snapshot: Dictionary = JSON.parse_string(transport.sent[2])
	if _check(input_snapshot.get("client_sequence") == 1, "input sequence is monotonic") != 0:
		client.queue_free()
		return 1
	if _check(
		input_snapshot.get("axes") == [0.25, -0.5, 0.75, -1.0],
		"v4 transport publishes canonical operator axes without model mapping",
	) != 0:
		client.queue_free()
		return 1
	if _check(input_snapshot.get("focused") == true and input_snapshot.get("connected") == true, "focused input remains connected") != 0:
		client.queue_free()
		return 1

	client.inject_server_frame({"type": "input_ack", "client_sequence": 1, "accepted": true})
	client.inject_server_frame({"type": "input_ack", "client_sequence": 99, "accepted": true})
	if _check(client.get_status_snapshot()["last_input_ack"].get("client_sequence") == 1, "unknown input acknowledgements cannot mutate diagnostics") != 0:
		client.queue_free()
		return 1
	var command_id := client.request_start()
	if _check(not command_id.is_empty(), "start command is sent while ready") != 0:
		client.queue_free()
		return 1
	client.inject_server_frame({
		"type": "command_applied",
		"id": command_id,
		"command": "start",
		"lifecycle": "running",
		"state_sequence": 2,
	})
	if _check(client.get_status_snapshot()["lifecycle"] == "running", "command acknowledgement updates lifecycle") != 0:
		client.queue_free()
		return 1
	var pause_id := client.request_pause()
	client.inject_server_frame({
		"type": "error",
		"code": "command_failed",
		"message": "pause rejected for test",
		"recoverable": true,
		"request_id": pause_id,
	})
	if _check(client.get_status_snapshot()["lifecycle"] == "running", "command error preserves confirmed lifecycle") != 0:
		client.queue_free()
		return 1

	client.inject_server_frame(_view_state(zero_pose, "epoch-a", 0, 0, 0))
	if _check(client.get_pose_buffer_size() == 1 and client.get_accepted_view_revision() == 1, "stale revision cannot replace the newest pose") != 0:
		client.queue_free()
		return 1
	var asymmetric_pose: Dictionary = fixture["poses"]["asymmetric"]
	client.inject_server_frame(_view_state(asymmetric_pose, "epoch-a", 2, 2, 0))
	if _check(client.get_pose_buffer_size() == 2, "same-generation asymmetric pose is accepted") != 0:
		client.queue_free()
		return 1
	client.inject_server_frame(_view_state(zero_pose, "epoch-b", 0, 0, 0))
	if _check(client.get_generation() > 1 and client.get_accepted_view_revision() == 0, "new epoch starts a fresh pose generation") != 0:
		client.queue_free()
		return 1
	client.inject_server_frame(_view_state(asymmetric_pose, "epoch-b", 1, 1, 1))
	if _check(client.get_pose_buffer_size() == 2 and client.get_accepted_view_revision() == 1, "new epoch accepts poses regardless of recording buffer") != 0:
		client.queue_free()
		return 1
	client.inject_server_frame(_view_state(zero_pose, "epoch-b", 2, 2, 0))
	if _check(client.get_pose_buffer_size() == 2 and client.get_accepted_view_revision() == 2, "recording buffer changes do not reset a motion generation") != 0:
		client.queue_free()
		return 1
	client.inject_server_frame(_view_state(zero_pose, "epoch-a", 3, 3, 0))
	if _check(client.get_pose_buffer_size() == 2 and client.get_accepted_view_revision() == 2 and client.simulation_epoch == "epoch-b", "retired simulation epochs cannot replace current state") != 0:
		client.queue_free()
		return 1

	var reconnect_command_id := client.request_start()
	if _check(not reconnect_command_id.is_empty() and client.get_pending_command_count() == 1, "pending command is tracked before reconnect") != 0:
		client.queue_free()
		return 1
	client.set_transport_factory_for_test(Callable(self, "_new_reconnect_transport"))
	client.set_preflight_optional_capabilities_for_test(["bucket_load_feedback_v1"])
	client.reconnect_now()
	client.process_for_test(0.01)
	if _check(_reconnect_transport != null and _reconnect_transport.sent.size() == 1 and client.get_pending_command_count() == 0 and client.get_pose_buffer_size() == 0, "reconnect creates a fresh socket and clears pending state") != 0:
		client.queue_free()
		return 1
	var optional_hello: Dictionary = JSON.parse_string(_reconnect_transport.sent[0])
	if _check(optional_hello.get("optional_capabilities", []) == ["bucket_load_feedback_v1"], "optional capability is offered only after preflight") != 0:
		client.queue_free()
		return 1
	_reconnect_transport.enqueue(_hello_ack("session-feedback", "epoch-feedback", "stopped", true))
	client.process_for_test(0.01)
	if _check(client.negotiated_optional_capabilities == ["bucket_load_feedback_v1"], "positive optional negotiation is recorded") != 0:
		client.queue_free()
		return 1
	if _check(client.queue_bucket_load_feedback({"world_generation": 0, "authority_generation": 1, "payload_mass_kg": 40.0, "center_of_mass_local": Vector3(0.0, -0.1, 0.2), "fill_ratio": 0.25, "resistance": 0.1, "quality": "balanced"}), "negotiated feedback is queued") != 0:
		client.queue_free()
		return 1
	client.process_for_test(1.0 / MotionClient.BUCKET_FEEDBACK_HZ)
	var feedback_sent := false
	for raw in _reconnect_transport.sent:
		var decoded: Variant = JSON.parse_string(raw)
		if decoded is Dictionary and decoded.get("type", "") == "bucket_load_feedback":
			feedback_sent = true
	if _check(feedback_sent, "queued feedback is sent on its own bounded cadence") != 0:
		client.queue_free()
		return 1
	client.set_focused(false)
	if _check(_reconnect_transport.sent.size() > 2, "focus loss sends a safety snapshot") != 0:
		client.queue_free()
		return 1
	var focus_loss_snapshot: Dictionary = JSON.parse_string(_reconnect_transport.sent.back())
	if _check(focus_loss_snapshot.get("axes") == [0.0, 0.0, 0.0, 0.0] and focus_loss_snapshot.get("focused") == false, "focus-loss snapshot is zeroed and unfocused") != 0:
		client.queue_free()
		return 1
	client.disconnect_from_service()
	if _check(client.get_connection_state() == MotionClient.STATE_DISCONNECTED and client.get_pose_buffer_size() == 0, "disconnect clears pose state") != 0:
		client.queue_free()
		return 1
	client.queue_free()
	await process_frame

	var draining_client := MotionClient.new()
	draining_client.auto_connect = false
	draining_client.auto_reconnect = false
	root.add_child(draining_client)
	await process_frame
	var draining_transport := FakeTransport.new()
	draining_client.set_transport_factory_for_test(func() -> FakeTransport: return draining_transport)
	draining_client.model_changed.connect(func(_model_id: String) -> void: draining_client.disconnect_from_service())
	draining_client.connect_to_service()
	draining_client.process_for_test(0.01)
	draining_transport.enqueue(_hello_ack("session-drain", "epoch-drain", "stopped"))
	draining_client.process_for_test(0.01)
	if _check(draining_client.get_connection_state() == MotionClient.STATE_DISCONNECTED, "packet draining tolerates a signal callback closing the transport") != 0:
		draining_client.queue_free()
		return 1
	draining_client.queue_free()
	await process_frame
	print("Motion client transport contract passed.")
	return 0


func _assert_equipment_bindings(client: MotionClient, model_id: String) -> int:
	var stale_key := InputEventKey.new()
	stale_key.physical_keycode = KEY_Q
	InputMap.action_add_event("operator_swing_right", stale_key)
	if _check(client.configure_equipment_model(model_id), "%s command profile is supported" % model_id) != 0:
		return 1
	for action in MotionClient.INPUT_ACTIONS:
		var definition: Dictionary = MotionClient.INPUT_ACTIONS[action]
		var expected_sign := float(definition["joy_sign"])
		var key_count := 0
		var key_matches := 0
		var joy_count := 0
		var joy_matches := 0
		for event in InputMap.action_get_events(action):
			if event is InputEventKey:
				key_count += 1
				if (event as InputEventKey).physical_keycode == int(EXPECTED_EQUIPMENT_KEYS[action]):
					key_matches += 1
			elif event is InputEventJoypadMotion:
				joy_count += 1
				var motion := event as InputEventJoypadMotion
				if motion.axis == int(definition["joy_axis"]) and is_equal_approx(motion.axis_value, expected_sign):
					joy_matches += 1
		if _check(
			key_count == 1 and key_matches == 1 and joy_count == 1 and joy_matches == 1,
			"%s installs the fixed operator keyboard and gamepad binding for %s" % [model_id, action],
		) != 0:
			return 1
	return 0


func _test_scene_presentation() -> int:
	var scene := load("res://scenes/main.tscn") as PackedScene
	if _check(scene != null, "main scene loads for presentation test") != 0:
		return 1
	var instance := scene.instantiate()
	root.add_child(instance)
	await process_frame
	var presentation := instance.get_node_or_null("MotionPresentation") as MotionPresentation
	if _check(presentation != null and presentation.get_contract_error().is_empty(), "presentation mapping contract loads") != 0:
		instance.queue_free()
		return 1
	if _check(presentation.set_authority_profile_for_test(AuthorityProfile.PYTHON_KINEMATIC), "presentation parity test selects Python compatibility profile") != 0:
		instance.queue_free()
		return 1
	var excavation := instance.get_node_or_null("TerrainRoot/ExcavationWorld") as ExcavationWorld
	if _check(excavation != null, "excavation world exposes the bucket tooth proxy") != 0:
		instance.queue_free()
		return 1
	var zero_linkage: Dictionary = presentation.get_passive_linkage_snapshot_for_test()
	if _check(bool(zero_linkage.get("reachable", false)), "zero pose passive linkage is reachable") != 0:
		instance.queue_free()
		return 1
	if _check_linkage_lengths(zero_linkage, "zero") != 0:
		instance.queue_free()
		return 1
	var zero_a_world: Vector3 = zero_linkage["a_world"]
	var zero_b_rotation: Vector3 = zero_linkage["b_rotation"]
	var zero_side_position: Vector3 = zero_linkage["side_position"]
	var zero_side_rotation: Vector3 = zero_linkage["side_rotation"]
	var arm_node := presentation.get_frame_node("arm_link")
	var zero_primary_transform: Transform3D = arm_node.get_node("PIVOT_LINKAGE_B_ARM/bucket_linkage_primary").global_transform
	var zero_secondary_transform: Transform3D = arm_node.get_node("CTRL_LINKAGE_SIDE_LINKS/bucket_linkage_secondary_a").global_transform
	var fixture := _read_fixture()
	var poses: Dictionary = fixture["poses"]
	var rest_globals := {}
	var rest_locals := {}
	for frame_name in MotionProtocol.FRAME_NAMES:
		rest_globals[frame_name] = presentation.get_frame_node(frame_name).global_transform
		rest_locals[frame_name] = presentation.get_frame_node(frame_name).transform
	var zero_pose: Dictionary = poses["zero"]
	for pose_name in ["zero", "swing_positive_90", "boom_only", "arm_only", "bucket_only", "asymmetric"]:
		var pose: Dictionary = poses[pose_name]
		if _check(presentation.apply_pose_for_test(pose), "%s local pose applies" % pose_name) != 0:
			instance.queue_free()
			return 1
		if _check(presentation.get_pivot_diagnostics_for_test().is_empty(), "%s pivot transforms have no diagnostic" % pose_name) != 0:
			instance.queue_free()
			return 1
		if _check_main_joint_contract(presentation, pose, pose_name) != 0:
			instance.queue_free()
			return 1
		if _check_frame_local_contract(presentation, pose_name) != 0:
			instance.queue_free()
			return 1
		var bucket_frame := presentation.get_frame_node("bucket_link")
		var expected_tooth: Vector3 = bucket_frame.global_transform * excavation.local_tooth_offset
		var actual_tooth: Variant = excavation._bucket_tooth_world()
		if _check(actual_tooth is Vector3, "%s pose exposes a bucket tooth proxy" % pose_name) != 0:
			instance.queue_free()
			return 1
		if _check((actual_tooth as Vector3).is_equal_approx(expected_tooth), "%s bucket tooth proxy follows the corrected bucket frame" % pose_name) != 0:
			instance.queue_free()
			return 1
		var linkage: Dictionary = presentation.get_passive_linkage_snapshot_for_test()
		if bool(linkage.get("reachable", false)):
			if _check_linkage_lengths(linkage, pose_name) != 0:
				instance.queue_free()
				return 1
		else:
			if _check(not String(linkage.get("reason", "")).is_empty(), "%s unreachable linkage has a diagnostic" % pose_name) != 0:
				instance.queue_free()
				return 1
	presentation.restore_rest_pose_for_test()
	var valid_bucket := presentation.get_frame_node("bucket_link")
	valid_bucket.rotation.x += 0.2
	presentation.recompute_passive_linkage_for_test()
	var valid_linkage: Dictionary = presentation.get_passive_linkage_snapshot_for_test()
	if _check(bool(valid_linkage.get("reachable", false)), "valid bucket motion solves passive linkage") != 0:
		instance.queue_free()
		return 1
	if _check_linkage_lengths(valid_linkage, "valid bucket motion") != 0:
		instance.queue_free()
		return 1
	if _check(not (valid_linkage["a_world"] as Vector3).is_equal_approx(zero_a_world), "valid bucket motion moves passive A") != 0:
		instance.queue_free()
		return 1
	if _check(not (valid_linkage["b_rotation"] as Vector3).is_equal_approx(zero_b_rotation), "valid bucket motion rotates passive B rocker") != 0:
		instance.queue_free()
		return 1
	if _check(not (valid_linkage["side_position"] as Vector3).is_equal_approx(zero_side_position), "valid bucket motion moves side-link controller") != 0:
		instance.queue_free()
		return 1
	if _check(
		not (arm_node.get_node("PIVOT_LINKAGE_B_ARM/bucket_linkage_primary").global_transform as Transform3D).is_equal_approx(zero_primary_transform),
		"valid bucket motion moves primary rocker mesh"
	) != 0:
		instance.queue_free()
		return 1
	if _check(
		not (arm_node.get_node("CTRL_LINKAGE_SIDE_LINKS/bucket_linkage_secondary_a").global_transform as Transform3D).is_equal_approx(zero_secondary_transform),
		"valid bucket motion moves secondary side-link mesh"
	) != 0:
		instance.queue_free()
		return 1
	var impossible_pose: Dictionary = zero_pose.duplicate(true)
	var impossible_frames: Dictionary = impossible_pose["frame_transforms"]
	impossible_frames["bucket_link"] = [
		[1.0, 0.0, 0.0, 0.0],
		[0.0, 1.0, 0.0, 100.0],
		[0.0, 0.0, 1.0, 0.0],
		[0.0, 0.0, 0.0, 1.0],
	]
	var before_unreachable: Dictionary = valid_linkage
	var before_invalid_bucket_local: Transform3D = presentation.get_frame_node("bucket_link").transform
	if _check(presentation.apply_pose_for_test(impossible_pose), "unreachable pose applies authoritative bucket frame") != 0:
		instance.queue_free()
		return 1
	var unreachable: Dictionary = presentation.get_passive_linkage_snapshot_for_test()
	var invalid_diagnostics := presentation.get_pivot_diagnostics_for_test()
	if _check(invalid_diagnostics.get("bucket_link", "") == "authority_joint_origin_drift", "invalid bucket origin is diagnosed") != 0:
		instance.queue_free()
		return 1
	if _check(
		(presentation.get_frame_node("bucket_link").transform as Transform3D).is_equal_approx(before_invalid_bucket_local),
		"invalid bucket origin retains its last valid local pivot"
	) != 0:
		instance.queue_free()
		return 1
	if _check(
		(unreachable["a_world"] as Vector3).is_equal_approx(before_unreachable["a_world"] as Vector3),
		"invalid bucket pose retains last valid passive A"
	) != 0:
		instance.queue_free()
		return 1
	if _check(
		(unreachable["side_position"] as Vector3).is_equal_approx(before_unreachable["side_position"] as Vector3),
		"invalid bucket pose retains last valid side-link controller"
	) != 0:
		instance.queue_free()
		return 1
	if _check(presentation.apply_pose_for_test(zero_pose), "zero pose reapplies after motion") != 0:
		instance.queue_free()
		return 1
	var restored_linkage: Dictionary = presentation.get_passive_linkage_snapshot_for_test()
	if _check(bool(restored_linkage.get("reachable", false)), "zero pose restores passive linkage reachability") != 0:
		instance.queue_free()
		return 1
	if _check((restored_linkage["b_rotation"] as Vector3).is_equal_approx(zero_b_rotation), "zero pose restores passive B rotation") != 0:
		instance.queue_free()
		return 1
	if _check((restored_linkage["side_position"] as Vector3).is_equal_approx(zero_side_position), "zero pose restores side-link position") != 0:
		instance.queue_free()
		return 1
	if _check((restored_linkage["side_rotation"] as Vector3).is_equal_approx(zero_side_rotation), "zero pose restores side-link rotation") != 0:
		instance.queue_free()
		return 1
	for frame_name in MotionProtocol.FRAME_NAMES:
		if _check(
			(presentation.get_frame_node(frame_name).global_transform as Transform3D).is_equal_approx(
				rest_globals[frame_name] as Transform3D
			),
			"zero pose restores %s rest transform" % frame_name
		) != 0:
			instance.queue_free()
			return 1
		if _check(
			(presentation.get_frame_node(frame_name).transform as Transform3D).is_equal_approx(
				rest_locals[frame_name] as Transform3D
			),
			"zero pose restores %s local pivot" % frame_name
		) != 0:
			instance.queue_free()
			return 1
	instance.queue_free()
	await process_frame
	print("Motion presentation five-frame parity contract passed.")
	return 0


func _check_linkage_lengths(snapshot: Dictionary, label: String) -> int:
	for constraint in ["ab", "ac", "cd"]:
		var length := float(snapshot.get("%s_length" % constraint, -1.0))
		var rest_length := float(snapshot.get("rest_%s_length" % constraint, -1.0))
		if _check(is_finite(length) and is_finite(rest_length), "%s %s linkage length is finite" % [label, constraint]) != 0:
			return 1
		if _check(absf(length - rest_length) <= 0.0001, "%s %s linkage length is conserved" % [label, constraint]) != 0:
			return 1
	return 0


func _check_main_joint_contract(presentation: MotionPresentation, pose: Dictionary, label: String) -> int:
	var angles: Array = pose.get("joint_angles", [])
	if _check(angles.size() == 4, "%s has four joint angles" % label) != 0:
		return 1
	var expected_angles := {
		"upper_structure_link": float(angles[0]),
		"boom_link": float(angles[1]),
		"arm_link": float(angles[2]),
		"bucket_link": float(angles[3]),
	}
	for frame_name in MotionProtocol.FRAME_NAMES:
		var pivot := presentation.get_frame_node(frame_name)
		var rotation := pivot.rotation
		var expected := float(expected_angles.get(frame_name, 0.0))
		var actual := rotation.y if frame_name == "upper_structure_link" else rotation.x
		if _check(absf(wrapf(actual - expected, -PI, PI)) <= 0.001, "%s %s rotation matches authority" % [label, frame_name]) != 0:
			return 1
		if frame_name == "base_link" or frame_name == "upper_structure_link":
			if _check(absf(rotation.x) <= 0.001 and absf(rotation.z) <= 0.001, "%s %s rotates only on runtime axis" % [label, frame_name]) != 0:
				return 1
		else:
			if _check(absf(rotation.y) <= 0.001 and absf(rotation.z) <= 0.001, "%s %s rotates only on runtime axis" % [label, frame_name]) != 0:
				return 1
	return 0


func _check_frame_local_contract(presentation: MotionPresentation, label: String) -> int:
	var expected_positions := {
		"base_link": Vector3(0.0, 0.45, 0.0),
		"upper_structure_link": Vector3(0.0, 0.46, 0.0),
		"boom_link": Vector3(-0.119, 0.713, -0.075),
		"arm_link": Vector3(0.066, 4.295, 3.915),
		"bucket_link": Vector3(-0.008, -3.026, -0.63),
	}
	var parent_names := {
		"upper_structure_link": "base_link",
		"boom_link": "upper_structure_link",
		"arm_link": "boom_link",
		"bucket_link": "arm_link",
	}
	for frame_name in MotionProtocol.FRAME_NAMES:
		var pivot := presentation.get_frame_node(frame_name)
		if _check(pivot.position.distance_to(expected_positions[frame_name]) <= 0.002, "%s %s parent-local pivot position is fixed" % [label, frame_name]) != 0:
			return 1
		if _check(pivot.scale.is_equal_approx(Vector3.ONE), "%s %s pivot scale is fixed" % [label, frame_name]) != 0:
			return 1
		if frame_name != "base_link":
			var parent := presentation.get_frame_node(parent_names[frame_name])
			if _check(pivot.get_parent() == parent, "%s %s parent hierarchy is fixed" % [label, frame_name]) != 0:
				return 1
	var arm := presentation.get_frame_node("arm_link")
	var bucket := presentation.get_frame_node("bucket_link")
	var b := arm.get_node("PIVOT_LINKAGE_B_ARM") as Node3D
	var d := bucket
	var c := bucket.get_node("PIVOT_LINKAGE_C_BUCKET") as Node3D
	if _check(arm.to_local(b.global_position).distance_to(Vector3(-0.008, -2.682, -0.548)) <= 0.002, "%s B remains fixed in arm-local space" % label) != 0:
		return 1
	if _check(arm.to_local(d.global_position).distance_to(Vector3(-0.008, -3.026, -0.63)) <= 0.002, "%s D remains fixed in arm-local space" % label) != 0:
		return 1
	if _check(bucket.to_local(c.global_position).distance_to(Vector3(0.0, -0.397, -0.279)) <= 0.002, "%s C remains fixed in bucket-local space" % label) != 0:
		return 1
	return 0


func _new_reconnect_transport() -> FakeTransport:
	_reconnect_transport = FakeTransport.new()
	return _reconnect_transport


func _new_initial_transport() -> FakeTransport:
	return _initial_transport


func _hello_ack(session: String, epoch: String, lifecycle: String, optional: bool = false) -> Dictionary:
	var payload := {
		"type": "hello_ack",
		"session_id": session,
		"simulation_epoch": epoch,
		"recording_epoch": "recording-a",
		"versions": VERSIONS.duplicate(true),
		"model_url": "/api/model",
		"lifecycle": lifecycle,
		"capabilities": ["commands", "input_snapshot"],
	}
	if optional:
		payload["negotiated_optional_capabilities"] = ["bucket_load_feedback_v1"]
	return payload


func _view_state(pose: Dictionary, epoch: String, revision: int, source_sequence: int, buffer_generation: int) -> Dictionary:
	return {
		"type": "view_state",
		"emitted_sequence": revision,
		"source_sequence": source_sequence,
		"simulation_epoch": epoch,
		"recording_epoch": "recording-a",
		"buffer_generation": buffer_generation,
		"end_sample_sequence": source_sequence,
		"view_revision": revision,
		"source_mode": "live",
		"playback_state": "following",
		"cursor_recording_time_ns": 0,
		"retained_start_ns": 0,
		"retained_end_ns": 0,
		"selected_sample_sequence": source_sequence,
		"simulation_time_s": 0.0,
		"lifecycle": "running",
		"versions": VERSIONS.duplicate(true),
		"joint_names": ["swing_joint", "boom_joint", "arm_joint", "bucket_joint"],
		"joint_position": pose["joint_angles"],
		"joint_velocity": [0.0, 0.0, 0.0, 0.0],
		"joint_acceleration": [0.0, 0.0, 0.0, 0.0],
		"frame_transforms": pose["frame_transforms"],
		"quality_flags": [],
		"last_input_client_sequence": null,
		"server_monotonic_ms": 0.0,
	}


func _read_fixture() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(FIXTURE_PATH))


func _check(condition: bool, message: String) -> int:
	if condition:
		return 0
	push_error("M2 check failed: %s" % message)
	return 1

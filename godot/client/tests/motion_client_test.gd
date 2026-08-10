extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"
const FIXTURE_PATH := "res://tests/fixtures/sy205_frame_parity_cases.json"
const VERSIONS := {
	"protocol_version": "babylon-sim-v3",
	"state_schema_version": "babylon-sim-state-v2",
	"model_version": "docs-urdf-v3",
	"calibration_version": "machine-calibration-v2",
	"software_version": "0.1.0",
	"terrain_spec_version": "terrain-spec-v1",
	"terrain_algorithm_version": "terrain-algorithm-v2",
	"visual_model_version": "original-skin-v1",
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
	var result := await _test_motion_client()
	if result == 0:
		result = await _test_scene_presentation()
	quit(result)


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
	for action in [
		"motion_swing_positive", "motion_swing_negative",
		"motion_boom_positive", "motion_boom_negative",
		"motion_arm_positive", "motion_arm_negative",
		"motion_bucket_positive", "motion_bucket_negative",
	]:
		if _check(InputMap.has_action(action) and InputMap.action_get_events(action).size() >= 2, "keyboard and gamepad bindings exist for %s" % action) != 0:
			client.queue_free()
			return 1
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
	client.reconnect_now()
	client.process_for_test(0.01)
	if _check(_reconnect_transport != null and _reconnect_transport.sent.size() == 1 and client.get_pending_command_count() == 0 and client.get_pose_buffer_size() == 0, "reconnect creates a fresh socket and clears pending state") != 0:
		client.queue_free()
		return 1
	client.set_focused(false)
	if _check(_reconnect_transport.sent.size() == 2, "focus loss sends a safety snapshot") != 0:
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
	print("Motion client transport contract passed.")
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
	var fixture := _read_fixture()
	var zero_pose: Dictionary = fixture["poses"]["zero"]
	var asymmetric_pose: Dictionary = fixture["poses"]["asymmetric"]
	var rest_transform := presentation.get_frame_node("arm_link").global_transform
	if _check(presentation.apply_pose_for_test(zero_pose), "zero parity pose applies") != 0:
		instance.queue_free()
		return 1
	if _check(presentation.get_frame_node("arm_link").global_transform.is_equal_approx(rest_transform), "zero pose preserves calibrated rest transform") != 0:
		instance.queue_free()
		return 1
	if _check(presentation.apply_pose_for_test(asymmetric_pose), "asymmetric parity pose applies") != 0:
		instance.queue_free()
		return 1
	if _check(not presentation.get_frame_node("arm_link").global_transform.is_equal_approx(rest_transform), "asymmetric pose moves the visual arm") != 0:
		instance.queue_free()
		return 1
	instance.queue_free()
	await process_frame
	print("Motion presentation parity contract passed.")
	return 0


func _new_reconnect_transport() -> FakeTransport:
	_reconnect_transport = FakeTransport.new()
	return _reconnect_transport


func _new_initial_transport() -> FakeTransport:
	return _initial_transport


func _hello_ack(session: String, epoch: String, lifecycle: String) -> Dictionary:
	return {
		"type": "hello_ack",
		"session_id": session,
		"simulation_epoch": epoch,
		"recording_epoch": "recording-a",
		"versions": VERSIONS.duplicate(true),
		"model_url": "/api/model",
		"lifecycle": lifecycle,
		"capabilities": ["commands", "input_snapshot"],
	}


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

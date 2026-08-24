class_name MotionClient
extends Node

signal connection_changed(state: String, diagnostics: Dictionary)
signal authority_changed(session_id: String, simulation_epoch: String, generation: int)
signal pose_accepted(pose: Dictionary)
signal pose_cleared(generation: int, reason: String)
signal input_acknowledged(ack: Dictionary)
signal command_acknowledged(ack: Dictionary)
signal diagnostics_changed(diagnostics: Dictionary)
signal model_changed(model_id: String)

const STATE_DISCONNECTED := "disconnected"
const STATE_PREFLIGHTING := "preflighting"
const STATE_CONNECTING := "connecting"
const STATE_AWAITING_HELLO_ACK := "awaiting_hello_ack"
const STATE_READY := "ready"
const STATE_STALE := "stale"
const STATE_FAULT := "fault"

const DEFAULT_ENDPOINT := "ws://127.0.0.1:8765/ws"
const INPUT_HZ := 30.0
const BUCKET_FEEDBACK_HZ := 10.0
const SHADOW_TRUTH_HZ := 30.0
const SENSOR_TELEMETRY_HZ := 30.0
const PREFLIGHT_TIMEOUT_SECONDS := 1.5
const HELLO_TIMEOUT_SECONDS := 3.0
const RECONNECT_INITIAL_SECONDS := 0.25
const RECONNECT_MAX_SECONDS := 5.0
const INPUT_ACTIONS := {
	"motion_swing_positive": {"keys": [KEY_Y], "joy_axis": JOY_AXIS_LEFT_X, "joy_sign": 1.0},
	"motion_swing_negative": {"keys": [KEY_H], "joy_axis": JOY_AXIS_LEFT_X, "joy_sign": -1.0},
	"motion_boom_positive": {"keys": [KEY_U], "joy_axis": JOY_AXIS_LEFT_Y, "joy_sign": -1.0},
	"motion_boom_negative": {"keys": [KEY_J], "joy_axis": JOY_AXIS_LEFT_Y, "joy_sign": 1.0},
	"motion_arm_positive": {"keys": [KEY_I], "joy_axis": JOY_AXIS_RIGHT_Y, "joy_sign": -1.0},
	"motion_arm_negative": {"keys": [KEY_K], "joy_axis": JOY_AXIS_RIGHT_Y, "joy_sign": 1.0},
	"motion_bucket_positive": {"keys": [KEY_O], "joy_axis": JOY_AXIS_TRIGGER_RIGHT, "joy_sign": 1.0},
	"motion_bucket_negative": {"keys": [KEY_L], "joy_axis": JOY_AXIS_TRIGGER_LEFT, "joy_sign": 1.0},
}
const COMMAND_ACTIONS := {"motion_start": KEY_F6, "motion_pause": KEY_F7, "motion_reset": KEY_F8}

@export var endpoint := DEFAULT_ENDPOINT
@export var auto_connect := false
@export var auto_reconnect := false
@export var interpolation_enabled := false
@export var desired_model_id := "sy205"
@export var lifecycle_input_enabled := true

var connection_state := STATE_DISCONNECTED
var session_id := ""
var simulation_epoch := ""
var recording_epoch := ""
var lifecycle := "stopped"
var capabilities: Array[String] = []
var negotiated_optional_capabilities: Array[String] = []
var active_model_id := ""
var accepted_versions: Dictionary = {}
var last_error: Dictionary = {}
var last_input_ack: Dictionary = {}
var confirmed_lifecycle := "stopped"

var _transport: Variant = null
var _queued_test_transport: Variant = null
var _transport_factory := Callable()
var _test_axes := Vector4.ZERO
var _test_axes_override := false
var _focused := true
var _input_elapsed := 0.0
var _hello_elapsed := 0.0
var _retry_elapsed := 0.0
var _retry_delay := RECONNECT_INITIAL_SECONDS
var _socket_generation := 0
var _generation := 0
var _next_client_sequence := 0
var _last_acked_input_sequence := -1
var _command_serial := 0
var _accepted_view_revision := -1
var _accepted_source_sequence := -1
var _authoritative_buffer_generation := -1
var _retired_simulation_epochs: Dictionary = {}
var _zero_armed := false
var _hello_sent := false
var _pending_inputs := {}
var _pending_commands := {}
var _pose_buffer: Array[Dictionary] = []
var _preflight_request: HTTPRequest
var _preflight_override: Variant = null
var _offered_optional_capabilities: Array[String] = []
var _feedback_elapsed := 0.0
var _next_feedback_sequence := 0
var _pending_bucket_feedback: Dictionary = {}
var _shadow_elapsed := 0.0
var _pending_shadow_truth: Dictionary = {}
var _sensor_elapsed := 0.0
var _pending_sensor_telemetry: Dictionary = {}


func _ready() -> void:
	_ensure_input_actions()
	_ensure_preflight_request()
	endpoint = String(ProjectSettings.get_setting("motion/endpoint", endpoint))
	auto_connect = bool(ProjectSettings.get_setting("gateway/enabled", auto_connect))
	auto_reconnect = bool(ProjectSettings.get_setting("motion/auto_reconnect", auto_reconnect))
	if auto_connect:
		connect_to_service()


func _exit_tree() -> void:
	disconnect_from_service()


func _process(delta: float) -> void:
	_tick(delta)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		set_focused(false)
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		set_focused(true)


## Test and embedding seam.  A fake implementing the small WebSocketPeer API
## (connect_to_url, poll, get_ready_state, packet and send_text methods) can be
## supplied without importing the Godot MCP addon or opening a real socket.
func set_transport_for_test(transport: Variant) -> void:
	_queued_test_transport = transport
	_transport_factory = Callable()
	auto_connect = false
	auto_reconnect = false


func set_transport_factory_for_test(factory: Callable) -> void:
	_transport_factory = factory
	auto_connect = false


func set_preflight_optional_capabilities_for_test(optional_capabilities: Array[String]) -> void:
	_preflight_override = optional_capabilities.duplicate()
	auto_connect = false


func connect_to_service() -> void:
	if connection_state in [STATE_PREFLIGHTING, STATE_CONNECTING, STATE_AWAITING_HELLO_ACK]:
		return
	_start_preflight()


func request_model_switch(model_id: String) -> bool:
	if model_id.is_empty():
		_set_error("unknown_model", "model ID must not be empty", true)
		return false
	if model_id == desired_model_id and active_model_id == model_id and (
		connection_state == STATE_READY or connection_state == STATE_STALE
	):
		return true
	desired_model_id = model_id
	if connection_state != STATE_DISCONNECTED:
		auto_reconnect = true
		_close_transport()
		_handle_disconnected(true)
	else:
		connect_to_service()
	return true


func get_desired_model_id() -> String:
	return desired_model_id


func disconnect_from_service() -> void:
	auto_reconnect = false
	if _preflight_request != null:
		_preflight_request.cancel_request()
	if _is_open():
		_send_input(Vector4.ZERO, false, false)
	_close_transport()
	_handle_disconnected(false)


func reconnect_now() -> void:
	auto_reconnect = true
	_retry_elapsed = 0.0
	_retry_delay = RECONNECT_INITIAL_SECONDS
	_start_preflight()


func queue_bucket_load_feedback(sample: Dictionary) -> bool:
	if connection_state != STATE_READY:
		return false
	if not negotiated_optional_capabilities.has("bucket_load_feedback_v1"):
		return false
	if not _valid_bucket_feedback_sample(sample):
		_set_error("invalid_bucket_feedback", "bucket feedback sample is malformed", true)
		return false
	_pending_bucket_feedback = sample.duplicate(true)
	return true


func clear_bucket_load_feedback() -> void:
	_pending_bucket_feedback.clear()
	_feedback_elapsed = 0.0


func queue_simulation_truth_shadow(snapshot: Dictionary) -> bool:
	if connection_state != STATE_READY:
		return false
	if not negotiated_optional_capabilities.has("simulation_truth_shadow_v1"):
		return false
	if snapshot.get("schema_version") != "simulation-truth-v1":
		_set_error("invalid_shadow_truth", "shadow truth sample is malformed", true)
		return false
	_pending_shadow_truth = snapshot.duplicate(true)
	return true


func clear_simulation_truth_shadow() -> void:
	_pending_shadow_truth.clear()
	_shadow_elapsed = 0.0


func queue_sensor_telemetry(batch: Dictionary) -> bool:
	if connection_state != STATE_READY:
		return false
	if not negotiated_optional_capabilities.has("sensor_telemetry_v1"):
		return false
	if String(batch.get("type", "sensor_telemetry_batch")) != "sensor_telemetry_batch":
		_set_error("invalid_sensor_telemetry", "sensor telemetry batch is malformed", true)
		return false
	_pending_sensor_telemetry = batch.duplicate(true)
	return true


func clear_sensor_telemetry() -> void:
	_pending_sensor_telemetry.clear()
	_sensor_elapsed = 0.0


func set_focused(focused: bool) -> void:
	if _focused == focused:
		return
	_focused = focused
	if not focused and _is_open():
		_send_input(Vector4.ZERO, true, false)


func set_input_axes(axes: Vector4) -> void:
	_test_axes = Vector4(
		clampf(axes.x, -1.0, 1.0),
		clampf(axes.y, -1.0, 1.0),
		clampf(axes.z, -1.0, 1.0),
		clampf(axes.w, -1.0, 1.0)
	)
	_test_axes_override = true


func clear_test_input_axes() -> void:
	_test_axes_override = false


func request_start() -> String:
	return send_command("start")


func request_pause() -> String:
	return send_command("pause")


func request_reset() -> String:
	return send_command("reset")


func send_command(command: String) -> String:
	if not ["start", "pause", "reset"].has(command):
		_set_error("invalid_command", "unsupported lifecycle command", true)
		return ""
	if connection_state != STATE_READY and connection_state != STATE_STALE:
		_set_error("not_ready", "lifecycle command requires a ready connection", true)
		return ""
	var id := "socket-%d-command-%d" % [_socket_generation, _command_serial]
	_command_serial += 1
	var payload := {"type": "command", "id": id, "command": command}
	if not _send_payload(payload):
		return ""
	_pending_commands[id] = command
	return id


func inject_server_frame(payload: Dictionary) -> void:
	## Deterministic tests may inject decoded dictionaries without a socket.
	_handle_server_payload(payload)


func process_for_test(delta: float = 1.0 / INPUT_HZ) -> void:
	_tick(delta)


func get_connection_state() -> String:
	return connection_state


func get_generation() -> int:
	return _generation


func get_pose_buffer_size() -> int:
	return _pose_buffer.size()


func get_accepted_view_revision() -> int:
	return _accepted_view_revision


func get_latest_accepted_pose() -> Dictionary:
	if _pose_buffer.is_empty():
		return {}
	return (_pose_buffer.back() as Dictionary).duplicate(true)


func get_pending_command_count() -> int:
	return _pending_commands.size()


func get_pending_input_count() -> int:
	return _pending_inputs.size()


func get_render_pose() -> Dictionary:
	if _pose_buffer.is_empty():
		return {}
	if not interpolation_enabled or _pose_buffer.size() < 2:
		return _pose_buffer.back().duplicate(true)
	var previous: Dictionary = _pose_buffer[_pose_buffer.size() - 2]
	var latest: Dictionary = _pose_buffer.back()
	if previous.get("generation") != latest.get("generation"):
		return latest.duplicate(true)
	var result := latest.duplicate(true)
	var blended := {}
	var previous_frames: Dictionary = previous.get("transforms", {})
	var latest_frames: Dictionary = latest.get("transforms", {})
	for frame_name in MotionProtocol.FRAME_NAMES:
		var before: Variant = previous_frames.get(frame_name)
		var after: Variant = latest_frames.get(frame_name)
		if before is Transform3D and after is Transform3D:
			blended[frame_name] = (before as Transform3D).interpolate_with(after as Transform3D, 0.5)
	result["transforms"] = blended
	return result


func get_authoritative_input_axes() -> Vector4:
	if not _focused:
		return Vector4.ZERO
	return _read_input_axes()


func get_status_snapshot() -> Dictionary:
	return {
		"connection_state": connection_state,
		"session_id": session_id,
		"simulation_epoch": simulation_epoch,
		"recording_epoch": recording_epoch,
		"generation": _generation,
		"lifecycle": confirmed_lifecycle,
		"capabilities": capabilities.duplicate(),
		"negotiated_optional_capabilities": negotiated_optional_capabilities.duplicate(),
		"desired_model_id": desired_model_id,
		"active_model_id": active_model_id,
		"focused": _focused,
		"last_input_ack": last_input_ack.duplicate(true),
		"last_error": last_error.duplicate(true),
		"pending_commands": _pending_commands.size(),
		"accepted_view_revision": _accepted_view_revision,
		"bucket_feedback_pending": not _pending_bucket_feedback.is_empty(),
		"shadow_truth_pending": not _pending_shadow_truth.is_empty(),
		"sensor_telemetry_pending": not _pending_sensor_telemetry.is_empty(),
	}


func _ensure_preflight_request() -> void:
	if _preflight_request != null:
		return
	_preflight_request = HTTPRequest.new()
	_preflight_request.name = "CapabilityPreflight"
	_preflight_request.timeout = PREFLIGHT_TIMEOUT_SECONDS
	add_child(_preflight_request)
	_preflight_request.request_completed.connect(_on_preflight_completed)


func _start_preflight() -> void:
	if _preflight_override is Array:
		_offered_optional_capabilities = _filter_optional_capabilities(_preflight_override as Array)
		_begin_connection()
		return
	if _transport_factory.is_valid() or _queued_test_transport != null:
		_offered_optional_capabilities.clear()
		_begin_connection()
		return
	_ensure_preflight_request()
	_preflight_request.cancel_request()
	_set_connection_state(STATE_PREFLIGHTING)
	var result := _preflight_request.request(_endpoint_origin() + "/api/capabilities")
	if result != OK:
		_offered_optional_capabilities.clear()
		_begin_connection()


func _on_preflight_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if connection_state != STATE_PREFLIGHTING:
		return
	_offered_optional_capabilities.clear()
	if response_code == 200:
		var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
		if parsed is Dictionary and (parsed as Dictionary).get("protocol_version", "") == MotionProtocol.PROTOCOL_VERSION:
			var advertised: Variant = (parsed as Dictionary).get("optional_capabilities", [])
			if advertised is Array:
				_offered_optional_capabilities = _filter_optional_capabilities(advertised as Array)
	_begin_connection()


func _filter_optional_capabilities(values: Array) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		var capability := String(value)
		if MotionProtocol.OPTIONAL_CAPABILITIES.has(capability) and not result.has(capability):
			result.append(capability)
	return result


func _begin_connection() -> void:
	_close_transport()
	_socket_generation += 1
	_clear_generation("reconnect")
	_next_client_sequence = 0
	_next_feedback_sequence = 0
	clear_bucket_load_feedback()
	negotiated_optional_capabilities.clear()
	accepted_versions.clear()
	_last_acked_input_sequence = -1
	_zero_armed = false
	_hello_sent = false
	_hello_elapsed = 0.0
	_retry_elapsed = 0.0
	_input_elapsed = 0.0
	_transport = _make_transport()
	if _transport == null:
		_set_connection_state(STATE_FAULT)
		_set_error("transport_unavailable", "unable to create a WebSocketPeer", true)
		_schedule_reconnect()
		return
	var result: Variant = _transport.connect_to_url(endpoint)
	if typeof(result) == TYPE_INT and int(result) != OK:
		_set_connection_state(STATE_FAULT)
		_set_error("connect_failed", "WebSocketPeer.connect_to_url failed (%s)" % result, true)
		_close_transport()
		_schedule_reconnect()
		return
	_set_connection_state(STATE_CONNECTING)


func _make_transport() -> Variant:
	if _transport_factory.is_valid():
		return _transport_factory.call()
	if _queued_test_transport != null:
		var supplied: Variant = _queued_test_transport
		_queued_test_transport = null
		return supplied
	if _transport != null:
		var supplied: Variant = _transport
		_transport = null
		return supplied
	var websocket := WebSocketPeer.new()
	websocket.set_handshake_headers(PackedStringArray(["Origin: %s" % _endpoint_origin()]))
	return websocket


func _endpoint_origin() -> String:
	var origin := endpoint
	if origin.begins_with("ws://"):
		origin = "http://" + origin.trim_prefix("ws://")
	elif origin.begins_with("wss://"):
		origin = "https://" + origin.trim_prefix("wss://")
	var slash := origin.find("/", origin.find("://") + 3)
	return origin if slash < 0 else origin.left(slash)


func _tick(delta: float) -> void:
	if _transport != null:
		if _transport.has_method("poll"):
			_transport.poll()
		var ready_state: Variant = _transport.get_ready_state()
		if ready_state == WebSocketPeer.STATE_OPEN:
			if connection_state == STATE_CONNECTING:
				_on_transport_open()
			_drain_packets()
		elif ready_state == WebSocketPeer.STATE_CLOSED:
			if connection_state != STATE_DISCONNECTED:
				_handle_disconnected(true)
	if connection_state == STATE_AWAITING_HELLO_ACK:
		_hello_elapsed += delta
		if _hello_elapsed > HELLO_TIMEOUT_SECONDS:
			_set_error("hello_timeout", "hello_ack was not received in time", true)
			_close_transport()
			_handle_disconnected(true)
	if connection_state == STATE_DISCONNECTED and auto_reconnect:
		_retry_elapsed += delta
		if _retry_elapsed >= _retry_delay:
			_start_preflight()
	if connection_state == STATE_READY or connection_state == STATE_STALE:
		_input_elapsed += delta
		if _input_elapsed >= 1.0 / INPUT_HZ:
			_input_elapsed = 0.0
			_send_current_input()
			if lifecycle_input_enabled:
				_handle_lifecycle_actions()
	if connection_state == STATE_READY and not _pending_bucket_feedback.is_empty():
		_feedback_elapsed += delta
		if _feedback_elapsed >= 1.0 / BUCKET_FEEDBACK_HZ:
			_feedback_elapsed = 0.0
			_send_pending_bucket_feedback()
	if connection_state == STATE_READY and not _pending_shadow_truth.is_empty():
		_shadow_elapsed += delta
		if _shadow_elapsed >= 1.0 / SHADOW_TRUTH_HZ:
			_shadow_elapsed = 0.0
			_send_pending_shadow_truth()
	if connection_state == STATE_READY and not _pending_sensor_telemetry.is_empty():
		_sensor_elapsed += delta
		if _sensor_elapsed >= 1.0 / SENSOR_TELEMETRY_HZ:
			_sensor_elapsed = 0.0
			_send_pending_sensor_telemetry()


func _on_transport_open() -> void:
	if _hello_sent:
		return
	_hello_sent = true
	_hello_elapsed = 0.0
	if not _send_payload(MotionProtocol.hello_message(desired_model_id, _offered_optional_capabilities)):
		_close_transport()
		_handle_disconnected(true)
		return
	_set_connection_state(STATE_AWAITING_HELLO_ACK)


func _drain_packets() -> void:
	var transport: Variant = _transport
	if transport == null or not transport.has_method("get_available_packet_count"):
		return
	while _transport == transport and int(transport.get_available_packet_count()) > 0:
		var packet: Variant = transport.get_packet()
		if transport.has_method("was_string_packet") and not transport.was_string_packet():
			_set_error("binary_not_supported", "binary WebSocket messages are ignored", true)
			continue
		var raw: String = packet.get_string_from_utf8() if packet is PackedByteArray else String(packet)
		var decoded: Dictionary = MotionProtocol.decode_text(raw)
		if not bool(decoded.get("ok", false)):
			_set_error(String(decoded.get("code", "invalid_message")), String(decoded.get("message", "invalid server message")), bool(decoded.get("recoverable", true)))
			continue
		_handle_server_payload(decoded.get("payload", {}))


func _handle_server_payload(payload: Dictionary) -> void:
	var decoded: Dictionary = MotionProtocol.normalize_server_message(payload)
	if not bool(decoded.get("ok", false)):
		_set_error(String(decoded.get("code", "invalid_message")), String(decoded.get("message", "invalid server message")), bool(decoded.get("recoverable", true)))
		return
	var message_type := String(decoded.get("type", ""))
	var normalized: Dictionary = decoded.get("payload", {})
	if message_type == "ignored":
		return
	if message_type != "hello_ack" and connection_state != STATE_READY and connection_state != STATE_STALE:
		_set_error("hello_required", "application frames are ignored until hello_ack", true)
		return
	match message_type:
		"hello_ack":
			_accept_hello_ack(normalized)
		"view_state":
			_accept_view_state(normalized)
		"input_ack":
			_accept_input_ack(normalized)
		"command_applied":
			_accept_command_applied(normalized)
		"error":
			_accept_error(normalized)
		"status":
			_accept_status(normalized)
		"recording_status":
			diagnostics_changed.emit(get_status_snapshot())


func _accept_hello_ack(payload: Dictionary) -> void:
	if not _hello_sent or connection_state != STATE_AWAITING_HELLO_ACK:
		_set_error("duplicate_hello_ack", "hello_ack may only be accepted once per socket", true)
		return
	var negotiated_capabilities: Array = payload.get("capabilities", [])
	var negotiated_optional: Array = payload.get("negotiated_optional_capabilities", [])
	var negotiated_model_id := String(payload.get("model_id", desired_model_id))
	if negotiated_model_id != desired_model_id:
		_set_error("model_contract_mismatch", "server selected an unexpected model", false)
		_set_connection_state(STATE_FAULT)
		return
	active_model_id = negotiated_model_id
	for required_capability in MotionProtocol.CAPABILITIES:
		if not negotiated_capabilities.has(required_capability):
			_set_error("capability_unavailable", "server does not support required motion capability", false)
			_set_connection_state(STATE_FAULT)
			return
	session_id = String(payload["session_id"])
	simulation_epoch = String(payload["simulation_epoch"])
	recording_epoch = String(payload["recording_epoch"])
	confirmed_lifecycle = String(payload["lifecycle"])
	lifecycle = confirmed_lifecycle
	capabilities = negotiated_capabilities
	negotiated_optional_capabilities.assign(negotiated_optional)
	accepted_versions = (payload.get("versions", {}) as Dictionary).duplicate(true)
	last_error = {}
	last_input_ack = {}
	_generation += 1
	_retired_simulation_epochs.clear()
	_accepted_view_revision = -1
	_accepted_source_sequence = -1
	_authoritative_buffer_generation = -1
	_pending_commands.clear()
	clear_bucket_load_feedback()
	clear_simulation_truth_shadow()
	clear_sensor_telemetry()
	_pose_buffer.clear()
	_zero_armed = false
	_retry_delay = RECONNECT_INITIAL_SECONDS
	_retry_elapsed = 0.0
	_set_connection_state(STATE_READY)
	model_changed.emit(active_model_id)
	authority_changed.emit(session_id, simulation_epoch, _generation)
	pose_cleared.emit(_generation, "hello_ack")
	_send_input(Vector4.ZERO, true, true)


func _accept_view_state(payload: Dictionary) -> void:
	if connection_state != STATE_READY and connection_state != STATE_STALE:
		return
	var incoming_epoch := String(payload["simulation_epoch"])
	var incoming_buffer_generation := int(payload["buffer_generation"])
	if incoming_epoch != simulation_epoch:
		if _retired_simulation_epochs.has(incoming_epoch):
			_set_error("stale_simulation_epoch", "an older simulation epoch was rejected", true)
			return
		if not simulation_epoch.is_empty():
			_retired_simulation_epochs[simulation_epoch] = true
		simulation_epoch = incoming_epoch
		_begin_pose_generation("epoch_change", incoming_buffer_generation)
	if int(payload["view_revision"]) <= _accepted_view_revision:
		_set_error("stale_view_revision", "an older view revision was rejected", true)
		return
	if int(payload["source_sequence"]) < _accepted_source_sequence:
		_set_error("stale_source_sequence", "an older source sequence was rejected", true)
		return
	_accepted_view_revision = int(payload["view_revision"])
	_accepted_source_sequence = int(payload["source_sequence"])
	_authoritative_buffer_generation = incoming_buffer_generation
	confirmed_lifecycle = String(payload["lifecycle"])
	lifecycle = confirmed_lifecycle
	if connection_state == STATE_STALE:
		_set_connection_state(STATE_READY)
	var transforms := {}
	for frame_name in MotionProtocol.FRAME_NAMES:
		transforms[frame_name] = MotionProtocol.rows_to_transform(payload["frame_transforms"][frame_name])
	var pose := {
		"generation": _generation,
		"session_id": session_id,
		"simulation_epoch": simulation_epoch,
		"view_revision": _accepted_view_revision,
		"source_sequence": _accepted_source_sequence,
		"lifecycle": confirmed_lifecycle,
		"transforms": transforms,
		"frame_rows": payload["frame_transforms"],
		"raw": payload,
	}
	_pose_buffer.append(pose)
	if _pose_buffer.size() > 2:
		_pose_buffer.pop_front()
	pose_accepted.emit(pose.duplicate(true))
	diagnostics_changed.emit(get_status_snapshot())


func _accept_input_ack(payload: Dictionary) -> void:
	var sequence := int(payload["client_sequence"])
	if sequence <= _last_acked_input_sequence:
		_set_error("stale_input_ack", "an older input acknowledgement was ignored", true)
		return
	if not _pending_inputs.has(sequence):
		_set_error("unknown_input_ack", "input acknowledgement does not match a pending snapshot", true)
		return
	_last_acked_input_sequence = sequence
	_pending_inputs.erase(sequence)
	last_input_ack = payload.duplicate(true)
	input_acknowledged.emit(last_input_ack.duplicate(true))
	diagnostics_changed.emit(get_status_snapshot())


func _accept_command_applied(payload: Dictionary) -> void:
	var id := String(payload["id"])
	if not _pending_commands.has(id):
		_set_error("unknown_command_ack", "command acknowledgement does not match a pending request", true)
		return
	if String(_pending_commands[id]) != String(payload["command"]):
		_set_error("command_ack_conflict", "command acknowledgement does not match its request", true, id)
		return
	_pending_commands.erase(id)
	confirmed_lifecycle = String(payload["lifecycle"])
	lifecycle = confirmed_lifecycle
	if String(payload["command"]) == "reset":
		_begin_pose_generation("reset", -1)
	command_acknowledged.emit(payload.duplicate(true))
	diagnostics_changed.emit(get_status_snapshot())


func _accept_error(payload: Dictionary) -> void:
	var request_id := String(payload.get("request_id", ""))
	if not request_id.is_empty() and _pending_commands.has(request_id):
		_pending_commands.erase(request_id)
	_set_error(String(payload["code"]), String(payload["message"]), bool(payload["recoverable"]), request_id)
	if not bool(payload["recoverable"]):
		_set_connection_state(STATE_FAULT)
	diagnostics_changed.emit(get_status_snapshot())


func _accept_status(payload: Dictionary) -> void:
	if bool(payload["stale"]):
		_clear_pose_buffer("stale_status")
		_set_connection_state(STATE_STALE)
	else:
		if connection_state == STATE_STALE:
			_set_connection_state(STATE_READY)
	diagnostics_changed.emit(get_status_snapshot())


func _send_current_input() -> void:
	var axes := _read_input_axes()
	if not _focused:
		axes = Vector4.ZERO
	if not _zero_armed and not _is_zero(axes):
		_send_input(Vector4.ZERO, true, true)
		return
	_send_input(axes, true, _focused)


func _send_input(axes: Vector4, connected: bool, focused: bool) -> bool:
	var normalized := Vector4(
		clampf(axes.x, -1.0, 1.0),
		clampf(axes.y, -1.0, 1.0),
		clampf(axes.z, -1.0, 1.0),
		clampf(axes.w, -1.0, 1.0)
	)
	var sequence := _next_client_sequence
	_next_client_sequence += 1
	var payload := {
		"type": "input_snapshot",
		"client_sequence": sequence,
		"connected": connected,
		"focused": focused,
		"axes": [normalized.x, normalized.y, normalized.z, normalized.w],
		"client_sent_ms": Time.get_ticks_msec(),
	}
	if not _send_payload(payload):
		return false
	_pending_inputs[sequence] = payload
	if _is_zero(normalized):
		_zero_armed = true
	return true


func _send_pending_bucket_feedback() -> void:
	if _pending_bucket_feedback.is_empty() or connection_state != STATE_READY:
		return
	var model_version := String(accepted_versions.get("model_version", ""))
	if session_id.is_empty() or simulation_epoch.is_empty() or active_model_id.is_empty() or model_version.is_empty():
		clear_bucket_load_feedback()
		return
	var payload := MotionProtocol.bucket_load_feedback_message(
		session_id,
		simulation_epoch,
		active_model_id,
		model_version,
		_next_feedback_sequence,
		_pending_bucket_feedback
	)
	if _send_payload(payload):
		_next_feedback_sequence += 1
		_pending_bucket_feedback.clear()


func _send_pending_shadow_truth() -> void:
	if _pending_shadow_truth.is_empty() or connection_state != STATE_READY:
		return
	if _send_payload(MotionProtocol.simulation_truth_shadow_message(_pending_shadow_truth)):
		_pending_shadow_truth.clear()


func _send_pending_sensor_telemetry() -> void:
	if _pending_sensor_telemetry.is_empty() or connection_state != STATE_READY:
		return
	if _send_payload(MotionProtocol.sensor_telemetry_batch_message(_pending_sensor_telemetry)):
		_pending_sensor_telemetry.clear()


func _valid_bucket_feedback_sample(sample: Dictionary) -> bool:
	var center: Variant = sample.get("center_of_mass_local")
	if not center is Vector3 or not _finite_vector3(center as Vector3):
		return false
	for field in ["payload_mass_kg", "fill_ratio", "resistance"]:
		var value := float(sample.get(field, -1.0))
		if is_nan(value) or is_inf(value):
			return false
	if float(sample.get("payload_mass_kg", -1.0)) < 0.0:
		return false
	var fill_ratio := float(sample.get("fill_ratio", -1.0))
	if fill_ratio < 0.0 or fill_ratio > 1.5:
		return false
	var resistance := float(sample.get("resistance", -1.0))
	if resistance < 0.0 or resistance > 1.0:
		return false
	if int(sample.get("world_generation", -1)) < 0 or int(sample.get("authority_generation", -1)) < 0:
		return false
	return ["low", "balanced", "high"].has(String(sample.get("quality", "")))


func _finite_vector3(value: Vector3) -> bool:
	return not is_nan(value.x) and not is_inf(value.x) and not is_nan(value.y) and not is_inf(value.y) and not is_nan(value.z) and not is_inf(value.z)


func _send_payload(payload: Dictionary) -> bool:
	if _transport == null or not _is_open():
		_set_error("not_connected", "cannot send while the WebSocket is closed", true)
		return false
	var encoded := JSON.stringify(payload)
	var result: Variant = _transport.send_text(encoded)
	if typeof(result) == TYPE_INT and int(result) != OK:
		_set_error("send_failed", "WebSocketPeer.send_text failed (%s)" % result, true)
		return false
	return true


func _read_input_axes() -> Vector4:
	if _test_axes_override:
		return _test_axes
	return Vector4(
		Input.get_axis("motion_swing_negative", "motion_swing_positive"),
		Input.get_axis("motion_boom_negative", "motion_boom_positive"),
		Input.get_axis("motion_arm_negative", "motion_arm_positive"),
		Input.get_axis("motion_bucket_negative", "motion_bucket_positive"),
	)


func _handle_lifecycle_actions() -> void:
	if Input.is_action_just_pressed("motion_start"):
		request_start()
	if Input.is_action_just_pressed("motion_pause"):
		request_pause()
	if Input.is_action_just_pressed("motion_reset"):
		request_reset()


func _is_open() -> bool:
	return _transport != null and _transport.get_ready_state() == WebSocketPeer.STATE_OPEN


func _close_transport() -> void:
	if _transport != null and _transport.has_method("close"):
		_transport.close()
	_transport = null


func _handle_disconnected(schedule_retry: bool) -> void:
	_close_transport()
	_hello_sent = false
	_zero_armed = false
	negotiated_optional_capabilities.clear()
	accepted_versions.clear()
	clear_bucket_load_feedback()
	clear_simulation_truth_shadow()
	clear_sensor_telemetry()
	_clear_generation("disconnect")
	_set_connection_state(STATE_DISCONNECTED)
	if schedule_retry and auto_reconnect:
		_schedule_reconnect()


func _schedule_reconnect() -> void:
	_retry_elapsed = 0.0
	_retry_delay = minf(maxf(_retry_delay, RECONNECT_INITIAL_SECONDS), RECONNECT_MAX_SECONDS)
	_retry_delay = minf(_retry_delay * 2.0, RECONNECT_MAX_SECONDS)


func _clear_generation(reason: String) -> void:
	_generation += 1
	_session_id_clear_if_disconnect(reason)
	_accepted_view_revision = -1
	_accepted_source_sequence = -1
	_authoritative_buffer_generation = -1
	_pending_commands.clear()
	_pending_inputs.clear()
	_pose_buffer.clear()
	pose_cleared.emit(_generation, reason)
	authority_changed.emit(session_id, simulation_epoch, _generation)
	diagnostics_changed.emit(get_status_snapshot())


func _begin_pose_generation(reason: String, buffer_generation: int) -> void:
	_generation += 1
	_accepted_view_revision = -1
	_accepted_source_sequence = -1
	_authoritative_buffer_generation = buffer_generation
	_pending_commands.clear()
	_pose_buffer.clear()
	pose_cleared.emit(_generation, reason)
	authority_changed.emit(session_id, simulation_epoch, _generation)


func _session_id_clear_if_disconnect(reason: String) -> void:
	if reason == "disconnect" or reason == "reconnect":
		session_id = ""
		simulation_epoch = "" if reason == "disconnect" or reason == "reconnect" else simulation_epoch
		if reason == "disconnect" or reason == "reconnect":
			recording_epoch = ""


func _clear_pose_buffer(reason: String) -> void:
	_pose_buffer.clear()
	pose_cleared.emit(_generation, reason)


func _set_connection_state(next_state: String) -> void:
	if connection_state == next_state:
		return
	connection_state = next_state
	connection_changed.emit(connection_state, get_status_snapshot())
	diagnostics_changed.emit(get_status_snapshot())


func _set_error(code: String, message: String, recoverable: bool, request_id: String = "") -> void:
	last_error = {
		"code": code,
		"message": message,
		"recoverable": recoverable,
	}
	if not request_id.is_empty():
		last_error["request_id"] = request_id
	diagnostics_changed.emit(get_status_snapshot())


func _ensure_input_actions() -> void:
	for action in INPUT_ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.08)
		var definition: Dictionary = INPUT_ACTIONS[action]
		for keycode in definition["keys"]:
			_add_key_event(action, int(keycode))
		_add_joy_axis_event(action, int(definition["joy_axis"]), float(definition["joy_sign"]))
	for action in COMMAND_ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		_add_key_event(action, int(COMMAND_ACTIONS[action]))


func _add_key_event(action: String, keycode: int) -> void:
	for existing in InputMap.action_get_events(action):
		if existing is InputEventKey and (existing as InputEventKey).physical_keycode == keycode:
			return
	var event := InputEventKey.new()
	event.physical_keycode = keycode as Key
	InputMap.action_add_event(action, event)


func _add_joy_axis_event(action: String, axis: int, axis_value: float) -> void:
	for existing in InputMap.action_get_events(action):
		if existing is InputEventJoypadMotion:
			var motion := existing as InputEventJoypadMotion
			if motion.axis == axis and is_equal_approx(motion.axis_value, axis_value):
				return
	var event := InputEventJoypadMotion.new()
	event.axis = axis as JoyAxis
	event.axis_value = axis_value
	InputMap.action_add_event(action, event)


func _is_zero(axes: Vector4) -> bool:
	return is_zero_approx(axes.x) and is_zero_approx(axes.y) and is_zero_approx(axes.z) and is_zero_approx(axes.w)

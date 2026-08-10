class_name MotionProtocol
extends RefCounted

## The product-side wire boundary for the BabylonSim v3 WebSocket contract.
##
## MotionClient is deliberately kept free of payload-shape checks.  Every
## server frame goes through this normalizer before it can mutate client or
## presentation state.

const PROTOCOL_VERSION := "babylon-sim-v3"
const STATE_SCHEMA_VERSION := "babylon-sim-state-v2"
const MODEL_VERSION := "docs-urdf-v3"
const CALIBRATION_VERSION := "machine-calibration-v2"
const SOFTWARE_VERSION := "0.1.0"
const TERRAIN_SPEC_VERSION := "terrain-spec-v1"
const TERRAIN_ALGORITHM_VERSION := "terrain-algorithm-v2"
const VISUAL_MODEL_VERSION := "original-skin-v1"

const CAPABILITIES := [
	"input_snapshot",
	"commands",
]
const FRAME_NAMES := [
	"base_link",
	"upper_structure_link",
	"boom_link",
	"arm_link",
	"bucket_link",
]
const LIFECYCLES := ["stopped", "running", "paused", "fault"]
const SERVER_MESSAGE_TYPES := [
	"hello_ack",
	"input_ack",
	"command_applied",
	"view_state",
	"status",
	"recording_status",
	"error",
]
const IGNORED_SERVER_MESSAGE_TYPES := [
	"playback_applied",
	"terrain_applied",
	"terrain_view",
	"terrain_patch",
	"pong",
]
const MAX_SAFE_JSON_INTEGER := 9_007_199_254_740_991


static func hello_message() -> Dictionary:
	return {
		"type": "hello",
		"protocol_version": PROTOCOL_VERSION,
		"capabilities": CAPABILITIES.duplicate(),
	}


static func rows_to_transform(rows: Array) -> Transform3D:
	var frame_basis := Basis(
		Vector3(float(rows[0][0]), float(rows[1][0]), float(rows[2][0])),
		Vector3(float(rows[0][1]), float(rows[1][1]), float(rows[2][1])),
		Vector3(float(rows[0][2]), float(rows[1][2]), float(rows[2][2]))
	)
	var origin := Vector3(float(rows[0][3]), float(rows[1][3]), float(rows[2][3]))
	return Transform3D(frame_basis, origin)


static func decode_text(raw: String) -> Dictionary:
	if raw.to_utf8_buffer().size() > 64 * 1024:
		return _fail("message_too_large", "message exceeds the 64 KiB WebSocket limit", false)
	var parsed: Variant = JSON.parse_string(raw)
	if parsed == null or not parsed is Dictionary:
		return _fail("invalid_json", "message must be a JSON object")
	return normalize_server_message(parsed as Dictionary)


static func normalize_server_message(payload: Dictionary) -> Dictionary:
	var message_type: Variant = payload.get("type")
	if typeof(message_type) != TYPE_STRING or String(message_type).is_empty():
		return _fail("invalid_message", "message type must be a non-empty string")
	if IGNORED_SERVER_MESSAGE_TYPES.has(message_type):
		return _ok("ignored", payload.duplicate(true))
	if not SERVER_MESSAGE_TYPES.has(message_type):
		return _fail("unknown_message_type", "unsupported server message type: %s" % message_type)

	match String(message_type):
		"hello_ack":
			return _normalize_hello_ack(payload)
		"view_state":
			return _normalize_view_state(payload)
		"input_ack":
			return _normalize_input_ack(payload)
		"command_applied":
			return _normalize_command_applied(payload)
		"status":
			return _normalize_status(payload)
		"recording_status":
			return _normalize_recording_status(payload)
		"error":
			return _normalize_error(payload)
	return _fail("unknown_message_type", "unsupported server message type")


static func _normalize_hello_ack(payload: Dictionary) -> Dictionary:
	var session_id: Variant = _string_field(payload, "session_id", true)
	var simulation_epoch: Variant = _string_field(payload, "simulation_epoch", true)
	var recording_epoch: Variant = _string_field(payload, "recording_epoch", true)
	var model_url: Variant = _string_field(payload, "model_url", false)
	var lifecycle: Variant = _string_field(payload, "lifecycle", false)
	if session_id == null or simulation_epoch == null or recording_epoch == null:
		return _fail("schema_validation_failed", "hello_ack is missing an epoch or session")
	if model_url == null or String(model_url) != "/api/model":
		return _fail("schema_validation_failed", "hello_ack model_url is invalid")
	if lifecycle == null or not LIFECYCLES.has(lifecycle):
		return _fail("schema_validation_failed", "hello_ack lifecycle is invalid")
	var versions: Variant = _normalize_versions(payload.get("versions"))
	if versions == null:
		return _fail("schema_validation_failed", "hello_ack versions are incompatible")
	var capabilities: Variant = _normalize_capabilities(payload.get("capabilities"))
	if capabilities == null:
		return _fail("schema_validation_failed", "hello_ack capabilities are malformed")
	var normalized := payload.duplicate(true)
	normalized["session_id"] = session_id
	normalized["simulation_epoch"] = simulation_epoch
	normalized["recording_epoch"] = recording_epoch
	normalized["model_url"] = model_url
	normalized["lifecycle"] = lifecycle
	normalized["versions"] = versions
	normalized["capabilities"] = capabilities
	return _ok("hello_ack", normalized)


static func _normalize_view_state(payload: Dictionary) -> Dictionary:
	var simulation_epoch: Variant = _string_field(payload, "simulation_epoch", true)
	var recording_epoch: Variant = _string_field(payload, "recording_epoch", true)
	var source_mode: Variant = _string_field(payload, "source_mode", false)
	var playback_state: Variant = _string_field(payload, "playback_state", false)
	var lifecycle: Variant = _string_field(payload, "lifecycle", false)
	if simulation_epoch == null or recording_epoch == null:
		return _fail("schema_validation_failed", "view_state is missing an epoch")
	if source_mode == null or not ["live", "imported"].has(source_mode):
		return _fail("schema_validation_failed", "view_state source_mode is invalid")
	if playback_state == null or not ["following", "paused", "playing", "complete"].has(playback_state):
		return _fail("schema_validation_failed", "view_state playback_state is invalid")
	if lifecycle == null or not LIFECYCLES.has(lifecycle):
		return _fail("schema_validation_failed", "view_state lifecycle is invalid")
	var versions: Variant = _normalize_versions(payload.get("versions"))
	if versions == null:
		return _fail("schema_validation_failed", "view_state versions are incompatible")
	var integer_fields := [
		"emitted_sequence", "source_sequence", "buffer_generation", "end_sample_sequence",
		"view_revision", "cursor_recording_time_ns", "retained_start_ns", "retained_end_ns",
		"selected_sample_sequence",
	]
	var normalized := payload.duplicate(true)
	for field in integer_fields:
		var value: Variant = _integer_field(payload, field)
		if value == null:
			return _fail("schema_validation_failed", "view_state %s is not an integer" % field)
		normalized[field] = value
	for field in ["simulation_time_s", "server_monotonic_ms"]:
		var number: Variant = _number_field(payload, field)
		if number == null or float(number) < 0.0:
			return _fail("schema_validation_failed", "view_state %s is invalid" % field)
		normalized[field] = number
	var joint_names: Variant = _joint_names(payload.get("joint_names"))
	if joint_names == null:
		return _fail("schema_validation_failed", "view_state joint_names are invalid")
	var joint_fields := ["joint_position", "joint_velocity", "joint_acceleration"]
	for field in joint_fields:
		var vector: Variant = _vector4(payload.get(field), field)
		if vector == null:
			return _fail("schema_validation_failed", "view_state %s is invalid" % field)
		normalized[field] = vector
	var frames: Variant = _frame_transforms(payload.get("frame_transforms"))
	if frames == null:
		return _fail("schema_validation_failed", "view_state frame_transforms are invalid")
	normalized["frame_transforms"] = frames
	var quality_flags: Variant = _string_array(payload.get("quality_flags"), "quality_flags")
	if quality_flags == null:
		return _fail("schema_validation_failed", "view_state quality_flags are invalid")
	normalized["quality_flags"] = quality_flags
	if not payload.has("last_input_client_sequence"):
		return _fail("schema_validation_failed", "view_state is missing last_input_client_sequence")
	var last_sequence: Variant = payload.get("last_input_client_sequence")
	if last_sequence != null:
		last_sequence = _integer_value(last_sequence)
		if last_sequence == null:
			return _fail("schema_validation_failed", "view_state last input sequence is invalid")
	normalized["last_input_client_sequence"] = last_sequence
	normalized["joint_names"] = joint_names
	normalized["versions"] = versions
	normalized["simulation_epoch"] = simulation_epoch
	normalized["recording_epoch"] = recording_epoch
	normalized["source_mode"] = source_mode
	normalized["playback_state"] = playback_state
	normalized["lifecycle"] = lifecycle
	return _ok("view_state", normalized)


static func _normalize_input_ack(payload: Dictionary) -> Dictionary:
	var sequence: Variant = _integer_field(payload, "client_sequence")
	var accepted: Variant = payload.get("accepted")
	if sequence == null or typeof(accepted) != TYPE_BOOL:
		return _fail("schema_validation_failed", "input_ack is malformed")
	if payload.has("error_code") and payload.get("error_code") != null and not payload.get("error_code") is String:
		return _fail("schema_validation_failed", "input_ack error_code is malformed")
	var normalized := payload.duplicate(true)
	normalized["client_sequence"] = sequence
	normalized["accepted"] = accepted
	return _ok("input_ack", normalized)


static func _normalize_command_applied(payload: Dictionary) -> Dictionary:
	var id: Variant = _string_field(payload, "id", true)
	var command: Variant = _string_field(payload, "command", false)
	var lifecycle: Variant = _string_field(payload, "lifecycle", false)
	var state_sequence: Variant = _integer_field(payload, "state_sequence")
	if id == null or command == null or not ["start", "pause", "reset"].has(command):
		return _fail("schema_validation_failed", "command_applied command is malformed")
	if lifecycle == null or not LIFECYCLES.has(lifecycle) or state_sequence == null:
		return _fail("schema_validation_failed", "command_applied state is malformed")
	var normalized := payload.duplicate(true)
	normalized["id"] = id
	normalized["command"] = command
	normalized["lifecycle"] = lifecycle
	normalized["state_sequence"] = state_sequence
	return _ok("command_applied", normalized)


static func _normalize_error(payload: Dictionary) -> Dictionary:
	var code: Variant = _string_field(payload, "code", true)
	var message: Variant = _string_field(payload, "message", true)
	var recoverable: Variant = payload.get("recoverable")
	if code == null or message == null or typeof(recoverable) != TYPE_BOOL:
		return _fail("schema_validation_failed", "error frame is malformed")
	if payload.has("request_id") and payload.get("request_id") != null and not payload.get("request_id") is String:
		return _fail("schema_validation_failed", "error request_id is malformed")
	var normalized := payload.duplicate(true)
	normalized["code"] = code
	normalized["message"] = message
	normalized["recoverable"] = recoverable
	return _ok("error", normalized)


static func _normalize_status(payload: Dictionary) -> Dictionary:
	var normalized := payload.duplicate(true)
	for field in ["simulation_hz", "state_hz", "render_target_hz"]:
		var value: Variant = _number_field(payload, field)
		if value == null or float(value) < 0.0:
			return _fail("schema_validation_failed", "status %s is invalid" % field)
		normalized[field] = value
	if float(normalized["render_target_hz"]) != 30.0:
		return _fail("schema_validation_failed", "status render_target_hz is invalid")
	for field in ["overruns", "dropped_snapshots"]:
		var integer: Variant = _integer_field(payload, field)
		if integer == null:
			return _fail("schema_validation_failed", "status %s is invalid" % field)
		normalized[field] = integer
	var stale: Variant = payload.get("stale")
	if typeof(stale) != TYPE_BOOL:
		return _fail("schema_validation_failed", "status stale is invalid")
	normalized["stale"] = stale
	var source: Variant = payload.get("controller_source")
	if source != null and not source is String:
		return _fail("schema_validation_failed", "status controller_source is invalid")
	return _ok("status", normalized)


static func _normalize_recording_status(payload: Dictionary) -> Dictionary:
	var normalized := payload.duplicate(true)
	for field in ["buffer_generation", "end_sample_sequence", "sample_count", "evicted_samples", "cursor_recording_time_ns", "view_revision"]:
		var value: Variant = _integer_field(payload, field)
		if value == null:
			return _fail("schema_validation_failed", "recording_status %s is invalid" % field)
		normalized[field] = value
	for field in ["recording_epoch"]:
		var value: Variant = _string_field(payload, field, true)
		if value == null:
			return _fail("schema_validation_failed", "recording_status %s is invalid" % field)
		normalized[field] = value
	for field in ["retained_start_ns", "retained_end_ns"]:
		if not payload.has(field):
			return _fail("schema_validation_failed", "recording_status %s is missing" % field)
		var retained: Variant = payload.get(field)
		if retained != null:
			retained = _integer_value(retained)
			if retained == null:
				return _fail("schema_validation_failed", "recording_status %s is invalid" % field)
		normalized[field] = retained
	var source_mode: Variant = _string_field(payload, "source_mode", false)
	var playback_state: Variant = _string_field(payload, "playback_state", false)
	if source_mode == null or not ["live", "imported"].has(source_mode):
		return _fail("schema_validation_failed", "recording_status source_mode is invalid")
	if playback_state == null or not ["following", "paused", "playing", "complete"].has(playback_state):
		return _fail("schema_validation_failed", "recording_status playback_state is invalid")
	normalized["source_mode"] = source_mode
	normalized["playback_state"] = playback_state
	return _ok("recording_status", normalized)


static func _normalize_versions(value: Variant) -> Variant:
	if value == null or not value is Dictionary:
		return null
	var expected := {
		"protocol_version": PROTOCOL_VERSION,
		"state_schema_version": STATE_SCHEMA_VERSION,
		"model_version": MODEL_VERSION,
		"calibration_version": CALIBRATION_VERSION,
		"software_version": SOFTWARE_VERSION,
		"terrain_spec_version": TERRAIN_SPEC_VERSION,
		"terrain_algorithm_version": TERRAIN_ALGORITHM_VERSION,
		"visual_model_version": VISUAL_MODEL_VERSION,
	}
	var versions: Dictionary = value
	for key in expected:
		if versions.get(key) != expected[key]:
			return null
	return versions.duplicate(true)


static func _normalize_capabilities(value: Variant) -> Variant:
	if value == null or not value is Array:
		return null
	var result: Array[String] = []
	for capability in value as Array:
		if not capability is String or not CAPABILITIES.has(capability) or result.has(capability):
			return null
		result.append(capability)
	return result


static func _joint_names(value: Variant) -> Variant:
	if value == null or not value is Array or (value as Array).size() != 4:
		return null
	var expected := ["swing_joint", "boom_joint", "arm_joint", "bucket_joint"]
	for index in range(4):
		if (value as Array)[index] != expected[index]:
			return null
	return expected


static func _vector4(value: Variant, _field: String) -> Variant:
	if value == null or not value is Array or (value as Array).size() != 4:
		return null
	var result: Array[float] = []
	for item in value as Array:
		var number: Variant = _number_value(item)
		if number == null:
			return null
		result.append(float(number))
	return result


static func _frame_transforms(value: Variant) -> Variant:
	if value == null or not value is Dictionary:
		return null
	var result := {}
	for frame_name in FRAME_NAMES:
		if not (value as Dictionary).has(frame_name):
			return null
		var rows: Variant = (value as Dictionary).get(frame_name)
		if rows == null or not rows is Array or (rows as Array).size() != 4:
			return null
		var normalized_rows: Array = []
		for row in rows as Array:
			if not row is Array or (row as Array).size() != 4:
				return null
			var normalized_row: Array[float] = []
			for item in row as Array:
				var number: Variant = _number_value(item)
				if number == null:
					return null
				normalized_row.append(float(number))
			normalized_rows.append(normalized_row)
		result[frame_name] = normalized_rows
	return result


static func _string_array(value: Variant, _field: String) -> Variant:
	if value == null or not value is Array:
		return null
	var result: Array[String] = []
	for item in value as Array:
		if not item is String:
			return null
		result.append(item)
	return result


static func _string_field(payload: Dictionary, key: String, non_empty: bool) -> Variant:
	if not payload.has(key) or not payload.get(key) is String:
		return null
	var value: String = payload.get(key)
	if non_empty and value.is_empty():
		return null
	return value


static func _number_field(payload: Dictionary, key: String) -> Variant:
	if not payload.has(key):
		return null
	return _number_value(payload.get(key))


static func _integer_field(payload: Dictionary, key: String) -> Variant:
	if not payload.has(key):
		return null
	return _integer_value(payload.get(key))


static func _number_value(value: Variant) -> Variant:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return null
	var number := float(value)
	if is_nan(number) or is_inf(number):
		return null
	return number


static func _integer_value(value: Variant) -> Variant:
	var integer := 0
	if typeof(value) == TYPE_INT:
		integer = int(value)
		if abs(float(integer)) > MAX_SAFE_JSON_INTEGER:
			return null
	elif typeof(value) == TYPE_FLOAT:
		var number := float(value)
		if is_nan(number) or is_inf(number) or number != floor(number) or number > MAX_SAFE_JSON_INTEGER:
			return null
		integer = int(number)
	else:
		return null
	if integer < 0:
		return null
	return integer


static func _ok(message_type: String, payload: Dictionary) -> Dictionary:
	return {"ok": true, "type": message_type, "payload": payload}


static func _fail(code: String, message: String, recoverable: bool = true) -> Dictionary:
	return {"ok": false, "code": code, "message": message, "recoverable": recoverable}

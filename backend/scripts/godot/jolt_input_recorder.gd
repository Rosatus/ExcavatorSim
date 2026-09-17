extends SceneTree
## Records real operator input (tracks + equipment axes) per physics tick into a
## JSON trace that jolt_product_soak.gd can replay via --replay. Runs windowed:
## the user drives the real product session while this script samples the same
## resolved command sources the chassis consumes.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const READY_TIMEOUT_SECONDS := 20.0
const RECORDING_SCHEMA := "excavator-sim-input-recording-v1"
const QUALITY_PROFILES := ["low", "balanced", "high"]
const BUCKET_GROUND_MODES := ["normal", "bucket_passthrough"]
const FLUSH_INTERVAL_TICKS := 300

var _model_id := "sy135"
var _quality_profile := "balanced"
var _bucket_ground_mode := "normal"
var _endpoint := "ws://127.0.0.1:8765/ws"
var _record_path := ""
var _duration_seconds := 90.0
var _lead_in_seconds := 3.0


func _init() -> void:
	if not _parse_arguments():
		quit(2)
		return
	call_deferred("_run")


func _run() -> void:
	var packed := load(MAIN_SCENE_PATH) as PackedScene
	if packed == null:
		_finish(false, "main scene is unavailable")
		return
	var scene := packed.instantiate() as Node3D
	var client := scene.get_node("MotionClient") as MotionClient
	var chassis := scene.get_node("ChassisMotionRoot") as TrackedChassisController
	var session := scene.get_node("ProductSession") as ProductSession
	var quality := scene.get_node_or_null("VisualQualityController") as VisualQualityController
	if quality == null:
		_finish(false, "visual quality controller is unavailable")
		return
	client.endpoint = _endpoint
	client.desired_model_id = _model_id
	quality.profile = _quality_profile
	root.add_child(scene)
	# MotionClient applies product ProjectSettings in _ready(), so the isolated
	# endpoint and opt-in connection must be applied afterward.
	client.endpoint = _endpoint
	client.desired_model_id = _model_id
	client.connect_to_service()
	DisplayServer.window_set_title(
		"ExcavatorSim INPUT RECORDING - %s/%s" % [_model_id, _bucket_ground_mode]
	)
	DisplayServer.window_set_size(Vector2i(1280, 720))
	await process_frame
	if not session.request_model_switch(_model_id):
		_finish(false, "product model switch was rejected: %s" % session.get_status_snapshot())
		return
	if not await _wait_until_ready(scene, session, client):
		_finish(false, "product scene did not become ready")
		return
	if not session.request_bucket_ground_mode(_bucket_ground_mode):
		_finish(false, "bucket-ground mode request was rejected")
		return
	await physics_frame
	await physics_frame
	var observed_mode := String(session.get_status_snapshot().get("bucket_ground_mode", ""))
	if observed_mode != _bucket_ground_mode:
		_finish(
			false,
			"bucket-ground mode mismatch: requested=%s observed=%s" % [_bucket_ground_mode, observed_mode]
		)
		return
	session.request_start()
	if not await _wait_for_lifecycle(session, ProductSession.LIFECYCLE_RUNNING):
		_finish(false, "product session did not reach running")
		return
	var lead_in_left := _lead_in_seconds
	while lead_in_left > 0.0:
		DisplayServer.window_set_title(
			"ExcavatorSim REC lead-in %.0fs - get ready (F9 = stop early)" % lead_in_left
		)
		await create_timer(minf(1.0, lead_in_left)).timeout
		lead_in_left -= 1.0
	var base_tick := Engine.get_physics_frames()
	var started_usec := Time.get_ticks_usec()
	var tracks: Array = []
	var equipment: Array = []
	var chassis_yaw: Array = []
	var chassis_pos: Array = []
	var active_ticks := 0
	var last_title_tick := -1
	var last_flush_tick := 0
	while float(Time.get_ticks_usec() - started_usec) / 1_000_000.0 < _duration_seconds:
		await physics_frame
		var tick := Engine.get_physics_frames() - base_tick
		if tick < 0:
			continue
		var gate := session.lifecycle == ProductSession.LIFECYCLE_RUNNING and session.focused
		var left := 0.0
		var right := 0.0
		if gate:
			left = (
				Input.get_action_strength("track_left_forward")
				- Input.get_action_strength("track_left_reverse")
			)
			right = (
				Input.get_action_strength("track_right_forward")
				- Input.get_action_strength("track_right_reverse")
			)
		var axes := session.get_equipment_input_axes()
		var forward := -chassis.global_transform.basis.z
		var yaw_deg := rad_to_deg(atan2(-forward.x, -forward.z))
		var pos := chassis.global_position
		# Fill any physics ticks that elapsed within a single process frame; input
		# state is constant across them so the current sample applies to all.
		while tracks.size() <= tick:
			tracks.append([left, right])
			equipment.append([axes.x, axes.y, axes.z, axes.w])
			chassis_yaw.append(yaw_deg)
			chassis_pos.append([pos.x, pos.y, pos.z])
		if left != 0.0 or right != 0.0 or axes != Vector4.ZERO:
			active_ticks += 1
		if tick - last_title_tick >= 12:
			last_title_tick = tick
			DisplayServer.window_set_title(
				"ExcavatorSim REC %.0fs / %.0fs (F9 = stop early)"
				% [float(Time.get_ticks_usec() - started_usec) / 1_000_000.0, _duration_seconds]
			)
		if tick - last_flush_tick >= FLUSH_INTERVAL_TICKS:
			last_flush_tick = tick
			_write_recording(tracks, equipment, chassis_yaw, chassis_pos)
		if Input.is_physical_key_pressed(KEY_F9):
			break
	var ok := _write_recording(tracks, equipment, chassis_yaw, chassis_pos)
	print(
		"INPUT_RECORDER ticks=%d active=%d path=%s"
		% [tracks.size(), active_ticks, _record_path]
	)
	_finish(ok and not tracks.is_empty(), "" if ok else "recording write failed")


func _write_recording(tracks: Array, equipment: Array, chassis_yaw: Array, chassis_pos: Array) -> bool:
	var payload := {
		"schema": RECORDING_SCHEMA,
		"model_id": _model_id,
		"quality_profile": _quality_profile,
		"bucket_ground_mode": _bucket_ground_mode,
		"physics_ticks_per_second": Engine.physics_ticks_per_second,
		"recorded_at_utc": Time.get_datetime_string_from_system(true),
		"tick_count": tracks.size(),
		"tracks": tracks,
		"equipment": equipment,
		"chassis_yaw_deg": chassis_yaw,
		"chassis_pos_m": chassis_pos,
	}
	var file := FileAccess.open(_record_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(payload) + "\n")
	file.close()
	return true


func _wait_until_ready(scene: Node3D, session: ProductSession, client: MotionClient) -> bool:
	var deadline := Time.get_ticks_msec() + int(READY_TIMEOUT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var chassis := scene.get_node("ChassisMotionRoot") as TrackedChassisController
		var status := chassis.get_status_snapshot()
		if (
			client.connection_state == MotionClient.STATE_READY
			and client.active_model_id == _model_id
			and session.active_model_id == _model_id
			and bool(status.get("configured", false))
			and String(status.get("model_id", "")) == _model_id
		):
			return true
	return false


func _wait_for_lifecycle(session: ProductSession, expected: String) -> bool:
	var deadline := Time.get_ticks_msec() + int(READY_TIMEOUT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if session.lifecycle == expected:
			return true
	return false


func _finish(ok: bool, error := "") -> void:
	if not error.is_empty():
		push_error(error)
	quit(0 if ok else 1)


func _parse_arguments() -> bool:
	var arguments := OS.get_cmdline_user_args()
	var index := 0
	while index < arguments.size():
		var argument := String(arguments[index])
		if index + 1 >= arguments.size():
			push_error("missing value for %s" % argument)
			return false
		var value := String(arguments[index + 1])
		match argument:
			"--model": _model_id = value
			"--quality-profile": _quality_profile = value
			"--bucket-ground-mode": _bucket_ground_mode = value
			"--endpoint": _endpoint = value
			"--record": _record_path = value
			"--duration-seconds": _duration_seconds = value.to_float()
			"--lead-in-seconds": _lead_in_seconds = value.to_float()
			_:
				push_error("unknown recorder argument: %s" % argument)
				return false
		index += 2
	return (
		["sy205", "sy135"].has(_model_id)
		and QUALITY_PROFILES.has(_quality_profile)
		and BUCKET_GROUND_MODES.has(_bucket_ground_mode)
		and _duration_seconds > 0.0
		and _lead_in_seconds >= 0.0
		and not _record_path.is_empty()
	)

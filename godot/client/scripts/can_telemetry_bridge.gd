extends Node
## CAN telemetry bridge (autoload): streams machine physical quantities over
## UDP to the external Python gateway, supervises its process (auto-spawn,
## heartbeat liveness) and exposes recording control for the operator panel.
## When the gateway is offline the stream is fire-and-forget and gameplay is
## unaffected.

const DEFAULT_PORT := 29764
const DEFAULT_ACK_PORT := 29765
const EMIT_HZ := 50.0
const TELEMETRY_MAGIC := 0x314E5443  # "CTN1"
const CONTROL_MAGIC := 0x43544E43  # "CTNC"
const HEARTBEAT_MAGIC := 0x43544E4B  # "CTNK"
const SESSION_DONE_MAGIC := 0x43544E44  # "CTND"
const PROTOCOL_VERSION := 1
const CMD_RECORD_START := 1
const CMD_RECORD_STOP := 2
const CMD_SHUTDOWN := 3
const CMD_ICT_START := 4
const CMD_ICT_STOP := 5
const HEARTBEAT_TIMEOUT_MS := 2500

enum GatewayStatus { OFFLINE, ONLINE, RECORDING }

@export var remote_host := "127.0.0.1"
@export var remote_port := DEFAULT_PORT
@export var ack_port := DEFAULT_ACK_PORT
@export var auto_spawn := true
@export var python_command := "python"

var _udp: PacketPeerUDP = null
var _ack: PacketPeerUDP = null
var _ack_bound := false
var _last_bind_try_ms := -10000
var _presentation: Node = null
var _chassis: Node = null
var _resolved := false
var _accum := 0.0
var _send_buffer := PackedByteArray()
var _gateway_pid := -1
var _last_heartbeat_ms := -1
var _heartbeat_recording := false
var _gateway_is_linux := false
var _ict_active := false
var _control_seq := 0
var _last_segment_path := ""


func _ready() -> void:
	process_physics_priority = 110
	if auto_spawn and DisplayServer.get_name() != "headless":
		spawn_gateway()
	elif auto_spawn:
		# Headless (tests/CI): spawning would leak a child process that
		# inherits our stdout pipe and blocks engine exit; tests opt in by
		# calling spawn_gateway() explicitly.
		pass


func _ensure_ack_bound() -> bool:
	if _ack_bound:
		return true
	_ack = PacketPeerUDP.new()
	if _ack.bind(ack_port) != OK:
		return false
	_ack_bound = true
	return true


func _physics_process(delta: float) -> void:
	if not _ack_bound and Time.get_ticks_msec() - _last_bind_try_ms > 2000:
		_last_bind_try_ms = Time.get_ticks_msec()
		_ensure_ack_bound()
	_poll_heartbeats()
	_accum += delta
	if _accum < 1.0 / EMIT_HZ:
		return
	_accum = fmod(_accum, 1.0 / EMIT_HZ)
	_resolve_once()
	if _presentation == null or not _presentation.has_method("get_frame_node"):
		return
	var packet := _build_packet(Time.get_ticks_msec())
	if packet.is_empty():
		return
	if _udp == null:
		_udp = PacketPeerUDP.new()
		_udp.set_dest_address(remote_host, remote_port)
	_udp.put_packet(packet)


func _exit_tree() -> void:
	# Send SHUTDOWN via a throwaway peer: reusing _udp during teardown has
	# crashed the engine (access violation after peer teardown began).
	if _gateway_pid > 0:
		var peer := PacketPeerUDP.new()
		peer.set_dest_address(remote_host, remote_port)
		peer.put_packet(_build_control_packet(CMD_SHUTDOWN, 0))
		peer.close()
	if _ack != null and _ack_bound:
		_ack.close()


## --- public API for the operator panel ---

func get_status() -> int:
	var stale := _last_heartbeat_ms < 0 \
		or Time.get_ticks_msec() - _last_heartbeat_ms > HEARTBEAT_TIMEOUT_MS
	if _gateway_pid <= 0 or stale:
		return GatewayStatus.OFFLINE
	if _heartbeat_recording:
		return GatewayStatus.RECORDING
	return GatewayStatus.ONLINE


func is_gateway_online() -> bool:
	return get_status() != GatewayStatus.OFFLINE


func set_recording(enabled: bool) -> void:
	if enabled:
		if _gateway_pid <= 0:
			spawn_gateway()
		_send_control(CMD_RECORD_START)
	else:
		_send_control(CMD_RECORD_STOP)


func is_linux_gateway() -> bool:
	return _gateway_is_linux


func is_ict_active() -> bool:
	return _ict_active


func set_ict_connected(enabled: bool) -> void:
	if enabled:
		if _gateway_pid <= 0:
			spawn_gateway()
		_ict_active = true
		_send_control(CMD_ICT_START)
	else:
		_ict_active = false
		_send_control(CMD_ICT_STOP)


func respawn_gateway() -> bool:
	return spawn_gateway()


## --- process supervision ---

## Returns [executable, args...] for launching the gateway, or empty when the
## gateway cannot be located. Shipped builds prefer a bundled PyInstaller
## gateway.exe (launched directly); dev checkouts use python + gateway.py.
func _resolve_gateway_command() -> PackedStringArray:
	var exe_dir := OS.get_executable_path().get_base_dir()
	var native_names := ["gateway.exe"] if OS.get_name() == "Windows" else ["gateway"]
	for candidate_name in native_names:
		for candidate in [
			exe_dir.path_join("can_gateway/" + candidate_name),
			exe_dir.path_join(candidate_name),
		]:
			if FileAccess.file_exists(candidate):
				return PackedStringArray([
					candidate,
					"--host", remote_host,
					"--port", str(remote_port),
					"--ack-port", str(ack_port),
					"--out", _resolve_output_dir(),
				])
	var script := _resolve_gateway_script()
	if script.is_empty():
		return PackedStringArray()
	return PackedStringArray([
		python_command, script,
		"--host", remote_host,
		"--port", str(remote_port),
		"--ack-port", str(ack_port),
		"--out", _resolve_output_dir(),
	])


func spawn_gateway() -> bool:
	var argv := _resolve_gateway_command()
	if argv.is_empty():
		push_warning("CanTelemetryBridge: no gateway executable/script found")
		_gateway_pid = -1
		return false
	_gateway_pid = OS.create_process(argv[0], argv.slice(1))
	if _gateway_pid <= 0:
		push_warning("CanTelemetryBridge: failed to spawn '%s'" % argv[0])
	return _gateway_pid > 0


func _resolve_gateway_script() -> String:
	# 1) shipped layout: <exe_dir>/can_gateway/gateway.py (PyInstaller onedir
	#    or bundled source next to the executable)
	var exe_dir := OS.get_executable_path().get_base_dir()
	for candidate in [
		exe_dir.path_join("can_gateway/gateway.py"),
		exe_dir.path_join("gateway.py"),
	]:
		if FileAccess.file_exists(candidate):
			return candidate
	# 2) development checkout: <repo>/tools/can_gateway/gateway.py
	var dev := ProjectSettings.globalize_path("res://").path_join("../../tools/can_gateway/gateway.py").simplify_path()
	if FileAccess.file_exists(dev):
		return dev
	return ""


func _resolve_output_dir() -> String:
	# Shipped builds write next to the exe; dev writes to <repo>/output.
	var base := ""
	if OS.has_feature("editor"):
		base = ProjectSettings.globalize_path("res://").path_join("../../output/can_gateway")
	else:
		base = OS.get_executable_path().get_base_dir().path_join("output/can_gateway")
	base = base.simplify_path()
	DirAccess.make_dir_recursive_absolute(base)
	return base


func _poll_heartbeats() -> void:
	while _ack.get_available_packet_count() > 0:
		var packet := _ack.get_packet()
		if packet.size() == 16 and _read_u32(packet, 0) == HEARTBEAT_MAGIC \
				and packet[4] == PROTOCOL_VERSION:
			_heartbeat_recording = (packet[5] & 0x01) != 0
			_gateway_is_linux = (packet[5] & 0x02) != 0
			_last_heartbeat_ms = Time.get_ticks_msec()
		elif _read_u32(packet, 0) == SESSION_DONE_MAGIC and packet.size() > 8:
			var path_bytes := packet.slice(8)
			_last_segment_path = path_bytes.get_string_from_utf8()


func get_last_segment_path() -> String:
	return _last_segment_path


func set_last_segment_path(path: String) -> void:
	_last_segment_path = path


func _send_control(cmd: int) -> void:
	if _udp == null:
		_udp = PacketPeerUDP.new()
	_udp.set_dest_address(remote_host, remote_port)
	_control_seq += 1
	_udp.put_packet(_build_control_packet(cmd, _control_seq))


static func _build_control_packet(cmd: int, seq: int) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = false
	buffer.put_32(CONTROL_MAGIC)
	buffer.put_8(PROTOCOL_VERSION)
	buffer.put_8(cmd)
	buffer.put_16(0)
	buffer.put_32(seq)
	return buffer.data_array


static func _read_u32(data: PackedByteArray, offset: int) -> int:
	return data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24)


## --- telemetry streaming ---

func _resolve_once() -> void:
	if _resolved:
		return
	var scene := get_tree().current_scene if get_tree() != null else null
	if scene == null:
		return
	_presentation = scene.get_node_or_null("MotionPresentation")
	_chassis = scene.get_node_or_null("ChassisMotionRoot")
	_resolved = _presentation != null and _chassis != null


func _build_packet(tick_ms: int) -> PackedByteArray:
	_send_buffer.clear()
	var header := StreamPeerBuffer.new()
	header.big_endian = false
	header.put_32(TELEMETRY_MAGIC)
	header.put_8(PROTOCOL_VERSION)
	header.put_8(0)
	header.put_16(0)
	header.put_64(tick_ms)
	_send_buffer.append_array(header.data_array)

	for frame_name in FRAME_NAMES:
		var node := _presentation.get_frame_node(frame_name) as Node3D
		if node == null:
			return PackedByteArray()
		var transform := node.global_transform
		var quat := transform.basis.get_rotation_quaternion()
		var origin := transform.origin
		_send_buffer.append_array(_pack_floats([
			quat.x, quat.y, quat.z, quat.w,
			origin.x, origin.y, origin.z,
		]))

	var swing_rad := _swing_angle_rad()
	var speeds := _track_speeds()
	_send_buffer.append_array(_pack_floats([
		swing_rad, speeds.x, speeds.y, 0.0, 0.0,
	]))
	return _send_buffer


func _swing_angle_rad() -> float:
	var chassis_node := _presentation.get_frame_node("base_link") as Node3D
	var upper_node := _presentation.get_frame_node("upper_structure_link") as Node3D
	if chassis_node == null or upper_node == null:
		return 0.0
	var rel := chassis_node.global_transform.basis.get_rotation_quaternion().inverse() \
		* upper_node.global_transform.basis.get_rotation_quaternion()
	return rel.get_euler().y


func _track_speeds() -> Vector2:
	# jolt_authoritative: true track speeds live in the runtime's post-step
	# snapshot; locomotion_state stays zero on that path. The runtime node is
	# added to the chassis controller's PARENT (see
	# TrackedChassisController._connect_runtime), so look there first.
	if _chassis != null:
		var owner_node := _chassis.get_parent() if _chassis.get_parent() != null else _chassis
		var runtime := owner_node.get_node_or_null("JoltChassisTrackRuntime")
		if runtime != null and "get_status_snapshot" in runtime:
			var status: Dictionary = runtime.call("get_status_snapshot")
			return Vector2(float(status.get("left_speed_mps", 0.0)), float(status.get("right_speed_mps", 0.0)))
	if _chassis != null and "locomotion_state" in _chassis and _chassis.locomotion_state != null:
		var state: TrackedLocomotionState = _chassis.locomotion_state
		return Vector2(state.left_speed_mps, state.right_speed_mps)
	return Vector2.ZERO


static func _pack_floats(values: Array) -> PackedByteArray:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = false
	for value in values:
		buffer.put_float(float(value))
	return buffer.data_array


const FRAME_NAMES: Array[String] = [
	"base_link", "upper_structure_link", "boom_link", "arm_link", "bucket_link",
]

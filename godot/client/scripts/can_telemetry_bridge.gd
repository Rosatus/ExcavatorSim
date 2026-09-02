extends Node
## CAN telemetry bridge (autoload): streams machine physical quantities over
## UDP to the external Python gateway, supervises its process (auto-spawn,
## heartbeat liveness) and exposes recording control for the operator panel.
## When the gateway is offline the stream is fire-and-forget and gameplay is
## unaffected.

signal ict_link_status_changed(handshake_connected: bool, platform_linux: bool)

const DEFAULT_PORT := 29764
const DEFAULT_ACK_PORT := 29765
const DEFAULT_WEB_PORT := 29777
const EMIT_HZ := 50.0
const TELEMETRY_MAGIC := 0x314E5443  # "CTN1"
const CONTROL_MAGIC := 0x43544E43  # "CTNC"
const HEARTBEAT_MAGIC := 0x43544E4B  # "CTNK"
const SESSION_DONE_MAGIC := 0x43544E44  # "CTND"
const ICT_RESULT_MAGIC := 0x43544E52  # "CTNR"
const PROTOCOL_VERSION := 1
const CMD_RECORD_START := 1
const CMD_RECORD_STOP := 2
const CMD_SHUTDOWN := 3
const CMD_ICT_START := 4
const CMD_ICT_STOP := 5
const CMD_TIMED_CAN_START := 6
const HEARTBEAT_FLAG_RECORDING := 0x01
const HEARTBEAT_FLAG_PLATFORM_LINUX := 0x02
const HEARTBEAT_FLAG_ICT_HANDSHAKE := 0x04
const HEARTBEAT_TIMEOUT_MS := 2500
const GATEWAY_SHUTDOWN_GRACE_MS := 1500
const GATEWAY_KILL_GRACE_MS := 1000
const GATEWAY_STARTUP_TIMEOUT_MS := 5000
const ICT_RESULT_TIMEOUT_MS := 5000

enum GatewayStatus { OFFLINE, ONLINE, RECORDING }
enum GatewayLifecycle { IDLE, STARTING, STOPPING, FAILED }

@export var remote_host := "127.0.0.1"
@export var remote_port := DEFAULT_PORT
@export var ack_port := DEFAULT_ACK_PORT
@export var web_port := DEFAULT_WEB_PORT
@export var auto_spawn := true
@export var python_command := "python"
## Machine model selecting the gateway IMU mount-compensation table.
@export var model_id := "sy135"
## QML is the CAN semantic authority; the gateway fails closed if this strict
## profile or its SHA-bound calibration cannot be loaded.
@export var compatibility_profile := "builtin:qml-sy135-ground-truth"
@export_file("*.toml") var qml_calibration_path := ""

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
var _ict_handshake_connected := false
var _ict_active := false
var _ict_requested := false
var _ict_pending_seq := -1
var _ict_active_seq := -1
var _ict_result_deadline_ms := -1
## Cross-platform PC001 TCP listener endpoint injected into Gateway spawn argv.
var tcp_host := "0.0.0.0"
var tcp_port := 5678
var _spawned_tcp_host := ""
var _spawned_tcp_port := -1
var _gateway_lifecycle := GatewayLifecycle.IDLE
var _gateway_deadline_ms := -1
var _restart_after_stop := false
var _forced_kill_sent := false
var _last_gateway_error := ""
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
	_service_gateway_lifecycle()
	_expire_ict_handshake_if_stale()
	_expire_ict_result_if_stale()
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
	if _gateway_pid <= 0 or _gateway_lifecycle != GatewayLifecycle.IDLE or stale:
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


func is_ict_handshake_connected() -> bool:
	return _ict_handshake_connected and is_gateway_online()


## Validate and store the PC001 listener endpoint. Empty fields select the
## documented defaults; invalid input never mutates the current endpoint.
func set_tcp_endpoint(host: String, port_text: String) -> bool:
	var trimmed_host := host.strip_edges()
	if trimmed_host.is_empty():
		trimmed_host = "0.0.0.0"
	if trimmed_host.to_lower() != "localhost" and (
		not trimmed_host.is_valid_ip_address() or ":" in trimmed_host
	):
		_last_gateway_error = "Gateway TCP host must be an IPv4 listener address or localhost"
		return false
	var trimmed_port := port_text.strip_edges()
	var parsed_port := 5678
	if not trimmed_port.is_empty():
		if not trimmed_port.is_valid_int():
			_last_gateway_error = "Gateway TCP port must be an integer from 1 to 65535"
			return false
		parsed_port = trimmed_port.to_int()
	if parsed_port < 1 or parsed_port > 65535:
		_last_gateway_error = "Gateway TCP port must be an integer from 1 to 65535"
		return false
	tcp_host = trimmed_host.to_lower()
	tcp_port = parsed_port
	_last_gateway_error = ""
	return true


func is_ict_active() -> bool:
	return _ict_active


func is_ict_requested() -> bool:
	return _ict_requested


func is_ict_connecting() -> bool:
	return _ict_requested and not _ict_active and _ict_pending_seq >= 0


func set_ict_connected(enabled: bool) -> void:
	_ict_requested = enabled
	if not enabled:
		_ict_active = false
		_ict_pending_seq = -1
		_ict_active_seq = -1
		_ict_result_deadline_ms = -1
		if _gateway_pid > 0 and _gateway_lifecycle != GatewayLifecycle.STOPPING:
			_send_control(CMD_ICT_STOP)
		return
	_last_gateway_error = ""
	if _gateway_lifecycle == GatewayLifecycle.FAILED:
		_begin_gateway_restart()
		return
	if _gateway_lifecycle != GatewayLifecycle.IDLE:
		return
	if _gateway_pid <= 0 or not OS.is_process_running(_gateway_pid):
		_gateway_pid = -1
		spawn_gateway()
		return
	if _spawned_tcp_host != tcp_host or _spawned_tcp_port != tcp_port:
		_begin_gateway_restart()
		return
	if is_gateway_online():
		_activate_ict()
	else:
		_gateway_lifecycle = GatewayLifecycle.STARTING
		_gateway_deadline_ms = Time.get_ticks_msec() + GATEWAY_STARTUP_TIMEOUT_MS


func trigger_timed_can() -> bool:
	if not is_gateway_online():
		_last_gateway_error = "CAN gateway is offline; timed frame was not started"
		return false
	_send_control(CMD_TIMED_CAN_START)
	return true


func respawn_gateway() -> bool:
	if _gateway_lifecycle == GatewayLifecycle.STOPPING:
		_restart_after_stop = true
		return true
	if _gateway_lifecycle == GatewayLifecycle.FAILED:
		if _gateway_pid <= 0 or not OS.is_process_running(_gateway_pid):
			_gateway_pid = -1
			_gateway_lifecycle = GatewayLifecycle.IDLE
			return spawn_gateway()
		_begin_gateway_restart()
		return true
	if _gateway_pid > 0 and OS.is_process_running(_gateway_pid):
		_begin_gateway_restart()
		return true
	_gateway_pid = -1
	return spawn_gateway()


func get_gateway_lifecycle_state() -> String:
	match _gateway_lifecycle:
		GatewayLifecycle.STARTING:
			return "starting"
		GatewayLifecycle.STOPPING:
			return "stopping"
		GatewayLifecycle.FAILED:
			return "failed"
		_:
			return "idle"


func is_gateway_restart_pending() -> bool:
	return _gateway_lifecycle == GatewayLifecycle.STOPPING and _restart_after_stop


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
				var native_argv := PackedStringArray([candidate])
				native_argv.append_array(_gateway_arguments())
				return _with_compatibility_args(native_argv)
	var script := _resolve_gateway_script()
	if script.is_empty():
		return PackedStringArray()
	var script_argv := PackedStringArray([python_command, script])
	script_argv.append_array(_gateway_arguments())
	return _with_compatibility_args(script_argv)


func _gateway_arguments() -> PackedStringArray:
	return _gateway_arguments_for_platform(OS.get_name())


func _gateway_arguments_for_platform(_platform_name: String) -> PackedStringArray:
	var argv := PackedStringArray([
		"--host", remote_host,
		"--port", str(remote_port),
		"--ack-port", str(ack_port),
		"--web-port", str(web_port),
		"--out", _resolve_output_dir(),
		"--model", model_id,
		"--mode", "godot-managed",
	])
	argv.append_array(PackedStringArray([
		"--sink", "tcp",
		"--tcp-host", tcp_host,
		"--tcp-port", str(tcp_port),
	]))
	return argv


func _with_compatibility_args(argv: PackedStringArray) -> PackedStringArray:
	var profile := compatibility_profile.strip_edges()
	if not profile.is_empty():
		argv.append_array(PackedStringArray(["--compat-profile", profile]))
	var calibration := qml_calibration_path.strip_edges()
	if not calibration.is_empty():
		if calibration.begins_with("res://") or calibration.begins_with("user://"):
			calibration = ProjectSettings.globalize_path(calibration)
		argv.append_array(PackedStringArray(["--qml-calibration", calibration]))
	return argv


func spawn_gateway() -> bool:
	_drain_ack_packets()
	_last_heartbeat_ms = -1
	_heartbeat_recording = false
	_set_ict_link_state(false, false)
	var argv := _resolve_gateway_command()
	if argv.is_empty():
		_set_gateway_error("CanTelemetryBridge: no gateway executable/script found")
		_gateway_pid = -1
		_gateway_lifecycle = GatewayLifecycle.FAILED
		return false
	_gateway_pid = OS.create_process(argv[0], argv.slice(1))
	if _gateway_pid <= 0:
		_set_gateway_error("CanTelemetryBridge: failed to spawn '%s'" % argv[0])
		_gateway_lifecycle = GatewayLifecycle.FAILED
		return false
	_spawned_tcp_host = tcp_host
	_spawned_tcp_port = tcp_port
	_gateway_lifecycle = GatewayLifecycle.STARTING
	_gateway_deadline_ms = Time.get_ticks_msec() + GATEWAY_STARTUP_TIMEOUT_MS
	_last_gateway_error = ""
	return true


func _begin_gateway_restart() -> void:
	_ict_active = false
	_ict_pending_seq = -1
	_ict_active_seq = -1
	_ict_result_deadline_ms = -1
	_set_ict_link_state(false, false)
	_restart_after_stop = true
	_gateway_lifecycle = GatewayLifecycle.STOPPING
	_gateway_deadline_ms = Time.get_ticks_msec() + GATEWAY_SHUTDOWN_GRACE_MS
	_forced_kill_sent = false
	_send_control(CMD_ICT_STOP)
	_send_control(CMD_SHUTDOWN)


func _service_gateway_lifecycle() -> void:
	var now_ms := Time.get_ticks_msec()
	if _gateway_lifecycle == GatewayLifecycle.STARTING:
		if _gateway_pid <= 0 or not OS.is_process_running(_gateway_pid):
			_gateway_pid = -1
			_gateway_lifecycle = GatewayLifecycle.FAILED
			_ict_requested = false
			_ict_active = false
			_set_ict_link_state(false, false)
			_set_gateway_error(
				(
					"CAN gateway exited before its first heartbeat; verify TCP endpoint %s:%s "
					+ "is available (external port owners are not terminated)"
				) % [tcp_host, tcp_port]
			)
		elif now_ms >= _gateway_deadline_ms:
			OS.kill(_gateway_pid)
			_ict_requested = false
			_ict_active = false
			_set_ict_link_state(false, false)
			_restart_after_stop = false
			_forced_kill_sent = true
			_gateway_lifecycle = GatewayLifecycle.STOPPING
			_gateway_deadline_ms = now_ms + GATEWAY_KILL_GRACE_MS
			_set_gateway_error("CAN gateway did not become ready before timeout")
	elif _gateway_lifecycle == GatewayLifecycle.STOPPING:
		if _gateway_pid <= 0 or not OS.is_process_running(_gateway_pid):
			_gateway_pid = -1
			_gateway_lifecycle = GatewayLifecycle.IDLE
			_forced_kill_sent = false
			if _restart_after_stop:
				_restart_after_stop = false
				spawn_gateway()
		elif now_ms >= _gateway_deadline_ms:
			if not _forced_kill_sent:
				OS.kill(_gateway_pid)
				_forced_kill_sent = true
				_gateway_deadline_ms = now_ms + GATEWAY_KILL_GRACE_MS
			else:
				_restart_after_stop = false
				_gateway_lifecycle = GatewayLifecycle.FAILED
				_ict_requested = false
				_ict_active = false
				_set_ict_link_state(false, false)
				_set_gateway_error("CAN gateway process did not stop after termination request")


func _activate_ict() -> void:
	if not _ict_requested or _ict_active or _ict_pending_seq >= 0:
		return
	_ict_pending_seq = _send_control(CMD_ICT_START)
	_ict_result_deadline_ms = Time.get_ticks_msec() + ICT_RESULT_TIMEOUT_MS
	ict_link_status_changed.emit(_ict_handshake_connected, _gateway_is_linux)


func _expire_ict_result_if_stale() -> void:
	if _ict_pending_seq < 0 or Time.get_ticks_msec() < _ict_result_deadline_ms:
		return
	# The Gateway can still be blocked in the privileged can0 helper. Queueing
	# STOP before clearing local state makes a late setup success self-cancel.
	_send_control(CMD_ICT_STOP)
	_ict_pending_seq = -1
	_ict_result_deadline_ms = -1
	_ict_requested = false
	_ict_active = false
	_set_gateway_error("ICT connection timed out before Gateway acknowledged transport readiness")
	ict_link_status_changed.emit(_ict_handshake_connected, _gateway_is_linux)


func _handle_ict_result(packet: PackedByteArray) -> void:
	if packet.size() < 14 or packet[4] != PROTOCOL_VERSION or packet[5] != CMD_ICT_START:
		return
	var request_seq := _read_u32(packet, 6)
	var result_code := _read_u16(packet, 10)
	var detail_len := _read_u16(packet, 12)
	if detail_len > 160 or packet.size() != 14 + detail_len:
		return
	var matches_pending := request_seq == _ict_pending_seq
	var matches_active := request_seq == _ict_active_seq
	if not matches_pending and not matches_active:
		return
	var detail_bytes := packet.slice(14)
	var detail := detail_bytes.get_string_from_utf8()
	if detail.to_utf8_buffer() != detail_bytes:
		return
	if result_code == 0:
		if matches_active:
			return
		_ict_active = true
		_ict_active_seq = request_seq
		_ict_pending_seq = -1
		_ict_result_deadline_ms = -1
		_last_gateway_error = ""
	else:
		_ict_active = false
		_ict_requested = false
		_ict_pending_seq = -1
		_ict_active_seq = -1
		_ict_result_deadline_ms = -1
		_set_gateway_error(_ict_result_message(result_code, detail))
	ict_link_status_changed.emit(_ict_handshake_connected, _gateway_is_linux)


func _ict_result_message(code: int, detail: String) -> String:
	var category: String = String({
		1: "Gateway has no ICT transport",
		2: "can0 is missing; check the USB-CAN adapter and driver",
		3: "can0 setup helper or sudoers authorization is unavailable",
		4: "can0 privileged setup failed",
		5: "can0 did not pass readiness verification",
		6: "Linux AF_CAN is unavailable",
		7: "Gateway could not bind can0",
		8: "SocketCAN frame sending failed",
		9: "Gateway ICT transport failed internally",
	}.get(code, "Gateway returned an unknown ICT result"))
	return category if detail.is_empty() else "%s (%s)" % [category, detail]


func _set_gateway_error(message: String) -> void:
	_last_gateway_error = message
	push_warning(message)


func _set_ict_link_state(handshake_connected: bool, platform_linux: bool) -> void:
	if (
		_ict_handshake_connected == handshake_connected
		and _gateway_is_linux == platform_linux
	):
		return
	_ict_handshake_connected = handshake_connected
	_gateway_is_linux = platform_linux
	ict_link_status_changed.emit(_ict_handshake_connected, _gateway_is_linux)


func _expire_ict_handshake_if_stale() -> void:
	if not _ict_handshake_connected:
		return
	if (
		_last_heartbeat_ms < 0
		or Time.get_ticks_msec() - _last_heartbeat_ms > HEARTBEAT_TIMEOUT_MS
	):
		_set_ict_link_state(false, _gateway_is_linux)


func get_last_gateway_error() -> String:
	return _last_gateway_error


func get_gateway_pid_for_test() -> int:
	return _gateway_pid


func get_spawned_tcp_endpoint_for_test() -> Dictionary:
	return {"host": _spawned_tcp_host, "port": _spawned_tcp_port}


func get_desired_tcp_endpoint_for_test() -> Dictionary:
	return {"host": tcp_host, "port": tcp_port}


func set_ict_pending_for_test(request_seq: int) -> void:
	_ict_requested = true
	_ict_active = false
	_ict_pending_seq = request_seq
	_ict_active_seq = -1
	_ict_result_deadline_ms = Time.get_ticks_msec() + ICT_RESULT_TIMEOUT_MS


func handle_ict_result_for_test(packet: PackedByteArray) -> void:
	_handle_ict_result(packet)


func expire_ict_result_for_test() -> void:
	_ict_result_deadline_ms = 0
	_expire_ict_result_if_stale()


func get_control_sequence_for_test() -> int:
	return _control_seq


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
			_heartbeat_recording = (packet[5] & HEARTBEAT_FLAG_RECORDING) != 0
			_last_heartbeat_ms = Time.get_ticks_msec()
			if _gateway_lifecycle == GatewayLifecycle.STARTING:
				_gateway_lifecycle = GatewayLifecycle.IDLE
				_gateway_deadline_ms = -1
				_last_gateway_error = ""
				_activate_ict()
			_set_ict_link_state(
				(packet[5] & HEARTBEAT_FLAG_ICT_HANDSHAKE) != 0,
				(packet[5] & HEARTBEAT_FLAG_PLATFORM_LINUX) != 0,
			)
		elif packet.size() > 8 and _read_u32(packet, 0) == SESSION_DONE_MAGIC:
			var path_bytes := packet.slice(8)
			_last_segment_path = path_bytes.get_string_from_utf8()
		elif packet.size() >= 14 and _read_u32(packet, 0) == ICT_RESULT_MAGIC:
			_handle_ict_result(packet)


func _drain_ack_packets() -> void:
	if _ack == null or not _ack_bound:
		return
	while _ack.get_available_packet_count() > 0:
		_ack.get_packet()


func get_last_segment_path() -> String:
	return _last_segment_path


func set_last_segment_path(path: String) -> void:
	_last_segment_path = path


func _send_control(cmd: int) -> int:
	if _udp == null:
		_udp = PacketPeerUDP.new()
	_udp.set_dest_address(remote_host, remote_port)
	_control_seq += 1
	_udp.put_packet(_build_control_packet(cmd, _control_seq))
	return _control_seq


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


static func _read_u16(data: PackedByteArray, offset: int) -> int:
	return data[offset] | (data[offset + 1] << 8)


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

extends SceneTree
## Regression for the frozen-gateway lifecycle: PyInstaller onefile builds run
## the real gateway as a *child* of the spawned launcher pid, so the launcher
## dying or being killed leaves a port-owning orphan. The supervisor must
## adopt heartbeat sources with no live pid (instead of flagging the gateway
## as abnormal), and reclaim them through SHUTDOWN before respawning.

const HEARTBEAT_MAGIC := 0x43544E4B
const PROTOCOL_VERSION := 1
const TEST_GATEWAY_PORT := 39784
const TEST_ACK_PORT := 39785
const TEST_WEB_PORT := 39797

var failures: Array[String] = []
var _sender: PacketPeerUDP = null
var _ack_port := TEST_ACK_PORT


func _init() -> void:
	call_deferred("_run")


func _send_heartbeat(flags := 0) -> void:
	var packet := PackedByteArray()
	packet.resize(16)
	packet.encode_u32(0, HEARTBEAT_MAGIC)
	packet[4] = PROTOCOL_VERSION
	packet[5] = flags
	packet.encode_u16(6, 0)
	packet.encode_u64(8, Time.get_ticks_msec())
	_sender.put_packet(packet)


func _pump_heartbeats(frames: int) -> void:
	for _i in range(frames):
		_send_heartbeat()
		await physics_frame


func _run() -> void:
	var bridge := root.get_node_or_null("CanTelemetryBridge")
	if bridge == null:
		_fail("CanTelemetryBridge autoload missing")
		_finish()
		return
	bridge.remote_port = TEST_GATEWAY_PORT
	var existing_ack := bridge.get("_ack") as PacketPeerUDP
	if existing_ack != null:
		existing_ack.close()
	bridge.set("_ack_bound", false)
	bridge.ack_port = TEST_ACK_PORT
	bridge.web_port = TEST_WEB_PORT
	# Spawn attempts must fail fast if reached — the adoption flow is what's
	# under test, not real process supervision.
	bridge.python_command = "definitely_missing_python_gateway_xyz"

	# A squatter on the desired ack port must not blind the bridge: binding
	# falls back to a free port and the spawn argv carries the bound one.
	var squatter := PacketPeerUDP.new()
	if squatter.bind(_ack_port) == OK:
		var held_ack := bridge.get("_ack") as PacketPeerUDP
		if held_ack != null:
			held_ack.close()
		bridge.set("_ack_bound", false)
		bridge.set("_ack_port_bound", -1)
		if not bool(bridge.call("_ensure_ack_bound")) \
				or int(bridge.get("_ack_port_bound")) != _ack_port + 1:
			_fail("occupied ack port did not fall back to the next free port")
		var argv: PackedStringArray = bridge.call("_resolve_gateway_command")
		var ack_arg := argv.find("--ack-port")
		if ack_arg < 0 or int(argv[ack_arg + 1]) != _ack_port + 1:
			_fail("spawn argv did not carry the actually bound ack port")
		squatter.close()
		(bridge.get("_ack") as PacketPeerUDP).close()
		bridge.set("_ack_bound", false)
		bridge.set("_ack_port_bound", -1)
		bridge.call("_ensure_ack_bound")
	else:
		print("note: ack-port squatter unavailable; fallback path skipped")

	_sender = PacketPeerUDP.new()
	_sender.set_dest_address("127.0.0.1", int(bridge.get("_ack_port_bound")))

	if bridge.get_status() != 0:
		_fail("fresh bridge reported non-OFFLINE status")

	# Heartbeats with no spawned process: the port owner gets adopted.
	await _pump_heartbeats(4)
	if not bool(bridge.get("_gateway_detached")):
		_fail("heartbeats without a tracked pid did not mark the gateway detached")
	if bridge.get_status() == 0:
		_fail("adopted heartbeat source did not come ONLINE")
	if bridge.is_gateway_restart_required():
		_fail("adopted heartbeat source was flagged as needing a restart")

	# Restarting an adopted gateway must SHUTDOWN the port owner first — a
	# blind respawn would die on the port bind.
	bridge.respawn_gateway()
	if bridge.get_gateway_lifecycle_state() != "stopping":
		_fail("respawn while heartbeats flow did not go through SHUTDOWN")

	# While heartbeats keep arriving the owner may still be alive: stay
	# STOPPING until they go quiet.
	await _pump_heartbeats(12)
	if bridge.get_gateway_lifecycle_state() != "stopping":
		_fail("STOPPING did not wait for heartbeat silence")

	# Silence → respawn is attempted; the broken spawn command lands in FAILED.
	var quiet_deadline := Time.get_ticks_msec() + 6000
	while bridge.get_gateway_lifecycle_state() == "stopping" \
			and Time.get_ticks_msec() < quiet_deadline:
		await physics_frame
	if bridge.get_gateway_lifecycle_state() != "failed":
		_fail("quiet heartbeats did not fall through STOPPING to a respawn attempt")

	# A heartbeat source reappearing after FAILED self-heals via adoption.
	await _pump_heartbeats(4)
	if bridge.get_gateway_lifecycle_state() != "idle":
		_fail("heartbeats after FAILED did not re-adopt the gateway")
	if bridge.get_status() == 0:
		_fail("re-adopted gateway stayed OFFLINE")

	_sender.close()
	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("Gateway detached-adoption contract passed.")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _fail(message: String) -> void:
	failures.append(message)

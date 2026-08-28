extends SceneTree

const ICT_RESULT_MAGIC := 0x43544E52
const PROTOCOL_VERSION := 1
const CMD_ICT_START := 4

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var bridge := root.get_node_or_null("CanTelemetryBridge")
	if bridge == null:
		_fail("CanTelemetryBridge autoload is unavailable")
		_finish()
		return

	bridge.set_ict_pending_for_test(7)
	bridge.handle_ict_result_for_test(_result_packet(8, 0, "late"))
	_check(not bridge.is_ict_active() and bridge.is_ict_connecting(),
		"mismatched result does not mutate pending state")
	bridge.handle_ict_result_for_test(_result_packet(7, 0, ""))
	_check(bridge.is_ict_active() and not bridge.is_ict_connecting(),
		"matching success establishes active ICT state")
	bridge.handle_ict_result_for_test(_result_packet(7, 0, "duplicate"))
	_check(bridge.is_ict_active() and bridge.is_ict_requested(),
		"duplicate success result is idempotent after activation")

	bridge.set_ict_pending_for_test(9)
	bridge.handle_ict_result_for_test(_result_packet(9, 2, "can0 missing"))
	_check(not bridge.is_ict_active() and not bridge.is_ict_requested(),
		"matching failure clears requested and active state")
	_check("USB-CAN" in String(bridge.get_last_gateway_error()),
		"stable missing-interface result exposes actionable hardware guidance")

	bridge.set_ict_pending_for_test(10)
	var malformed := _result_packet(10, 0, "ok")
	malformed.resize(malformed.size() - 1)
	bridge.handle_ict_result_for_test(malformed)
	_check(bridge.is_ict_connecting(), "malformed result is ignored")

	var invalid_utf8 := _result_packet(10, 0, "x")
	invalid_utf8[14] = 0xff
	bridge.handle_ict_result_for_test(invalid_utf8)
	_check(bridge.is_ict_connecting(), "invalid UTF-8 result detail is ignored")

	var control_seq_before: int = bridge.get_control_sequence_for_test()
	bridge.expire_ict_result_for_test()
	_check(not bridge.is_ict_requested() and not bridge.is_ict_active(),
		"result timeout clears requested and active state")
	_check(bridge.get_control_sequence_for_test() == control_seq_before + 1,
		"result timeout sends one compensating ICT stop command")
	_finish()


func _result_packet(seq: int, code: int, detail: String) -> PackedByteArray:
	var detail_bytes := detail.to_utf8_buffer()
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = false
	buffer.put_32(ICT_RESULT_MAGIC)
	buffer.put_8(PROTOCOL_VERSION)
	buffer.put_8(CMD_ICT_START)
	buffer.put_32(seq)
	buffer.put_16(code)
	buffer.put_16(detail_bytes.size())
	buffer.put_data(detail_bytes)
	return buffer.data_array


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		_fail(message)


func _fail(message: String) -> void:
	failures.append(message)
	push_error(message)


func _finish() -> void:
	quit(0 if failures.is_empty() else 1)

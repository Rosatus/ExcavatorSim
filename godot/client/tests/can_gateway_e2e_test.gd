extends SceneTree
## E2E for the CAN gateway supervision flow: autoload spawns python gateway,
## heartbeat flips status ONLINE, recording writes CSV rows, stop closes it.
## Skips gracefully when python is unavailable.

const MAIN_SCENE := "res://scenes/main.tscn"
const OUTPUT_DIR := "res://../../output/can_gateway"
const SETTLE_FRAMES := 30


var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if _python_available() != true:
		print("can_gateway_e2e: SKIP (python not on PATH)")
		quit(0)
		return
	var packed := load(MAIN_SCENE) as PackedScene
	var scene := packed.instantiate()
	root.add_child(scene)
	for i in SETTLE_FRAMES:
		await process_frame

	var bridge := root.get_node_or_null("CanTelemetryBridge")
	if bridge == null:
		print("FAIL: CanTelemetryBridge autoload missing")
		quit(1)
		return

	# A stale gateway from an earlier run may hold the port; force a fresh spawn.
	var online := false
	for attempt in 3:
		if bridge.is_gateway_online():
			online = true
			break
		_send_shutdown_probe()
		bridge.respawn_gateway()
		for i in 4:
			await create_timer(0.7).timeout
			if bridge.is_gateway_online():
				online = true
				break
	_check(online, "gateway reaches ONLINE via heartbeat")

	_wipe_output_dir()
	bridge.set_recording(true)
	var start_acked := false
	for i in 15:
		await create_timer(0.1).timeout
		if int(bridge.get_status()) == 2:
			start_acked = true
			break
	_check(start_acked, "gateway acknowledges RECORD_START via heartbeat")
	var rows_after_start := 0
	for i in 50:
		await create_timer(0.1).timeout
		rows_after_start = _count_rows(_newest_csv())
		if rows_after_start > 0:
			break
	_check(rows_after_start > 0, "recording produces CSV data rows")

	bridge.set_recording(false)
	var left_recording := true
	for i in 15:
		await create_timer(0.1).timeout
		if int(bridge.get_status()) != 2:
			left_recording = false
			break
	var rows_final := _count_rows(_newest_csv())
	_check(rows_final >= rows_after_start, "stop keeps the captured segment on disk")
	_check(not left_recording, "status leaves RECORDING after stop")

	scene.queue_free()
	await process_frame
	if _failures == 0:
		print("can_gateway_e2e_test: PASS")
		quit(0)
	else:
		print("can_gateway_e2e_test: FAIL (%d)" % _failures)
		quit(1)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: %s" % label)
	else:
		_failures += 1
		print("FAIL: %s" % label)


func _send_shutdown_probe() -> void:
	var peer := PacketPeerUDP.new()
	peer.set_dest_address("127.0.0.1", 29764)
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = false
	buffer.put_32(0x43544E43)
	buffer.put_8(1)
	buffer.put_8(3)
	buffer.put_16(0)
	buffer.put_32(0)
	peer.put_packet(buffer.data_array)
	peer.close()


func _python_available() -> bool:
	return OS.execute("python", ["--version"], [], true) == 0


func _wipe_output_dir() -> void:
	var dir := DirAccess.open(ProjectSettings.globalize_path(OUTPUT_DIR).simplify_path())
	if dir == null:
		return
	for file in dir.get_files():
		if file.ends_with(".csv"):
			dir.remove(file)


func _newest_csv() -> String:
	var global_dir := ProjectSettings.globalize_path(OUTPUT_DIR).simplify_path()
	var dir := DirAccess.open(global_dir)
	if dir == null:
		return ""
	var best_name := ""
	var best_time := -1
	for file in dir.get_files():
		if not file.ends_with(".csv"):
			continue
		var modified := FileAccess.get_modified_time(global_dir.path_join(file))
		if modified > best_time:
			best_time = modified
			best_name = file
	return "" if best_name.is_empty() else global_dir.path_join(best_name)


func _count_rows(path: String) -> int:
	if path.is_empty() or not FileAccess.file_exists(path):
		return 0
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var rows := -1
	while not file.eof_reached():
		file.get_line()
		rows += 1
	file.close()
	return max(rows, 0)

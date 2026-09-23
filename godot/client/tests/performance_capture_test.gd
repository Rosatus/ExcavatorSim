extends SceneTree

const Capture := preload("res://scripts/performance_capture.gd")
var failures: Array[String] = []

class WorldSpy extends ExcavationWorld:
	var reads := 0
	func _ready() -> void:
		set_physics_process(false)
	func set_voxel_diagnostics_enabled(enabled: bool) -> void:
		voxel_diagnostics_enabled = enabled
	func get_performance_context() -> Dictionary:
		reads += 1
		return {"available": true, "generation": 1, "model_id": "sy135"}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	var world := WorldSpy.new()
	world.name = "World"
	scene.add_child(world)
	var capture := Capture.new()
	capture.excavation_world_path = NodePath("../World")
	scene.add_child(capture)
	check(not capture.recording and not capture.is_processing() and world.reads == 0, "recorder off performs no polling")
	var directory := ProjectSettings.globalize_path("res://../../output/digging-performance/capture-test")
	check(capture.start_capture(directory), "start capture succeeds")
	check(capture._metadata.source_sha256.has("res://scripts/voxel_cut_proposal.gd"), "capture identifies proposal hashing implementation")
	capture.set_process(false)
	check(not capture.start_capture(directory), "duplicate start rejected")
	check(not world.voxel_diagnostics_enabled and world.performance_capture_enabled, "capture enables timing without full diagnostics")
	var event := {"ended_usec": Time.get_ticks_usec(), "physics_frame": 1, "automatic_usec": 1000, "step_usec": 3000, "publish_usec": 2000, "total_usec": 6000,
		"cut_preparation": {"total_usec": 1200, "coverage_usec": 800, "edit_usec": 300},
		"cutter_phases": {"cutter_admission_usec": 100, "cutter_contact_usec": 500, "cutter_paths_usec": 200},
		"transaction": {"generation": 1, "revision": 1, "operation": "cut", "model_id": "sy135", "commit_usec": 2000, "coverage_usec": 1000, "support_cleanup_usec": 400}}
	world.performance_step_sampled.emit(event)
	world.performance_step_sampled.emit(event)
	capture._last_frame_usec -= 20000
	capture._process(0.0)
	capture._on_chassis_step(3000, 1000)
	capture._on_chassis_step(4000, 2000)
	check(capture._pending[26] == 7 and capture._pending[27] == 3 and capture._pending[28] == 2, "chassis and track time accumulate every physics callback")
	var row := capture._frames[0]
	check(row[35] == 2.4 and row[36] == 1.6 and row[37] == 0.6, "private preparation is attributed to its actual frame")
	check(row[14] == 2 and row[17] == 12 and row[18] == 2 and row[19] == 4, "all physics steps and transactions accumulate in frame")
	check(is_equal_approx(row[29], 0.2) and row[30] == 1.0 and is_equal_approx(row[32], 0.4) and is_equal_approx(row[34], 0.8), "cutter and cleanup phases accumulate across physics steps")
	check(row[2] >= 20 and row[6] == -1 and row[7] == -1, "wall interval and unavailable headless GPU are explicit")
	check(capture._events.size() == 2, "transactions are not lost between rendered frames")
	check(world.reads == 1, "per-frame collection avoids world status reads")
	capture._process(0.0)
	check(capture._frames[1][26] == 7 and capture._pending[26] == 0, "chassis timing drains once per render frame")
	check(capture._frames[1][35] == 0 and capture._frames[1][36] == 0 and capture._frames[1][37] == 0, "preparation drains once per frame")
	check(capture._frames[1][17] == 0, "stage accumulator resets each frame")
	check(capture._frames[1][30] == 0 and capture._frames[1][34] == 0, "new phase clocks drain once per frame")
	capture._last_context_usec -= Capture.CONTEXT_PERIOD_USEC
	capture._process(0.0)
	check(world.reads == 2, "context sampled at four Hz")
	paused = true
	capture._process(0.0)
	paused = false
	capture._process(0.0)
	check(capture._frames[-1][12] == 1, "pause transition excluded from active summary")
	capture._on_focus_transition()
	capture._on_focus_transition()
	capture._process(0.0)
	check(capture._frames[-1][13] == 0, "focus changes between callbacks exclude interval")
	capture.add_marker("test spike")
	check(capture.marker_count == 1, "marker captured")
	var correct_path := capture.last_path
	capture.last_path = directory
	check(not capture.stop_capture() and bool(capture.get_capture_status()["unsaved"]), "failed save retains data for retry")
	check(not world.voxel_diagnostics_enabled and not world.performance_capture_enabled, "failed save still restores diagnostics")
	check(not capture.start_capture(directory), "unsaved trace cannot be silently replaced")
	capture.last_path = correct_path
	capture.set_overlay_measurement(true)
	check(capture.save_capture(), "retry save succeeds")
	check(capture.overlay_measurement, "saving capture preserves independent HUD measurement")
	capture.set_overlay_measurement(false)
	var report: Variant = JSON.parse_string(FileAccess.get_file_as_string(correct_path))
	check(report is Dictionary and bool(report.get("complete", false)), "complete report parses")
	check(report["frame_columns"].size() == report["frames"][0].size(), "packed rows serialize as numeric JSON arrays")
	check(report["events"].size() == 5 and report["contexts"].size() == 2, "export preserves events and context")
	check(not capture.start_capture(correct_path.path_join("invalid")), "unwritable directory rejected")
	check(not capture.recording and not world.performance_capture_enabled, "failed start leaves capture disabled")
	world.voxel_diagnostics_enabled = true
	check(capture.start_capture(directory, 1.0), "second session starts")
	capture.set_process(false)
	check(capture._frames.is_empty() and capture._events.is_empty(), "new capture has no old data")
	capture._started_usec -= 2000000
	capture._process(0.0)
	check(not capture.recording and capture._stop_reason == "duration_limit", "duration bound auto-saves")
	check(world.voxel_diagnostics_enabled and not world.performance_capture_enabled, "pre-existing diagnostics stay enabled")
	check(capture.start_capture(directory), "teardown fixture starts")
	capture._process(0.0)
	scene.remove_child(capture)
	check(not capture.recording and not capture._unsaved and capture._stop_reason == "scene_exit", "normal scene exit saves recording")
	capture.free()
	scene.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	print("PERFORMANCE_CAPTURE %s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

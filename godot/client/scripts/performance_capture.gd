class_name PerformanceCapture
extends Node

## Opt-in, bounded in-memory trace. No per-frame JSON, sorting, or disk writes.
## Intervals are wall time between late _process callbacks, not GPU present time.
signal state_changed

const SCHEMA := "excavator-performance-capture-v1"
const OUTPUT_DIR := "user://performance-captures"
const MAX_FRAMES := 60000
const MAX_EVENTS := 12000
const MAX_CONTEXTS := 1000
const CONTEXT_PERIOD_USEC := 250000
const FRAME_COLUMNS := [
	"t_ms", "process_frame", "frame_interval_ms", "engine_process_ms", "engine_physics_ms", "physics_steps",
	"render_cpu_ms", "render_gpu_ms", "render_setup_cpu_ms", "draw_calls", "primitives", "static_memory_mb",
	"paused", "focused", "soil_automatic_ms", "soil_step_ms", "soil_publish_ms", "soil_total_ms",
	"transaction_count", "commit_ms", "coverage_ms", "material_ms", "native_edit_ms", "digest_ms", "readiness_issue_ms",
	"recorder_ms",
]
const STAGE_COLUMNS := {"automatic_usec": 14, "step_usec": 15, "publish_usec": 16, "total_usec": 17}
const TRANSACTION_COLUMNS := {"commit_usec": 19, "coverage_usec": 20, "material_usec": 21, "native_edit_usec": 22, "digest_usec": 23, "readiness_issue_usec": 24}

@export var excavation_world_path := NodePath("../TerrainRoot/ExcavationWorld")
var recording := false
var last_path := ""
var last_error := ""
var marker_count := 0
var _world: ExcavationWorld
var _prior_diagnostics := false
var _render_measurement_enabled := false
var _viewport_rid := RID()
var _started_usec := 0
var _last_frame_usec := 0
var _last_physics_frame := 0
var _last_context_usec := 0
var _duration_limit_s := 180.0
var _previous_paused := false
var _previous_focused := true
var _focus_transition := false
var _observer_usec := 0
var _pending := PackedFloat64Array()
var _frames: Array[PackedFloat64Array] = []
var _events: Array[Dictionary] = []
var _contexts: Array[Dictionary] = []
var _metadata: Dictionary = {}
var _unsaved := false
var _stop_reason := ""
var _stopped_usec := 0
var _dropped_events := 0
var _last_summary: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 10000
	_world = get_node_or_null(excavation_world_path) as ExcavationWorld
	if _world != null:
		_world.performance_step_sampled.connect(_on_soil_step)
	get_window().focus_entered.connect(_on_focus_transition)
	get_window().focus_exited.connect(_on_focus_transition)
	set_process(false)


func start_capture(directory: String = OUTPUT_DIR, duration_limit_s: float = 180.0) -> bool:
	if recording or _unsaved:
		return false
	last_error = ""
	var absolute_dir := ProjectSettings.globalize_path(directory)
	var error := DirAccess.make_dir_recursive_absolute(absolute_dir)
	if error != OK:
		return _fail("无法创建录制目录：%s (%s)" % [absolute_dir, error_string(error)])
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	last_path = absolute_dir.path_join("capture-%s-%d.json" % [stamp, Time.get_ticks_usec()])
	# Preflight before driving; an interrupted run leaves an explicit incomplete
	# header rather than a file that can be mistaken for a complete measurement.
	var file := FileAccess.open(last_path, FileAccess.WRITE)
	if file == null:
		return _fail("无法写入录制文件：%s" % error_string(FileAccess.get_open_error()))
	file.store_string(JSON.stringify({"schema": SCHEMA, "complete": false}))
	file.flush()
	var preflight_error := file.get_error()
	file.close()
	if preflight_error != OK:
		return _fail("无法写入录制文件：%s" % error_string(preflight_error))
	_frames.clear()
	_events.clear()
	_contexts.clear()
	_pending.resize(FRAME_COLUMNS.size())
	_pending.fill(0.0)
	marker_count = 0
	_dropped_events = 0
	_last_summary.clear()
	_observer_usec = 0
	_duration_limit_s = clampf(duration_limit_s, 1.0, 180.0)
	_prior_diagnostics = _world.voxel_diagnostics_enabled if is_instance_valid(_world) else false
	if is_instance_valid(_world):
		_world.set_performance_capture_enabled(true)
	_viewport_rid = get_viewport().get_viewport_rid()
	_render_measurement_enabled = DisplayServer.get_name() != "headless"
	if _render_measurement_enabled:
		RenderingServer.viewport_set_measure_render_time(_viewport_rid, true)
	_metadata = {
		"started_local": Time.get_datetime_string_from_system(),
		"engine": Engine.get_version_info(), "os": OS.get_name(), "cpu": OS.get_processor_name(),
		"cpu_threads": OS.get_processor_count(), "gpu": RenderingServer.get_video_adapter_name(),
		"renderer": RenderingServer.get_current_rendering_method(), "display_server": DisplayServer.get_name(),
		"viewport_size": [get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y],
		"max_fps": Engine.max_fps, "physics_ticks_per_second": Engine.physics_ticks_per_second,
		"authority_profile": ProjectSettings.get_setting("simulation/authority_profile", "unknown"),
		"vsync_mode": DisplayServer.window_get_vsync_mode() if _render_measurement_enabled else -1,
		"duration_limit_s": _duration_limit_s, "frame_limit": MAX_FRAMES,
		"soil_diagnostics_enabled": _prior_diagnostics, "soil_timing_enabled": is_instance_valid(_world),
		"render_timing_available": _render_measurement_enabled,
		"measurement_notes": [
			"All time columns use milliseconds. -1 means unavailable, not zero cost.",
			"Frame interval is monotonic wall time between late process callbacks; includes pacing/waits, not GPU presentation latency.",
			"Engine/render timings are latest engine reports and may lag the row. Physics time is one reported tick, not all ticks in the interval.",
			"Render CPU/GPU cover the main viewport only. CPU/GPU overlap; do not sum them into frame time.",
			"Soil stage columns accumulate steps since the preceding row. Commit phases are nested inside soil_step, not additive to it.",
			"Capture enables lightweight stage clocks only, not full soil diagnostics or additional SDF digest sampling.",
			"Recorder cost includes sampling/context/callback work, excludes engine instrumentation. Pre-existing full diagnostics add digest work inside soil/commit times.",
			"Pause/focus transitions exclude the adjacent interval from active-play summary. Low-rate context is sampled at four Hz.",
			"The first partial interval is excluded from summary. Unframed tail stages at stop are saved separately.",
			"JSON serialization/file saving occurs after capture stops. Abrupt termination loses buffered samples.",
		],
	}
	var hashes: Dictionary = {}
	for path in ["res://scripts/performance_capture.gd", "res://scripts/excavation_world.gd", "res://scripts/voxel_excavation_authority.gd", "res://scripts/voxel_bucket_cutter.gd", "res://scripts/voxel_cut_proposal.gd"]:
		hashes[path] = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else "unavailable_in_export"
	_metadata["source_sha256"] = hashes
	_started_usec = Time.get_ticks_usec()
	_last_frame_usec = _started_usec
	_last_context_usec = _started_usec
	_last_physics_frame = Engine.get_physics_frames()
	_previous_paused = get_tree().paused
	_previous_focused = get_window().has_focus()
	_focus_transition = false
	_stopped_usec = 0
	recording = true
	_sample_context(_started_usec)
	set_process(true)
	state_changed.emit()
	_observer_usec += Time.get_ticks_usec() - _started_usec
	return true


func stop_capture(reason: String = "user") -> bool:
	if not recording:
		return save_capture() if _unsaved else false
	_stopped_usec = Time.get_ticks_usec()
	_stop_reason = reason
	recording = false
	set_process(false)
	if _render_measurement_enabled:
		RenderingServer.viewport_set_measure_render_time(_viewport_rid, false)
		_render_measurement_enabled = false
	if is_instance_valid(_world):
		_world.set_performance_capture_enabled(false)
	_unsaved = true
	return save_capture()


func save_capture() -> bool:
	if recording or not _unsaved:
		return false
	_last_summary = _summary()
	var report := {
		"schema": SCHEMA, "complete": true, "metadata": _metadata,
		"duration_ms": float(_stopped_usec - _started_usec) / 1000.0, "stop_reason": _stop_reason,
		"frame_columns": FRAME_COLUMNS, "frames": _frames, "events": _events, "contexts": _contexts,
		"dropped_events": _dropped_events, "summary": _last_summary,
		"tail_partial_interval_ms": float(_stopped_usec - _last_frame_usec) / 1000.0,
		"tail_stage_values": _pending,
	}
	var encoded := JSON.stringify(report)
	var file := FileAccess.open(last_path, FileAccess.WRITE)
	if file == null:
		return _fail("保存失败，录制数据仍在内存中，可重试：%s" % error_string(FileAccess.get_open_error()))
	file.store_string(encoded)
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		return _fail("保存失败，录制数据仍在内存中，可重试：%s" % error_string(error))
	_unsaved = false
	last_error = ""
	state_changed.emit()
	return true


func add_marker(label: String = "卡顿") -> void:
	if not recording:
		return
	marker_count += 1
	_append_event({"kind": "marker", "t_ms": _elapsed_ms(), "label": label.left(120), "number": marker_count})
	state_changed.emit()


func get_capture_status() -> Dictionary:
	return {"recording": recording, "elapsed_s": _elapsed_ms() / 1000.0, "frames": _frames.size(), "markers": marker_count, "path": last_path, "error": last_error, "unsaved": _unsaved, "active_frames": _last_summary.get("active_frames", 0)}


func _process(_delta: float) -> void:
	if not recording:
		return
	var started := Time.get_ticks_usec()
	var current_physics := Engine.get_physics_frames()
	var paused := get_tree().paused
	var focused := get_window().has_focus()
	var row := _pending.duplicate()
	_pending.fill(0.0)
	row[0] = float(started - _started_usec) / 1000.0
	row[1] = Engine.get_process_frames()
	row[2] = float(started - _last_frame_usec) / 1000.0
	row[3] = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	row[4] = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	row[5] = current_physics - _last_physics_frame
	row[6] = RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid) if _render_measurement_enabled else -1.0
	row[7] = RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid) if _render_measurement_enabled else -1.0
	row[8] = RenderingServer.get_frame_setup_time_cpu() if _render_measurement_enabled else -1.0
	row[9] = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	row[10] = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	row[11] = Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	row[12] = 1.0 if paused or _previous_paused else 0.0
	row[13] = 1.0 if focused and _previous_focused and not _focus_transition else 0.0
	_focus_transition = false
	_previous_paused = paused
	_previous_focused = focused
	_last_frame_usec = started
	_last_physics_frame = current_physics
	if started - _last_context_usec >= CONTEXT_PERIOD_USEC:
		_sample_context(started)
		_last_context_usec = started
		state_changed.emit()
	# Attribute the previous callback and intervening signal handlers to the wall
	# interval they occupied. This callback's cost belongs to the following row.
	row[25] = float(_observer_usec) / 1000.0
	_observer_usec = Time.get_ticks_usec() - started
	_frames.append(row)
	if _frames.size() >= MAX_FRAMES or row[0] >= _duration_limit_s * 1000.0:
		stop_capture("frame_limit" if _frames.size() >= MAX_FRAMES else "duration_limit")


func _on_soil_step(sample: Dictionary) -> void:
	if not recording:
		return
	var started := Time.get_ticks_usec()
	for key in STAGE_COLUMNS:
		_pending[STAGE_COLUMNS[key]] += float(sample.get(key, 0)) / 1000.0
	var transaction := sample.get("transaction", {}) as Dictionary
	if not transaction.is_empty():
		_pending[18] += 1
		var event := {"kind": "transaction", "t_ms": float(int(sample.get("ended_usec", started)) - _started_usec) / 1000.0, "process_frame": sample.get("process_frame"), "physics_frame": sample.get("physics_frame")}
		for key in ["generation", "revision", "sequence", "operation", "model_id", "rejection_reason", "accepted_mass_q", "affected_samples", "native_path_count"]:
			event[key] = transaction.get(key)
		for key in TRANSACTION_COLUMNS:
			var elapsed_ms := float(transaction.get(key, 0)) / 1000.0
			_pending[TRANSACTION_COLUMNS[key]] += elapsed_ms
			event[String(key).replace("_usec", "_ms")] = elapsed_ms
		_append_event(event)
	_observer_usec += Time.get_ticks_usec() - started


func _on_focus_transition() -> void:
	if not recording:
		return
	_focus_transition = true
	_append_event({"kind": "focus", "t_ms": _elapsed_ms(), "focused": get_window().has_focus()})


func _sample_context(now_usec: int) -> void:
	if _contexts.size() >= MAX_CONTEXTS:
		return
	var context := _world.get_performance_context() if is_instance_valid(_world) else {"available": false}
	context["t_ms"] = float(now_usec - _started_usec) / 1000.0
	context["process_frame"] = Engine.get_process_frames()
	context["viewport_size"] = [get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y]
	var quality := get_node_or_null("../VisualQualityController") as VisualQualityController
	if quality != null:
		context["visual_quality"] = quality.get_quality_snapshot()
	_contexts.append(context)


func _append_event(event: Dictionary) -> void:
	if _events.size() < MAX_EVENTS:
		_events.append(event)
	else:
		_dropped_events += 1


func _summary() -> Dictionary:
	var intervals: Array[float] = []
	var total_ms := 0.0
	var over_33 := 0
	var over_50 := 0
	var over_100 := 0
	for index in _frames.size():
		var row := _frames[index]
		if index == 0 or row[12] > 0.0 or row[13] < 1.0:
			continue
		intervals.append(row[2])
		total_ms += row[2]
		over_33 += 1 if row[2] > 1000.0 / 30.0 else 0
		over_50 += 1 if row[2] > 50.0 else 0
		over_100 += 1 if row[2] > 100.0 else 0
	intervals.sort()
	return {"active_frames": intervals.size(), "excluded_frames": _frames.size() - intervals.size(), "average_fps": intervals.size() * 1000.0 / total_ms if total_ms > 0.0 else 0.0, "p50_ms": _percentile(intervals, 0.5), "p95_ms": _percentile(intervals, 0.95), "p99_ms": _percentile(intervals, 0.99), "max_ms": intervals[-1] if not intervals.is_empty() else 0.0, "over_33_3_ms": over_33, "over_50_ms": over_50, "over_100_ms": over_100}


func _percentile(values: Array[float], fraction: float) -> float:
	return values[clampi(ceili(values.size() * fraction) - 1, 0, values.size() - 1)] if not values.is_empty() else 0.0


func _elapsed_ms() -> float:
	if _started_usec == 0:
		return 0.0
	return float((Time.get_ticks_usec() if recording else _stopped_usec) - _started_usec) / 1000.0


func _fail(message: String) -> bool:
	last_error = message
	state_changed.emit()
	return false


func _exit_tree() -> void:
	if recording:
		stop_capture("scene_exit")

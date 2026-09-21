extends Control
## Bounded 4 Hz display. Frame peaks retain hitches hidden by average FPS.
const CAPACITY := 40
const WINDOW_USEC := 10000000
const GREEN := Color(0.30, 0.88, 0.68)
const AMBER := Color(1.0, 0.69, 0.30)
const MUTED := Color(0.62, 0.70, 0.78)
var capture: Node
var _history := PackedVector2Array()
var _times := PackedInt64Array()
var _cursor := 0
var _count := 0
var _last_usec := 0
var _elapsed_ms := 0.0
var _frames := 0
var _worst_ms := 0.0
var _was_active := false
var _cpu_ms := 0.0
var _physics_ms := 0.0
var _gpu_ms := -1.0
var _panel_style: StyleBoxFlat

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -376
	offset_right = -16
	offset_top = 52
	offset_bottom = 424
	_history.resize(CAPACITY)
	_times.resize(CAPACITY)
	_panel_style = StyleBoxFlat.new()
	_panel_style.bg_color = Color(0.035, 0.055, 0.075, 0.94)
	_panel_style.set_corner_radius_all(8)
	set_enabled(false)

func _reset_samples() -> void:
	_last_usec = 0
	_elapsed_ms = 0.0
	_frames = 0
	_worst_ms = 0.0
	_count = 0
	_cursor = 0
	_gpu_ms = -1.0

func set_enabled(enabled: bool) -> void:
	visible = enabled
	set_process(enabled)
	_reset_samples()
	if is_instance_valid(capture):
		capture.set_overlay_measurement(enabled)
	queue_redraw()

func _process(_delta: float) -> void:
	_sample_interval(Time.get_ticks_usec(), not get_tree().paused and get_window().has_focus())

func _sample_interval(now: int, active: bool) -> void:
	if active != _was_active:
		_reset_samples()
		_was_active = active
		queue_redraw()
	if not active:
		return
	if _last_usec == 0:
		_last_usec = now
		return
	var interval := (now - _last_usec) / 1000.0
	_last_usec = now
	if interval <= 0.0:
		return
	_elapsed_ms += interval
	_frames += 1
	_worst_ms = maxf(_worst_ms, interval)
	if _elapsed_ms < 250.0:
		return
	_append_sample(Vector2(_frames * 1000.0 / _elapsed_ms, _worst_ms), now)
	_cpu_ms = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	_physics_ms = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_gpu_ms = -1.0
	if is_instance_valid(capture) and capture._render_measurement_enabled:
		_gpu_ms = RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
	_elapsed_ms = 0.0
	_frames = 0
	_worst_ms = 0.0
	queue_redraw()

func _append_sample(value: Vector2, now: int) -> void:
	_history[_cursor] = value
	_times[_cursor] = now
	_cursor = (_cursor + 1) % CAPACITY
	_count = mini(_count + 1, CAPACITY)
	while _count > 0 and now - _times[(_cursor - _count + CAPACITY) % CAPACITY] >= WINDOW_USEC:
		_count -= 1

func window_stats() -> Vector2:
	if _count == 0:
		return Vector2.ZERO
	var minimum := INF
	var peak := 0.0
	for i in _count:
		var value := _history[(_cursor - _count + i + CAPACITY) % CAPACITY]
		minimum = minf(minimum, value.x)
		peak = maxf(peak, value.y)
	return Vector2(minimum, peak)

func _text(position: Vector2, text: String, font_size: int = 12, color: Color = Color.WHITE) -> void:
	draw_string(ThemeDB.fallback_font, position, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _draw() -> void:
	draw_style_box(_panel_style, Rect2(Vector2.ZERO, size))
	var latest := _history[(_cursor - 1 + CAPACITY) % CAPACITY] if _count > 0 else Vector2.ZERO
	var stats := window_stats()
	_text(Vector2(16, 23), "性能监测", 13)
	_text(Vector2(214, 23), "实时 · 每 0.25 秒更新" if _was_active else "暂停 / 后台 · 停止采样", 11, MUTED)
	_text(Vector2(16, 63), "%.0f" % latest.x if _count > 0 else "—", 34, GREEN)
	_text(Vector2(106, 62), "FPS", 13, MUTED)
	_text(Vector2(193, 49), "当前平均帧时间", 11, MUTED)
	_text(Vector2(193, 70), "%.1f ms" % (1000.0 / latest.x) if latest.x > 0.0 else "—", 20)
	draw_line(Vector2(16, 84), Vector2(344, 84), Color(0.22, 0.28, 0.34))
	_text(Vector2(16, 104), "近 10 秒最低 FPS", 12, MUTED)
	_text(Vector2(193, 104), "近 10 秒最大帧时间", 12, MUTED)
	_text(Vector2(16, 132), "%.1f" % stats.x if _count > 0 else "—", 24, GREEN)
	_text(Vector2(193, 132), "%.1f ms" % stats.y if _count > 0 else "—", 24, AMBER)
	_text(Vector2(16, 149), "按 0.25 秒均值统计", 10, MUTED)
	_text(Vector2(193, 149), "保留单帧卡顿尖峰", 10, MUTED)
	_text(Vector2(16, 171), "FPS 趋势 · 越高越好", 11, GREEN)
	_graph(Rect2(16, 180, 283, 43), true, 60.0, GREEN)
	_text(Vector2(16, 244), "帧时间峰值 · 越低越好", 11, AMBER)
	_graph(Rect2(16, 253, 283, 43), false, 33.333, AMBER)
	_text(Vector2(16, 310), "−10 s", 10, MUTED)
	_text(Vector2(271, 310), "现在", 10, MUTED)
	_text(Vector2(16, 333), "CPU 帧  %s    物理单步  %s    GPU  %s" % ["%.1f" % _cpu_ms if _count > 0 else "—", "%.1f" % _physics_ms if _count > 0 else "—", "%.1f" % _gpu_ms if _gpu_ms > 0.0 else "—"], 11)
	_text(Vector2(16, 354), "耗时单位 ms · 帧时间含等待 · 各项不可相加", 10, MUTED)

func _graph(rect: Rect2, fps: bool, reference: float, color: Color) -> void:
	var ceiling := reference * 1.4
	for i in _count:
		var value := _history[(_cursor - _count + i + CAPACITY) % CAPACITY]
		ceiling = maxf(ceiling, value.x if fps else value.y)
	var y := rect.end.y - reference / ceiling * rect.size.y
	draw_rect(rect, Color(0.02, 0.035, 0.05, 0.6))
	draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y), Color(0.4, 0.45, 0.5, 0.5))
	_text(Vector2(rect.end.x + 5, y + 4), "60" if fps else "33.3", 10, MUTED)
	var points := PackedVector2Array()
	var newest := _times[(_cursor - 1 + CAPACITY) % CAPACITY] if _count > 0 else 0
	for i in _count:
		var index := (_cursor - _count + i + CAPACITY) % CAPACITY
		var value := _history[index]
		var age := float(newest - _times[index]) / WINDOW_USEC
		points.append(Vector2(rect.end.x - age * rect.size.x, rect.end.y - (value.x if fps else value.y) / ceiling * rect.size.y))
	if points.size() > 1:
		draw_polyline(points, color, 1.5, true)
	if not points.is_empty():
		draw_circle(points[-1], 2.0, color)

func _exit_tree() -> void:
	if is_instance_valid(capture) and capture.is_inside_tree():
		capture.set_overlay_measurement(false)

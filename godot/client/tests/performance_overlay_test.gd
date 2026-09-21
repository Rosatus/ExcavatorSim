extends SceneTree
var failures: Array[String] = []
func _init() -> void:
	call_deferred("_run")
func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
func _run() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	var ui: Node = scene.get_node("OperatorUI")
	var overlay: Control = ui._performance_overlay
	var capture: Node = scene.get_node("PerformanceCapture")
	check(ui.find_child("PerformanceOverlayToggle", true, false) != null, "advanced menu toggle exists")
	overlay.set_enabled(true)
	check(overlay.visible and overlay.is_processing() and capture.overlay_measurement, "HUD owns sampling only while enabled")
	for resolution in [Vector2i(1280,720), Vector2i(1920,1080)]:
		root.size = resolution
		root.content_scale_size = resolution
		await process_frame
		check(Rect2(Vector2.ZERO, Vector2(resolution)).encloses(overlay.get_global_rect()), "HUD fits viewport")
	overlay.set_process(false)
	overlay._reset_samples()
	overlay._was_active = true
	for i in 100:
		overlay._append_sample(Vector2(60, 17), 1000000 + i * 250000)
	check(overlay._count == 40 and overlay._history.size() == 40, "history remains bounded")
	overlay._append_sample(Vector2(30, 80), 26000000)
	check(overlay.window_stats() == Vector2(30, 80), "window retains minimum average FPS and single-frame maximum")
	overlay._append_sample(Vector2(55, 20), 36250000)
	check(overlay._count == 1 and overlay.window_stats() == Vector2(55, 20), "old spike expires by time rather than sample count")
	overlay._sample_interval(37000000, false)
	check(overlay._count == 0, "background clears stale driving readings")
	overlay._sample_interval(47000000, false)
	overlay._sample_interval(48000000, true)
	check(overlay._count == 0, "return to foreground does not record focus gap")
	for i in range(1, 26):
		overlay._sample_interval(48000000 + i * 10000, true)
	check(overlay.window_stats().is_equal_approx(Vector2(100, 10)), "fresh foreground samples exclude background duration")
	overlay.set_process(true)
	check(overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE, "HUD does not steal camera input")
	check(capture.start_capture("res://../../output/performance-overlay/lifecycle-test"), "capture can start alongside HUD")
	capture.stop_capture()
	check(capture.overlay_measurement and overlay.is_processing(), "capture stop keeps HUD running")
	check(capture.start_capture("res://../../output/performance-overlay/lifecycle-test"), "second capture starts")
	overlay.set_enabled(false)
	check(overlay.window_stats() == Vector2.ZERO, "reset has no stale readings")
	check(capture.recording, "HUD off preserves recording")
	capture.stop_capture()
	check(not overlay.visible and not overlay.is_processing() and not capture.overlay_measurement, "HUD off stops sampling")
	scene.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	print("PERFORMANCE_OVERLAY ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)


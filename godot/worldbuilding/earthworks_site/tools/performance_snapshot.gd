extends SceneTree

var frames: Array[float] = []


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var scene := load("res://scenes/earthworks_site_workbench.tscn") as PackedScene
	var world := scene.instantiate() as Node3D
	root.add_child(world)
	current_scene = world
	(world.get_node("ReviewCamera") as Camera3D).call("jump_to", "OverviewCamera")
	for frame in 240:
		await process_frame
	var previous := Time.get_ticks_usec()
	for frame in 180:
		await process_frame
		var now := Time.get_ticks_usec()
		frames.append(float(now - previous) / 1000.0)
		previous = now
	frames.sort()
	var result := {"scope":"one stationary overview; no vehicle or digging workload", "renderer":RenderingServer.get_current_rendering_method(), "adapter":RenderingServer.get_video_adapter_name(), "viewport":root.size, "fps":Performance.get_monitor(Performance.TIME_FPS), "frame_p50_ms":frames[90], "frame_p95_ms":frames[171], "draw_calls":Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), "render_objects":Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME), "primitives":Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME), "video_memory_bytes":Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)}
	var file := FileAccess.open("res://artifacts/performance_snapshot.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "  "))
	file.close()
	print("PERFORMANCE_SNAPSHOT ", JSON.stringify(result))
	world.queue_free()
	await process_frame
	quit()

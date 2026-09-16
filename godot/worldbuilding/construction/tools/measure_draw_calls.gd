extends SceneTree
## Renders the construction map preview at fixed camera poses and reports
## draw-call counts, so perf changes are measured against a stable baseline.
## Usage: godot --path . --script res://tools/measure_draw_calls.gd

const OUT_DIR := "E:/projects/ExcavatorSim/artifacts/construction-map/mcp-capture"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var packed := load("res://preview.tscn") as PackedScene
	var scene := packed.instantiate()
	root.add_child(scene)
	for i in 150:
		await process_frame
	var cam := root.get_viewport().get_camera_3d()
	if cam == null:
		print("MEASURE no camera")
		quit(1)
		return
	cam.current = true
	# Ground-level pose, same as the mcp-capture screenshot series.
	cam.position = Vector3(38.3, 2.6, 18.0)
	cam.look_at(Vector3(38.3, 1.2, 56.0), Vector3.UP)
	cam.fov = 70.0
	for i in 30:
		await process_frame
	await RenderingServer.frame_post_draw
	print("MEASURE ground draw_calls=%d primitives=%d" % [
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)])
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(OUT_DIR + "/measure-ground.png")
	# Shadow-pass breakdown: same pose with the sun shadow disabled.
	var we := scene.get_node_or_null("Map/WorldEnvironment")
	var sun: DirectionalLight3D = null
	if we != null:
		sun = we.get_node_or_null("SunLight") as DirectionalLight3D
	var shadow_was := false
	if sun != null:
		shadow_was = sun.shadow_enabled
		sun.shadow_enabled = false
		for i in 10:
			await process_frame
		await RenderingServer.frame_post_draw
		print("MEASURE ground_noshadow draw_calls=%d primitives=%d" % [
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)])
		if sun != null:
			sun.shadow_enabled = shadow_was
	# Shadow-distance variant: production balanced uses 55 m, workbench default is 100 m.
	if sun != null:
		sun.shadow_enabled = shadow_was
		sun.directional_shadow_max_distance = 55.0
		for i in 10:
			await process_frame
		await RenderingServer.frame_post_draw
		print("MEASURE ground_shadow55 draw_calls=%d primitives=%d" % [
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)])
	# Overview pose.
	cam.position = Vector3(100, 110, 150)
	cam.rotation_degrees = Vector3(-30, 28, 0)
	cam.fov = 75.0
	for i in 30:
		await process_frame
	await RenderingServer.frame_post_draw
	print("MEASURE overview draw_calls=%d primitives=%d" % [
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)])
	quit(0)

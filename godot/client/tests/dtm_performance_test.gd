extends SceneTree

const Sampler := preload("res://scripts/dtm_surface_sampler.gd")
const Model := preload("res://scripts/dtm_model.gd")
var failures: Array[String] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	root.get_node("MapCatalog").active_map_id = "training"
	root.get_node("MapCatalog").retained_model_id = "sy135"
	var scene: Node3D = load("res://scenes/main.tscn").instantiate()
	scene.get_node("OperatorUI").preferences_path = "user://dtm-perf-unused.cfg"
	root.add_child(scene)
	current_scene = scene
	await process_frame
	var zone: VoxelWorkZone = scene.get_node("TerrainRoot/VoxelWorkZone")
	var sampler := Sampler.new()
	sampler.zone = zone
	var center: Vector3 = zone.layout.ORIGIN_WORLD
	for i in 600:
		await physics_frame
		if is_finite(sampler.height_at(Vector2(center.x, center.z))):
			break
	var points: Array[Vector2] = []
	for z in 24:
		for x in 24:
			points.append(Vector2(center.x - 3 + (x + 0.5) * 0.25, center.z - 3 + (z + 0.5) * 0.25))
	var started := Time.get_ticks_usec()
	for point in points:
		sampler.height_at(point)
	print("DTM_PERF grid576_usec=", Time.get_ticks_usec() - started)
	var ui = scene.get_node("OperatorUI")
	var dashboard = ui._dtm
	ui._dtm_open = true
	ui._sync_dtm_visibility()
	dashboard.show()
	dashboard.load_demo("pit")
	dashboard.set_process(false)
	started = Time.get_ticks_usec()
	for i in 120:
		dashboard._process(1.0 / 60)
	print("DTM_PERF dashboard120_usec=", Time.get_ticks_usec() - started, " samples=", dashboard.model.samples.size(), " visible=", dashboard.is_visible_in_tree())
	# Measure actual draw callbacks separately from scene simulation and GPU work.
	var draw_usec := 0
	for i in 30:
		for view in dashboard.views:
			view.queue_redraw()
		await process_frame
		for view in dashboard.views:
			draw_usec += view.last_draw_usec
	print("DTM_PERF draw30_usec=", draw_usec)
	for view in [dashboard.views[0], dashboard.views[1]]:
		if view.mesh_build_count != 1:
			failures.append("unchanged cells rebuilt on redraw: " + view.mode)
		var arrays: Array = view._cells_mesh.surface_get_arrays(0)
		# ArrayMesh stores vertex colors at 8-bit channel precision.
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		if colors.size() != 576 * 4 or absf(colors[0].a - (0.48 if view.mode == "plan" else 1.0)) > 1.0 / 255.0:
			failures.append("cached mesh changed cell count/opacity: " + view.mode)
	# Deterministic section motion/revision probes do not move the machine.
	dashboard._bucket = {"tooth": center + Vector3(0, 1, 0), "axis": Vector2(0, 1), "width": 1.0}
	dashboard._profile_cursor = 49
	dashboard.views[3].profile.clear()
	var section_frames := 0
	for i in 20:
		dashboard._sample_local_profile_step()
		section_frames += 1
		if dashboard._profile_cursor == 49:
			break
	print("DTM_PERF section_frames=", section_frames, " section_latency_ms=", dashboard.profile_latency_ms)
	if dashboard.views[3].profile.size() != 49:
		failures.append("section never published")
	var count: int = dashboard.profile_sample_count
	for i in 20:
		dashboard._sample_local_profile_step()
	if dashboard.profile_sample_count != count:
		failures.append("stationary known section was resampled")
	dashboard._bucket.tooth.y += 0.5
	dashboard._sample_local_profile_step()
	if dashboard.profile_sample_count != count:
		failures.append("vertical-only motion unnecessarily resampled horizontal SDF")
	dashboard._bucket.tooth.x += 0.2
	dashboard._sample_local_profile_step()
	if dashboard.profile_sample_count == count:
		failures.append("horizontal motion did not immediately start sampling")
	# Whole-area publication must not delay the changed local heatmap.
	var measurement := Model.new()
	measurement.sampler.zone = zone
	measurement.set_surface(dashboard.model.surface)
	measurement.focus_xz = Vector2(center.x, center.z)
	var identity := {"world_generation": 0, "authority_generation": 0, "data_revision": 0}
	measurement.identity_provider = func() -> Dictionary: return identity
	var grid_frames := 0
	for i in 300:
		measurement.update()
		grid_frames += 1
		if measurement.sampled_at_ms > 0:
			break
	print("DTM_PERF grid_frames=", grid_frames)
	if measurement.sampled_at_ms == 0:
		failures.append("grid never completed")
	var display_revision: int = measurement.display_revision
	for i in 5:
		measurement.update()
	if measurement.display_revision != display_revision:
		failures.append("unchanged complete grid was resampled")
	var tool := zone.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	tool.mode = VoxelTool.MODE_REMOVE
	tool.do_sphere(zone.layout.world_to_voxel(center, zone.voxel_scale_m), 1.0 / zone.voxel_scale_m)
	identity.data_revision += 1
	measurement.update()
	if measurement.display_revision <= display_revision or not measurement.sampling:
		failures.append("changed terrain not published progressively")
	if measurement.cached_height(Vector2(center.x, center.z)) > -0.5:
		failures.append("active work face not sampled before the distant grid")
	if measurement.sampled_revision != 0:
		failures.append("partial sweep incorrectly reported complete")
	identity.authority_generation += 1
	measurement.update()
	if not measurement.samples.is_empty():
		failures.append("authority reset retained old samples")
	dashboard.model.set_surface(null)
	dashboard._refresh_profiles()
	dashboard._sample_local_profile_step()
	if not dashboard.views[2].profile.is_empty() or not dashboard.views[3].profile.is_empty():
		failures.append("removed design retained section data")
	for failure in failures:
		push_error(failure)
	print("DTM_PERF_TEST ", "PASS" if failures.is_empty() else "FAIL")
	scene.queue_free()
	await process_frame
	await physics_frame
	quit(0 if failures.is_empty() else 1)

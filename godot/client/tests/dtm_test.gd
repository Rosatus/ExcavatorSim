extends SceneTree

const Surface := preload("res://scripts/landxml_surface.gd")
const Model := preload("res://scripts/dtm_model.gd")
const Sampler := preload("res://scripts/dtm_surface_sampler.gd")
const View := preload("res://scripts/dtm_view.gd")
var failures: Array[String] = []

func _init() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)

func parser_tests() -> void:
	check(View.stepped_color(NAN) == View.UNKNOWN, "voxel missing measurement stays unknown")
	check(View.stepped_color(-0.05) == View.GRADE and View.stepped_color(0.05) == View.GRADE, "voxel tolerance remains five centimetres")
	check(View.stepped_color(0.06) == View.stepped_color(0.19) and View.stepped_color(0.21) != View.stepped_color(0.19), "voxel fixed bands do not normalize with terrain")
	check(View.stepped_color(3.01) == View.stepped_color(20) and View.stepped_color(-0.6) != View.stepped_color(0.6), "voxel saturation and cut/fill signs")
	check(View.difference_color(0.05) == View.GRADE and View.difference_color(-0.05) == View.GRADE, "both tolerance edges remain on-grade")
	check(View.difference_color(0.2) != View.difference_color(0.6) and View.difference_color(-0.6) != View.difference_color(0.6), "depth and cut/fill have distinct colors")
	check(View.difference_color(3) == View.difference_color(20), "fixed color range saturates beyond three metres")
	for path in ["res://resources/dtm/training-pit.xml", "res://resources/dtm/training-trench-sy135.xml"]:
		check(Surface.load_file(path).get("error", "missing") == "", "bundled XML import " + path)
	var xml := Model.demo_xml("pit", Vector3(0, 0, 24), 1.2)
	var parsed := Surface.parse(xml)
	check(parsed.error == "", "pit parses")
	if not parsed.has("surfaces"):
		return
	var pit: Surface = parsed.surfaces[0]
	check(is_equal_approx(pit.height_at(Vector2(0, 24)), -1.5), "pit center elevation")
	check(is_nan(pit.height_at(Vector2(4, 24))), "no extrapolation outside footprint")
	var trench: Surface = Surface.parse(Model.demo_xml("trench", Vector3(0, 0, 24), 1.37)).surfaces[0]
	check(is_equal_approx(trench.bounds.size.x, 1.37) and is_equal_approx(trench.bounds.size.z, 12), "single bucket width trench")
	for bad in [xml.replace('linearUnit="meter"', 'linearUnit="foot"'), xml.replace("1 2 3</F>", "1 2 999</F>"), xml.replace('id="2"', 'id="1"'), xml.replace("</LandXML>", ""), xml.replace('surfType="TIN"', 'surfType="Grid"'), xml.replace("1 2 3</F>", "1 1 3</F>"), xml.replace("1 2 3</F>", "1 2 3 4</F>")]:
		check(not String(Surface.parse(bad).get("error", "")).is_empty(), "reject malformed/unsupported TIN")
	var triangle := '<?xml version="1.0"?><LandXML><Units><Metric linearUnit="meter"/></Units><Surfaces><Surface name="grade"><Definition surfType="TIN"><Pnts><P id="1">0 0 0</P><P id="2">0 2 2</P><P id="3">2 0 0</P></Pnts><Faces><F>1 2 3</F></Faces></Definition></Surface></Surfaces></LandXML>'
	var grade: Surface = Surface.parse(triangle).surfaces[0]
	check(is_equal_approx(grade.height_at(Vector2(0.5, 0.5)), 0.5), "barycentric sloped TIN interpolation")
	check(is_nan(grade.height_at(Vector2(1.8, 1.8))), "inside bounds outside triangle is unknown")
	var geo: Surface = Surface.parse(Model.demo_xml("trench", Vector3(500000, 120, 4000000), 1.37)).surfaces[0]
	check(absf(geo.bounds.size.x - 1.37) < 0.00001, "georeferenced width preserved before float32 conversion")
	var stats := Model.summarize(PackedFloat32Array([-1.0, 0.0, 0.0, 0.0, NAN]), PackedFloat32Array([0.0, -0.4, 0.02, NAN, 1.0]), 0.25)
	check(is_equal_approx(stats.cut_m3, 0.255) and is_equal_approx(stats.fill_m3, 0.1), "signed cut/fill integration")
	check(stats.valid == 3 and is_equal_approx(stats.coverage, 0.75), "unknown excluded from quantities and exposed as coverage")
	check(is_equal_approx(stats.on_grade, 1.0 / 3), "on-grade coverage counts only valid measurements")
	check(not Surface.parse(xml.replace('<Definition surfType="TIN">', '').replace('</Definition>', '')).error.is_empty(), "missing TIN definition rejected")
	check(not Surface.parse(xml.replace('<Units>', '').replace('</Units>', '')).error.is_empty(), "misplaced unit declaration rejected")
	check(not Surface.parse(xml.replace('<Faces>', '<Boundaries/><Faces>')).error.is_empty(), "unsupported boundary cannot silently enlarge design footprint")
	var extent := Vector3(10000000, 0, 20000000)
	check(maxf(extent.x, extent.z) / View.grid_step_for(extent) <= 20, "large survey grid drawing work bounded")
	var rect := Rect2(10, 20, 100, 80)
	var segment := View.clip_segment(Vector2(50, -1000), Vector2(50, 1000), rect)
	check(segment.size() == 2 and segment[0].is_equal_approx(Vector2(50, 20)) and segment[1].is_equal_approx(Vector2(50, 100)), "out-of-range profile clipped away from title/footer")
	check(View.clip_segment(Vector2(-10, 30), Vector2(-10, 40), rect).is_empty(), "fully outside profile omitted")

func run() -> void:
	parser_tests()
	root.get_node("MapCatalog").active_map_id = "training"
	root.get_node("MapCatalog").retained_model_id = "sy135"
	var scene := load("res://scenes/main.tscn").instantiate() as Node3D
	scene.get_node("OperatorUI").preferences_path = "user://dtm-test-unused.cfg"
	root.add_child(scene)
	current_scene = scene
	await process_frame
	var ui := scene.get_node("OperatorUI") as MotionOperatorUI
	var zone := scene.get_node("TerrainRoot/VoxelWorkZone") as VoxelWorkZone
	var sampler := Sampler.new()
	sampler.zone = zone
	var center: Vector3 = zone.layout.ORIGIN_WORLD
	var xz := Vector2(center.x, center.z)
	for i in 600:
		await physics_frame
		if is_finite(sampler.height_at(xz)):
			break
	var initial := sampler.height_at(xz)
	check(is_finite(initial) and absf(initial) < 0.03, "actual initial SDF surface")
	check(is_nan(sampler.height_at(Vector2(500, 500))), "outside voxel domain unknown")
	var shortcut := InputEventKey.new()
	shortcut.pressed = true
	shortcut.keycode = KEY_F9
	ui._input(shortcut)
	check(not ui._dtm.visible, "F9 no longer toggles DTM")
	shortcut.keycode = KEY_P
	ui._input(shortcut)
	check(ui._dtm.visible and not paused, "dashboard nonmodal while operating")
	check(ui._dtm.views.size() == 4, "four coordinated views")
	check(ui._advanced_panel.is_ancestor_of(ui._dtm_toggle) and not ui._dtm_toggle.is_visible_in_tree(), "DTM entry is only in advanced tools, absent from driving screen")
	for i in 300:
		await process_frame
		if ui._dtm.model.sampled_at_ms > 0:
			break
	check(int(ui._dtm.model.statistics.get("valid", 0)) > 0, "live actual samples available")
	check(absf(float(ui._dtm.model.statistics.get("cut_m3", 0)) - 54) < 1, "6x6x1.5 pit estimated cut")
	var original_statistics: Dictionary = ui._dtm.model.statistics.duplicate(true)
	var original_revision: int = ui._dtm.model.display_revision
	ui._dtm.set_chart_style(View.STYLE_TERRAIN)
	ui._dtm.controls.style.pressed.emit()
	check(ui._dtm.chart_style == View.STYLE_VOXEL and ui._dtm._legend.voxel, "style button switches charts and legend")
	check(ui._dtm.model.statistics == original_statistics and ui._dtm.model.display_revision == original_revision, "style switch preserves measurement and volumes")
	var saved := ConfigFile.new()
	saved.load(ui.preferences_path)
	check(saved.get_value("ui", "dtm_chart_style", "") == View.STYLE_VOXEL, "chart choice persisted")
	for resolution in [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(2560, 1080)]:
		root.size = resolution
		ui._dtm.layout_dashboard()
		await process_frame
		await process_frame
		var available := Rect2(Vector2.ZERO, root.get_visible_rect().size)
		check(available.encloses(ui._dtm.get_global_rect()), "DTM fits viewport %s: %s" % [resolution, ui._dtm.get_global_rect()])
		for view in ui._dtm.views:
			check(ui._dtm.get_global_rect().encloses(view.get_global_rect()), "view contained " + view.mode)
		var selected_surface = ui._dtm.model.surface
		ui._dtm.controls.mode.pressed.emit()
		await process_frame
		await process_frame
		check(ui._dtm.hud_mode and not paused, "HUD mode is nonmodal")
		check(ui._dtm.model.surface == selected_surface, "mode switch preserves selected design")
		check(available.encloses(ui._dtm.get_global_rect()) and ui._dtm.size.x <= 381, "narrow right HUD fits " + str(resolution))
		var previous_bottom := 0.0
		for view in ui._dtm.views:
			var rect := view.get_global_rect()
			check(view.compact and ui._dtm.get_global_rect().encloses(rect), "compact view contained " + view.mode)
			check(rect.position.y >= previous_bottom, "HUD charts stacked without overlap")
			previous_bottom = rect.end.y
		check(ui._dtm._hud_metrics.is_visible_in_tree() and ui._dtm._hud_values[0].text.contains("m³") and ui._dtm._hud_values[2].text.contains("%"), "HUD exposes cut fill and on-grade metrics")
		ui._input(shortcut)
		ui._input(shortcut)
		check(ui._dtm.visible and ui._dtm.hud_mode, "P hide/show preserves HUD selection")
		ui._dtm.controls.mode.pressed.emit()
		await process_frame
		await process_frame
		check(not ui._dtm.hud_mode and ui._dtm.views[0].get_parent() == ui._dtm.views[1].get_parent(), "restore floating two-column layout")
	root.size = Vector2i(1280, 720)
	for variant in ["industrial", "sany"]:
		ui.set_ui_theme_for_test(variant)
		check(ui._dtm.chart_style == View.STYLE_VOXEL, "application skin preserves chart style")
		await process_frame
		await process_frame
		check(Rect2(Vector2.ZERO, root.get_visible_rect().size).encloses(ui._dtm.get_global_rect()), "DTM theme bounds " + variant)
		ui._dtm.set_hud_mode(true)
		await process_frame
		await process_frame
		check(Rect2(Vector2.ZERO, root.get_visible_rect().size).encloses(ui._dtm.get_global_rect()), "HUD theme bounds " + variant)
		check(ui._dtm.get_theme_stylebox("panel") is StyleBoxEmpty, "HUD has no opaque outer panel")
		ui._dtm.set_hud_mode(false)
		ui._dtm_open = false
		ui._set_panel_collapsed(false)
		check(ui._advanced_panel.is_ancestor_of(ui._dtm_toggle), "advanced DTM entry survives theme rebuild")
		ui._dtm_toggle.pressed.emit()
		check(ui._dtm.visible and ui._panel_collapsed and not paused, "advanced entry opens DTM and resumes through menu ownership")
	ui._dtm.controls.style.pressed.emit()
	check(ui._dtm.chart_style == View.STYLE_TERRAIN and not ui._dtm._legend.voxel, "restore terrain charts and legend")
	ui._open_dtm_import()
	check(paused and not ui._panel_collapsed and ui._dtm_file.visible, "file dialog pauses through existing menu")
	ui._finish_dtm_import()
	check(not paused and ui._panel_collapsed and ui._dtm.visible, "cancel import restores prior running state")
	ui._set_panel_collapsed(false)
	ui._open_dtm_import()
	ui._finish_dtm_import()
	check(paused and not ui._panel_collapsed, "import does not unpause preexisting menu")
	ui._set_panel_collapsed(true)
	check(ui._dtm.load_demo("trench"), "load demo trench")
	var bucket := Model.bucket_state(scene.get_node("MotionPresentation"))
	check(absf(ui._dtm.model.surface.bounds.size.x - bucket.width) < 0.00001, "demo width follows actual attachment contract")
	var upper := (scene.get_node("MotionPresentation") as MotionPresentation).get_frame_node("upper_structure_link")
	var outward: Vector3 = bucket.tooth - upper.global_position
	check((bucket.axis as Vector2).dot(Vector2(outward.x, outward.z)) > 0, "bucket profile positive direction points outward")
	var file := FileAccess.open("user://dtm-test.xml", FileAccess.WRITE)
	file.store_string(Model.demo_xml("pit", Vector3(500, 10, 900), 1.0))
	file.close()
	check(ui._dtm.import_file("user://dtm-test.xml", true, -10), "import real LandXML file")
	check(absf(ui._dtm.model.surface.height_at(xz) + 1.5) < 0.00001, "explicit center and elevation offset")
	# Controlled test edit through the same VoxelTool SDF the production cutter
	# writes. DTM itself never edits terrain or waits for collider rebuilds.
	var tool := zone.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	tool.mode = VoxelTool.MODE_REMOVE
	tool.do_sphere(zone.layout.world_to_voxel(center, zone.voxel_scale_m), 1.0 / zone.voxel_scale_m)
	zone.issue_edit_ticket(AABB(zone.layout.world_to_voxel(center - Vector3.ONE, zone.voxel_scale_m), Vector3.ONE * 2 / zone.voxel_scale_m), &"dtm_test")
	var cut := sampler.height_at(xz)
	check(is_finite(cut) and cut < initial - 0.8, "DTM observes excavated SDF immediately, not initial heightfield")
	# Batched row/section reads must equal the scalar column search, including
	# the dug bowl, its rim and points outside the voxel domain.
	var probe := PackedVector2Array()
	for k in 61:
		probe.append(xz + Vector2(-1.9 + k * 0.0637, 0.31 - k * 0.0217))
	probe.append(Vector2(500, 500))
	var batched := sampler.heights_at(probe)
	var batch_ok := true
	for k in probe.size():
		var scalar := sampler.height_at(probe[k])
		if is_finite(scalar) != is_finite(batched[k]) or (is_finite(scalar) and absf(scalar - batched[k]) > 0.0001):
			batch_ok = false
	check(batch_ok, "batched SDF heights equal scalar sampler")
	ui._dtm.model.invalidate()
	for i in 300:
		await process_frame
		if ui._dtm.model.sampled_at_ms > 0:
			break
	check(float(ui._dtm.model.statistics.get("cut_m3", 54)) < 53, "cut updates target difference and remaining volume")

	zone.reset_zone()
	ui._dtm.model.update()
	check(ui._dtm.model.is_empty(), "reset discards old generation samples immediately")
	for i in 600:
		await physics_frame
		if is_finite(sampler.height_at(xz)):
			break
	check(absf(sampler.height_at(xz) - initial) < 0.03, "reset measures fresh flat SDF")
	ui._dtm.load_demo("trench")
	var session := scene.get_node("ProductSession") as ProductSession
	check(session.request_model_switch("sy155w"), "model switch for attachment-width invalidation")
	for i in 12:
		await process_frame
		await physics_frame
	var next_bucket := Model.bucket_state(scene.get_node("MotionPresentation"))
	check(absf(ui._dtm.model.surface.bounds.size.x - next_bucket.width) < 0.00001, "trench refreshes after actual machine/attachment change")
	check(not is_equal_approx(bucket.width, next_bucket.width), "test exercises different effective bucket widths")
	print("DTM_RESULT initial=", initial, " cut=", cut, " bucket_width=", bucket.width, " failures=", failures.size())
	ui._dtm_open = false
	ui._sync_dtm_visibility()
	scene.queue_free()
	await process_frame
	await physics_frame
	for failure in failures:
		push_error(failure)
	print("DTM_TEST ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

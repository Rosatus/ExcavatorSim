extends SceneTree
## Real-frame Terrain3D compatibility probe for Godot 4.7 Forward+/D3D12.
##
## This runner intentionally builds the production terrain seams without the
## excavator, HUD, Sky3D, or site dressing. It compares each native frame with
## an otherwise identical frame where only Terrain3D is hidden, so sky/UI pixels
## cannot make a black or missing terrain surface pass.

const OUTPUT_ARG := "--output-dir"
const WIDTH := 960
const HEIGHT := 540
const WARMUP_FRAMES := 180
const VARIANT_FRAMES := 45
const WORKSITE_MATERIAL := "res://assets/terrain/terrain3d_worksite_material.tres"

var _output_dir := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_output_dir = _parse_output_dir()
	if _output_dir.is_empty():
		push_error("Terrain3D probe requires --output-dir <absolute path>")
		quit(2)
		return
	if DirAccess.make_dir_recursive_absolute(_output_dir) != OK:
		push_error("Terrain3D probe could not create output directory: %s" % _output_dir)
		quit(2)
		return
	root.size = Vector2i(WIDTH, HEIGHT)
	var rig := _build_rig(WORKSITE_MATERIAL)
	root.add_child(rig["scene"])
	var adapter := rig["adapter"] as Terrain3DAdapter
	var world := rig["world"] as TerrainWorld
	var fallback := rig["fallback"] as TerrainRenderer
	var foundation := rig["foundation"] as MeshInstance3D
	var authority_before := _authority_fingerprint_from_rig(world)
	for _frame in WARMUP_FRAMES:
		if adapter.available and adapter.is_native_mesh_active():
			break
		await process_frame
	for _frame in VARIANT_FRAMES:
		await process_frame
	var status := adapter.get_status_snapshot()
	var fallback_visible_during_native := fallback.visible
	var foundation_visible_during_native := foundation.visible
	var native := adapter.get_node_or_null("Terrain3DNative") as Node3D
	var dressing := adapter.get_node_or_null("ConstructionSiteDressing") as Node3D
	if dressing != null:
		dressing.visible = false
	var frames := {}
	frames["worksite_native_before"] = await _capture("worksite_native_before")
	var mouse_quad := native.find_child("MouseQuad", true, false) as MeshInstance3D if native != null else null
	if mouse_quad != null:
		mouse_quad.visible = false
		for _frame in VARIANT_FRAMES:
			await process_frame
	frames["worksite_mouse_quad_hidden"] = await _capture("worksite_mouse_quad_hidden")
	adapter.deactivate_native_for_test()
	for _frame in VARIANT_FRAMES:
		await process_frame
	frames["worksite_fallback_before"] = await _capture("worksite_fallback_before")
	var fallback_before_visible := fallback.visible and foundation.visible
	_reactivate_native(adapter)
	for _frame in VARIANT_FRAMES:
		await process_frame
	var state := world.terrain_state
	if not state.enqueue_brush(state.next_brush_sequence(), Vector2.ZERO, 1.35, 0.16) \
			or not state.step_fixed() or not world.rebuild_mesh():
		push_error("Terrain3D probe could not apply the deformation fixture")
		rig["scene"].queue_free()
		quit(1)
		return
	for _frame in VARIANT_FRAMES:
		await process_frame
	frames["worksite_native_after"] = await _capture("worksite_native_after")
	var authority_after_deformation := _authority_fingerprint_from_rig(world)
	adapter.deactivate_native_for_test()
	for _frame in VARIANT_FRAMES:
		await process_frame
	frames["worksite_fallback_after"] = await _capture("worksite_fallback_after")
	var fallback_after_visible := fallback.visible and foundation.visible
	fallback.visible = false
	foundation.visible = false
	for _frame in VARIANT_FRAMES:
		await process_frame
	var absent := await _capture("terrain_absent")
	var variants := {}
	for variant_name in frames:
		variants[variant_name] = _compare_surface_to_absent(frames[variant_name], absent)
	var native_deformation := _compare_frames(
		frames["worksite_mouse_quad_hidden"],
		frames["worksite_native_after"]
	)
	var fallback_deformation := _compare_frames(
		frames["worksite_fallback_before"],
		frames["worksite_fallback_after"]
	)
	var native_fallback_after := _compare_frames(
		frames["worksite_native_after"],
		frames["worksite_fallback_after"]
	)
	var logical_snapshot: Dictionary = world.terrain_state.surface_snapshot()
	var height_range := _surface_range(logical_snapshot["surface"] as PackedFloat32Array)
	var authority_after_capture := _authority_fingerprint_from_rig(world)
	var failure := await _run_deliberate_material_failure()
	var native_before_pass := bool((variants.get("worksite_native_before", {}) as Dictionary).get("pass", false))
	var native_after_pass := bool((variants.get("worksite_native_after", {}) as Dictionary).get("pass", false))
	var fallback_before_pass := bool((variants.get("worksite_fallback_before", {}) as Dictionary).get("pass", false))
	var fallback_after_pass := bool((variants.get("worksite_fallback_after", {}) as Dictionary).get("pass", false))
	var target_renderer := String(status.get("rendering_method", "")) == "Forward Plus" and String(status.get("rendering_driver", "")) == "d3d12"
	var material_contract := String(status.get("material_identity", "")) == "project_procedural_worksite_soil" \
		and bool(status.get("shader_override_enabled", false)) \
		and String(status.get("shader_override_source", "")) == "res://assets/terrain/shaders/worksite_soil_terrain3d.gdshader" \
		and not bool(status.get("demo_texture_sampling_enabled", true)) \
		and not bool(status.get("world_background_enabled", true))
	var dressing_contract := not bool(status.get("native_demo_dressing_enabled", true)) \
		and int(status.get("rock_count", -1)) == 0 \
		and int(status.get("tree_count", -1)) == 0 \
		and not bool(status.get("grass_enabled", true)) \
		and not bool(status.get("foliage_enabled", true))
	var deformation_contract := authority_before != authority_after_deformation \
		and authority_after_deformation == authority_after_capture \
		and float(native_deformation.get("changed_ratio", 0.0)) >= 0.0001 \
		and float(fallback_deformation.get("changed_ratio", 0.0)) >= 0.0001
	var project_contract := _project_contract()
	var evidence := {
		"schema_version": "terrain3d-forwardplus-probe-v2",
		"passed": native_before_pass and native_after_pass and fallback_before_pass and fallback_after_pass \
			and target_renderer and material_contract and dressing_contract and deformation_contract \
			and fallback_before_visible and fallback_after_visible and bool(project_contract.get("passed", false)) \
			and failure.get("passed", false),
		"target_renderer": target_renderer,
		"material_contract": material_contract,
		"dressing_contract": dressing_contract,
		"deformation_contract": deformation_contract,
		"project_contract": project_contract,
		"status": status,
		"fallback_visible_during_native": fallback_visible_during_native,
		"foundation_visible_during_native": foundation_visible_during_native,
		"fallback_before_visible": fallback_before_visible,
		"fallback_after_visible": fallback_after_visible,
		"logical_height_min": height_range.x,
		"logical_height_max": height_range.y,
		"logical_height_range": height_range.y - height_range.x,
		"authority_before": authority_before,
		"authority_after_deformation": authority_after_deformation,
		"authority_after_capture": authority_after_capture,
		"variants": variants,
		"native_deformation": native_deformation,
		"fallback_deformation": fallback_deformation,
		"native_fallback_after": native_fallback_after,
		"deliberate_failure": failure,
	}
	_write_json("evidence.json", evidence)
	print("TERRAIN3D_PROBE_EVIDENCE ", JSON.stringify(evidence))
	rig["scene"].queue_free()
	await process_frame
	quit(0 if bool(evidence["passed"]) else 1)


func _build_rig(material_path: String) -> Dictionary:
	var scene := Node3D.new()
	scene.name = "Terrain3DForwardPlusProbe"
	var environment_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.035, 0.045, 0.055)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.72, 0.75, 0.78)
	environment.ambient_light_energy = 0.65
	environment_node.environment = environment
	scene.add_child(environment_node)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -32.0, 0.0)
	sun.light_energy = 1.35
	sun.shadow_enabled = true
	scene.add_child(sun)
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 25.0, 27.0)
	camera.fov = 48.0
	camera.current = true
	camera.basis = Basis.looking_at((Vector3(0.0, 0.0, -2.0) - camera.position).normalized(), Vector3.UP)
	scene.add_child(camera)
	var foundation := MeshInstance3D.new()
	foundation.name = "FoundationGround"
	var plane := PlaneMesh.new()
	plane.size = Vector2(70.0, 70.0)
	var foundation_material := StandardMaterial3D.new()
	foundation_material.albedo_color = Color(0.16, 0.18, 0.20)
	plane.material = foundation_material
	foundation.mesh = plane
	foundation.position.y = -0.03
	scene.add_child(foundation)
	var world := TerrainWorld.new()
	world.name = "TerrainWorld"
	world.terrain_backend = "terrain3d"
	world.terrain3d_adapter_path = NodePath("../Terrain3DAdapter")
	world.foundation_ground_path = NodePath("../FoundationGround")
	var fallback := TerrainRenderer.new()
	fallback.name = "TerrainMesh"
	world.add_child(fallback)
	scene.add_child(world)
	var adapter := Terrain3DAdapter.new()
	adapter.name = "Terrain3DAdapter"
	adapter.material_path = material_path
	adapter.native_collision_mode = 0
	scene.add_child(adapter)
	return {
		"scene": scene,
		"adapter": adapter,
		"world": world,
		"fallback": fallback,
		"foundation": foundation,
	}


func _capture(label: String) -> Image:
	await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	var path := _output_dir.path_join("%s.png" % label)
	if image.save_png(path) != OK:
		push_error("Terrain3D probe could not save %s" % path)
	return image


func _compare_surface_to_absent(native_image: Image, absent_image: Image) -> Dictionary:
	if native_image == null or absent_image == null or native_image.get_size() != absent_image.get_size():
		return {"pass": false, "reason": "image_size_mismatch"}
	var samples := 0
	var changed := 0
	var nonblack := 0
	var luma_min := INF
	var luma_max := -INF
	var luma_sum := 0.0
	var brown := 0
	for y in range(0, native_image.get_height(), 3):
		for x in range(0, native_image.get_width(), 3):
			samples += 1
			var native_color := native_image.get_pixel(x, y)
			var absent_color := absent_image.get_pixel(x, y)
			var difference := absf(native_color.r - absent_color.r) + absf(native_color.g - absent_color.g) + absf(native_color.b - absent_color.b)
			if difference < 0.045:
				continue
			changed += 1
			var luma := native_color.get_luminance()
			luma_min = minf(luma_min, luma)
			luma_max = maxf(luma_max, luma)
			luma_sum += luma
			if luma >= 0.025:
				nonblack += 1
			if native_color.r > native_color.g * 1.03 and native_color.g > native_color.b * 1.03:
				brown += 1
	var changed_ratio := float(changed) / float(maxi(samples, 1))
	var nonblack_ratio := float(nonblack) / float(maxi(changed, 1))
	var brown_ratio := float(brown) / float(maxi(changed, 1))
	var luma_range := luma_max - luma_min if changed > 0 else 0.0
	return {
		"pass": changed_ratio >= 0.08 and nonblack_ratio >= 0.80 and brown_ratio >= 0.45 and luma_range >= 0.025,
		"sample_count": samples,
		"changed_count": changed,
		"changed_ratio": changed_ratio,
		"nonblack_ratio": nonblack_ratio,
		"brown_ratio": brown_ratio,
		"luma_min": luma_min if changed > 0 else 0.0,
		"luma_max": luma_max if changed > 0 else 0.0,
		"luma_mean": luma_sum / float(maxi(changed, 1)),
		"luma_range": luma_range,
	}


func _compare_frames(first: Image, second: Image) -> Dictionary:
	if first == null or second == null or first.get_size() != second.get_size():
		return {"changed_ratio": 0.0, "mean_rgb_distance": 0.0, "reason": "image_size_mismatch"}
	var samples := 0
	var changed := 0
	var distance_sum := 0.0
	for y in range(0, first.get_height(), 3):
		for x in range(0, first.get_width(), 3):
			samples += 1
			var first_color := first.get_pixel(x, y)
			var second_color := second.get_pixel(x, y)
			var distance := absf(first_color.r - second_color.r) \
				+ absf(first_color.g - second_color.g) \
				+ absf(first_color.b - second_color.b)
			distance_sum += distance
			if distance >= 0.025:
				changed += 1
	return {
		"sample_count": samples,
		"changed_count": changed,
		"changed_ratio": float(changed) / float(maxi(samples, 1)),
		"mean_rgb_distance": distance_sum / float(maxi(samples, 1)),
	}


func _reactivate_native(adapter: Terrain3DAdapter) -> void:
	adapter.set_test_mode(true)
	adapter.set_test_mode(false)


func _project_contract() -> Dictionary:
	var packed := load("res://scenes/main.tscn") as PackedScene
	var scene := packed.instantiate() if packed != null else null
	var terrain_world := scene.get_node_or_null("TerrainRoot/TerrainWorld") as TerrainWorld if scene != null else null
	var backend := terrain_world.terrain_backend if terrain_world != null else ""
	if scene != null:
		scene.free()
	var features: PackedStringArray = ProjectSettings.get_setting("application/config/features", PackedStringArray())
	var driver := String(ProjectSettings.get_setting("rendering/rendering_device/driver.windows", ""))
	var main_scene := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	return {
		"passed": main_scene.ends_with("scenes/main.tscn") and features.has("Forward Plus") \
			and driver == "d3d12" and backend == "terrain3d",
		"main_scene": main_scene,
		"features": features,
		"windows_driver": driver,
		"main_terrain_backend": backend,
	}


func _run_deliberate_material_failure() -> Dictionary:
	var rig := _build_rig("res://tests/__missing_terrain3d_material__.tres")
	(root as Window).add_child(rig["scene"])
	for _frame in 12:
		await process_frame
	var adapter := rig["adapter"] as Terrain3DAdapter
	var fallback := rig["fallback"] as TerrainRenderer
	var foundation := rig["foundation"] as MeshInstance3D
	var status := adapter.get_status_snapshot()
	var reason := String(status.get("last_error", ""))
	var fallback_visible := fallback.visible
	var foundation_visible := foundation.visible
	var passed := not adapter.available and fallback_visible and foundation_visible and reason == "Terrain3D material is unavailable: res://tests/__missing_terrain3d_material__.tres"
	rig["scene"].queue_free()
	await process_frame
	return {
		"passed": passed,
		"reason": reason,
		"fallback_visible": fallback_visible,
		"foundation_visible": foundation_visible,
	}


func _authority_fingerprint_from_rig(world: TerrainWorld) -> Dictionary:
	var snapshot := world.terrain_state.surface_snapshot()
	return {
		"world_generation": int(snapshot["world_generation"]),
		"terrain_revision": int(snapshot["terrain_revision"]),
		"terrain_epoch": String(snapshot["terrain_epoch"]),
		"surface_sha256": _sha256_text(snapshot["surface_bytes"] as PackedByteArray),
	}


func _surface_range(surface: PackedFloat32Array) -> Vector2:
	var low := INF
	var high := -INF
	for value in surface:
		low = minf(low, value)
		high = maxf(high, value)
	return Vector2(low, high)


func _sha256_text(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	context.update(bytes)
	return context.finish().hex_encode()


func _parse_output_dir() -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find(OUTPUT_ARG)
	if index < 0 or index + 1 >= args.size():
		return ""
	return String(args[index + 1]).replace("\\", "/")


func _write_json(file_name: String, payload: Dictionary) -> void:
	var file := FileAccess.open(_output_dir.path_join(file_name), FileAccess.WRITE)
	if file == null:
		push_error("Terrain3D probe could not write %s" % file_name)
		return
	file.store_string(JSON.stringify(payload, "  "))

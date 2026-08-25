extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var result := _test_quality_profiles()
	if result == 0:
		result = await _test_quality_failure_propagation()
	if result == 0:
		result = _test_effect_budget()
	if result == 0:
		result = await _test_scene_visual_nodes()
	if result == 0:
		print("Realistic visual contracts passed.")
	quit(result)


func _test_quality_profiles() -> int:
	var quality := VisualQualityController.new()
	if not quality.apply_profile("test") or quality.get_quality_snapshot()["particles"] != 0 or not bool(quality.get_quality_snapshot()["test_ground"]):
		return _fail("test profile selects the grid-ground presentation budget")
	if not quality.apply_profile("low") or quality.get_quality_snapshot()["particles"] != 500:
		return _fail("low profile applies bounded particle budget")
	if not quality.apply_profile("high") or quality.get_quality_snapshot()["camera_far"] != 220.0:
		return _fail("high profile applies far distance")
	if quality.apply_profile("unsupported") or quality.last_error != "unknown_quality_profile":
		return _fail("unsupported profile is mutation-free")
	return 0


func _test_quality_failure_propagation() -> int:
	var container := Node.new()
	var environment := VisualEnvironment.new()
	environment.name = "VisualEnvironment"
	var quality := VisualQualityController.new()
	quality.name = "VisualQualityController"
	container.add_child(environment)
	container.add_child(quality)
	root.add_child(container)
	await process_frame
	if quality.apply_profile("high") or quality.last_error != "visual_environment_profile_failed":
		container.queue_free()
		return _fail("quality controller propagates a missing Sky3D backend")
	container.queue_free()
	await process_frame
	return 0


func _test_effect_budget() -> int:
	var effects := SoilEffects.new()
	effects.max_particles = 96
	effects.set_budget(1000)
	if effects.get_effect_snapshot()["budget"] != 96:
		return _fail("soil effect budget is bounded")
	effects.clear_for_generation(4)
	if effects.get_effect_snapshot()["generation"] != 4:
		return _fail("soil effect generation advances explicitly")
	return 0


func _test_scene_visual_nodes() -> int:
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		return _fail("main scene loads")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	var visual_environment := scene.get_node_or_null("VisualEnvironment") as VisualEnvironment
	var quality := scene.get_node_or_null("VisualQualityController") as VisualQualityController
	var dressing := scene.get_node_or_null("TerrainRoot/ConstructionSiteDressing") as ConstructionSiteDressing
	var scene_effects := scene.get_node_or_null("SoilEffects") as SoilEffects
	if visual_environment == null or quality == null or dressing == null or scene_effects == null:
		return _fail("visual environment, quality and effects nodes exist")
	if not bool(scene_effects.get_effect_snapshot()["dust_node"]):
		return _fail("soil effects include a bounded contact-dust pool")
	var terrain_renderer := scene.get_node_or_null("TerrainRoot/TerrainWorld/TerrainMesh") as TerrainRenderer
	var terrain_adapter := scene.get_node_or_null("TerrainRoot/Terrain3DAdapter") as Terrain3DAdapter
	if terrain_renderer == null or terrain_adapter == null or terrain_renderer.get_status_snapshot().get("material_kind", "") != "procedural_worksite_soil":
		return _fail("fallback terrain retains the procedural worksite material identity")
	if scene.get_node_or_null("OperatorUI/SkyAttribution") != null:
		return _fail("running client keeps third-party attribution out of the simulation viewport")
	var sky := scene.get_node_or_null("WorldEnvironment") as Sky3D
	if sky == null or sky.sun == null or sky.tod == null:
		return _fail("root WorldEnvironment uses the initialized Sky3D backend")
	var snapshot := visual_environment.get_visual_snapshot()
	if snapshot["backend"] != "Sky3D" or not is_equal_approx(float(snapshot["fixed_time"]), 10.5) or bool(snapshot["time_progression"]):
		return _fail("Sky3D stays at the fixed construction-workday time")
	if sky.tod.celestials_calculations != TimeOfDay.CelestialMode.SIMPLE or not sky.is_day():
		return _fail("Sky3D uses deterministic simple daytime celestial positioning")
	if not is_equal_approx(sky.sky.sun_altitude, deg_to_rad(19.5)):
		return _fail("fixed Sky3D time resolves to the calibrated high daytime sun")
	if sky.sky.wind_speed != 0.0 or sky.sky.ground_color != VisualEnvironment.HORIZON_GROUND_COLOR:
		return _fail("Sky3D keeps a deterministic construction-site horizon")
	var legacy_light := scene.get_node_or_null("KeyLight") as DirectionalLight3D
	if legacy_light == null or legacy_light.visible or legacy_light.light_energy != 0.0:
		return _fail("legacy key-light seam stays present but inactive")
	if visual_environment.get_active_sun() != sky.sun or not sky.sun.visible:
		return _fail("Sky3D SunLight is the single active daytime light")
	if not quality.apply_profile("low") or sky.clouds_enabled or sky.fog_enabled or sky.sun.shadow_enabled:
		return _fail("low quality disables clouds, fog, and sun shadows")
	var low_site := dressing.get_status_snapshot()
	if int(low_site["visible_cues"]) != 14 or int(low_site["shadow_instances"]) != 0:
		return _fail("low quality keeps primary non-shadowing worksite cues")
	if not quality.apply_profile("test"):
		return _fail("test quality applies from the production quality owner")
	var test_site := dressing.get_status_snapshot()
	var terrain3d_status := terrain_adapter.get_status_snapshot()
	if int(test_site["visible_cues"]) != 0 or bool(terrain3d_status["available"]) or not bool(terrain3d_status["test_mode"]):
		return _fail("test quality disables native terrain and all site dressing")
	if not terrain_renderer.visible or String(terrain_renderer.get_status_snapshot()["material_kind"]) != "test_black_white_grid":
		return _fail("test quality exposes the untextured black/white fallback grid")
	var test_effects := scene_effects.get_effect_snapshot()
	if int(test_effects["budget"]) != 0 or bool(test_effects["enabled"]) or bool(test_effects["particles_emitting"]) or bool(test_effects["dust_emitting"]) or int(test_effects["active_clods"]) != 0:
		return _fail("test quality disables disposable soil particles: %s" % test_effects)
	if not quality.apply_profile("balanced"):
		return _fail("balanced quality restores worksite context")
	var balanced_site := dressing.get_status_snapshot()
	if int(balanced_site["visible_cues"]) != 28 or int(balanced_site["shadow_instances"]) <= 0:
		return _fail("balanced quality applies its context and shadow budget")
	var restored_adapter := terrain_adapter.get_status_snapshot()
	var restored_effects := scene_effects.get_effect_snapshot()
	if not bool(restored_adapter["available"]) or bool(restored_adapter["test_mode"]) or terrain_renderer.visible:
		return _fail("leaving test quality restores native Terrain3D presentation")
	if String(terrain_renderer.get_status_snapshot()["material_kind"]) != "procedural_worksite_soil" or int(restored_effects["budget"]) != 1800 or not bool(restored_effects["enabled"]):
		return _fail("leaving test quality restores normal terrain material and effects budget")
	if not quality.apply_profile("high") or not sky.clouds_enabled or not sky.fog_enabled or not sky.sun.shadow_enabled:
		return _fail("high quality restores bounded Sky3D atmosphere and shadows")
	var high_site := dressing.get_status_snapshot()
	if int(high_site["visible_cues"]) != 45 or int(high_site["collision_objects"]) != 0 or not bool(high_site["code_native"]):
		return _fail("high quality exposes all code-native cues without collision")
	if sky.game_time_enabled or sky.tod.system_sync:
		return _fail("quality changes never enable Sky3D time authority")
	var camera := scene.get_node_or_null("Camera3D") as CameraRig
	if camera == null:
		return _fail("camera uses the presentation rig")
	scene.queue_free()
	return 0


func _fail(message: String) -> int:
	push_error("M6 check failed: %s" % message)
	return 1

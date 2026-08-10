extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var result := _test_quality_profiles()
	if result == 0:
		result = _test_effect_budget()
	if result == 0:
		result = _test_scene_visual_nodes()
	if result == 0:
		print("Realistic visual contracts passed.")
	quit(result)


func _test_quality_profiles() -> int:
	var quality := VisualQualityController.new()
	if not quality.apply_profile("low") or quality.get_quality_snapshot()["particles"] != 32:
		return _fail("low profile applies bounded particle budget")
	if not quality.apply_profile("high") or quality.get_quality_snapshot()["camera_far"] != 220.0:
		return _fail("high profile applies far distance")
	if quality.apply_profile("unsupported") or quality.last_error != "unknown_quality_profile":
		return _fail("unsupported profile is mutation-free")
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
	if scene.get_node_or_null("VisualEnvironment") == null or scene.get_node_or_null("VisualQualityController") == null or scene.get_node_or_null("SoilEffects") == null:
		return _fail("visual environment, quality and effects nodes exist")
	var camera := scene.get_node_or_null("Camera3D") as CameraRig
	if camera == null:
		return _fail("camera uses the presentation rig")
	scene.queue_free()
	return 0


func _fail(message: String) -> int:
	push_error("M6 check failed: %s" % message)
	return 1

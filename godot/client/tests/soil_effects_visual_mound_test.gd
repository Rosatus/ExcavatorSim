extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var effects := SoilEffects.new()
	effects.max_visual_mounds = 2
	effects.excavation_world_path = NodePath()
	root.add_child(effects)
	await process_frame
	var first := _snapshot("dump:1", Vector3(1.0, 0.0, 2.0), 0.4)
	effects.apply_visual_snapshot_for_test(first)
	if int(effects.get_effect_snapshot().get("active_visual_mounds", 0)) != 1:
		return _fail("first visual mound was not presented")
	effects.apply_visual_snapshot_for_test(first)
	if int(effects.get_effect_snapshot().get("active_visual_mounds", 0)) != 1:
		return _fail("duplicate dump event spawned another mound")
	effects.apply_visual_snapshot_for_test(_snapshot("dump:2", Vector3.ZERO, 0.8))
	effects.apply_visual_snapshot_for_test(_snapshot("dump:3", Vector3(3.0, 0.0, 1.0), 1.0))
	var status := effects.get_effect_snapshot()
	if int(status.get("active_visual_mounds", 0)) != 2 or int(status.get("visual_mound_cap", 0)) != 2:
		return _fail("bounded visual mound pool did not recycle at capacity")
	for child in effects.get_children():
		if String(child.name).begins_with("VisualSoilMound") and (child is CollisionObject3D or child is CollisionShape3D):
			return _fail("visual mound pool introduced a physics node")
	effects.clear_for_generation(7)
	if int(effects.get_effect_snapshot().get("active_visual_mounds", -1)) != 0:
		return _fail("generation reset retained visual mounds")
	effects.queue_free()
	print("soil_effects_visual_mound_test: PASS")
	quit(0)


func _snapshot(event_id: String, release_world: Vector3, ratio: float) -> Dictionary:
	return {
		"accepted_dump_event_id": event_id,
		"dump_release_world": release_world,
		"dump_released_fill_ratio": ratio,
		"bucket_pose": {},
	}


func _fail(message: String) -> void:
	push_error(message)
	quit(1)

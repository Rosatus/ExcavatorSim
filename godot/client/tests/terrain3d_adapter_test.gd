extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var result := await _test_snapshot_guards_without_native_backend()
	if result == 0:
		result = await _test_scene_adapter_seam()
	if result == 0:
		result = await _test_jolt_collision_and_disable()
	if result == 0:
		print("Terrain3D adapter contracts passed.")
	quit(result)


func _test_snapshot_guards_without_native_backend() -> int:
	var state := TerrainState.new(77)
	var adapter := Terrain3DAdapter.new()
	adapter.enabled = false
	root.add_child(adapter)
	await process_frame
	var baseline := state.surface_snapshot()
	if not adapter.queue_snapshot(baseline):
		return _fail("adapter accepts a complete TerrainState snapshot")
	if adapter.apply_pending() or adapter.available:
		return _fail("disabled native backend fails open")
	var status: Dictionary = adapter.get_status_snapshot()
	if int(status["queued_generation"]) != int(baseline["world_generation"]) or int(status["queued_revision"]) != int(baseline["terrain_revision"]):
		return _fail("adapter exposes queued generation and revision")
	if not state.enqueue_brush(1, Vector2.ZERO, 1.0, 0.2) or not state.step_fixed():
		return _fail("test edit changes the logical source")
	var newer := state.surface_snapshot()
	if not adapter.queue_snapshot(newer):
		return _fail("newer revision replaces pending native work")
	if adapter.queue_snapshot(baseline):
		return _fail("stale revision cannot replace newer native work")
	if state.surface_snapshot()["surface_bytes"] != newer["surface_bytes"]:
		return _fail("adapter queueing never mutates logical snapshot bytes")
	adapter.queue_free()
	return 0


func _test_scene_adapter_seam() -> int:
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		return _fail("main scene loads")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	var adapter := scene.get_node_or_null("TerrainRoot/Terrain3DAdapter") as Terrain3DAdapter
	var terrain_world := scene.get_node_or_null("TerrainRoot/TerrainWorld") as TerrainWorld
	var fallback := scene.get_node_or_null("TerrainRoot/TerrainWorld/TerrainMesh") as TerrainRenderer
	if adapter == null or terrain_world == null or fallback == null:
		scene.queue_free()
		return _fail("scene keeps adapter and custom renderer seams")
	if terrain_world.terrain_state == null:
		scene.queue_free()
		return _fail("adapter is downstream of an initialized TerrainState")
	if not adapter.get_status_snapshot().has_all(["queued_generation", "queued_revision", "applied_generation", "applied_revision"]):
		scene.queue_free()
		return _fail("adapter reports generation-gated status")
	scene.queue_free()
	await process_frame
	return 0


func _test_jolt_collision_and_disable() -> int:
	if String(ProjectSettings.get_setting("physics/3d/physics_engine", "")) != "Jolt Physics":
		return _fail("project keeps Jolt as the 3D physics backend")
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		return _fail("collision smoke scene loads")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	var adapter := scene.get_node_or_null("TerrainRoot/Terrain3DAdapter") as Terrain3DAdapter
	var terrain_world := scene.get_node_or_null("TerrainRoot/TerrainWorld") as TerrainWorld
	if adapter == null or terrain_world == null or not adapter.available:
		scene.queue_free()
		return _fail("native Terrain3D backend is available for collision smoke")
	var before := terrain_world.terrain_state.surface_snapshot()
	if not adapter.set_collision_mode(1):
		scene.queue_free()
		return _fail("Terrain3D Dynamic/Game collision enables")
	await physics_frame
	await physics_frame
	var query := PhysicsRayQueryParameters3D.create(Vector3(0.0, 5.0, 0.0), Vector3(0.0, -5.0, 0.0))
	var hit: Dictionary = scene.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or not (hit.get("collider") is Terrain3D):
		scene.queue_free()
		return _fail("Jolt raycast hits the Terrain3D static collider")
	if adapter.set_collision_mode(0) or adapter.collision_available:
		scene.queue_free()
		return _fail("Terrain3D collision disables fail-open")
	await physics_frame
	await physics_frame
	if not scene.get_world_3d().direct_space_state.intersect_ray(query).is_empty():
		scene.queue_free()
		return _fail("disabled Terrain3D collision leaves no stale shape")
	var after := terrain_world.terrain_state.surface_snapshot()
	if before["surface_bytes"] != after["surface_bytes"] or before["terrain_revision"] != after["terrain_revision"]:
		scene.queue_free()
		return _fail("Jolt collision toggles never mutate logical terrain")
	scene.queue_free()
	await process_frame
	return 0


func _fail(message: String) -> int:
	push_error("Terrain3D adapter check failed: %s" % message)
	return 1

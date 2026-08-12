extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var result := await _test_snapshot_guards_without_native_backend()
	if result == 0:
		result = await _test_scene_adapter_seam()
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


func _fail(message: String) -> int:
	push_error("Terrain3D adapter check failed: %s" % message)
	return 1

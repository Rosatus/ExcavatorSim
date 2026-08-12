extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var result := _test_repeatability_and_layers()
	if result == 0:
		result = _test_ordering_and_noop()
	if result == 0:
		result = _test_reset_and_renderer_generation()
	if result == 0:
		result = await _test_scene_integration()
	quit(result)


func _test_repeatability_and_layers() -> int:
	var first := TerrainState.new(77)
	var second := TerrainState.new(77)
	for state in [first, second]:
		if not state.enqueue_brush(1, Vector2(0.0, 0.0), 1.5, 0.25):
			return _fail("valid fill command queues")
		if not state.enqueue_brush(2, Vector2(0.5, 0.0), 0.8, -0.15):
			return _fail("valid cut command queues")
		state.step_fixed()
	var first_snapshot := first.surface_snapshot()
	var second_snapshot := second.surface_snapshot()
	if first_snapshot["surface_bytes"] != second_snapshot["surface_bytes"] or first_snapshot["snapshot_sha256"] != second_snapshot["snapshot_sha256"]:
		return _fail("same seed and edits produce identical snapshot bytes and digest")
	if first.terrain_revision != second.terrain_revision or first.stable_heights != second.stable_heights or first.loose_depth != second.loose_depth:
		return _fail("same seed and edits retain identical Float32 layers")
	for index in first.stable_heights.size():
		if not is_equal_approx(first.get_surface()[index], first.stable_heights[index] + first.loose_depth[index]):
			return _fail("surface remains stable plus loose")
	if first_snapshot["surface_bytes"].size() != TerrainState.DEFAULT_ROWS * TerrainState.DEFAULT_COLUMNS * 4:
		return _fail("snapshot uses row-major Float32 bytes")
	return 0


func _test_ordering_and_noop() -> int:
	var state := TerrainState.new(99)
	var baseline: PackedByteArray = state.surface_snapshot()["surface_bytes"]
	if state.enqueue_brush(1, Vector2.ZERO, 0.0, 0.2):
		return _fail("invalid radius is rejected")
	if state.get_pending_count() != 0 or state.get_last_enqueued_sequence() != -1:
		return _fail("invalid input is mutation-free")
	if not state.enqueue_brush(4, Vector2.ZERO, 1.0, 0.0):
		return _fail("zero delta remains a valid ordered command")
	if state.enqueue_brush(4, Vector2.ZERO, 1.0, 0.2) or state.enqueue_brush(3, Vector2.ZERO, 1.0, 0.2):
		return _fail("duplicate and stale sequences are rejected")
	if state.step_fixed() or state.terrain_revision != 0 or state.surface_snapshot()["surface_bytes"] != baseline:
		return _fail("no-op command cannot mutate state or revision")
	if not state.enqueue_brush(5, Vector2.ZERO, 1.0, 0.2):
		return _fail("next monotonic command is accepted")
	if not state.step_fixed() or state.terrain_revision != 1:
		return _fail("changed fixed step increments revision once")
	return 0


func _test_reset_and_renderer_generation() -> int:
	var state := TerrainState.new(123)
	var baseline: PackedByteArray = state.surface_snapshot()["surface_bytes"]
	state.enqueue_brush(1, Vector2.ZERO, 1.0, 0.3)
	state.step_fixed()
	var renderer := TerrainRenderer.new()
	if not renderer.queue_snapshot(state.surface_snapshot()) or not renderer.apply_pending():
		return _fail("renderer applies a copied current snapshot")
	if not _terrain_mesh_front_faces_up(renderer):
		return 1
	var old_snapshot := state.surface_snapshot()
	state.reset()
	if state.world_generation != 1 or state.terrain_revision != 2 or state.surface_snapshot()["surface_bytes"] != baseline:
		return _fail("reset restores baseline and advances identity")
	for depth in state.loose_depth:
		if depth != 0.0:
			return _fail("reset clears loose material")
	if not renderer.queue_snapshot(state.surface_snapshot()) or not renderer.apply_pending():
		return _fail("renderer accepts reset generation")
	if renderer.queue_snapshot(old_snapshot):
		return _fail("stale renderer snapshot is rejected")
	return 0


func _terrain_mesh_front_faces_up(renderer: TerrainRenderer) -> bool:
	var terrain_mesh := renderer.mesh as ArrayMesh
	if terrain_mesh == null or terrain_mesh.get_surface_count() != 1:
		return _fail("renderer produces one terrain mesh surface") == 0
	var arrays := terrain_mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if indices.size() < 6 or vertices.is_empty() or normals.size() != vertices.size():
		return _fail("terrain mesh exposes indexed vertices and normals") == 0
	var expected := PackedInt32Array([0, 1, TerrainState.DEFAULT_COLUMNS, 1, TerrainState.DEFAULT_COLUMNS + 1, TerrainState.DEFAULT_COLUMNS])
	for index in expected.size():
		if indices[index] != expected[index]:
			return _fail("terrain indices use Godot top-facing winding") == 0
	for triangle_start in [0, 3]:
		var first := vertices[indices[triangle_start]]
		var second := vertices[indices[triangle_start + 1]]
		var third := vertices[indices[triangle_start + 2]]
		if (second - first).cross(third - first).dot(Vector3.UP) >= 0.0:
			return _fail("terrain triangle winding is front-facing from above") == 0
	for normal_index in expected:
		if normals[normal_index].y <= 0.0:
			return _fail("terrain vertex normals remain upward") == 0
	return true


func _test_scene_integration() -> int:
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		return _fail("main scene loads")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	var terrain_world := scene.get_node_or_null("TerrainRoot/TerrainWorld") as TerrainWorld
	var terrain_mesh := scene.get_node_or_null("TerrainRoot/TerrainWorld/TerrainMesh") as TerrainRenderer
	var fallback := scene.get_node_or_null("TerrainRoot/FoundationGround") as MeshInstance3D
	if terrain_world == null or terrain_mesh == null or fallback == null:
		scene.queue_free()
		return _fail("TerrainWorld, TerrainMesh, and fallback ground exist")
	if terrain_world.terrain_state == null or terrain_mesh.mesh == null:
		scene.queue_free()
		return _fail("TerrainWorld builds a visible derived mesh")
	scene.queue_free()
	await process_frame
	print("Terrain state and renderer contracts passed.")
	return 0


func _fail(message: String) -> int:
	push_error("M4 check failed: %s" % message)
	return 1

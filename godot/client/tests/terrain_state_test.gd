extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var result := _test_repeatability_and_layers()
	if result == 0:
		result = _test_ordering_and_noop()
	if result == 0:
		result = _test_dirty_bounds_contract()
	if result == 0:
		result = _test_reset_and_renderer_generation()
	if result == 0:
		result = _test_incremental_renderer_patch()
	if result == 0:
		result = await _test_scene_integration()
	quit(result)


func _test_repeatability_and_layers() -> int:
	var first := TerrainState.new(77)
	var second := TerrainState.new(77)
	if String(first.surface_snapshot()["algorithm_version"]) != "godot-terrain-state-v2-flat":
		return _fail("flat construction-pad baseline advances the terrain algorithm identity")
	for height in first.stable_heights:
		if height != 0.0:
			return _fail("initial logical terrain is a level construction pad")
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


## Expected clamped brush cell rectangle, mirroring TerrainState._brush_cell_bounds.
func _expected_brush_rect(state: TerrainState, center: Vector2, radius: float) -> Rect2i:
	var min_column := clampi(floori((center.x - radius - state.origin_xz.x) / state.spacing_m), 0, state.columns - 1)
	var max_column := clampi(ceili((center.x + radius - state.origin_xz.x) / state.spacing_m), 0, state.columns - 1)
	var min_row := clampi(floori((center.y - radius - state.origin_xz.y) / state.spacing_m), 0, state.rows - 1)
	var max_row := clampi(ceili((center.y + radius - state.origin_xz.y) / state.spacing_m), 0, state.rows - 1)
	return Rect2i(min_column, min_row, max_column - min_column + 1, max_row - min_row + 1)


func _expand_halo(rect: Rect2i, state: TerrainState, halo: int) -> Rect2i:
	var min_cell := Vector2i(maxi(rect.position.x - halo, 0), maxi(rect.position.y - halo, 0))
	var max_cell := Vector2i(
		mini(rect.position.x + rect.size.x - 1 + halo, state.columns - 1),
		mini(rect.position.y + rect.size.y - 1 + halo, state.rows - 1)
	)
	return Rect2i(min_cell, max_cell - min_cell + Vector2i.ONE)


func _test_dirty_bounds_contract() -> int:
	# Startup publishes no current dirty rectangle: the first snapshot must
	# request a full materialization.
	var state := TerrainState.new(41)
	var startup := state.surface_snapshot()
	if not bool(startup["full_refresh"]):
		return _fail("startup snapshot requests full refresh")
	if Rect2i(startup["dirty_rect_cells"]).size.x != 0:
		return _fail("startup dirty rectangle is empty")

	# A local brush publishes a clamped rect plus one-cell halo, both smaller
	# than the full logical grid.
	if not state.enqueue_brush(state.next_brush_sequence(), Vector2.ZERO, 1.0, 0.2):
		return _fail("center brush queues")
	if not state.step_fixed():
		return _fail("center brush changes terrain")
	var expected := _expected_brush_rect(state, Vector2.ZERO, 1.0)
	var cells := Rect2i(state.surface_snapshot()["dirty_rect_cells"])
	var halo := Rect2i(state.surface_snapshot()["dirty_rect_with_halo"])
	if cells != expected:
		return _fail("dirty rect matches the clamped brush bounds")
	if halo != _expand_halo(expected, state, 1):
		return _fail("dirty halo expands exactly one cell")
	if cells.size.x * cells.size.y >= state.rows * state.columns:
		return _fail("local brush dirty bounds stay smaller than the full grid")
	var after := state.surface_snapshot()
	if bool(after["full_refresh"]) or int(after["dirty_revision"]) != int(after["terrain_revision"]):
		return _fail("ordinary revision publishes a current dirty rectangle")

	# Corner brushes clamp to the grid edge without negative indices.
	var corner := TerrainState.new(42)
	if not corner.enqueue_brush(corner.next_brush_sequence(), corner.origin_xz, 1.0, 0.2):
		return _fail("corner brush queues")
	if not corner.step_fixed():
		return _fail("corner brush changes terrain")
	var corner_cells := Rect2i(corner.surface_snapshot()["dirty_rect_cells"])
	if corner_cells.position != Vector2i.ZERO:
		return _fail("corner dirty rect clamps to grid origin")
	if Rect2i(corner.surface_snapshot()["dirty_rect_with_halo"]).position != Vector2i.ZERO:
		return _fail("corner halo clamps to grid origin")

	# One batch unions all brush rectangles.
	var batched := TerrainState.new(43)
	var split := TerrainState.new(43)
	batched.enqueue_brush(batched.next_brush_sequence(), Vector2(-4.0, 0.0), 1.0, 0.2)
	batched.enqueue_brush(batched.next_brush_sequence(), Vector2(4.0, 0.0), 1.0, 0.2)
	batched.step_fixed()
	split.enqueue_brush(split.next_brush_sequence(), Vector2(-4.0, 0.0), 1.0, 0.2)
	split.step_fixed()
	var first_rect := Rect2i(split.surface_snapshot()["dirty_rect_cells"])
	split.enqueue_brush(split.next_brush_sequence(), Vector2(4.0, 0.0), 1.0, 0.2)
	split.step_fixed()
	var second_rect := Rect2i(split.surface_snapshot()["dirty_rect_cells"])
	var union_rect := Rect2i(batched.surface_snapshot()["dirty_rect_cells"])
	if union_rect != first_rect.merge(second_rect):
		return _fail("batched dirty rect unions per-brush rectangles")
	if batched.surface_snapshot()["surface_bytes"] != split.surface_snapshot()["surface_bytes"]:
		return _fail("batching does not change resulting terrain bytes")

	# A no-op batch neither bumps the revision nor refreshes dirty identity.
	var noop := TerrainState.new(44)
	noop.enqueue_brush(noop.next_brush_sequence(), Vector2.ZERO, 1.0, 0.0)
	if noop.step_fixed():
		return _fail("zero-delta brush is a no-op")
	var noop_snapshot := noop.surface_snapshot()
	if not bool(noop_snapshot["full_refresh"]) or int(noop_snapshot["terrain_revision"]) != 0:
		return _fail("no-op batch keeps startup full-refresh state")

	# Reset invalidates dirty work and forces a full refresh for the new
	# generation.
	var before_reset := noop.surface_snapshot()
	noop.reset()
	var after_reset := noop.surface_snapshot()
	if int(after_reset["world_generation"]) != int(before_reset["world_generation"]) + 1:
		return _fail("reset advances world generation")
	if not bool(after_reset["full_refresh"]):
		return _fail("reset requests a full refresh")
	if int(after_reset["dirty_revision"]) == int(after_reset["terrain_revision"]):
		return _fail("reset invalidates the stale dirty rectangle")
	return 0


func _test_incremental_renderer_patch() -> int:
	var state := TerrainState.new(87)
	var renderer := TerrainRenderer.new()
	if not renderer.queue_snapshot(state.surface_snapshot()) or not renderer.apply_pending():
		return _fail("renderer performs the initial full build")
	var full_identity := renderer.get_applied_identity()
	if full_identity != Vector2i(state.world_generation, state.terrain_revision):
		return _fail("full build reports the applied identity")
	var mesh := renderer.mesh as ArrayMesh
	if mesh == null:
		return _fail("full build produces a mesh")
	var arrays := mesh.surface_get_arrays(0)
	var before_vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]

	# Ordinary contiguous revision patches only the dirty vertices.
	if not state.enqueue_brush(state.next_brush_sequence(), Vector2.ZERO, 1.0, 0.25):
		return _fail("patch brush queues")
	if not state.step_fixed():
		return _fail("patch brush changes terrain")
	var patch_snapshot := state.surface_snapshot()
	if not renderer.queue_snapshot(patch_snapshot) or not renderer.apply_pending():
		return _fail("renderer applies an ordinary patch")
	if renderer.get_applied_identity() != Vector2i(state.world_generation, state.terrain_revision):
		return _fail("patch advances the applied identity")
	var patched_arrays := (renderer.mesh as ArrayMesh).surface_get_arrays(0)
	var patched_vertices: PackedVector3Array = patched_arrays[Mesh.ARRAY_VERTEX]
	if patched_vertices.size() != before_vertices.size():
		return _fail("patch preserves vertex count")
	var dirty: Rect2i = patch_snapshot["dirty_rect_with_halo"]
	for row in state.rows:
		for column in state.columns:
			var index := row * state.columns + column
			var inside := row >= dirty.position.y and row < dirty.position.y + dirty.size.y \
				and column >= dirty.position.x and column < dirty.position.x + dirty.size.x
			if inside:
				if not is_equal_approx(patched_vertices[index].y, state.get_surface()[index]):
					return _fail("patch updates dirty vertex heights")
			elif patched_vertices[index] != before_vertices[index]:
				return _fail("patch leaves untouched vertices bit-identical")
	# A revision gap (skipped snapshot) falls back to a safe full rebuild.
	state.enqueue_brush(state.next_brush_sequence(), Vector2.ZERO, 1.0, 0.1)
	state.step_fixed()
	var skipped := state.surface_snapshot()
	state.enqueue_brush(state.next_brush_sequence(), Vector2(-3.0, 2.0), 1.0, -0.1)
	state.step_fixed()
	if not renderer.queue_snapshot(state.surface_snapshot()) or not renderer.apply_pending():
		return _fail("renderer recovers across a revision gap")
	if renderer.get_applied_identity() != Vector2i(state.world_generation, state.terrain_revision):
		return _fail("gap recovery converges to the accepted revision")
	if skipped["surface_bytes"] == state.surface_snapshot()["surface_bytes"]:
		return _fail("gap scenario actually skips a revision")
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

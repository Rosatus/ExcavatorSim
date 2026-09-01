extends SceneTree

## Incremental TerrainCollider contract: stable chunk partition, transactional
## dirty-chunk swap, applied-identity gating, and stale fail-closed behavior.
##
## The applied identity is the exact seam every bucket query and tracked
## support height refinement checks, so a lagging identity after a failed or
## gapped install must fail those queries closed until a full rebuild succeeds.

func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var result := await _test_chunk_identity_and_transactional_swap()
	if result == 0:
		result = await _test_revision_gap_rebuilds_everything()
	if result == 0:
		result = await _test_failed_install_fails_closed()
	if result == 0:
		print("Terrain collider chunk contracts passed.")
	quit(result)


func _make_collider() -> TerrainCollider:
	var collider := TerrainCollider.new()
	collider.name = "TerrainCollider"
	collider.enabled = true
	if collider.chunk_size_cells != 16:
		push_error("Terrain collider default chunk must stay bounded for live patch latency")
	root.add_child(collider)
	return collider


func _chunk_keys(state: TerrainState, collider: TerrainCollider) -> Array[Vector2i]:
	var keys: Array[Vector2i] = []
	var chunk := maxi(2, collider.chunk_size_cells)
	for row_start in range(0, state.rows - 1, chunk):
		for column_start in range(0, state.columns - 1, chunk):
			keys.append(Vector2i(row_start, column_start))
	return keys


func _shape_rids(collider: TerrainCollider, state: TerrainState) -> Dictionary:
	var rids := {}
	for key in _chunk_keys(state, collider):
		var node := collider.get_chunk_shape(key)
		rids[key] = node.shape.get_rid() if node != null and node.shape != null else RID()
	return rids


func _apply(collider: TerrainCollider, snapshot: Dictionary, message: String) -> int:
	if not collider.queue_snapshot(snapshot) or not collider.apply_pending():
		return _fail(message)
	return 0


func _test_chunk_identity_and_transactional_swap() -> int:
	var state := TerrainState.new(55)
	var collider := _make_collider()
	if _apply(collider, state.surface_snapshot(), "initial full collider build accepts the snapshot") != 0:
		collider.free()
		return 1
	if collider.get_chunk_count() != _chunk_keys(state, collider).size():
		collider.free()
		return _fail("full build partitions the logical grid into stable chunks")
	var body := collider.get_child(0) as StaticBody3D
	if body == null:
		collider.free()
		return _fail("one stable static body owns every chunk")
	var body_id := body.get_instance_id()
	var baseline_rids := _shape_rids(collider, state)

	# Ordinary contiguous revision: only chunks overlapped by the dirty halo
	# swap shapes; untouched chunks and the body keep their identity.
	if not state.enqueue_brush(state.next_brush_sequence(), Vector2.ZERO, 1.0, 0.2):
		collider.free()
		return _fail("patch brush queues")
	if not state.step_fixed():
		collider.free()
		return _fail("patch brush changes terrain")
	if _apply(collider, state.surface_snapshot(), "ordinary revision installs dirty chunks") != 0:
		collider.free()
		return 1
	if collider.get_applied_identity() != Vector2i(state.world_generation, state.terrain_revision):
		collider.free()
		return _fail("applied identity advances only after all dirty chunks install")
	if (collider.get_child(0) as StaticBody3D).get_instance_id() != body_id:
		collider.free()
		return _fail("chunk swap never replaces the static body")
	var patched_rids := _shape_rids(collider, state)
	var changed_chunks := 0
	var unchanged_chunks := 0
	for key in _chunk_keys(state, collider):
		if patched_rids[key] == baseline_rids[key]:
			unchanged_chunks += 1
		else:
			changed_chunks += 1
	if changed_chunks == 0 or unchanged_chunks == 0:
		collider.free()
		return _fail("ordinary revision swaps only dirty chunks")

	# The swapped geometry is query-visible and matches the logical surface.
	await physics_frame
	await physics_frame
	var query := PhysicsRayQueryParameters3D.create(Vector3(0.0, 5.0, 0.0), Vector3(0.0, -5.0, 0.0))
	query.collision_mask = 1
	var hit: Dictionary = root.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or not is_equal_approx(float(hit["position"].y), state.sample_surface_at(Vector2.ZERO)):
		collider.free()
		return _fail("raycast sees the patched chunk height")
	collider.queue_free()
	await process_frame
	return 0


func _test_revision_gap_rebuilds_everything() -> int:
	var state := TerrainState.new(56)
	var collider := _make_collider()
	if _apply(collider, state.surface_snapshot(), "gap scenario initial build") != 0:
		collider.free()
		return 1
	# Two revisions pass before one apply: the skipped snapshot breaks
	# contiguity, so a safe full rebuild must replace every chunk shape.
	for _edit in 2:
		state.enqueue_brush(state.next_brush_sequence(), Vector2(-2.0, 1.0), 1.0, -0.05)
		state.step_fixed()
	var before_rids := _shape_rids(collider, state)
	if _apply(collider, state.surface_snapshot(), "revision-gap rebuild") != 0:
		collider.free()
		return 1
	if collider.get_applied_identity() != Vector2i(state.world_generation, state.terrain_revision):
		collider.free()
		return _fail("revision-gap rebuild converges to the accepted revision")
	if collider.is_stale:
		collider.free()
		return _fail("successful rebuild clears the stale flag")
	var after_rids := _shape_rids(collider, state)
	for key in _chunk_keys(state, collider):
		if after_rids[key] == before_rids[key]:
			collider.free()
			return _fail("revision gap replaces even distant chunk shapes: %s" % key)
	collider.queue_free()
	await process_frame
	return 0


func _test_failed_install_fails_closed() -> int:
	var state := TerrainState.new(57)
	var collider := _make_collider()
	if _apply(collider, state.surface_snapshot(), "failure scenario initial build") != 0:
		collider.free()
		return 1
	var applied_identity := collider.get_applied_identity()
	var retained_rids := _shape_rids(collider, state)

	# A corrupt surface cannot install: old chunks are retained and the applied
	# identity lags so bucket queries and tracked support fail closed.
	state.enqueue_brush(state.next_brush_sequence(), Vector2.ZERO, 1.0, 0.1)
	state.step_fixed()
	var corrupt := state.surface_snapshot()
	corrupt["rows"] = int(corrupt["rows"]) + 4
	if not collider.queue_snapshot(corrupt):
		collider.free()
		return _fail("queue validates only required keys")
	if collider.apply_pending():
		collider.free()
		return _fail("corrupt surface cannot install")
	if not collider.is_stale:
		collider.free()
		return _fail("failed install marks the collider stale")
	if collider.available:
		collider.free()
		return _fail("stale collider reports unavailable for contact queries")
	if collider.get_applied_identity() != applied_identity:
		collider.free()
		return _fail("failed install never advances the applied identity")

	# A healthy later snapshot recovers through a full rebuild.
	if _apply(collider, state.surface_snapshot(), "recovery full rebuild") != 0:
		collider.free()
		return 1
	if collider.is_stale or not collider.available:
		collider.free()
		return _fail("recovery clears the stale flag")
	if collider.get_applied_identity() != Vector2i(state.world_generation, state.terrain_revision):
		collider.free()
		return _fail("recovery converges to the accepted revision")
	var recovered_rids := _shape_rids(collider, state)
	var any_changed := false
	for key in _chunk_keys(state, collider):
		if recovered_rids[key] != retained_rids[key]:
			any_changed = true
	if not any_changed:
		collider.free()
		return _fail("recovery actually rebuilt chunk shapes")
	collider.queue_free()
	await process_frame
	return 0


func _fail(message: String) -> int:
	push_error("Terrain collider chunk check failed: %s" % message)
	return 1

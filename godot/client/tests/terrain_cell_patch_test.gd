extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var state := TerrainState.new(1937, 41, 41, 0.25)
	var base := state.surface_snapshot()
	var read_view := state.cell_patch_read_snapshot()
	if read_view.has("surface") or read_view.has("surface_bytes") or read_view.has("snapshot_sha256"):
		return _fail("cell patch read view performed presentation snapshot work")
	if (read_view["stable_heights"] as PackedFloat32Array).size() != state.rows * state.columns:
		return _fail("cell patch read view omitted terrain authority layers")
	var center_index := 20 * state.columns + 20
	var patch := _patch_for(base, [
		_row(base, center_index, -0.04, "cut", ["teeth_main_edge"]),
		_row(base, center_index + 1, -0.03, "scrape", ["floor_wear_plate"]),
	], 7)
	var validation := state.validate_cell_patch(patch)
	if not bool(validation.get("valid", false)):
		return _fail("valid cell patch rejected: %s" % validation.get("reason", "missing"))
	if not state.enqueue_cell_patch(state.next_brush_sequence(), patch):
		return _fail("valid cell patch did not queue")
	if not state.step_fixed() or state.terrain_revision != int(base["terrain_revision"]) + 1:
		return _fail("cell patch did not commit exactly one revision")
	if not is_equal_approx(state.stable_heights[center_index], float(base["stable_heights"][center_index]) - 0.04):
		return _fail("cell patch stable target was not installed")
	if state.get_dirty_rect_cells() != Rect2i(20, 20, 2, 1):
		return _fail("cell patch dirty rectangle is not exact")

	var after := state.surface_snapshot()
	var bytes_after: PackedByteArray = after["surface_bytes"]
	var revision_after := state.terrain_revision
	var stale := patch.duplicate(true)
	if state.enqueue_cell_patch(state.next_brush_sequence(), stale):
		return _fail("stale revision patch queued")
	if state.terrain_revision != revision_after or state.surface_snapshot()["surface_bytes"] != bytes_after:
		return _fail("stale rejection mutated terrain")

	var duplicate_rows := [
		_row(after, center_index + state.columns, -0.02, "cut", ["teeth_main_edge"]),
		_row(after, center_index + state.columns, -0.03, "cut", ["teeth_main_edge"]),
	]
	var duplicate := _patch_for(after, duplicate_rows, 8)
	if bool(state.validate_cell_patch(duplicate).get("valid", false)):
		return _fail("duplicate cell index was accepted")

	var mismatch := _patch_for(after, [_row(after, center_index + state.columns, -0.02, "cut", ["teeth_main_edge"])], 9)
	mismatch["rows"][0]["original_stable_height"] = float(mismatch["rows"][0]["original_stable_height"]) + 0.01
	mismatch["patch_hash"] = SoilCellPatch.compute_hash(mismatch)
	if bool(state.validate_cell_patch(mismatch).get("valid", false)):
		return _fail("original-value mismatch was accepted")

	var tampered_volume := _patch_for(after, [_row(after, center_index + state.columns, -0.02, "cut", ["teeth_main_edge"])], 10)
	tampered_volume["removed_stable_m3"] = float(tampered_volume["removed_stable_m3"]) + 0.01
	if bool(state.validate_cell_patch(tampered_volume).get("valid", false)):
		return _fail("tampered cell-patch volume metadata was accepted")
	var tampered_dirty := _patch_for(after, [_row(after, center_index + state.columns, -0.02, "cut", ["teeth_main_edge"])], 11)
	tampered_dirty["dirty_rect_cells"] = Rect2i(0, 0, 1, 1)
	if bool(state.validate_cell_patch(tampered_dirty).get("valid", false)):
		return _fail("tampered dirty rectangle was accepted")

	var scheduler_state := TerrainState.new(1937, 41, 41, 0.25)
	var scheduler_base := scheduler_state.surface_snapshot()
	var scheduler_patch := _patch_for(scheduler_base, [_row(scheduler_base, center_index, -0.05, "cut", ["teeth_main_edge"])], 12)
	var scheduler := TerrainCommitScheduler.new(scheduler_state)
	if not scheduler.queue_cell_patch(1, scheduler_patch, scheduler_state.world_generation, "surface-patch-10"):
		return _fail("scheduler rejected valid cell patch")
	var commit := scheduler.step_fixed(0.0, true)
	if not bool(commit.get("changed", false)) or commit.get("reason") != "committed":
		return _fail("scheduler did not commit cell patch")
	if int(scheduler.get_status_snapshot()["pending_cell_patches"]) != 0:
		return _fail("scheduler retained committed patch")

	print("terrain_cell_patch_test: PASS")
	quit(0)


func _row(snapshot: Dictionary, index: int, stable_delta: float, action: String, contributors: Array) -> Dictionary:
	var stable: PackedFloat32Array = snapshot["stable_heights"]
	var loose: PackedFloat32Array = snapshot["loose_depth"]
	return {
		"index": index,
		"original_stable_height": float(stable[index]),
		"original_loose_depth": float(loose[index]),
		"target_stable_height": float(stable[index]) + stable_delta,
		"target_loose_depth": float(loose[index]),
		"action": action,
		"contributing_region_ids": contributors,
	}


func _patch_for(snapshot: Dictionary, rows: Array, tick: int) -> Dictionary:
	var patch := {
		"schema_version": SoilCellPatch.SCHEMA_VERSION,
		"generation": int(snapshot["world_generation"]),
		"base_revision": int(snapshot["terrain_revision"]),
		"tick": tick,
		"tool_identity": "test-tool|%d" % tick,
		"rows": rows,
	}
	patch["patch_hash"] = SoilCellPatch.compute_hash(patch)
	var cell_area := float(snapshot["spacing_m"]) * float(snapshot["spacing_m"])
	var removed_stable := 0.0
	var removed_loose := 0.0
	for value in rows:
		var row := value as Dictionary
		removed_stable += (float(row["original_stable_height"]) - float(row["target_stable_height"])) * cell_area
		removed_loose += (float(row["original_loose_depth"]) - float(row["target_loose_depth"])) * cell_area
	patch["removed_stable_m3"] = removed_stable
	patch["removed_loose_m3"] = removed_loose
	return patch


func _fail(message: String) -> void:
	push_error(message)
	quit(1)

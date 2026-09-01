extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	for model_id in ["sy205", "sy135"]:
		var failure := _test_model(model_id)
		if not failure.is_empty():
			return _fail(failure)
	print("arcade_excavation_stamp_test: PASS")
	quit(0)


func _test_model(model_id: String) -> String:
	var descriptor := SoilContractDescriptor.load_for_model(model_id)
	if descriptor == null or not descriptor.is_valid_for(model_id):
		return "%s contract unavailable" % model_id
	var contract := descriptor.to_dictionary()
	var terrain := TerrainState.new(1937, 129, 129, 0.5)
	var scheduler := TerrainCommitScheduler.new(terrain)
	var stamp := ArcadeExcavationStamp.new()
	if not stamp.configure(terrain, scheduler, contract):
		return "%s stamp did not configure" % model_id
	var surface := terrain.sample_surface_bilinear_at(Vector2.ZERO)
	var slow := stamp.build_proposals(_pose(contract, Vector3(-0.1, surface - 0.04, 0.0), Vector3(0.0, surface - 0.04, 0.0)), terrain.cell_patch_read_snapshot(), false)
	if not bool(slow.get("engaged", false)) or int(slow.get("covered_cell_count", 0)) < 3:
		return "%s slow sweep did not cover a connected work band" % model_id
	var fast := stamp.build_proposals(_pose(contract, Vector3(-0.5, surface - 0.04, 0.0), Vector3(0.5, surface - 0.04, 0.0)), terrain.cell_patch_read_snapshot(), false)
	if int(fast.get("sample_steps", 0)) < 2 or int(fast.get("covered_cell_count", 0)) <= int(slow.get("covered_cell_count", 0)):
		return "%s fast sweep was not interpolated" % model_id
	var fast_repeat := stamp.build_proposals(_pose(contract, Vector3(-0.5, surface - 0.04, 0.0), Vector3(0.5, surface - 0.04, 0.0)), terrain.cell_patch_read_snapshot(), false)
	if (fast.get("proposals", {}) as Dictionary) != (fast_repeat.get("proposals", {}) as Dictionary):
		return "%s fixed sweep proposals were not deterministic" % model_id
	var stationary := stamp.build_proposals(_pose(contract, Vector3.ZERO, Vector3.ZERO), terrain.cell_patch_read_snapshot(), false)
	if String(stationary.get("reason", "")) != "stationary" or bool(stationary.get("engaged", false)):
		return "%s stationary guard failed" % model_id
	var above := stamp.build_proposals(_pose(contract, Vector3(-0.1, surface + 1.0, 0.0), Vector3(0.1, surface + 1.0, 0.0)), terrain.cell_patch_read_snapshot(), false)
	if String(above.get("reason", "")) != "above_work_band" or bool(above.get("engaged", false)):
		return "%s above-ground guard failed" % model_id
	var teleport := stamp.build_proposals(_pose(contract, Vector3(-1.1, surface, 0.0), Vector3(1.1, surface, 0.0)), terrain.cell_patch_read_snapshot(), false)
	if not bool(teleport.get("teleport_reset", false)):
		return "%s teleport guard failed" % model_id
	var covered_rows := {}
	for segment in 10:
		var z0 := -2.5 + float(segment) * 0.5
		var z1 := z0 + 0.5
		var y0 := terrain.sample_surface_bilinear_at(Vector2(0.0, z0)) - 0.04
		var y1 := terrain.sample_surface_bilinear_at(Vector2(0.0, z1)) - 0.04
		var path_segment := stamp.build_proposals(_pose(contract, Vector3(0.0, y0, z0), Vector3(0.0, y1, z1)), terrain.cell_patch_read_snapshot(), segment > 0)
		for index_value in (path_segment.get("proposals", {}) as Dictionary).keys():
			covered_rows[int(index_value) / terrain.columns] = true
	var sorted_rows: Array = covered_rows.keys()
	sorted_rows.sort()
	if sorted_rows.size() < 10:
		return "%s 5 m path left too few connected terrain rows" % model_id
	for row_index in range(1, sorted_rows.size()):
		if int(sorted_rows[row_index]) - int(sorted_rows[row_index - 1]) > 1:
			return "%s 5 m path left a coverage gap" % model_id
	var before_revision := terrain.terrain_revision
	var first := stamp.step_fixed(0.05, _pose(contract, Vector3(-0.2, surface - 0.04, 0.0), Vector3(0.0, surface - 0.04, 0.0)), 1)
	if bool(first.get("changed", false)) or terrain.terrain_revision != before_revision:
		return "%s committed before the coalescing window" % model_id
	var second := stamp.step_fixed(0.05, _pose(contract, Vector3(0.0, surface - 0.04, 0.0), Vector3(0.2, surface - 0.04, 0.0)), 2)
	if not bool(second.get("changed", false)) or terrain.terrain_revision != before_revision + 1:
		return "%s did not commit one coalesced patch at 100 ms" % model_id
	var status := stamp.get_status_snapshot()
	if int(status.get("accepted_commits", 0)) != 1 or float(status.get("bucket_volume_m3", 0.0)) <= 0.0:
		return "%s accepted cut did not credit visual load" % model_id
	var mirror_terrain := TerrainState.new(1937, 129, 129, 0.5)
	var mirror_stamp := ArcadeExcavationStamp.new()
	if not mirror_stamp.configure(mirror_terrain, TerrainCommitScheduler.new(mirror_terrain), contract):
		return "%s deterministic mirror did not configure" % model_id
	var mirror_surface := mirror_terrain.sample_surface_bilinear_at(Vector2.ZERO)
	mirror_stamp.step_fixed(0.05, _pose(contract, Vector3(-0.2, mirror_surface - 0.04, 0.0), Vector3(0.0, mirror_surface - 0.04, 0.0)), 1)
	mirror_stamp.step_fixed(0.05, _pose(contract, Vector3(0.0, mirror_surface - 0.04, 0.0), Vector3(0.2, mirror_surface - 0.04, 0.0)), 2)
	if String((mirror_stamp.get_status_snapshot().get("last_patch", {}) as Dictionary).get("patch_hash", "")) != String((status.get("last_patch", {}) as Dictionary).get("patch_hash", "")):
		return "%s fixed coalesced patch hash was not deterministic" % model_id
	var retry_terrain := TerrainState.new(1937, 129, 129, 0.5)
	var retry_stamp := ArcadeExcavationStamp.new()
	if not retry_stamp.configure(retry_terrain, TerrainCommitScheduler.new(retry_terrain), contract):
		return "%s retry stamp did not configure" % model_id
	var retry_surface := retry_terrain.sample_surface_bilinear_at(Vector2.ZERO)
	retry_terrain.fail_next_cell_patch_apply_for_test()
	var rejected := retry_stamp.step_fixed(0.1, _pose(contract, Vector3(-0.2, retry_surface - 0.04, 0.0), Vector3(0.0, retry_surface - 0.04, 0.0)), 10)
	if bool(rejected.get("changed", false)) or int(retry_stamp.get_status_snapshot().get("pending_cells", 0)) == 0:
		return "%s rejected patch did not remain pending for retry" % model_id
	var retried := retry_stamp.step_fixed(0.1, _pose(contract, Vector3.ZERO, Vector3.ZERO), 11)
	if not bool(retried.get("changed", false)) or int(retry_stamp.get_status_snapshot().get("pending_cells", -1)) != 0:
		return "%s rejected patch was not committed on the next window" % model_id
	var load: Variant = stamp.load_state
	load.credit_accepted_cut(float(load.get_status_snapshot().get("bucket_capacity_m3", 0.0)) * 10.0, 3, "capacity-clamp")
	if float(load.get_status_snapshot().get("fill_ratio", 0.0)) > 1.000001:
		return "%s scalar visual load exceeded capacity" % model_id
	var dump: Dictionary = load.dump_visual_load(Vector3(1.0, 2.0, 3.0), 4)
	if not bool(dump.get("changed", false)) or float(load.get_status_snapshot().get("bucket_volume_m3", -1.0)) != 0.0:
		return "%s visual dump did not clear the scalar load" % model_id
	return ""


func _pose(contract: Dictionary, previous_origin: Vector3, current_origin: Vector3) -> Dictionary:
	var previous := {"cutting_edge": Transform3D(Basis.IDENTITY, previous_origin), "opening": Transform3D(Basis.IDENTITY, previous_origin + Vector3.UP)}
	var current := {"cutting_edge": Transform3D(Basis.IDENTITY, current_origin), "opening": Transform3D(Basis.IDENTITY, current_origin + Vector3.UP)}
	return {
		"valid": true,
		"identity": "arcade-test",
		"previous": previous,
		"current": current,
		"opening_normal_world": Vector3.UP,
		"contract": contract,
	}


func _fail(message: String) -> void:
	push_error(message)
	quit(1)

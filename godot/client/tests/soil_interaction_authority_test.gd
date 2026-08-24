extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	for model_id in ["sy205", "sy135"]:
		var result := _run_journey(model_id, "balanced")
		if not bool(result.get("passed", false)):
			return _fail("%s lifecycle journey failed: %s" % [model_id, result.get("reason", "unknown")])

	var low := _run_journey("sy205", "low")
	var high := _run_journey("sy205", "high")
	if not bool(low.get("passed", false)) or not bool(high.get("passed", false)):
		return _fail("quality comparison journey failed")
	if absf(float(low["cut_volume_m3"]) - float(high["cut_volume_m3"])) > 0.00001:
		return _fail("quality profile changed accepted displacement")
	if absf(float(low["peak_bucket_volume_m3"]) - float(high["peak_bucket_volume_m3"])) > 0.00001:
		return _fail("quality profile changed bucket opening flux")
	var repeated := _run_repeated_cycles("sy205", 20)
	if not bool(repeated.get("passed", false)):
		return _fail("20-cycle lifecycle failed: %s" % repeated.get("reason", "unknown"))

	print("soil_interaction_authority_test: PASS")
	quit(0)


func _run_journey(model_id: String, quality: String) -> Dictionary:
	var descriptor := SoilContractDescriptor.load_for_model(model_id)
	if descriptor == null or not descriptor.is_valid_for(model_id):
		return {"passed": false, "reason": "contract_unavailable"}
	var contract := descriptor.to_dictionary()
	var source := TerrainState.new(1937, 41, 41, 0.25)
	var source_before := source.surface_snapshot()
	var patch := ActiveSoilPatch.new()
	if not patch.configure(source_before, quality, "loose"):
		return {"passed": false, "reason": "patch_configure"}
	var authority := SoilInteractionAuthority.new()
	if not authority.configure(contract, source.world_generation, "loose"):
		return {"passed": false, "reason": "authority_configure"}
	var tool := BucketSoilTool.new()
	if not tool.configure(contract):
		return {"passed": false, "reason": "tool_configure"}

	var identity_snapshot := tool.compose_snapshot(Transform3D.IDENTITY, Transform3D.IDENTITY, true, "%s:identity" % model_id)
	var teeth_local := _region_sample_point(identity_snapshot, "teeth_main_edge")
	var cut_snapshot := tool.compose_snapshot(
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.18 - teeth_local.y, 0.0)),
		Transform3D(Basis.IDENTITY, Vector3(0.0, -0.04 - teeth_local.y, 0.0)),
		true,
		"%s:%s:cut" % [model_id, quality],
	)
	var cut_classification := tool.classify(cut_snapshot, patch.persistent_field.terrain_state, 0.0, contract["interaction"] as Dictionary)
	var cut_point := _candidate_point(cut_classification, "cut")
	if not cut_point.is_finite():
		return {"passed": false, "reason": "cut_candidate"}
	authority.step_fixed(1.0 / 60.0, 1, cut_snapshot, cut_classification, patch, cut_point)
	var after_cut := authority.get_status_snapshot()
	var cut_volume := float((after_cut["compartments_m3"] as Dictionary)["active"])
	if cut_volume <= 0.000001:
		return {"passed": false, "reason": "no_active_displacement"}
	if not _journal_has_kind(authority.get_journal_snapshot(), "cut"):
		return {"passed": false, "reason": "cut_transaction_missing"}

	var inner_local := _region_center(identity_snapshot, "inner_shell")
	var carry_transform := Transform3D(Basis.IDENTITY, cut_point - inner_local)
	var carry_snapshot := tool.compose_snapshot(carry_transform, carry_transform, true, "%s:%s:carry" % [model_id, quality])
	var carry_classification := tool.classify(carry_snapshot, patch.persistent_field.terrain_state, 0.0, contract["interaction"] as Dictionary)
	authority.step_fixed(1.0 / 60.0, 2, carry_snapshot, carry_classification, patch, cut_point)
	var peak_bucket := float(authority.get_status_snapshot()["bucket_volume_m3"])
	if peak_bucket <= 0.000001:
		return {"passed": false, "reason": "opening_flux_zero"}
	if not _journal_has_kind(authority.get_journal_snapshot(), "bucket_entry"):
		return {"passed": false, "reason": "entry_transaction_missing"}

	var opening_local_normal := _region_normal(identity_snapshot, "opening")
	var dump_basis := Basis(Quaternion(opening_local_normal, Vector3.DOWN))
	var dump_transform := Transform3D(dump_basis, Vector3(0.0, 1.5, 0.0))
	var dump_snapshot := tool.compose_snapshot(dump_transform, dump_transform, true, "%s:%s:dump" % [model_id, quality])
	for tick in range(3, 243):
		var fill_ratio := float(authority.get_status_snapshot()["fill_ratio"])
		var dump_classification := tool.classify(dump_snapshot, patch.persistent_field.terrain_state, fill_ratio, contract["interaction"] as Dictionary)
		authority.step_fixed(1.0 / 60.0, tick, dump_snapshot, dump_classification, patch, dump_transform.origin)
	var final_status := authority.get_status_snapshot()
	var compartments := final_status["compartments_m3"] as Dictionary
	if absf(float(final_status["conservation_drift_m3"])) > 0.00001:
		return {"passed": false, "reason": "ledger_drift"}
	if int(final_status["invariant_failure_count"]) != 0:
		return {"passed": false, "reason": "invariant_failure"}
	if float(compartments["bucket"]) > 0.00001:
		return {"passed": false, "reason": "bucket_not_empty_%.8f_last_%s" % [float(compartments["bucket"]), String((final_status["last_transaction"] as Dictionary).get("kind", "none"))]}
	var journal := authority.get_journal_snapshot()
	var ids := {}
	var kinds := {}
	for row in journal:
		var transaction_id := String(row["transaction_id"])
		if ids.has(transaction_id):
			return {"passed": false, "reason": "duplicate_transaction"}
		ids[transaction_id] = true
		kinds[String(row["kind"])] = true
		var delta_total := 0.0
		for delta_value in (row["deltas_m3"] as Dictionary).values():
			delta_total += float(delta_value)
		if absf(delta_total) > 0.000001:
			return {"passed": false, "reason": "unbalanced_transaction"}
	for required_kind in ["dump", "settle"]:
		if not kinds.has(required_kind):
			return {"passed": false, "reason": "missing_%s" % required_kind}
	var source_after := source.surface_snapshot()
	if source_after["snapshot_sha256"] != source_before["snapshot_sha256"] or source_after["terrain_revision"] != source_before["terrain_revision"]:
		return {"passed": false, "reason": "product_terrain_mutated"}
	return {
		"passed": true,
		"cut_volume_m3": cut_volume,
		"peak_bucket_volume_m3": peak_bucket,
		"final_status": final_status,
	}


func _run_repeated_cycles(model_id: String, cycle_count: int) -> Dictionary:
	var descriptor := SoilContractDescriptor.load_for_model(model_id)
	if descriptor == null or not descriptor.is_valid_for(model_id):
		return {"passed": false, "reason": "contract_unavailable"}
	var contract := descriptor.to_dictionary()
	var source := TerrainState.new(991, 41, 41, 0.25)
	var product_digest := String(source.surface_snapshot()["snapshot_sha256"])
	var patch := ActiveSoilPatch.new()
	patch.configure(source.surface_snapshot(), "low", "loose")
	var authority := SoilInteractionAuthority.new()
	authority.configure(contract, source.world_generation, "loose")
	var tool := BucketSoilTool.new()
	tool.configure(contract)
	var identity := tool.compose_snapshot(Transform3D.IDENTITY, Transform3D.IDENTITY, true, "repeat:identity")
	var teeth_local := _region_sample_point(identity, "teeth_main_edge")
	var inner_local := _region_center(identity, "inner_shell")
	var opening_normal := _region_normal(identity, "opening")
	var dump_basis := Basis(Quaternion(opening_normal, Vector3.DOWN))
	var tick := 0
	for cycle in cycle_count:
		var cut_target := Vector2(-2.0 + float(cycle % 5), -2.0 + float(cycle / 5))
		var surface := patch.persistent_field.sample_surface_at(cut_target)
		var frame_x := cut_target.x - teeth_local.x
		var frame_z := cut_target.y - teeth_local.z
		var cut_snapshot := tool.compose_snapshot(
			Transform3D(Basis.IDENTITY, Vector3(frame_x, surface + 0.18 - teeth_local.y, frame_z)),
			Transform3D(Basis.IDENTITY, Vector3(frame_x, surface - 0.04 - teeth_local.y, frame_z)),
			true,
			"repeat:%d:cut" % cycle,
		)
		var cut_classification := tool.classify(cut_snapshot, patch.persistent_field.terrain_state, 0.0, contract["interaction"] as Dictionary)
		var cut_point := _candidate_point(cut_classification, "cut")
		if not cut_point.is_finite():
			return {"passed": false, "reason": "cycle_%d_cut" % cycle}
		tick += 1
		authority.step_fixed(1.0 / 60.0, tick, cut_snapshot, cut_classification, patch, cut_point)
		var carry_transform := Transform3D(Basis.IDENTITY, cut_point - inner_local)
		var carry_snapshot := tool.compose_snapshot(carry_transform, carry_transform, true, "repeat:%d:carry" % cycle)
		var carry_classification := tool.classify(carry_snapshot, patch.persistent_field.terrain_state, 0.0, contract["interaction"] as Dictionary)
		tick += 1
		authority.step_fixed(1.0 / 60.0, tick, carry_snapshot, carry_classification, patch, cut_point)
		if float(authority.get_status_snapshot()["bucket_volume_m3"]) <= 0.000001:
			return {"passed": false, "reason": "cycle_%d_payload" % cycle}
		var dump_x := -2.0 + float(cycle % 5)
		var dump_z := 3.4
		var dump_transform := Transform3D(dump_basis, Vector3(dump_x, 1.4, dump_z))
		var dump_snapshot := tool.compose_snapshot(dump_transform, dump_transform, true, "repeat:%d:dump" % cycle)
		for _settle_tick in 120:
			var fill_ratio := float(authority.get_status_snapshot()["fill_ratio"])
			var dump_classification := tool.classify(dump_snapshot, patch.persistent_field.terrain_state, fill_ratio, contract["interaction"] as Dictionary)
			tick += 1
			authority.step_fixed(1.0 / 60.0, tick, dump_snapshot, dump_classification, patch, dump_transform.origin)
		if float(authority.get_status_snapshot()["bucket_volume_m3"]) > 0.00001:
			return {"passed": false, "reason": "cycle_%d_dump" % cycle}
	var final_status := authority.get_status_snapshot()
	var drift_limit := maxf(0.00001, float(final_status["bucket_capacity_m3"]) * 0.005)
	if absf(float(final_status["conservation_drift_m3"])) > drift_limit:
		return {"passed": false, "reason": "drift_%.9f" % float(final_status["conservation_drift_m3"])}
	if int(final_status["invariant_failure_count"]) != 0:
		return {"passed": false, "reason": "invariant_failures"}
	if source.surface_snapshot()["snapshot_sha256"] != product_digest:
		return {"passed": false, "reason": "product_terrain_mutated"}
	return {"passed": true, "final_status": final_status}


func _candidate_point(classification: Dictionary, action: String) -> Vector3:
	for value in classification.get("candidates", []):
		var candidate := value as Dictionary
		if String(candidate.get("classification", "none")) == action:
			return candidate.get("point_world", Vector3(INF, INF, INF)) as Vector3
	return Vector3(INF, INF, INF)


func _journal_has_kind(journal: Array[Dictionary], kind: String) -> bool:
	for row in journal:
		if String(row.get("kind", "")) == kind:
			return true
	return false


func _region_center(snapshot: Dictionary, region_id: String) -> Vector3:
	for value in snapshot.get("regions", []):
		var region := value as Dictionary
		if String(region.get("region_id", "")) == region_id:
			return region.get("current_center_world", Vector3.ZERO) as Vector3
	return Vector3.ZERO


func _region_sample_point(snapshot: Dictionary, region_id: String) -> Vector3:
	for value in snapshot.get("regions", []):
		var region := value as Dictionary
		if String(region.get("region_id", "")) != region_id:
			continue
		var points := region.get("current_points", []) as Array
		return points[0] as Vector3 if not points.is_empty() else region.get("current_center_world", Vector3.ZERO) as Vector3
	return Vector3.ZERO


func _region_normal(snapshot: Dictionary, region_id: String) -> Vector3:
	for value in snapshot.get("regions", []):
		var region := value as Dictionary
		if String(region.get("region_id", "")) == region_id:
			return region.get("outward_normal_world", Vector3.UP) as Vector3
	return Vector3.UP


func _fail(message: String) -> void:
	push_error(message)
	quit(1)

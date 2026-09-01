extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	for model_id in ["sy205", "sy135"]:
		var descriptor := SoilContractDescriptor.load_for_model(model_id)
		if descriptor == null or not descriptor.is_valid_for(model_id):
			return _fail("%s soil contract unavailable" % model_id)
		var contract := descriptor.to_dictionary()
		var tool := BucketSoilTool.new()
		if not tool.configure(contract):
			return _fail("%s tool configure failed" % model_id)
		var terrain := TerrainState.new(1937, 41, 41, 0.25)
		var start_y := 1.25 if model_id == "sy205" else 0.25
		var finish_y := 0.70 if model_id == "sy205" else -0.30
		var snapshot := tool.compose_snapshot(
			Transform3D(Basis.IDENTITY, Vector3(0.0, start_y, -0.25)),
			Transform3D(Basis.IDENTITY, Vector3(0.0, finish_y, 0.25)),
			true,
			"%s|surface-sweep" % model_id,
		)
		var floor_region := {}
		for region_value in snapshot.get("regions", []):
			var region := region_value as Dictionary
			if String(region.get("region_id", "")) == "floor_wear_plate":
				floor_region = region
				break
		if floor_region.is_empty():
			return _fail("%s floor semantic region missing" % model_id)
		var floor_transform := floor_region["current_transform"] as Transform3D
		var floor_outward := floor_region["outward_normal_world"] as Vector3
		if floor_transform.basis.y.normalized().dot(floor_outward.normalized()) < 0.999:
			return _fail("%s sloped floor plate was flattened to a bucket-link axis" % model_id)
		var rotation_sampling := tool._sweep_sampling(
			Transform3D.IDENTITY,
			Transform3D(Basis(Vector3.RIGHT, deg_to_rad(4.0)), Vector3.ZERO),
		)
		if int(rotation_sampling.get("sample_count", 0)) < 3:
			return _fail("%s rotation sampling ignored the distant cutting edge" % model_id)
		var before := terrain.surface_snapshot()
		var classification := tool.classify(snapshot, terrain, 0.0, contract["interaction"] as Dictionary)
		var builder := BucketSurfaceSweep.new()
		var result := builder.build_patch(snapshot, classification, before, contract["interaction"] as Dictionary, 17)
		if not bool(result.get("valid", false)):
			return _fail("%s sweep rejected: %s" % [model_id, result.get("reason", "missing")])
		var cell_patch := result["patch"] as Dictionary
		var validation := SoilCellPatch.validate_for_snapshot(cell_patch, before)
		if not bool(validation.get("valid", false)):
			return _fail("%s patch invalid: %s" % [model_id, validation.get("reason", "missing")])
		var rows := cell_patch.get("rows", []) as Array
		if rows.size() < 6:
			return _fail("%s sweep did not cover a continuous working surface" % model_id)
		var previous_index := -1
		var covered_columns := {}
		var observed_actions := {}
		var changed_indices := {}
		for value in rows:
			var row := value as Dictionary
			var index := int(row["index"])
			if index <= previous_index:
				return _fail("%s patch rows are not canonical" % model_id)
			previous_index = index
			covered_columns[index % terrain.columns] = true
			observed_actions[String(row["action"])] = true
			changed_indices[index] = true
			var original_surface := float(row["original_stable_height"]) + float(row["original_loose_depth"])
			var target_surface := float(row["target_stable_height"]) + float(row["target_loose_depth"])
			if target_surface >= original_surface - 0.0005 or target_surface < original_surface - float((contract["interaction"] as Dictionary)["maximum_cut_depth_m"]) - 0.00001:
				return _fail("%s target escaped the bounded swept envelope" % model_id)
		if covered_columns.size() < 3:
			return _fail("%s tooth sweep collapsed back to a point/brush" % model_id)
		if not observed_actions.has("cut") or not observed_actions.has("side_cut"):
			return _fail("%s semantic tooth/side surfaces did not contribute" % model_id)
		var product_terrain := TerrainState.new(1937, TerrainState.DEFAULT_ROWS, TerrainState.DEFAULT_COLUMNS, TerrainState.DEFAULT_SPACING_M)
		var product_before := product_terrain.cell_patch_read_snapshot()
		var product_classification := tool.classify(snapshot, product_terrain, 0.0, contract["interaction"] as Dictionary)
		var product_result := builder.build_patch(snapshot, product_classification, product_before, contract["interaction"] as Dictionary, 171)
		if not bool(product_result.get("valid", false)) or int(product_result.get("changed_cell_count", 0)) < 6:
			return _fail("%s sweep lost continuity on the product 0.5 m grid" % model_id)
		var product_columns := {}
		for product_row_value in (product_result["patch"] as Dictionary).get("rows", []):
			product_columns[int((product_row_value as Dictionary)["index"]) % product_terrain.columns] = true
		if product_columns.size() < 3:
			return _fail("%s product-grid sweep collapsed below bucket width" % model_id)
		var continuous_fallback := builder.build_patch(snapshot, {"candidates": []}, product_before, contract["interaction"] as Dictionary, 172)
		if not bool(continuous_fallback.get("valid", false)) or int(continuous_fallback.get("changed_cell_count", 0)) < 6:
			return _fail("%s continuous surface could not recover a sparse-probe miss" % model_id)
		if terrain.surface_snapshot()["snapshot_sha256"] != before["snapshot_sha256"] or terrain.terrain_revision != int(before["terrain_revision"]):
			return _fail("%s pure builder mutated product terrain" % model_id)
		var applied := TerrainState.from_surface_snapshot(before)
		if not applied.enqueue_cell_patch(applied.next_brush_sequence(), cell_patch) or not applied.step_fixed():
			return _fail("%s canonical sweep patch did not apply" % model_id)
		var applied_snapshot := applied.surface_snapshot()
		var before_stable := before["stable_heights"] as PackedFloat32Array
		var before_loose := before["loose_depth"] as PackedFloat32Array
		var after_stable := applied_snapshot["stable_heights"] as PackedFloat32Array
		var after_loose := applied_snapshot["loose_depth"] as PackedFloat32Array
		for index in before_stable.size():
			if changed_indices.has(index):
				continue
			if before_stable[index] != after_stable[index] or before_loose[index] != after_loose[index]:
				return _fail("%s patch changed bytes outside canonical rows" % model_id)

		var semantic_snapshot := tool.compose_snapshot(
			Transform3D(Basis.IDENTITY, Vector3(0.0, finish_y - 0.4, -0.25)),
			Transform3D(Basis.IDENTITY, Vector3(0.0, finish_y - 0.4, 0.25)),
			true,
			"%s|semantic-surfaces" % model_id,
		)
		for semantic_case in [["floor_wear_plate", "scrape"], ["outer_left_side", "side_cut"]]:
			var semantic_result := builder.build_patch(
				semantic_snapshot,
				{"candidates": [{"region_id": semantic_case[0], "classification": semantic_case[1], "role_scope": "stable"}]},
				before,
				contract["interaction"] as Dictionary,
				18,
			)
			if not bool(semantic_result.get("valid", false)):
				return _fail("%s %s semantic surface did not rasterize" % [model_id, semantic_case[0]])

		var slope_snapshot := before.duplicate(true)
		var slope_stable := (before["stable_heights"] as PackedFloat32Array).duplicate()
		var slope_loose := (before["loose_depth"] as PackedFloat32Array).duplicate()
		var slope_surface := PackedFloat32Array()
		slope_surface.resize(slope_stable.size())
		for index in slope_stable.size():
			var column := index % terrain.columns
			slope_stable[index] += (float(column) - float(terrain.columns - 1) * 0.5) * 0.003
			slope_surface[index] = slope_stable[index] + slope_loose[index]
		slope_snapshot["stable_heights"] = slope_stable
		slope_snapshot["loose_depth"] = slope_loose
		slope_snapshot["surface"] = slope_surface
		var slope_state := TerrainState.from_surface_snapshot(slope_snapshot)
		var slope_classification := tool.classify(snapshot, slope_state, 0.0, contract["interaction"] as Dictionary)
		var slope_result := builder.build_patch(snapshot, slope_classification, slope_snapshot, contract["interaction"] as Dictionary, 19)
		if not bool(slope_result.get("valid", false)) or int(slope_result.get("changed_cell_count", 0)) < 6:
			return _fail("%s sloped sweep lost continuous coverage" % model_id)
		var compacted_snapshot := before.duplicate(true)
		var compacted := PackedFloat32Array()
		compacted.resize(terrain.rows * terrain.columns)
		compacted.fill(1.0)
		compacted_snapshot["soil_compaction"] = compacted
		var compacted_result := builder.build_patch(snapshot, classification, compacted_snapshot, contract["interaction"] as Dictionary, 20)
		if not bool(compacted_result.get("valid", false)):
			return _fail("%s compacted sweep did not produce a bounded patch" % model_id)
		var loose_cut := float(result.get("removed_stable_m3", 0.0)) + float(result.get("removed_loose_m3", 0.0))
		var compacted_cut := float(compacted_result.get("removed_stable_m3", 0.0)) + float(compacted_result.get("removed_loose_m3", 0.0))
		if compacted_cut >= loose_cut - 0.000001:
			return _fail("%s compaction did not reduce later cut acceptance" % model_id)

		var reordered := snapshot.duplicate(true)
		var reversed_regions := reordered["regions"] as Array
		reversed_regions.reverse()
		var reordered_result := builder.build_patch(reordered, classification, before, contract["interaction"] as Dictionary, 17)
		if not bool(reordered_result.get("valid", false)) or reordered_result["patch_hash"] != result["patch_hash"]:
			return _fail("%s region order changed canonical patch" % model_id)

		var resting := tool.compose_snapshot(
			Transform3D(Basis.IDENTITY, Vector3(0.0, start_y, 0.0)),
			Transform3D(Basis.IDENTITY, Vector3(0.0, start_y, 0.0)),
			true,
			"%s|rest" % model_id,
		)
		var resting_result := builder.build_patch(resting, tool.classify(resting, terrain, 0.0, contract["interaction"] as Dictionary), before, contract["interaction"] as Dictionary, 20)
		if bool(resting_result.get("valid", false)) or int(resting_result.get("changed_cell_count", 0)) != 0:
			return _fail("%s resting tool erased terrain" % model_id)

		var separating := tool.compose_snapshot(
			Transform3D(Basis.IDENTITY, Vector3(0.0, finish_y, 0.25)),
			Transform3D(Basis.IDENTITY, Vector3(0.0, start_y, 0.25)),
			true,
			"%s|separating" % model_id,
		)
		var separating_result := builder.build_patch(separating, tool.classify(separating, terrain, 0.0, contract["interaction"] as Dictionary), before, contract["interaction"] as Dictionary, 21)
		if bool(separating_result.get("valid", false)) or int(separating_result.get("changed_cell_count", 0)) != 0:
			return _fail("%s separating tool erased terrain" % model_id)

		var denied_classification := classification.duplicate(true)
		for candidate_value in denied_classification.get("candidates", []):
			var denied_candidate := candidate_value as Dictionary
			denied_candidate["classification"] = "contain"
			denied_candidate["role_scope"] = "active"
		var denied_result := builder.build_patch(snapshot, denied_classification, before, contract["interaction"] as Dictionary, 22)
		if bool(denied_result.get("valid", false)) or int(denied_result.get("changed_cell_count", 0)) != 0:
			return _fail("%s non-stable role scope erased terrain" % model_id)

	var descriptor := SoilContractDescriptor.load_for_model("sy205")
	var contract := descriptor.to_dictionary()
	var tool := BucketSoilTool.new()
	tool.configure(contract)
	var discontinuous := tool.compose_snapshot(
		Transform3D(Basis.IDENTITY, Vector3(0.0, 4.0, 0.0)),
		Transform3D(Basis.IDENTITY, Vector3(0.0, -4.0, 0.0)),
		true,
		"sy205|discontinuous",
	)
	if not bool(discontinuous.get("sweep_discontinuous", false)):
		return _fail("discontinuous accepted-pose jump was not marked")
	var terrain := TerrainState.new(1937, 41, 41, 0.25)
	var rejected := BucketSurfaceSweep.new().build_patch(discontinuous, tool.classify(discontinuous, terrain, 0.0, contract["interaction"] as Dictionary), terrain.surface_snapshot(), contract["interaction"] as Dictionary, 21)
	if bool(rejected.get("valid", false)) or rejected.get("reason") != "sweep_discontinuous":
		return _fail("discontinuous sweep did not fail closed")

	var closure_builder := BucketSurfaceSweep.new()
	var closure_stable := PackedFloat32Array()
	closure_stable.resize(9)
	closure_stable[4] = 0.04
	var closure_loose := PackedFloat32Array()
	closure_loose.resize(9)
	var closure_offers := {}
	for index in [1, 3, 5, 7]:
		closure_offers[index] = {"target_surface": -0.02, "action": "cut", "contributors": ["teeth"]}
	var closure_coverage := {}
	for index in 9:
		closure_coverage[index] = {"target_surface": -0.02, "action": "cut", "contributors": ["teeth"]}
	var closure_context := {
		"stable": closure_stable,
		"loose": closure_loose,
		"rows": 3,
		"columns": 3,
		"maximum_cut_depth_m": 0.08,
		"offers": closure_offers,
		"coverage": closure_coverage,
	}
	if closure_builder._close_isolated_spikes(closure_context) != 1:
		return _fail("isolated covered spike was not closed exactly once")
	var closed_offer := (closure_context["offers"] as Dictionary).get(4, {}) as Dictionary
	if closed_offer.is_empty() or absf(float(closed_offer["target_surface"]) + 0.02) > 0.000001:
		return _fail("isolated spike closure did not match its surrounding envelope")
	(closure_context["offers"] as Dictionary).erase(4)
	(closure_context["coverage"] as Dictionary).erase(4)
	if closure_builder._close_isolated_spikes(closure_context) != 0:
		return _fail("spike closure escaped proven swept coverage")

	print("surface_sweep_patch_test: PASS")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)

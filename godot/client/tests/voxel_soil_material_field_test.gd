extends SceneTree

const MaterialField = preload("res://scripts/voxel_soil_material_field.gd")


func _init() -> void:
	var failures: Array[String] = []
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	var field := MaterialField.new()
	_expect(field.configure(contract, 3), "field configures", failures)
	var default_status := field.get_status_snapshot()
	_expect(is_equal_approx(float(default_status.get("bucket_capacity_m3", 0.0)), float(contract.get("heaped_capacity_m3", 0.0))), "default capacity comes from the model contract", failures)
	_expect(not bool(default_status.get("bucket_capacity_overridden", true)), "default capacity is not marked overridden", failures)
	var override_field := MaterialField.new()
	_expect(override_field.configure(contract, 4, 1000.0), "finite test capacity configures", failures)
	var override_status := override_field.get_status_snapshot()
	_expect(is_equal_approx(float(override_status.get("contract_bucket_capacity_m3", 0.0)), float(contract.get("heaped_capacity_m3", 0.0))), "override preserves contract capacity diagnostics", failures)
	_expect(is_equal_approx(float(override_status.get("bucket_capacity_override_m3", 0.0)), 1000.0), "override provenance is reported", failures)
	_expect(is_equal_approx(float(override_status.get("bucket_capacity_m3", 0.0)), 1000.0) and bool(override_status.get("bucket_capacity_overridden", false)), "effective test capacity is reported", failures)
	var fallback_field := MaterialField.new()
	_expect(fallback_field.configure(contract, 5, -1.0), "invalid override falls back to the contract", failures)
	var fallback_status := fallback_field.get_status_snapshot()
	_expect(is_equal_approx(float(fallback_status.get("bucket_capacity_m3", 0.0)), float(contract.get("heaped_capacity_m3", 0.0))) and not bool(fallback_status.get("bucket_capacity_overridden", true)), "negative override cannot replace the contract", failures)
	var cell_volume := 0.125 * 0.125 * 0.125
	var removed_volume := cell_volume * 0.25
	var requested := field.mass_q_for_volume(removed_volume)
	var changes: Array[Dictionary] = [{
		"coordinate": Vector3i(1, 2, 3),
		"pre_fraction": 1.0,
		"post_fraction": 0.75,
		"cell_volume_m3": cell_volume,
		"removed_mass_q": requested,
	}]
	var staged := field.stage_cut(changes, requested)
	_expect(bool(staged.get("valid", false)), "cut stages", failures)
	_expect(field.bucket_mass_q == 0, "staging is mutation-free", failures)
	_expect(field.commit_cut(staged), "cut commits", failures)
	_expect(field.bucket_mass_q == requested, "bucket receives exact fixed-point mass", failures)
	_expect(field.terrain_mass_delta_q == -requested, "terrain loses equal mass", failures)
	_expect(field.conservation_error_q == 0, "conservation is exact", failures)
	field.bucket_mass_q = field.bucket_capacity_mass_q
	var full_stage := field.stage_cut(changes, 1)
	_expect(not bool(full_stage.get("valid", false)), "full bucket stages no removal", failures)

	var cycle := MaterialField.new()
	_expect(cycle.configure(contract, 6), "material cycle field configures", failures)
	var loose_mass_q := cycle.mass_q_for_loose_volume(cell_volume * 0.25)
	_expect(cycle.credit_bucket_mass_for_test(loose_mass_q), "test seam credits conserved bucket mass", failures)
	var deposit_changes: Array[Dictionary] = [{
		"coordinate": Vector3i(4, 5, 6),
		"pre_fraction": 0.0,
		"post_fraction": 0.25,
		"cell_volume_m3": cell_volume,
		"added_mass_q": loose_mass_q,
	}]
	var deposit_stage := cycle.stage_deposit(deposit_changes, loose_mass_q)
	_expect(bool(deposit_stage.get("valid", false)) and cycle.bucket_mass_q == loose_mass_q, "deposit staging is mutation-free", failures)
	_expect(cycle.commit_deposit(deposit_stage), "deposit commits atomically", failures)
	_expect(cycle.bucket_mass_q == 0 and cycle.terrain_mass_delta_q == 0, "deposit reverses bucket credit exactly", failures)
	_expect(cycle.total_mobile_mass_q() == loose_mass_q and cycle.total_stable_mass_q() == 0, "aggregate material totals expose deposited soil", failures)
	var deposited := cycle.cell_snapshot(Vector3i(4, 5, 6))
	_expect(int(deposited.get("mobile_mass_q", 0)) == loose_mass_q and int(deposited.get("stable_mass_q", -1)) == 0, "deposit creates mobile soil without stable reclassification", failures)
	var transfer_q := loose_mass_q / 2
	var transfer_stage := cycle.stage_mobile_transfer(
		[{"coordinate": Vector3i(4, 5, 6), "removed_mass_q": transfer_q}],
		[{"coordinate": Vector3i(5, 4, 6), "pre_fraction": 0.0, "cell_volume_m3": cell_volume, "added_mass_q": transfer_q, "incoming_compaction_q": 0}],
		transfer_q,
	)
	_expect(cycle.commit_mobile_transfer(transfer_stage), "paired repose transfer commits", failures)
	_expect(cycle.mobile_mass_q_at(Vector3i(4, 5, 6)) + cycle.mobile_mass_q_at(Vector3i(5, 4, 6)) == loose_mass_q, "paired transfer conserves mobile mass", failures)
	var stable_digest := cycle.state_digest()
	var compact_mass_q := cycle.mobile_mass_q_at(Vector3i(5, 4, 6))
	var loose_bulk_volume := cycle.mobile_bulk_volume_for_mass_q(compact_mass_q, cycle.mobile_compaction_q_at(Vector3i(5, 4, 6)))
	var compact_stage := cycle.stage_compaction([Vector3i(5, 4, 6), Vector3i(99, 99, 99)], 80)
	_expect(float(compact_stage.get("volume_loss_m3", 0.0)) > 0.0, "compaction stages an explicit bulk-volume reduction", failures)
	_expect(cycle.commit_compaction(compact_stage), "loose-only compaction commits", failures)
	_expect(cycle.state_digest() != stable_digest, "compaction changes mobile material state", failures)
	_expect(cycle.mobile_bulk_volume_for_mass_q(compact_mass_q, cycle.mobile_compaction_q_at(Vector3i(5, 4, 6))) < loose_bulk_volume, "higher compaction reduces equal-mass bulk volume", failures)
	_expect(cycle.total_mobile_mass_q() == loose_mass_q, "compaction preserves aggregate mobile mass", failures)
	_expect(cycle.cell_snapshot(Vector3i(99, 99, 99)).is_empty(), "compaction does not create material on untouched stable/empty cells", failures)
	_expect(cycle.conservation_error_q == 0, "deposit, settle and compact keep exact ledger conservation", failures)

	var approximate := MaterialField.new()
	_expect(approximate.configure(contract, 7, 1000.0), "approximate cut field configures", failures)
	var approximate_coordinates: Array[Vector3i] = [Vector3i(8, -2, 12), Vector3i(8, -2, 12), Vector3i(9, -2, 12)]
	var approximate_stage := approximate.stage_approximate_cut(approximate_coordinates, cell_volume)
	_expect(bool(approximate_stage.get("valid", false)), "sparse approximate cut stages", failures)
	var approximate_mass_q := int(approximate_stage.get("accepted_mass_q", 0))
	_expect(approximate.commit_approximate_cut(approximate_stage), "sparse approximate cut commits", failures)
	_expect(approximate.bucket_mass_q == approximate_mass_q and approximate.conservation_error_q == 0, "approximate credit remains exactly conserved", failures)
	var deferred_status := approximate.get_status_snapshot()
	_expect(bool(deferred_status.get("material_state_digest_deferred", false)) and String(deferred_status.get("material_state_digest", "")).is_empty(), "routine status defers the full material digest", failures)
	var diagnostic_digest := approximate.state_digest()
	var diagnostic_status := approximate.get_status_snapshot()
	_expect(not diagnostic_digest.is_empty() and not bool(diagnostic_status.get("material_state_digest_deferred", true)), "explicit diagnostics publish the current material digest", failures)
	var repeated_stage := approximate.stage_approximate_cut(approximate_coordinates, cell_volume)
	_expect(not bool(repeated_stage.get("valid", false)), "coverage prevents repeated credit for the same cut cells", failures)
	var approximate_deposit_changes: Array[Dictionary] = [{
		"coordinate": Vector3i(8, -2, 12),
		"pre_fraction": 0.0,
		"post_fraction": 1.0,
		"cell_volume_m3": cell_volume,
		"added_mass_q": approximate_mass_q,
	}]
	var approximate_deposit := approximate.stage_deposit(approximate_deposit_changes, approximate_mass_q)
	_expect(approximate.commit_deposit(approximate_deposit), "deposit invalidates approximate coverage", failures)
	var recut_stage := approximate.stage_approximate_cut([Vector3i(8, -2, 12)], cell_volume)
	_expect(bool(recut_stage.get("valid", false)), "deposited cell can be credited by a later cut", failures)
	if failures.is_empty():
		print("Voxel soil material field contracts passed.")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append("voxel material field: %s" % message)

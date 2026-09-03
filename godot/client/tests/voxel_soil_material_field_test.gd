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

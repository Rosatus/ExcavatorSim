extends SceneTree

const CONTRACT_PATHS := {
	"sy205": "res://resources/models/sy205_soil_contract.json",
	"sy135": "res://resources/models/sy135_soil_contract.json",
}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	for model_id in ["sy205", "sy135"]:
		var descriptor := SoilContractDescriptor.load_for_model(model_id)
		if descriptor == null or not descriptor.is_valid_for(model_id):
			return _fail("%s soil contract rejected: %s" % [model_id, "missing" if descriptor == null else descriptor.validation_error()])
		var contract := descriptor.to_dictionary()
		if (contract["bucket_tool"]["regions"] as Array).size() != 9:
			return _fail("%s does not define the complete bucket" % model_id)
		var tool := BucketSoilTool.new()
		if not tool.configure(contract):
			return _fail("%s tool configure failed: %s" % [model_id, tool.validation_error])
		var composed := tool.compose_snapshot(
			Transform3D(Basis.IDENTITY, Vector3(0.0, 1.2, 0.0)),
			Transform3D(Basis.IDENTITY, Vector3(0.0, 1.1, 0.0)),
			true,
			"%s|generation-1" % model_id,
		)
		if not bool(composed.get("valid", false)) or (composed.get("regions", []) as Array).size() != 9:
			return _fail("%s region composition failed" % model_id)

	var source := _read_json(CONTRACT_PATHS["sy205"])
	var invalid_inner := source.duplicate(true)
	invalid_inner["bucket_tool"]["regions"][7]["stable_soil_roles"] = ["cut"]
	var invalid_descriptor := SoilContractDescriptor.from_dictionary_for_test(invalid_inner)
	if invalid_descriptor.is_valid_for("sy205"):
		return _fail("inner shell was allowed to erase stable terrain")
	var invalid_capacity := source.duplicate(true)
	invalid_capacity["bucket_tool"]["capacity"]["heaped_m3"] = 1.09
	invalid_descriptor = SoilContractDescriptor.from_dictionary_for_test(invalid_capacity)
	if invalid_descriptor.is_valid_for("sy205"):
		return _fail("tool capacity drift was accepted")

	var terrain := TerrainState.new(7, 41, 41, 0.25)
	var tool := BucketSoilTool.new()
	if not tool.configure(source):
		return _fail(tool.validation_error)
	var interaction := source["interaction"] as Dictionary

	# Long downward motion crosses the surface between endpoints. The bounded
	# swept samples must retain the first working-band tooth contact.
	var long_sweep := tool.compose_snapshot(
		Transform3D(Basis.IDENTITY, Vector3(0.0, 1.25, 0.0)),
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.70, 0.0)),
		true,
		"sy205|generation-1|long-sweep",
	)
	if int(long_sweep.get("sweep_sample_count", 0)) <= 2:
		return _fail("long stroke was not segmented")
	var before_terrain := terrain.surface_snapshot()
	var soil_state := BucketSoilState.new(terrain, source)
	var before_soil := soil_state.get_status_snapshot()
	var cut_result := tool.classify(long_sweep, terrain, 0.0, interaction)
	if _classification(cut_result, "teeth_main_edge") != "cut":
		return _fail("forward swept tooth contact was not classified as cut")
	if terrain.terrain_revision != int(before_terrain["terrain_revision"]) or terrain.surface_snapshot()["snapshot_sha256"] != before_terrain["snapshot_sha256"]:
		return _fail("shadow classifier mutated terrain")
	if soil_state.get_status_snapshot()["bucket_volume_m3"] != before_soil["bucket_volume_m3"]:
		return _fail("shadow classifier mutated bucket inventory")

	var resting := tool.compose_snapshot(
		Transform3D(Basis.IDENTITY, Vector3(0.0, 1.01, 0.0)),
		Transform3D(Basis.IDENTITY, Vector3(0.0, 1.01, 0.0)),
		true,
		"sy205|generation-1|rest",
	)
	if _classification(tool.classify(resting, terrain, 0.0, interaction), "teeth_main_edge") != "none":
		return _fail("resting tooth produced cut intent")

	var lateral := tool.compose_snapshot(
		Transform3D(Basis.IDENTITY, Vector3(-0.05, 1.0, 0.0)),
		Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0)),
		true,
		"sy205|generation-1|side",
	)
	if _classification(tool.classify(lateral, terrain, 0.0, interaction), "left_side_cutter") != "side_cut":
		return _fail("side cutter did not classify lateral contact")

	var scrape := tool.compose_snapshot(
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.65, -0.05)),
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.65, 0.0)),
		true,
		"sy205|generation-1|scrape",
	)
	if _classification(tool.classify(scrape, terrain, 0.0, interaction), "floor_wear_plate") != "scrape":
		return _fail("floor did not classify scrape contact")

	var back_outward := Vector3(0.0, -0.707107, 0.707107).normalized()
	var push_start := Transform3D(Basis.IDENTITY, Vector3(0.0, 0.405, 0.0))
	var push_finish := Transform3D(Basis.IDENTITY, push_start.origin - back_outward * 0.05)
	var push := tool.compose_snapshot(push_start, push_finish, true, "sy205|generation-1|push")
	if _classification(tool.classify(push, terrain, 0.0, interaction), "outer_back") != "push":
		return _fail("outer back did not classify push contact")

	var carry := tool.compose_snapshot(
		Transform3D(Basis.IDENTITY, Vector3(0.0, 2.0, 0.0)),
		Transform3D(Basis.IDENTITY, Vector3(0.0, 2.0, 0.0)),
		true,
		"sy205|generation-1|carry",
	)
	if _classification(tool.classify(carry, terrain, 0.5, interaction), "inner_shell") != "contain":
		return _fail("inner shell did not classify active-soil containment")

	var opening_normal := Vector3(0.0, 0.707107, 0.707107).normalized()
	var dump_basis := Basis(Quaternion(opening_normal, Vector3.DOWN))
	var dump := tool.compose_snapshot(
		Transform3D(dump_basis, Vector3(0.0, 2.0, 0.0)),
		Transform3D(dump_basis, Vector3(0.0, 2.0, 0.0)),
		true,
		"sy205|generation-1|dump",
	)
	if _classification(tool.classify(dump, terrain, 0.5, interaction), "opening") != "dump":
		return _fail("opening orientation did not classify dump")

	var buried_inner := tool.compose_snapshot(
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.25, 0.0)),
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.20, 0.0)),
		true,
		"sy205|generation-1|inner-overlap",
	)
	var buried_result := tool.classify(buried_inner, terrain, 0.0, interaction)
	if _classification(buried_result, "inner_shell") != "none" or _scope(buried_result, "inner_shell") == "stable":
		return _fail("full inner-shell overlap acquired stable-terrain authority")

	print("bucket_soil_tool_test: PASS")
	quit(0)


func _classification(result: Dictionary, region_id: String) -> String:
	for value in result.get("candidates", []):
		var candidate := value as Dictionary
		if candidate.get("region_id") == region_id:
			return String(candidate.get("classification", "missing"))
	return "missing"


func _scope(result: Dictionary, region_id: String) -> String:
	for value in result.get("candidates", []):
		var candidate := value as Dictionary
		if candidate.get("region_id") == region_id:
			return String(candidate.get("role_scope", "missing"))
	return "missing"


func _read_json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}


func _fail(message: String) -> void:
	push_error(message)
	quit(1)

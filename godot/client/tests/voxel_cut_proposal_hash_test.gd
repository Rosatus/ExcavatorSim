extends SceneTree


func _init() -> void:
	var failures: Array[String] = []
	var proposal := VoxelCutProposal.create({"generation": 1, "fixed_tick_begin": 1,
		"fixed_tick_end": 2, "sequence": 2, "model_id": "sy135", "authority_epoch": "hash-test",
		"tool_hash": "tool", "area_voxels": AABB(Vector3.ZERO, Vector3.ONE * 4),
		"capsules": [{"source": "edge", "a_voxels": Vector3.ZERO, "b_voxels": Vector3.ONE, "radius_voxels": 1.0}],
		"clearance_capsules": [{"source": "clearance", "a_voxels": Vector3.ZERO, "b_voxels": Vector3.UP, "radius_voxels": 0.5}],
		"native_paths": [{"path_id": "native", "role": "leading_edge", "components": ["edge"],
			"points_voxels": PackedVector3Array([Vector3.ZERO, Vector3.ONE]), "radii_voxels": PackedFloat32Array([1, 1])}]})
	_check(proposal.is_valid() and proposal._compute_hash() == proposal._compute_uncached_hash(), "initial canonical hash", failures)
	_check(proposal.to_dictionary().schema_version == "voxel-cut-proposal-v2", "binary canonical identity is versioned", failures)
	var reordered := proposal.to_dictionary()
	for collection in ["capsules", "clearance_capsules", "native_paths"]:
		for index in reordered[collection].size():
			var source: Dictionary = reordered[collection][index]
			var keys := source.keys()
			keys.reverse()
			var rebuilt := {}
			for key in keys:
				rebuilt[key] = source[key]
			reordered[collection][index] = rebuilt
	var same := VoxelCutProposal.create(reordered)
	_check(same.input_hash == proposal.input_hash, "dictionary insertion order cannot change canonical identity", failures)
	reordered.native_paths[0].points_voxels = Array(reordered.native_paths[0].points_voxels)
	reordered.native_paths[0].radii_voxels = Array(reordered.native_paths[0].radii_voxels)
	_check(VoxelCutProposal.create(reordered).input_hash == proposal.input_hash, "array input normalizes to the same packed geometry", failures)
	for field in ["generation", "fixed_tick_begin", "fixed_tick_end", "sequence", "model_id", "authority_epoch", "tool_hash"]:
		var changed := proposal.duplicate_typed()
		var value: Variant = changed.get(field)
		changed.set(field, value + 1 if value is int else String(value) + "-changed")
		_check_mutation(changed, field, failures)
	for kind in 8:
		var changed := proposal.duplicate_typed()
		match kind:
			0: changed.capsules[0]["a_voxels"] = Vector3.LEFT
			1: changed.clearance_capsules[0]["radius_voxels"] = 0.7
			2: changed.native_paths[0]["points_voxels"][1] = Vector3.RIGHT
			3: changed.native_paths[0]["radii_voxels"][1] = 0.75
			4: changed.native_paths[0]["components"].append("side")
			5: changed.native_paths[0]["role"] = "bucket_floor"
			6: changed.native_paths[0]["path_id"] = "other-path"
			7: changed.capsules.append(changed.capsules[0].duplicate(true))
		_check_mutation(changed, "nested %d" % kind, failures)
		_check(proposal.is_valid(), "copy mutation leaves source valid", failures)
	var forged := proposal.duplicate_typed()
	forged.input_hash = "forged"
	_check(not forged.is_valid(), "forged public hash rejected", failures)
	var restored := proposal.duplicate_typed()
	restored.native_paths[0]["points_voxels"][1] = Vector3.RIGHT
	_check(not restored.is_valid(), "changed geometry rejected", failures)
	restored.native_paths[0]["points_voxels"][1] = Vector3.ONE
	_check(restored.is_valid(), "restored geometry regains canonical hash", failures)
	var precise := proposal.duplicate_typed()
	precise.native_paths[0].points_voxels[0] = Vector3(0.0000001, 0, 0)
	_check(not precise.is_valid(), "binary identity also detects changes below six decimal places", failures)
	for failure in failures:
		push_error(failure)
	print("PROPOSAL_HASH %s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)


func _check_mutation(proposal: VoxelCutProposal, label: String, failures: Array[String]) -> void:
	_check(not proposal.is_valid(), "mutation rejected: " + label, failures)
	_check(proposal._compute_hash() == proposal._compute_uncached_hash(), "same uncached canonical v2 hash: " + label, failures)


func _check(value: bool, message: String, failures: Array[String]) -> void:
	if not value:
		failures.append(message)

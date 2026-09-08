extends "res://tests/voxel_excavation_authority_test.gd"


func _run() -> void:
	var failures: Array[String] = []
	var zone := WorkZone.new()
	root.add_child(zone)
	_expect(await _wait_initial_ready(zone), "recut fixture ready", failures)
	_check_recut(zone, Vector3(0, -0.25, 24), 0.0, failures)
	_check_recut(zone, Vector3(4, -0.25, 24), 0.000001, failures)
	var empty := VoxelCutTransaction.new()
	empty.revision = 1
	empty.accounting_mode = "sparse_coverage_approximate"
	_expect(not empty.accepted(), "zero credit alone cannot accept a cut", failures)
	empty.native_geometry_only = true
	empty.operation = "deposit"
	_expect(not empty.accepted(), "geometry-only flag cannot accept a zero-mass deposit", failures)
	zone.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	print("RESIDUAL_RECUT %s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)


func _check_recut(zone: VoxelWorkZone, center_world: Vector3, capacity_m3: float, failures: Array[String]) -> void:
	var authority := Authority.new()
	authority.configure(zone, SoilContractDescriptor.load_for_model("sy135").to_dictionary(), zone.readiness.generation, capacity_m3)
	var center := WorkZoneConfig.world_to_voxel(center_world, zone.voxel_scale_m)
	var first_credit := -1
	var first_digest := ""
	var cleanup_commits := 0
	# Two overlapping product-radius brushes; the first credits nearby solid
	# stencil cells beyond the actual removed shape. The second targets them.
	for step in range(12):
		var a := center + Vector3(0.22 + step * 0.04, -0.42 + step * 0.02, 0.4 - step * 0.02)
		var path := authority.cutter._native_path("recut", "bucket_occupancy",
			PackedVector3Array([a, a + Vector3(0, 0, 0.12)]), 0.88)
		var paths: Array[Dictionary] = [path]
		var proposal := CutProposal.create({"generation": authority.generation, "fixed_tick_begin": step + 1,
			"fixed_tick_end": step + 1, "sequence": step + 1, "model_id": "sy135", "authority_epoch": "recut-test",
			"tool_hash": authority.tool_hash, "native_paths": paths, "area_voxels": authority.cutter._native_path_bounds(paths),
			"probe_world": WorkZoneConfig.voxel_to_world(a, zone.voxel_scale_m)})
		# Exercise the real queue/changed/publication path after admission.
		var before_sdf := zone.get_voxel_tool().get_voxel_f(Vector3i(center) + Vector3i.RIGHT)
		authority._queue.append(proposal)
		var result := authority.flush_for_test()
		var transaction := result["transaction"] as Dictionary
		var target := Vector3i(center) + Vector3i.RIGHT
		var actual := zone.get_voxel_tool().get_voxel_f(target)
		print("RECUT step=%d reason=%s changed=%s mass=%d target=%s sdf=%.4f" % [step, transaction["rejection_reason"],
			result["changed"], transaction["accepted_mass_q"], target, actual])
		if step == 0:
			first_credit = authority.material_field.bucket_mass_q
			first_digest = authority.material_field.state_digest()
			_expect(first_credit > 0 and actual <= 0, "first brush credits cell but leaves a real partial residual", failures)
		else:
			_expect(authority.material_field.bucket_mass_q == first_credit and authority.material_field.state_digest() == first_digest,
				"residual geometry never repeats mass credit", failures)
			if bool(result["changed"]):
				cleanup_commits += 1
				_expect(actual > before_sdf, "each residual commit changes real SDF", failures)
				_expect(int(transaction["accepted_mass_q"]) == 0 and bool(transaction["native_geometry_only"]),
					"zero-credit cleanup still publishes changed terrain", failures)
		# Inspect a real sample strictly inside this capsule, independently of
		# the sparse accounting stencil. It must be air after an authorized cut.
		if Vector3(target).distance_to(a) < 0.87:
			_expect(actual > 0, "recut step %d clears real solid despite prior credit (%s)" % [step, transaction["rejection_reason"]], failures)
	_expect(cleanup_commits > 0, "fixture executes at least one zero-credit geometry transaction", failures)
	_expect(authority.material_field.conservation_error_q == 0, "recut preserves mass balance", failures)
	authority.clear()

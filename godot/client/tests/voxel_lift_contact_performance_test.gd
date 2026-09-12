extends "res://tests/voxel_excavation_authority_test.gd"

var _reference_reads := 0


func _run() -> void:
	var failures: Array[String] = []
	for scale in WorkZoneConfig.candidate_scales_m():
		await _check_contact(float(scale), failures)
	await _check_recorded_scoop(failures)
	for failure in failures:
		push_error(failure)
	print("LIFT_CONTACT_PERFORMANCE %s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)


func _reference_sample(point: Vector3, authority: VoxelExcavationAuthority) -> Dictionary:
	_reference_reads += 1
	return authority._sample_sdf_world(point)


func _check_contact(scale: float, failures: Array[String]) -> void:
	var zone := WorkZone.new()
	zone.voxel_scale_m = scale
	root.add_child(zone)
	_expect(await _wait_initial_ready(zone), "contact fixture ready at %s" % scale, failures)
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	var authority := Authority.new()
	_expect(authority.configure(zone, contract, zone.readiness.generation), "contact authority configured", failures)
	_check_batch_probe_equivalence(authority, contract, failures)
	var previous := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(25)), Vector3(0, -1.0, 24))
	var current := Transform3D(previous.basis, previous.origin + Vector3(0, 0.005, 0.005))
	var pose := _pose_from_transforms(contract, previous, current, "contact-pair")
	# Both callbacks must admit exactly the same immutable proposal in solid soil.
	_compare_proposal(authority, pose, true, failures)
	_compare_proposal(authority, pose, false, failures)
	var probe := Vector3(0, -0.5, 24)
	var before := authority._sample_contact_sdf_world(probe, {})
	_expect(bool(before.get("valid", false)) and float(before.get("sdf", INF)) < 0, "probe initially solid", failures)
	var probe_voxel := WorkZoneConfig.world_to_voxel(probe, scale)
	var probe_coordinate := Vector3i(round(probe_voxel.x), round(probe_voxel.y), round(probe_voxel.z))
	_expect(authority._has_solid_contact_voxels({probe_coordinate: true}), "batch initially sees solid", failures)
	# Clear the entire trailing footprint. This is the costly no-contact case:
	# every column must be checked before retaining the episode without a cut.
	var tool := zone.get_voxel_tool()
	tool.mode = VoxelTool.MODE_REMOVE
	tool.do_box(WorkZoneConfig.world_to_voxel(Vector3(-3, -3, 20), scale),
		WorkZoneConfig.world_to_voxel(Vector3(3, 2, 28), scale))
	var after := authority._sample_contact_sdf_world(probe, {})
	_expect(bool(after.get("valid", false)) and float(after.get("sdf", -INF)) > 0, "new proposal observes edited SDF", failures)
	_expect(not authority._has_solid_contact_voxels({probe_coordinate: true}), "same-sized batch refreshes after a cut", failures)
	_compare_proposal(authority, pose, true, failures)
	_compare_proposal(authority, pose, false, failures)
	var samples: Dictionary = {}
	for point in [probe, probe + Vector3.ONE * scale * 0.01, Vector3(-1000, 0, 0),
		Vector3(INF, 0, 0), Vector3(0, 0, 24), Vector3(-3, -0.5, 24)]:
		var expected := authority._sample_sdf_world(point)
		var actual := authority._sample_contact_sdf_world(point, samples)
		_expect(actual.get("valid") == expected.get("valid"), "contact preserves validity at %s" % point, failures)
		if bool(expected.get("valid", false)):
			_expect(actual.get("sdf") == expected.get("sdf"), "contact preserves exact rounded SDF at %s" % point, failures)
	# A large/unloaded bounding box must fall back to per-point validity. The
	# valid solid probe still counts; invalid points alone never authorize a cut.
	var solid := Vector3i(probe_coordinate.x - ceili(4.0 / scale), probe_coordinate.y, probe_coordinate.z)
	_expect(authority._has_solid_contact_voxels({Vector3i(-10000, 0, 0): true, solid: true}), "batch fallback retains a valid solid point", failures)
	_expect(not authority._has_solid_contact_voxels({Vector3i(-10000, 0, 0): true, probe_coordinate: true}), "batch fallback does not invent solid at invalid points", failures)
	var timings: Array[Array] = [[], [], []]
	var unique_cells := 0
	var full_reads := 0
	for iteration in 7:
		for offset in 3:
			var variant := (iteration + offset) % 3
			var cache: Dictionary = {}
			_reference_reads = 0
			var sampler := _reference_sample.bind(authority) if variant == 0 else authority._sample_contact_sdf_world.bind(cache)
			var batch := authority._has_solid_contact_voxels if variant == 2 else Callable()
			var started := Time.get_ticks_usec()
			var contact := authority.cutter._has_lift_exit_contact(pose.soil_tool, sampler, true, batch)
			timings[variant].append(Time.get_ticks_usec() - started)
			_expect(not contact, "cleared lift has no contact", failures)
			if variant == 0:
				full_reads = _reference_reads
			elif variant == 1:
				unique_cells = cache.size()
	for series in timings:
		series.sort()
	_expect(full_reads > 100 and unique_cells > 0 and unique_cells < full_reads, "real repeated contact workload deduplicated", failures)
	print("PAIRED_LIFT_CONTACT %s" % JSON.stringify({"scale_m": scale, "samples_per_version": 7,
		"before_median_usec": timings[0][3], "after_median_usec": timings[1][3],
		"batch_median_usec": timings[2][3],
		"contact_queries": full_reads, "unique_cells": unique_cells,
		"before_native_sdf_reads": full_reads * 7, "after_native_sdf_reads": unique_cells}))
	# A later edit must restore contact, with unchanged accepted proposal geometry.
	tool.mode = VoxelTool.MODE_ADD
	tool.do_sphere(WorkZoneConfig.world_to_voxel(probe, scale), 0.3 / scale)
	_expect(authority._has_solid_contact_voxels({probe_coordinate: true}), "same-sized batch refreshes after a deposit", failures)
	_expect(authority.cutter._has_lift_exit_contact(pose.soil_tool, authority._sample_contact_sdf_world.bind({})), "later solid residual is detected", failures)
	_compare_proposal(authority, pose, true, failures)
	authority.clear()
	zone.queue_free()
	await process_frame


func _collect_air_probe(world: Vector3, authority: VoxelExcavationAuthority, collected: Dictionary) -> Dictionary:
	var voxel := WorkZoneConfig.world_to_voxel(world, authority._work_zone.voxel_scale_m)
	collected[Vector3i(round(voxel.x), round(voxel.y), round(voxel.z))] = true
	return {"valid": true, "sdf": 1.0, "gradient_world": Vector3.UP}


func _collect_air_batch(voxels: Dictionary, collected: Dictionary) -> bool:
	collected.merge(voxels)
	return false


func _check_batch_probe_equivalence(authority: VoxelExcavationAuthority, contract: Dictionary, failures: Array[String]) -> void:
	# Include the 32-interval deep-column cap, rotation, negative coordinates and
	# subvoxel boundary positions. Batching must not expand or thin the probe set.
	for depth in [-0.01, -0.75, -2.0, -4.5]:
		for angle in [-70.0, 25.0, 70.0]:
			var previous := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(angle)), Vector3(-0.063, depth, 23.937))
			var current := Transform3D(previous.basis, previous.origin + Vector3(0, 0.005, 0.005))
			var pose := _pose_from_transforms(contract, previous, current, "batch-points")
			var scalar: Dictionary = {}
			var batch: Dictionary = {}
			authority.cutter._has_lift_exit_contact(pose.soil_tool, _collect_air_probe.bind(authority, scalar))
			authority.cutter._has_lift_exit_contact(pose.soil_tool, _collect_air_probe.bind(authority, batch), true, _collect_air_batch.bind(batch))
			_expect(scalar == batch, "batch preserves exact rounded probes at depth %s angle %s" % [depth, angle], failures)


func _compare_proposal(authority: VoxelExcavationAuthority, pose: Dictionary, engaged: bool, failures: Array[String]) -> void:
	var baseline := authority.cutter.build_proposal(pose, authority.generation, 1, 1, "pair", engaged, authority._sample_sdf_world)
	var optimized := authority.cutter.build_proposal(pose, authority.generation, 1, 1, "pair", engaged,
		authority._sample_sdf_world, authority._sample_contact_sdf_world.bind({}), authority._has_solid_contact_voxels)
	var before := baseline.get("proposal") as VoxelCutProposal
	var after := optimized.get("proposal") as VoxelCutProposal
	_expect((before == null) == (after == null), "same proposal presence", failures)
	if before != null and after != null:
		_expect(before.input_hash == after.input_hash and before.native_paths == after.native_paths
			and before.capsules == after.capsules and before.clearance_capsules == after.clearance_capsules,
			"contact optimization preserves proposal identity and complete geometry", failures)
	baseline.erase("proposal")
	optimized.erase("proposal")
	_expect(baseline == optimized, "contact optimization preserves admission, episode and diagnostics", failures)


func _check_recorded_scoop(failures: Array[String]) -> void:
	var zone := WorkZone.new()
	root.add_child(zone)
	_expect(await _wait_initial_ready(zone), "recorded scoop fixture ready", failures)
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	var authority := Authority.new()
	authority.configure(zone, contract, zone.readiness.generation)
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/sy135_live_residual_trajectory.json"))
	var previous := Transform3D.IDENTITY
	var times: Array[Array] = [[], []]
	var accepted := 0
	var hash_times: Array[Array] = [[], []]
	for row in fixture.frames:
		var current := Transform3D(Basis(Vector3(row[4], row[5], row[6]), Vector3(row[7], row[8], row[9]), Vector3(row[10], row[11], row[12])), Vector3(row[1], row[2], row[3]))
		if previous == Transform3D.IDENTITY:
			previous = current
		var tick := int(row[0])
		var pose := _pose_from_transforms(contract, previous, current, "recorded-%d" % tick)
		var results: Array[Dictionary] = [{}, {}]
		for offset in 2:
			var variant := (tick + offset) % 2
			var sampler := Callable() if variant == 0 else authority._sample_contact_sdf_world.bind({})
			var batch := Callable() if variant == 0 else authority._has_solid_contact_voxels
			var started := Time.get_ticks_usec()
			results[variant] = authority.cutter.build_proposal(pose, authority.generation, tick, tick, "paired-recorded", authority._engaged, authority._sample_sdf_world, sampler, batch)
			times[variant].append(Time.get_ticks_usec() - started)
		var before := results[0].get("proposal") as VoxelCutProposal
		var after := results[1].get("proposal") as VoxelCutProposal
		_expect((before == null) == (after == null), "recorded proposal presence at %d" % tick, failures)
		if before != null and after != null:
			accepted += 1
			_expect(before.input_hash == after.input_hash and before.native_paths == after.native_paths,
				"recorded complete geometry/identity at %d" % tick, failures)
			for offset in 2:
				var variant := (tick + offset) % 2
				var started := Time.get_ticks_usec()
				var value := after._compute_uncached_hash() if variant == 0 else after._compute_hash()
				hash_times[variant].append(Time.get_ticks_usec() - started)
				_expect(value == after.input_hash, "recorded hash equals uncached canonical v2 format", failures)
		for result in results:
			result.erase("proposal")
		_expect(results[0] == results[1], "recorded admission and episode at %d" % tick, failures)
		authority.submit_pose(pose, _identity(authority.generation, tick, tick))
		authority.step_fixed(1.0 / 60.0)
		previous = current
	var summaries: Array = []
	for series in times:
		series.sort()
		summaries.append({"p50_usec": series[series.size() / 2], "p95_usec": series[ceili(series.size() * 0.95) - 1], "max_usec": series[-1]})
	_expect(accepted > 100 and authority.material_field.conservation_error_q == 0, "paired scoop performs real mass-conserving edits", failures)
	print("PAIRED_RECORDED_PROPOSALS %s" % JSON.stringify({"frames": times[0].size(), "accepted": accepted, "before": summaries[0], "after": summaries[1]}))
	for series in hash_times:
		series.sort()
	print("PAIRED_PROPOSAL_HASH %s" % JSON.stringify({"proposals": hash_times[0].size(),
		"before_p50_usec": hash_times[0][hash_times[0].size() / 2], "after_p50_usec": hash_times[1][hash_times[1].size() / 2],
		"before_p95_usec": hash_times[0][ceili(hash_times[0].size() * 0.95) - 1], "after_p95_usec": hash_times[1][ceili(hash_times[1].size() * 0.95) - 1]}))
	authority.clear()
	zone.queue_free()
	await process_frame

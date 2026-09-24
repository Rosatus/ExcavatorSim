extends "res://tests/voxel_excavation_authority_test.gd"

const Preparation = preload("res://scripts/voxel_cut_preparation.gd")
const LegacyCleanup = preload("res://tests/fixtures/legacy_voxel_support_cleanup.gd")


func _run() -> void:
	var failures: Array[String] = []
	var zone := WorkZone.new()
	root.add_child(zone)
	_expect(await _wait_initial_ready(zone), "deep fixture ready", failures)
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	var authority := Authority.new()
	authority.configure(zone, contract, zone.readiness.generation, 1000.0)
	for depth in [0.25, 2.0, 4.0]:
		_check_prepared_depth(zone, authority, contract, depth, failures)
	_check_cleanup_parity(zone, contract, failures)
	authority.clear()
	zone.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	print("DEEP_CUT failures=%d" % failures.size())
	quit(0 if failures.is_empty() else 1)


func _check_prepared_depth(zone: VoxelWorkZone, authority: VoxelExcavationAuthority, contract: Dictionary, depth: float, failures: Array[String]) -> void:
	var tool := zone.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var from := WorkZoneConfig.world_to_voxel(Vector3(-4, -depth + 0.15, 14), zone.voxel_scale_m)
	var to := WorkZoneConfig.world_to_voxel(Vector3(4, 2, 23), zone.voxel_scale_m)
	for refill in [false, true]:
		tool.mode = VoxelTool.MODE_ADD if refill else VoxelTool.MODE_REMOVE
		tool.do_box(from, to)
		var start := Vector3(0, _bucket_origin_y(contract, -depth), 18)
		var tick := int(depth * 100) + (10 if refill else 0)
		authority.configure(zone, contract, zone.readiness.generation, 1000.0)
		var admission := authority.submit_pose(_pose(contract, start, Vector3(0.08, -0.12, 0.18), "deep"), _identity(authority.generation, tick, tick))
		_expect(bool(admission.get("accepted", false)), "depth/refill proposal admitted", failures)
		if authority._queue.is_empty():
			continue
		var proposal: VoxelCutProposal = authority._queue.pop_front()
		var paths := authority._native_edit_paths(proposal)
		var area := authority.cutter._native_path_bounds(paths).grow(2.0)
		var origin := Vector3i(area.position.floor())
		var size := Vector3i(area.end.ceil()) - origin
		var original := _copy_sdf(tool, origin, size)
		var expected := _copy_sdf(tool, origin, size)
		var window := authority._integer_window_without_halo(proposal.area_voxels)
		var reference := Preparation.new()
		reference.configure(paths, authority._coverage_min, authority._coverage_size, authority._coverage_axis_ranks)
		reference.advance_coverage(0x7FFFFFFFFFFFFFFF)
		var expected_coordinates := authority._solid_coordinates_from_buffer(reference.unique, window.origin, window.size)
		reference.begin_edit(expected, origin, tool.get_sdf_scale(), tool.get_sdf_strength())
		if not expected_coordinates.is_empty():
			reference.advance_edit(0x7FFFFFFFFFFFFFFF)
		var job := Preparation.new()
		job.configure(paths, authority._coverage_min, authority._coverage_size, authority._coverage_axis_ranks)
		job.accounting_origin = window.origin
		job.accounting_size = window.size
		job.begin_edit(original, origin, tool.get_sdf_scale(), tool.get_sdf_strength())
		job.compute_snapshot()
		_expect(job.coordinates == expected_coordinates, "deep/refilled ordered coverage is exact", failures)
		_expect(original.get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF) == expected.get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF), "deep/refilled full SDF bytes are exact", failures)
		if depth >= 2.0 and not refill:
			_expect(job.skipped_coverage_steps > 0, "deep air skips coverage lattice samples", failures)
		for coordinate in expected_coordinates:
			_expect(job.geometry_candidates.has(coordinate) == reference.geometry_candidates.has(coordinate), "solid geometry-only admission is unchanged", failures)
		# A fresh snapshot after refill must not inherit an earlier air index.
		print("DEEP_SAMPLE depth=%s refill=%s skipped=%d occupancy_usec=%d" % [depth, refill, job.skipped_coverage_steps, job.occupancy_usec])


func _check_cleanup_parity(zone: VoxelWorkZone, contract: Dictionary, failures: Array[String]) -> void:
	var legacy := LegacyCleanup.new()
	var optimized := Authority.new()
	legacy.configure(zone, contract, zone.readiness.generation)
	optimized.configure(zone, contract, zone.readiness.generation)
	var tool := zone.get_voxel_tool()
	var origin := Vector3i(-16, -44, -64)
	var size := Vector3i(32, 74, 32)
	var area := AABB(Vector3(-14, -42, -62), Vector3(28, 12, 28))
	var original := _copy_sdf(tool, origin, size)
	# Include multiple runs, zero SDF, minimal positive SDF, supported columns
	# and >16K floating samples to exercise the legacy global deletion cap.
	for capped in [false, true]:
		var fixture := VoxelBuffer.new()
		fixture.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
		fixture.create(size.x, size.y, size.z)
		fixture.fill_f(-1.0, VoxelBuffer.CHANNEL_SDF)
		for x in size.x:
			for z in size.z:
				if capped or (x + z) % 3 == 0:
					fixture.fill_area_f(1.0, Vector3i(x, 1, z), Vector3i(x + 1, 4, z + 1), VoxelBuffer.CHANNEL_SDF)
				if not capped:
					fixture.fill_area_f(1.0, Vector3i(x, 10, z), Vector3i(x + 1, size.y, z + 1), VoxelBuffer.CHANNEL_SDF)
					fixture.set_voxel_f(0.0, x, 8, z, VoxelBuffer.CHANNEL_SDF)
					fixture.set_voxel_f(0.03, x, 9, z, VoxelBuffer.CHANNEL_SDF)
		tool.paste(origin, fixture, Authority.SDF_CHANNEL_MASK)
		var before := legacy._apply_support_cleanup(area)
		var expected := _copy_sdf(tool, origin, size).get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF)
		tool.paste(origin, fixture, Authority.SDF_CHANNEL_MASK)
		var after := optimized._apply_support_cleanup(area)
		var actual := _copy_sdf(tool, origin, size).get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF)
		_expect(expected == actual and before.deleted_samples == after.deleted_samples and before.columns == after.columns, "support run cleanup matches scalar bytes and cap", failures)
		_expect((after.area as AABB).size.y <= (before.area as AABB).size.y, "cleanup publication only bounds modified samples", failures)
	tool.paste(origin, original, Authority.SDF_CHANNEL_MASK)
	legacy.clear()
	optimized.clear()


func _copy_sdf(tool: VoxelTool, origin: Vector3i, size: Vector3i) -> VoxelBuffer:
	var buffer := VoxelBuffer.new()
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	buffer.create(size.x, size.y, size.z)
	tool.copy(origin, buffer, Authority.SDF_CHANNEL_MASK, false)
	return buffer

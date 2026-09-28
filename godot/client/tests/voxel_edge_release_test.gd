extends "res://tests/voxel_cut_preparation_test.gd"

func _run() -> void:
	var failures: Array[String] = []
	var outcomes: Array[Dictionary] = []
	for mode in 3:
		var zone := WorkZone.new()
		zone.layout.configure_area(Vector3(31.7, 1.1, 30.225), Vector2(15.8, 5.55))
		root.add_child(zone)
		_expect(await _wait_initial_ready(zone), "urban-sized finite terrain ready", failures)
		var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
		var authority := BudgetAuthority.new()
		authority.cut_preparation_budget_usec = 0 if mode == 0 else 500
		authority.threaded_cut_preparation = mode == 2
		authority.configure(zone, contract, zone.readiness.generation)
		var start := Vector3(35, _bucket_origin_y(contract, 1.05), zone.layout.MIN_WORLD.z + 0.25)
		var pose := _pose(contract, start, Vector3(0.08, -0.08, 0.10), "roadside")
		var tool := zone.get_voxel_tool()
		var outside := Vector3i(zone.layout.world_to_voxel(Vector3(35, 0.8, zone.layout.MIN_WORLD.z - 0.25)))
		var outside_before := tool.get_voxel_f(outside)
		var admission := authority.submit_pose(pose, _identity(authority.generation, 1, 1))
		_expect(bool(admission.get("accepted", false)), "roadside overlap admitted mode %d: %s" % [mode, admission], failures)
		var deadline := Time.get_ticks_msec() + 10000
		while authority.data_revision == 0 and Time.get_ticks_msec() < deadline:
			authority.step_fixed(0.05)
			await process_frame
		_expect(authority.data_revision > 0 and authority.material_field.bucket_mass_q > 0, "roadside cut commits and credits mode %d: %s" % [mode, authority._last_transaction], failures)
		_expect(tool.get_voxel_f(outside) == outside_before, "hidden outside apron is unchanged", failures)
		var probe_origin := Vector3i(zone.layout.world_to_voxel(start)) - Vector3i(12, 8, 12)
		var probe_buffer := VoxelBuffer.new()
		probe_buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
		probe_buffer.create(24, 24, 32)
		tool.copy(probe_origin, probe_buffer, Authority.SDF_CHANNEL_MASK, false)
		outcomes.append({"mass": authority.material_field.bucket_mass_q, "revision": authority.data_revision, "sdf": probe_buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF)})
		# Release outside at ground level must not sample unowned SDF as buried.
		var dump := _dump_pose(contract, Vector3(35, 1.5, 25), "outside")
		authority._engaged = false
		authority.submit_pose(dump, _identity(authority.generation, 2, 2), 0.1)
		var before := authority.material_field.bucket_mass_q
		var result := authority.submit_pose(dump, _identity(authority.generation, 3, 3), 0.1)
		_expect(result.get("reason") == "dump_exported" and authority.material_field.bucket_mass_q < before, "outside unload drains bucket", failures)
		_expect(authority.data_revision == 1 and authority.material_field.conservation_error_q == 0, "export preserves terrain and exact mass ledger", failures)
		authority.set_dump_gate_enabled(false)
		before = authority.material_field.bucket_mass_q
		authority.submit_pose(dump, _identity(authority.generation, 4, 4), 0.1)
		_expect(authority.material_field.bucket_mass_q == before, "simple digging prevents outside release", failures)
		authority.set_dump_gate_enabled(true)
		for tick in range(5, 105):
			authority.submit_pose(dump, _identity(authority.generation, tick, tick), 0.1)
		_expect(authority.material_field.bucket_mass_q == 0, "outside release drains sub-voxel remainder too", failures)
		_expect(authority.material_field.exported_dump_mass_q == outcomes[mode].mass, "all released soil enters explicit export sink", failures)
		authority.clear()
		zone.queue_free()
		await process_frame
	_expect(outcomes[0] == outcomes[1] and outcomes[0] == outcomes[2], "sync/sliced/threaded edge SDF and mass parity", failures)
	for failure in failures:
		push_error(failure)
	print("VOXEL_EDGE_RELEASE failures=%d" % failures.size())
	quit(0 if failures.is_empty() else 1)

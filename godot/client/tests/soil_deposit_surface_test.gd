extends "res://tests/voxel_excavation_authority_test.gd"

const Surface = preload("res://scripts/soil_deposit_surface.gd")
const LegacySurface = preload("res://tests/fixtures/legacy_soil_deposit_surface.gd")


func _run() -> void:
	var failures: Array[String] = []
	_check_surface_solver(failures)
	_check_routing_parity(failures)
	await _check_pit_edge_commits(failures)
	await _check_recorded_pit(failures)
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("PASS deposit surface: source routing, barriers, volume, slope, pit-edge unloading")
	quit(0 if failures.is_empty() else 1)


func _check_routing_parity(failures: Array[String]) -> void:
	# Freeze the pre-optimization solver to protect traversal/tie order and
	# floating-point accumulation, not merely total volume or mound shape.
	var side := 33
	for shape in 5:
		var heights := PackedFloat64Array()
		heights.resize(side * side)
		for z in side:
			for x in side:
				var height := 0.0
				match shape:
					1: height = -16.0 if x < 16 else 0.0
					2: height = 12.0 if x == 19 else (-20.0 if x > 19 else 0.0)
					3: height = INF if x < 4 or z < 4 else float((x * 17 + z * 7) % 9) * 0.1
					4: height = 100.0 + sin(float(x) * 0.3) + cos(float(z) * 0.2)
				heights[z * side + x] = height
		for source in [Vector2(16.3, 16.1), Vector2(2, 16)]:
			for volume in [0.0001, 30.0, 200.0]:
				var expected := LegacySurface.plan(heights, side, source, volume, tan(deg_to_rad(35.0)))
				var actual := Surface.plan(heights, side, source, volume, tan(deg_to_rad(35.0)))
				_expect(actual == expected, "routing preserves exact additions, boundary, step count and budget outcome", failures)


func _check_surface_solver(failures: Array[String]) -> void:
	var side := 49
	var slope := tan(deg_to_rad(35.0))
	var heights := PackedFloat64Array()
	heights.resize(side * side)
	var source := Vector2(24.3, 24.1)
	var flat := Surface.plan(heights, side, source, 200.0, slope)
	_expect(not flat.is_empty() and not flat["boundary_active"], "flat mound has a bounded footprint", failures)
	_expect(absf(float(flat["volume_voxels"]) - 200.0) < 0.000001, "flat mound conserves requested volume", failures)
	var additions := flat["additions"] as PackedFloat64Array
	for z in range(side - 1):
		for x in range(side - 1):
			var i := z * side + x
			_expect(absf(additions[i] - additions[i + 1]) <= slope + 0.000001
				and absf(additions[i] - additions[i + side]) <= slope + 0.000001,
				"new flat-ground pile obeys repose slope", failures)
	# A supported landing near a pit keeps some soil locally and spills the
	# remainder down the connected cliff; distant low cells cannot attract it.
	for z in side:
		for x in side:
			if x < 23:
				heights[z * side + x] = -16.0
	var pit := Surface.plan(heights, side, source, 200.0, slope)
	additions = pit["additions"] as PackedFloat64Array
	var rim_added := 0.0
	for z in side:
		for x in range(23, side):
			rim_added += additions[z * side + x]
	_expect(rim_added > 0.0 and rim_added < 200.0, "rim retains soil while connected pit receives overflow", failures)
	_expect(absf(float(pit["volume_voxels"]) - 200.0) < 0.000001, "pit fill conserves volume", failures)
	var offset_heights := heights.duplicate()
	for i in offset_heights.size():
		offset_heights[i] += 100.0
	var offset := Surface.plan(offset_heights, side, source, 200.0, slope)
	var offset_additions := offset["additions"] as PackedFloat64Array
	for i in additions.size():
		_expect(absf(additions[i] - offset_additions[i]) < 0.000001,
			"absolute datum does not change deposited thickness", failures)
	# A low point on the sampling boundary must request more domain, not claim
	# that no receiving capacity exists (the former ceiling <= low failure).
	heights.fill(0.0)
	heights[24 * side + 1] = -100.0
	var edge := Surface.plan(heights, side, Vector2(1, 24), 5.0, slope)
	_expect(not edge.is_empty() and edge["boundary_active"], "active boundary requests domain growth", failures)
	# A lower pit behind a ridge cannot attract soil across that ridge.
	heights.fill(0.0)
	for z in side:
		heights[z * side + 27] = 12.0
		for x in range(28, side):
			heights[z * side + x] = -20.0
	var blocked := Surface.plan(heights, side, Vector2(24, 24), 20.0, slope)
	var blocked_additions := blocked["additions"] as PackedFloat64Array
	var remote := 0.0
	for z in side:
		for x in range(28, side):
			remote += blocked_additions[z * side + x]
	_expect(remote == 0.0, "material cannot cross a ridge to a remote low pit", failures)
	_expect(blocked_additions[24 * side + 24] > 0.0, "soil rests at its supported landing point", failures)
	# Protected/unavailable columns never receive mass.
	heights.fill(INF)
	heights[24 * side + 24] = 0.0
	var masked := Surface.plan(heights, side, Vector2(24, 24), 0.0001, slope)
	_expect(absf(float(masked["volume_voxels"]) - 0.0001) < 0.00000001,
		"small representable deposits do not disappear in the solver", failures)
	_expect((masked["additions"] as PackedFloat64Array)[0] == 0.0, "masked columns receive no material", failures)


func _check_pit_edge_commits(failures: Array[String]) -> void:
	var zone := WorkZone.new()
	root.add_child(zone)
	_expect(await _wait_initial_ready(zone), "pit fixture ready", failures)
	var authority := Authority.new()
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	authority.configure(zone, contract, zone.readiness.generation)
	var scale_m := zone.voxel_scale_m
	var tool := zone.get_voxel_tool()
	tool.mode = VoxelTool.MODE_REMOVE
	tool.do_box(authority.layout.world_to_voxel(Vector3(-4, -2, 20), scale_m),
		authority.layout.world_to_voxel(Vector3(-0.125, 1, 28), scale_m))
	_check_support_sampling(authority, Vector3(0.125, 3, 24), failures)
	var release := Vector3(0.125, 3, 24)
	var planned := authority._plan_surface_deposit(release, 0.1 / pow(scale_m, 3.0))
	_expect(bool(planned.get("valid", false)), "pit-edge receiving plan succeeds", failures)
	_expect(int(planned.get("side", 0)) >= Surface.INITIAL_RADIUS * 2 + 1,
		"pit receiving plan has a valid sampling domain", failures)
	var rim_before := authority._find_sdf_support_world(Vector3(0.25, 3, 24))["position"] as Vector3
	var tick := 1
	for load_index in 3:
		authority.material_field.credit_bucket_mass_for_test(authority.material_field.mass_q_for_volume(0.66))
		var pose := _dump_pose(contract, release, "pit-edge-%d" % load_index)
		for step in 80:
			authority.submit_pose(pose, _identity(authority.generation, tick, tick), 0.05)
			authority.step_fixed(0.05)
			tick += 1
			if authority.material_field.bucket_mass_q < authority._minimum_dump_mass_q():
				break
		_expect(authority.material_field.bucket_mass_q < authority._minimum_dump_mass_q(),
			"stationary pit-edge dump empties without moving to another grid", failures)
		_expect(authority.material_field.conservation_error_q == 0, "pit-edge commits conserve material", failures)
	_check_support_sampling(authority, release, failures)
	var rim_after := authority._find_sdf_support_world(Vector3(0.25, 3, 24))["position"] as Vector3
	_expect(rim_after.y > rim_before.y and rim_after.y < 1.0, "rim deposit remains bounded while the pit receives overflow", failures)
	print("PIT_EDGE_DEPOSIT %s" % JSON.stringify({"bucket_mass_q":authority.material_field.bucket_mass_q,
		"rejections":authority.get_status_snapshot()["rejection_reasons"], "rim_before":rim_before.y,
		"rim_after":rim_after.y,"initial_plan_side":planned.get("side")}))
	authority.clear()
	zone.queue_free()
	await process_frame


func _check_support_sampling(authority: VoxelExcavationAuthority, world: Vector3, failures: Array[String]) -> void:
	var scale_m := authority._work_zone.voxel_scale_m
	var voxel := authority.layout.world_to_voxel(world, scale_m)
	var center := Vector2i(roundi(voxel.x), roundi(voxel.z))
	var small := authority._sample_deposit_surface_domain(center, 8, {})
	var sampled := authority._sample_deposit_surface_domain(center, 16, small)
	var fresh := authority._sample_deposit_surface_domain(center, 16, {})
	_expect(sampled == fresh, "growing a domain reuses only identical current-transaction samples", failures)
	var heights := sampled["heights"] as PackedFloat64Array
	var gradients := sampled["gradients"] as PackedFloat32Array
	var origin := sampled["origin"] as Vector3i
	var side := int(sampled["side"])
	var same := true
	for z in side:
		for x in side:
			var probe := authority.layout.voxel_to_world(Vector3(origin.x + x, 0, origin.z + z), scale_m)
			probe.y = authority.layout.MAX_WORLD.y - scale_m * 3.0
			var scalar := authority._find_sdf_support_world(probe)
			if not scalar.get("valid", false):
				same = false
				continue
			var expected_y := authority.layout.world_to_voxel(scalar["position"], scale_m).y
			same = same and absf(expected_y - heights[z * side + x]) < 0.00001
			same = same and absf(float(scalar["gradient"]) - gradients[z * side + x]) < 0.00001
	_expect(same, "batched raw-SDF support matches scalar first-hit height and gradient", failures)


func _check_recorded_pit(failures: Array[String]) -> void:
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/dump_pit_surface.json"))
	var zone := WorkZone.new()
	root.add_child(zone)
	_expect(await _wait_initial_ready(zone), "recorded pit fixture ready", failures)
	var authority := Authority.new()
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	authority.configure(zone, contract, zone.readiness.generation)
	var scale_m := zone.voxel_scale_m
	var side := int(fixture["side"])
	var origin_world := Vector3(float(fixture["origin"][0]), -4, float(fixture["origin"][1]))
	var origin := Vector3i(authority.layout.world_to_voxel(origin_world, scale_m))
	var buffer := VoxelBuffer.new()
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	buffer.create(side, 64, side)
	for z in side:
		for x in side:
			var height := float(fixture["heights"][z * side + x]) / scale_m
			for y in 64:
				buffer.set_voxel_f(float(origin.y + y) - height, x, y, z, VoxelBuffer.CHANNEL_SDF)
	authority._tool.paste(origin, buffer, 1 << VoxelBuffer.CHANNEL_SDF)
	var release := Vector3(float(fixture["release"][0]), float(fixture["release"][1]), float(fixture["release"][2]))
	var stock := authority.material_field.mass_q_for_volume(0.10741048375)
	authority.material_field.credit_bucket_mass_for_test(stock)
	var pose := _dump_pose(contract, release, "recorded-stall")
	for tick in range(1, 61):
		authority.submit_pose(pose, _identity(authority.generation, tick, tick), 0.05)
		authority.step_fixed(0.05)
		if authority.material_field.bucket_mass_q < authority._minimum_dump_mass_q():
			break
	print("RECORDED_PIT_DEPOSIT %s" % JSON.stringify({"bucket_mass_q":authority.material_field.bucket_mass_q,
		"initial_mass_q":stock,"rejections":authority.get_status_snapshot()["rejection_reasons"]}))
	_expect(authority.material_field.bucket_mass_q < authority._minimum_dump_mass_q(),
		"captured blocked receiving surface drains at the original stationary release position", failures)
	_expect(authority.material_field.conservation_error_q == 0, "recorded pit preserves material", failures)
	authority.clear()
	zone.queue_free()
	await process_frame

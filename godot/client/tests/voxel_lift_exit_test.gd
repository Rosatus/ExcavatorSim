extends "res://tests/voxel_excavation_authority_test.gd"


func _run() -> void:
	var failures: Array[String] = []
	var zone := WorkZone.new()
	root.add_child(zone)
	_expect(await _wait_initial_ready(zone), "lift fixture ready", failures)
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	var authority := Authority.new()
	authority.configure(zone, contract, zone.readiness.generation)
	var entered := Transform3D(Basis.IDENTITY, Vector3(0, -0.45, 24))
	var preceding := Transform3D(Basis.IDENTITY, entered.origin + Vector3(0, 0.04, -0.05))
	var cut_pose := _pose_from_transforms(contract, preceding, entered, "entry")
	_expect(bool(authority.submit_pose(cut_pose, _identity(authority.generation, 1, 1)).get("accepted", false)), "leading cut establishes engagement", failures)
	var held_pose := _pose_from_transforms(contract, entered, entered, "hold-before-lift")
	var held := authority.submit_pose(held_pose, _identity(authority.generation, 2, 2))
	_expect(not bool(held.get("accepted", false)) and authority._engaged, "pause retains an established soil contact without enqueueing a cut", failures)
	_expect(bool(authority.flush_for_test().get("changed", false)), "entry cut committed", failures)
	_check_inner_voxels(zone, authority.cutter._find_region(cut_pose["soil_tool"], "inner_shell"), "entry", failures)
	var exit_transform := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(25.0)), entered.origin + Vector3(0.04, 0.08, 0.07))
	var exit_pose := _pose_from_transforms(contract, entered, exit_transform, "lift-exit")
	var tool := exit_pose["soil_tool"] as Dictionary
	var inner := authority.cutter._find_region(tool, "inner_shell")
	var inner_previous := inner["previous_transform"] as Transform3D
	var half := authority.cutter._box_half_dimensions(inner)
	# Independent probe: original surface above the shallow trailing shell.
	# Its roof was too shallow for the old 1.5-voxel overburden threshold.
	var roof_world := inner_previous * Vector3(0, half.y * 0.82, half.z * 0.72)
	roof_world.y = WorkZoneConfig.INITIAL_SURFACE_Y
	var roof_voxel := WorkZoneConfig.world_to_voxel(roof_world, zone.voxel_scale_m)
	var roof_coordinate := Vector3i(roundi(roof_voxel.x), roundi(roof_voxel.y), roundi(roof_voxel.z))
	var before_sdf := zone.get_voxel_tool().get_voxel_f(roof_coordinate)
	# The lower-envelope cleanup may already remove this roof during entry.
	var submission := authority.submit_pose(exit_pose, _identity(authority.generation, 3, 3))
	_expect(bool(submission.get("accepted", false)), "lift exit reaches native executor (%s)" % submission.get("reason", ""), failures)
	var commit := authority.flush_for_test()
	var after_sdf := zone.get_voxel_tool().get_voxel_f(roof_coordinate)
	_expect(bool(commit.get("changed", false)), "exit sweep changes real SDF", failures)
	_expect(after_sdf > 0.0, "native exit sweep removes the remaining surface roof", failures)
	_expect(authority.material_field.conservation_error_q == 0, "exit cut preserves accounting", failures)
	_check_inner_voxels(zone, inner, "first lift", failures)
	var last := exit_transform
	for step in range(1, 9):
		var next := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(25.0 + step * 3.0)),
			exit_transform.origin + Vector3(0, step * 0.04, step * 0.025))
		var pose := _pose_from_transforms(contract, last, next, "continuous-lift-%d" % step)
		var result := authority.submit_pose(pose, _identity(authority.generation, 3 + step, 3 + step))
		if bool(result.get("accepted", false)):
			authority.flush_for_test()
		_check_inner_voxels(zone, authority.cutter._find_region(pose["soil_tool"], "inner_shell"), "lift %d (%s)" % [step, result.get("reason", "")], failures)
		last = next
	# Once fully clear, engagement must end rather than authorize future air cuts.
	var high := Transform3D(exit_transform.basis, exit_transform.origin + Vector3.UP * 1.5)
	var air_pose := _pose_from_transforms(contract, high, Transform3D(high.basis, high.origin + Vector3.UP * 0.04), "air")
	var air_result := authority.submit_pose(air_pose, _identity(authority.generation, 20, 20))
	_expect(not bool(air_result.get("accepted", false)) and not authority._engaged, "lift continuation stops after clearing soil", failures)
	print("LIFT_EXIT %s" % JSON.stringify({"before_sdf": before_sdf, "after_sdf": after_sdf,
		"revision": authority.data_revision, "exit_reason": submission.get("reason", "")}))
	# A separate shallow cut must clear the surface above the rotated lower
	# cavity, even though its local +Y face is entirely in air.
	var shallow := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(25)), Vector3(4, -0.55, 24))
	var shallow_entry := _pose_from_transforms(contract, Transform3D(shallow.basis, shallow.origin + Vector3(0, 0.04, -0.025)), shallow, "thin-wall-entry")
	var admitted := authority.submit_pose(shallow_entry, _identity(authority.generation, 21, 21))
	_expect(bool(admitted.get("accepted", false)), "thin wall entry admitted (%s)" % admitted.get("reason", ""), failures)
	authority.flush_for_test()
	var shallow_pose: Dictionary = {}
	for step in range(1, 13):
		var shallow_exit := Transform3D(shallow.basis, Vector3(4, -0.55 + step * 0.0375, 24 + step * 0.025))
		shallow_pose = _pose_from_transforms(contract, shallow, shallow_exit, "thin-wall-exit-%d" % step)
		authority.submit_pose(shallow_pose, _identity(authority.generation, 21 + step, 21 + step))
		authority.flush_for_test()
		shallow = shallow_exit
	_check_roof_voxels(zone, authority.cutter._find_region(shallow_pose["soil_tool"], "inner_shell"), failures)
	authority.clear()
	zone.queue_free()
	await process_frame
	if failures.is_empty():
		print("PASS native lift exit surface cleanup")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _check_roof_voxels(zone: VoxelWorkZone, inner: Dictionary, failures: Array[String]) -> void:
	var transform := inner["current_transform"] as Transform3D
	var half := Vector3(0.47, 0.32, 0.39)
	var coordinates: Dictionary = {}
	for ix in range(9):
		for iy in range(9):
			for iz in range(9):
				var world := transform * (half * Vector3(lerpf(-0.95, 0.95, ix / 8.0), lerpf(-0.95, 0.95, iy / 8.0), lerpf(-0.95, 0.95, iz / 8.0)))
				if world.y > -0.01:
					continue
				world.y = 0
				var point := WorkZoneConfig.world_to_voxel(world, zone.voxel_scale_m)
				coordinates[Vector3i(roundi(point.x), roundi(point.y), roundi(point.z))] = true
	var residual := 0
	for coordinate in coordinates:
		if zone.get_voxel_tool().get_voxel_f(coordinate) <= 0:
			residual += 1
	print("THIN_WALL surface_voxels=%d residual=%d" % [coordinates.size(), residual])
	_expect(not coordinates.is_empty() and residual == 0, "rotated shallow cavity leaves no surface wall (%d residual)" % residual, failures)
	# Clearly outside the swept footprint must retain untouched surface.
	var outside := WorkZoneConfig.world_to_voxel(Vector3(5.0, 0, 24), zone.voxel_scale_m)
	_expect(zone.get_voxel_tool().get_voxel_f(Vector3i(outside)) <= 0, "thin wall cleanup preserves adjacent uncut ground", failures)


func _check_inner_voxels(zone: VoxelWorkZone, inner: Dictionary, label: String, failures: Array[String]) -> void:
	var transform := inner["current_transform"] as Transform3D
	var inverse := transform.affine_inverse()
	var half := Vector3(0.47, 0.32, 0.39) - Vector3.ONE * 0.025
	var center := WorkZoneConfig.world_to_voxel(transform.origin, zone.voxel_scale_m)
	var misses := 0
	var checked := 0
	for x in range(floori(center.x) - 7, ceili(center.x) + 8):
		for y in range(floori(center.y) - 7, ceili(center.y) + 8):
			for z in range(floori(center.z) - 7, ceili(center.z) + 8):
				var coordinate := Vector3i(x, y, z)
				var world := WorkZoneConfig.voxel_to_world(Vector3(coordinate), zone.voxel_scale_m)
				var local := (inverse * world).abs()
				if world.y > 0.0 or local.x > half.x or local.y > half.y or local.z > half.z:
					continue
				checked += 1
				if zone.get_voxel_tool().get_voxel_f(coordinate) <= 0.0:
					misses += 1
	print("LIFT_VOLUME %s checked=%d residual=%d" % [label, checked, misses])
	_expect(misses == 0, "%s leaves no solid voxel inside swept bucket (%d/%d)" % [label, misses, checked], failures)

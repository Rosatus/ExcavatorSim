extends "res://tests/voxel_excavation_authority_test.gd"


func _run() -> void:
	var failures: Array[String] = []
	var zone := WorkZone.new()
	root.add_child(zone)
	_expect(await _wait_initial_ready(zone), "trajectory zone ready", failures)
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	for scenario in 2:
		var authority := Authority.new()
		authority.configure(zone, contract, zone.readiness.generation)
		var initial := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(25)), Vector3(-4 + scenario * 4, -0.65, 24))
		var previous := Transform3D(initial.basis, initial.origin + Vector3(0, 0.04, -0.025))
		var entry := _pose_from_transforms(contract, previous, initial, "entry")
		var submitted := authority.submit_pose(entry, _identity(authority.generation, 1, 1))
		_expect(bool(submitted.get("accepted")), "trajectory entry admitted", failures)
		_expect(bool(authority.flush_for_test().get("changed")), "trajectory entry committed", failures)
		var held := authority.submit_pose(_pose_from_transforms(contract, initial, initial, "hold"), _identity(authority.generation, 2, 2))
		_expect(not bool(held.get("accepted")) and authority._engaged, "pause after committed cut retains episode in cleared cavity", failures)
		var targets: Dictionary = {}
		var reasons: Dictionary = {}
		var lift_commits := 0
		previous = initial
		var frames := 120
		for tick in range(1, frames + 1):
			var alpha := float(tick) / frames
			var rotation := 25.0 + (25.0 * alpha if scenario == 1 else 0.0)
			var current := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(rotation)), initial.origin + Vector3(0, 0.65 * alpha, 0.6 * alpha))
			var pose := _pose_from_transforms(contract, previous, current, "lift-%d" % tick)
			var inner := authority.cutter._find_region(pose.soil_tool, "inner_shell")
			_collect_targets(zone, inner.current_transform, targets)
			var result := authority.submit_pose(pose, _identity(authority.generation, tick + 2, tick + 2))
			var commit := authority.step_fixed(1.0 / 60.0)
			if bool(commit.get("changed")):
				lift_commits += 1
			var reason := String(result.get("reason"))
			reasons[reason] = int(reasons.get(reason, 0)) + 1
			if tick == 1:
				_expect(not bool(result.get("accepted")) and authority._engaged, "clear lift frame retains episode without submitting air geometry", failures)
			previous = current
		for drain in 12:
			if bool(authority.flush_for_test().get("changed")):
				lift_commits += 1
		var residual: Array = []
		for coordinate in targets:
			if zone.get_voxel_tool().get_voxel_f(coordinate) <= 0:
				residual.append(coordinate)
		print("TRACE_FINAL scenario=%d targets=%d residual=%d reasons=%s example=%s" % [scenario, targets.size(), residual.size(), reasons, residual.slice(0, 8)])
		_expect(targets.size() >= 100 and residual.is_empty(), "whole historical lift footprint is clear, scenario %d (%d residual)" % [scenario, residual.size()], failures)
		_expect(lift_commits > 0 and int(reasons.get("queued", 0)) > 0, "lift actually resumes and commits beyond initial entry", failures)
		_expect(authority.material_field.conservation_error_q == 0, "continuous lift preserves mass balance", failures)
		var outside := WorkZoneConfig.world_to_voxel(initial.origin + Vector3(1.5, 0.65, 0), zone.voxel_scale_m)
		_expect(zone.get_voxel_tool().get_voxel_f(Vector3i(outside)) <= 0, "outside ground remains solid", failures)
		var high := Transform3D(previous.basis, previous.origin + Vector3.UP)
		authority.submit_pose(_pose_from_transforms(contract, previous, high, "exit"), _identity(authority.generation, 123, 123))
		var air := authority.submit_pose(_pose_from_transforms(contract, high, high, "above-surface-hold"), _identity(authority.generation, 124, 124))
		_expect(not bool(air.get("accepted")) and not authority._engaged, "episode retires after whole bucket exits", failures)
		authority.clear()
	zone.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("PASS continuous lift episode across cleared intervals")
	quit(0 if failures.is_empty() else 1)


func _collect_targets(zone: VoxelWorkZone, transform: Transform3D, targets: Dictionary) -> void:
	# Independent points well inside the cavity; include all soil above them,
	# and retain the entire trajectory footprint rather than only its last pose.
	var half := Vector3(0.47, 0.32, 0.39) - Vector3.ONE * 0.13
	for ix in 5:
		for iy in 5:
			for iz in 5:
				var point := transform * (half * Vector3((ix - 2) / 2.0, (iy - 2) / 2.0, (iz - 2) / 2.0))
				if point.y >= 0:
					continue
				var voxel := WorkZoneConfig.world_to_voxel(point, zone.voxel_scale_m)
				for y in range(ceili(voxel.y), 1 + roundi(WorkZoneConfig.world_to_voxel(Vector3.ZERO, zone.voxel_scale_m).y)):
					targets[Vector3i(roundi(voxel.x), y, roundi(voxel.z))] = true

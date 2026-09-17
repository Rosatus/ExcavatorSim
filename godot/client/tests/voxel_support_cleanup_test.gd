extends "res://tests/voxel_excavation_authority_test.gd"

## Undercut support cleanup: a commit that removes support under a solid run
## must delete the floating remainder (soil is allowed to vanish; the ledger
## only tracks bucket exchange).


func _run() -> void:
	var failures: Array[String] = []
	await _check_model("sy135", failures)
	await _check_model("sy205", failures)
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("Voxel support cleanup contracts passed.")
	quit(0 if failures.is_empty() else 1)


func _check_model(model_id: String, failures: Array[String]) -> void:
	var zone := WorkZone.new()
	root.add_child(zone)
	if not await _wait_initial_ready(zone):
		failures.append("%s: voxel fixture ready" % model_id)
		zone.queue_free()
		await process_frame
		return
	var descriptor := SoilContractDescriptor.load_for_model(model_id)
	var contract := descriptor.to_dictionary()
	var authority := Authority.new()
	authority.set_diagnostics_enabled(true)
	if not authority.configure(zone, contract, zone.readiness.generation):
		failures.append("%s: authority configures" % model_id)
		zone.queue_free()
		await process_frame
		return
	var scale_m := zone.voxel_scale_m
	# Pre-carve a cave below the untouched surface so a solid cap floats on air.
	var cave_world := Vector3(0.0, -1.0, 18.0)
	var cave_voxel := WorkZoneConfig.world_to_voxel(cave_world, scale_m)
	var cave_center := Vector3i(roundi(cave_voxel.x), roundi(cave_voxel.y), roundi(cave_voxel.z))
	var tool := zone.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	tool.mode = VoxelTool.MODE_REMOVE
	tool.do_sphere(Vector3(cave_center), 4.0)
	# Sanity: the cave ceiling column really does contain a floating solid run.
	_expect(
		_column_has_floating_solid(zone, cave_center.x, cave_center.z, cave_center.y - 1),
		"%s: pre-carved cave leaves a floating cap" % model_id,
		failures
	)
	# A shallow surface cut over the cave column: the commit removes surface
	# soil, and the support cleanup must delete the suspended cave ceiling.
	var first_pose := _pose(contract, Vector3(0.0, _bucket_origin_y(contract, -0.03), 18.0), Vector3(0.0, -0.04, 0.06), "commit")
	var submission := authority.submit_pose(first_pose, _identity(zone.readiness.generation, 10, 1))
	_expect(bool(submission.get("accepted", false)), "%s: cut pose accepted" % model_id, failures)
	var result := authority.flush_for_test()
	_expect(bool(result.get("changed", false)), "%s: cut commits" % model_id, failures)
	var status := authority.get_status_snapshot(true)
	var transaction := status.get("last_transaction", {}) as Dictionary
	_expect(
		int(transaction.get("support_deleted_samples", -1)) > 0,
		"%s: cleanup deletes suspended samples" % model_id,
		failures
	)
	var payload := authority.get_payload_snapshot()
	_expect(
		int(payload.get("conservation_error_q", 1)) == 0,
		"%s: deleted overhang stays out of the ledger" % model_id,
		failures
	)
	var area := transaction.get("area_voxels", AABB()) as AABB
	_expect(
		_area_has_no_floating_solid(zone, area),
		"%s: affected columns hold no unsupported solid" % model_id,
		failures
	)
	authority.clear()
	zone.queue_free()
	await process_frame


# A column has floating solid when a solid voxel's downward neighbor is air.
func _column_has_floating_solid(zone: VoxelWorkZone, x: int, z: int, floor_y: int) -> bool:
	var tool := zone.get_voxel_tool()
	var bounds := WorkZoneConfig.voxel_bounds(zone.voxel_scale_m)
	var top := bounds.end.y - WorkZoneConfig.PROTECTED_SHELL_VOXELS - 1
	var below_solid := true
	for y in range(floor_y, top + 1):
		var solid := tool.get_voxel_f(Vector3i(x, y, z)) <= 0.0
		if solid and not below_solid:
			return true
		below_solid = solid
	return false


func _area_has_no_floating_solid(zone: VoxelWorkZone, area: AABB) -> bool:
	var min_x := floori(area.position.x) - 1
	var max_x := ceili(area.end.x) + 1
	var min_z := floori(area.position.z) - 1
	var max_z := ceili(area.end.z) + 1
	var floor_y := floori(area.position.y) - 1
	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			if _column_has_floating_solid(zone, x, z, floor_y):
				return false
	return true

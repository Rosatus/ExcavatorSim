extends "res://scripts/voxel_excavation_authority.gd"

# Frozen pre-optimization scalar oracle for support semantics and SDF bytes.

func _apply_support_cleanup(edit_area: AABB) -> Dictionary:
	var started := _diagnostic_clock_usec()
	var result := {"deleted_samples": 0, "columns": 0, "area": AABB(), "usec": 0}
	var bounds := layout.voxel_bounds(_work_zone.voxel_scale_m)
	var min_x := maxi(floori(edit_area.position.x) - 1, floori(bounds.position.x))
	var max_x := mini(ceili(edit_area.end.x) + 1, ceili(bounds.end.x) - 1)
	var min_z := maxi(floori(edit_area.position.z) - 1, floori(bounds.position.z))
	var max_z := mini(ceili(edit_area.end.z) + 1, ceili(bounds.end.z) - 1)
	var column_count := (max_x - min_x + 1) * (max_z - min_z + 1)
	if column_count > MAX_SUPPORT_CLEANUP_COLUMNS:
		# Clamp the scan rectangle around the edit center; columns outside the
		# budget keep their overhang until a later commit touches them.
		var center_x := roundi(edit_area.get_center().x)
		var center_z := roundi(edit_area.get_center().z)
		var half := int((sqrt(float(MAX_SUPPORT_CLEANUP_COLUMNS)) - 1.0) * 0.5)
		min_x = center_x - half
		max_x = center_x + half
		min_z = center_z - half
		max_z = center_z + half
	# The lowest buffered row is the support reference under the edit; the
	# scan never writes it, only reads its solidity.
	var floor_y := maxi(floori(edit_area.position.y) - 2, floori(bounds.position.y))
	var top_y := ceili(bounds.end.y) - 1 - WorkZoneConfig.PROTECTED_SHELL_VOXELS
	var origin := Vector3i(min_x, floor_y, min_z)
	var size := Vector3i(max_x - min_x + 1, top_y - floor_y + 1, max_z - min_z + 1)
	if size.y <= 1:
		result["usec"] = _diagnostic_clock_usec() - started
		return result
	var buffer := VoxelBuffer.new()
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	buffer.create(size.x, size.y, size.z)
	_tool.copy(origin, buffer, SDF_CHANNEL_MASK, false)
	# Only signs are needed. Read the native signed-16 channel once instead of
	# calling get_voxel_f for every sample, then write only deleted samples.
	# Untouched SDF bytes (including the support row) stay exactly unchanged.
	var raw := buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF)
	var deleted := 0
	var columns := 0
	for lx in size.x:
		for lz in size.z:
			columns += 1
			var column_start := (lz * size.x + lx) * size.y * 2
			var below_solid := raw[column_start + 1] >= 0x80 or (raw[column_start + 1] == 0 and raw[column_start] == 0)
			var deleting := false
			for ly in range(1, size.y):
				var index := column_start + ly * 2
				if raw[index + 1] >= 0x80 or (raw[index + 1] == 0 and raw[index] == 0):
					if deleting or not below_solid:
						buffer.set_voxel_f(1.0, lx, ly, lz, VoxelBuffer.CHANNEL_SDF)
						deleted += 1
						deleting = true
						below_solid = false
					else:
						below_solid = true
				else:
					below_solid = false
				if deleted >= MAX_SUPPORT_CLEANUP_SAMPLES:
					break
	result["deleted_samples"] = deleted
	result["columns"] = columns
	if deleted > 0:
		_tool.paste(origin, buffer, SDF_CHANNEL_MASK)
		result["area"] = AABB(Vector3(origin), Vector3(size))
	result["usec"] = _diagnostic_clock_usec() - started
	return result

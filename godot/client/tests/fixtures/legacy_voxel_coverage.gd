extends "res://scripts/voxel_excavation_authority.gd"

# Frozen pre-optimization coverage oracle. Preserve the original string-key
# ordering, caps and full-buffer copy to detect accounting drift. Test-only.

func _native_coverage_coordinates(
	paths: Array[Dictionary],
	origin: Vector3i,
	size: Vector3i,
	geometry_candidates: Dictionary = {}
) -> Array[Vector3i]:
	# This frozen oracle compares credit coordinates, not residual admission.
	geometry_candidates.clear()
	var unique: Dictionary = {}
	var bounds := WorkZoneConfig.voxel_bounds(_work_zone.voxel_scale_m)
	var bounds_min := Vector3i(ceil(bounds.position.x), ceil(bounds.position.y), ceil(bounds.position.z))
	var bounds_max := Vector3i(floor(bounds.end.x), floor(bounds.end.y), floor(bounds.end.z)) - Vector3i.ONE
	for path in paths:
		var points := path.get("points_voxels", PackedVector3Array()) as PackedVector3Array
		var radii := path.get("radii_voxels", PackedFloat32Array()) as PackedFloat32Array
		for segment_index in range(points.size() - 1):
			var a := points[segment_index]
			var b := points[segment_index + 1]
			var distance := a.distance_to(b)
			var steps := maxi(1, ceili(distance / NATIVE_COVERAGE_STEP_VOXELS))
			for step_index in range(steps + 1):
				var alpha := float(step_index) / float(steps)
				var sample := a.lerp(b, alpha)
				var radius := lerpf(radii[segment_index], radii[segment_index + 1], alpha)
				var center := Vector3i(roundi(sample.x), roundi(sample.y), roundi(sample.z))
				for offset in NATIVE_COVERAGE_OFFSETS:
					var coordinate := center + offset
					if coordinate.x < bounds_min.x or coordinate.y < bounds_min.y or coordinate.z < bounds_min.z \
							or coordinate.x > bounds_max.x or coordinate.y > bounds_max.y or coordinate.z > bounds_max.z:
						continue
					if Vector3(coordinate).distance_to(sample) > radius + 0.55:
						continue
					var key := "%d,%d,%d" % [coordinate.x, coordinate.y, coordinate.z]
					if unique.has(key):
						continue
					unique[key] = coordinate
					if unique.size() >= MAX_NATIVE_COVERAGE_PROBES:
						return _solid_coordinates_from_buffer(unique, origin, size)
	return _solid_coordinates_from_buffer(unique, origin, size)


func _solid_coordinates_from_buffer(unique: Dictionary, origin: Vector3i, size: Vector3i) -> Array[Vector3i]:
	var buffer := VoxelBuffer.new()
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	buffer.create(size.x, size.y, size.z)
	_tool.copy(origin, buffer, SDF_CHANNEL_MASK, false)
	var keys := unique.keys()
	keys.sort()
	var result: Array[Vector3i] = []
	for key_value in keys:
		var coordinate := unique[key_value] as Vector3i
		var local := coordinate - origin
		if local.x < 0 or local.y < 0 or local.z < 0 \
				or local.x >= size.x or local.y >= size.y or local.z >= size.z:
			continue
		if buffer.get_voxel_f(local.x, local.y, local.z, VoxelBuffer.CHANNEL_SDF) > 0.0:
			continue
		result.append(coordinate)
		if result.size() >= MAX_NATIVE_COVERAGE_CELLS:
			break
	return result

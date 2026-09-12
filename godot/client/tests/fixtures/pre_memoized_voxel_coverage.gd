extends "res://scripts/voxel_excavation_authority.gd"

# Frozen geometry-aware coverage before repeated-candidate memoization.

func _native_coverage_coordinates(
	paths: Array[Dictionary],
	origin: Vector3i,
	size: Vector3i,
	geometry_candidates: Dictionary = {}
) -> Array[Vector3i]:
	geometry_candidates.clear()
	var unique: Dictionary = {}
	var bounds_min := _coverage_min
	var bounds_max := _coverage_min + _coverage_size - Vector3i.ONE
	var x_ranks := _coverage_axis_ranks[0]
	var y_ranks := _coverage_axis_ranks[1]
	var z_ranks := _coverage_axis_ranks[2]
	for path in paths:
		var points := path.get("points_voxels", PackedVector3Array()) as PackedVector3Array
		var radii := path.get("radii_voxels", PackedFloat32Array()) as PackedFloat32Array
		for segment_index in range(points.size() - 1):
			var a := points[segment_index]
			var b := points[segment_index + 1]
			var direction := b - a
			var distance_squared := direction.length_squared()
			var distance := sqrt(distance_squared)
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
					# Credit's broad stencil can reach outside the brush. Track strict
					# geometric inclusion separately, even when this key was seen on
					# an earlier segment. Leave a small SDF quantization margin.
					if not geometry_candidates.has(coordinate) and distance_squared > 0.00000001:
						var closest_alpha := clampf((Vector3(coordinate) - a).dot(direction) / distance_squared, 0.0, 1.0)
						var exact_radius := lerpf(radii[segment_index], radii[segment_index + 1], closest_alpha)
						if Vector3(coordinate).distance_to(a + direction * closest_alpha) < exact_radius - 0.02:
							geometry_candidates[coordinate] = true
					# Integer keys retain the old decimal-string lexical order so
					# the capped sample subset and transaction digests stay identical.
					var key := (x_ranks[coordinate.x - bounds_min.x] * _coverage_size.y \
						+ y_ranks[coordinate.y - bounds_min.y]) * _coverage_size.z \
						+ z_ranks[coordinate.z - bounds_min.z]
					if unique.has(key):
						continue
					unique[key] = coordinate
					if unique.size() >= MAX_NATIVE_COVERAGE_PROBES:
						return _solid_coordinates_from_buffer(unique, origin, size)
	return _solid_coordinates_from_buffer(unique, origin, size)

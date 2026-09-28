extends BucketSoilTool

## Frozen a3172ff composition and radius traversal, before static geometry caching.

func compose_snapshot(
	previous_bucket_frame: Transform3D,
	current_bucket_frame: Transform3D,
	has_previous: bool,
	identity: String
) -> Dictionary:
	var base := {
		"schema_version": SNAPSHOT_SCHEMA_VERSION,
		"valid": false,
		"reason": "tool_unavailable",
		"model_id": model_id,
		"identity": identity,
		"tool_schema_version": String(_tool.get("schema_version", "")),
		"sweep_sample_count": 0,
		"sweep_required_sample_count": 0,
		"sweep_discontinuous": false,
		"regions": [],
	}
	if not configured or identity.is_empty() or not current_bucket_frame.is_finite():
		return base
	if not has_previous or not previous_bucket_frame.is_finite():
		base["reason"] = "history_unavailable"
		return base
	var sweep_sampling := _sweep_sampling(previous_bucket_frame, current_bucket_frame)
	var sample_count := int(sweep_sampling["sample_count"])
	var composed: Array[Dictionary] = []
	for order in _regions.size():
		var region := _regions[order]
		var local_points := _local_sample_points(region)
		var previous_points: Array[Vector3] = []
		var current_points: Array[Vector3] = []
		for point in local_points:
			previous_points.append(previous_bucket_frame * point)
			current_points.append(current_bucket_frame * point)
		var swept_points: Array[Vector3] = []
		for sample_index in sample_count:
			var alpha := float(sample_index) / float(maxi(1, sample_count - 1))
			var bucket_frame := previous_bucket_frame.interpolate_with(current_bucket_frame, alpha)
			for point in local_points:
				swept_points.append(bucket_frame * point)
		var motion := Vector3.ZERO
		for point_index in local_points.size():
			var candidate_motion := current_points[point_index] - previous_points[point_index]
			if candidate_motion.length_squared() > motion.length_squared():
				motion = candidate_motion
		var center := _vector3(region["center_godot"])
		var previous_transform := previous_bucket_frame * region_local_transform(region)
		var current_transform := current_bucket_frame * region_local_transform(region)
		composed.append({
			"order": order,
			"region_id": String(region["region_id"]),
			"kind": String(region["kind"]),
			"shape": (region["shape"] as Dictionary).duplicate(true),
			"stable_soil_roles": (region["stable_soil_roles"] as Array).duplicate(),
			"active_soil_roles": (region["active_soil_roles"] as Array).duplicate(),
			"previous_transform": previous_transform,
			"current_transform": current_transform,
			"previous_center_world": previous_bucket_frame * center,
			"current_center_world": current_bucket_frame * center,
			"previous_points": previous_points,
			"current_points": current_points,
			"swept_points": swept_points,
			"points_per_sample": local_points.size(),
			"motion_world": motion,
			"outward_normal_world": (current_bucket_frame.basis * _vector3(region["outward_normal_godot"])).normalized(),
			"swept_bounds_world": _bounds_for_points(swept_points),
		})
	base["valid"] = true
	base["reason"] = "ok"
	base["sweep_sample_count"] = sample_count
	base["sweep_required_sample_count"] = int(sweep_sampling["required_sample_count"])
	base["sweep_discontinuous"] = bool(sweep_sampling["discontinuous"])
	base["regions"] = composed
	return base


func _maximum_semantic_radius_m() -> float:
	var maximum_radius := 0.0
	for region in _regions:
		for point in _local_sample_points(region):
			maximum_radius = maxf(maximum_radius, point.length())
	return maximum_radius


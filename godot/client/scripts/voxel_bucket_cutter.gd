class_name VoxelBucketCutter
extends RefCounted

const CutProposal = preload("res://scripts/voxel_cut_proposal.gd")
const WorkZoneConfig = preload("res://scripts/voxel_work_zone_config.gd")

const MAX_TELEPORT_M := 2.0
const MIN_MOTION_M := 0.0015
const ENTER_AIR_SDF := 0.35
const EXIT_AIR_SDF := 0.65
const MIN_INTO_MATERIAL_M := 0.0005
const MIN_EDGE_RADIUS_VOXELS := 0.75
const CLEARANCE_RADIUS_VOXELS := 0.72
const NATIVE_SURFACE_RADIUS_VOXELS := 0.88
const NATIVE_OVERBURDEN_RADIUS_VOXELS := 0.92
const NATIVE_MAX_SWEEP_SAMPLES := 12
const CUT_REGION_IDS := ["teeth_main_edge", "left_side_cutter", "right_side_cutter"]
const CLEARANCE_REGION_IDS := ["floor_wear_plate", "inner_shell"]
const OCCUPANCY_WIDTH_FRACTIONS := [-0.8, -0.4, 0.0, 0.4, 0.8]
const OCCUPANCY_HEIGHT_FRACTIONS := [-0.68, 0.0, 0.68]
const OVERBURDEN_DEPTH_FRACTIONS := [-0.72, 0.0, 0.72]

var configured := false
var model_id := ""
var voxel_scale_m := WorkZoneConfig.DEFAULT_VOXEL_SCALE_M
var tool_hash := ""
var validation_error := ""
var _contract: Dictionary = {}


func configure(contract: Dictionary, scale_m: float) -> bool:
	configured = false
	validation_error = ""
	var candidate_model := String(contract.get("model_id", ""))
	var descriptor := SoilContractDescriptor.from_dictionary_for_test(contract)
	if candidate_model.is_empty() or not descriptor.is_valid_for(candidate_model):
		validation_error = descriptor.validation_error()
		return false
	if not is_finite(scale_m) or scale_m <= 0.0:
		validation_error = "voxel scale must be finite and positive"
		return false
	model_id = candidate_model
	voxel_scale_m = scale_m
	_contract = contract.duplicate(true)
	tool_hash = JSON.stringify(_contract.get("bucket_tool", {})).sha256_text()
	configured = true
	return true


func build_proposal(
	pose_snapshot: Dictionary,
	generation: int,
	fixed_tick: int,
	sequence: int,
	authority_epoch: String,
	was_engaged: bool,
	sdf_sampler: Callable
) -> Dictionary:
	var rejected := {
		"accepted": false,
		"engaged": false,
		"reason": "cutter_unavailable",
		"proposal": null,
		"minimum_sdf": INF,
		"into_material_m": 0.0,
	}
	if not configured or not sdf_sampler.is_valid():
		return rejected
	if generation < 0 or fixed_tick < 0 or sequence < 0 or authority_epoch.is_empty():
		rejected["reason"] = "invalid_identity"
		return rejected
	if not bool(pose_snapshot.get("valid", false)) or String(pose_snapshot.get("model_id", "")) != model_id:
		rejected["reason"] = String(pose_snapshot.get("reason", "pose_unavailable"))
		return rejected
	var tool_snapshot := pose_snapshot.get("soil_tool", {}) as Dictionary
	if not bool(tool_snapshot.get("valid", false)) or bool(tool_snapshot.get("sweep_discontinuous", false)):
		rejected["reason"] = "sweep_discontinuous" if bool(tool_snapshot.get("sweep_discontinuous", false)) else "tool_history_unavailable"
		return rejected
	var edge := _find_region(tool_snapshot, "teeth_main_edge")
	if edge.is_empty():
		rejected["reason"] = "cutting_edge_unavailable"
		return rejected
	var previous_points := _typed_points(edge.get("previous_points", []))
	var current_points := _typed_points(edge.get("current_points", []))
	if previous_points.size() != current_points.size() or current_points.is_empty():
		rejected["reason"] = "cutting_edge_points_invalid"
		return rejected
	var maximum_motion := 0.0
	var minimum_sdf := INF
	var maximum_into := -INF
	var valid_samples := 0
	for index in current_points.size():
		var motion := current_points[index] - previous_points[index]
		maximum_motion = maxf(maximum_motion, motion.length())
		var sample_value: Variant = sdf_sampler.call(current_points[index])
		if not sample_value is Dictionary:
			continue
		var sample := sample_value as Dictionary
		if not bool(sample.get("valid", false)):
			continue
		valid_samples += 1
		minimum_sdf = minf(minimum_sdf, float(sample.get("sdf", INF)))
		var gradient := sample.get("gradient_world", Vector3.UP) as Vector3
		if gradient.is_finite() and gradient.length_squared() > 0.25:
			maximum_into = maxf(maximum_into, -motion.dot(gradient.normalized()))
	rejected["minimum_sdf"] = minimum_sdf
	rejected["into_material_m"] = maximum_into if is_finite(maximum_into) else 0.0
	if maximum_motion < MIN_MOTION_M:
		rejected["reason"] = "stationary"
		return rejected
	if maximum_motion > MAX_TELEPORT_M:
		rejected["reason"] = "teleported"
		return rejected
	if valid_samples != current_points.size():
		rejected["reason"] = "sdf_unavailable"
		return rejected
	var air_limit := EXIT_AIR_SDF if was_engaged else ENTER_AIR_SDF
	if minimum_sdf > air_limit:
		rejected["reason"] = "above_ground"
		return rejected
	var into_threshold := -MIN_INTO_MATERIAL_M if was_engaged else MIN_INTO_MATERIAL_M
	if maximum_into < into_threshold:
		rejected["reason"] = "separating"
		return rejected

	var capsules: Array[Dictionary] = []
	for region_id in CUT_REGION_IDS:
		var region := _find_region(tool_snapshot, region_id)
		if not region.is_empty():
			capsules.append_array(_segment_sweep_capsules(region, false))
	if capsules.is_empty():
		rejected["reason"] = "empty_cut_sweep"
		return rejected
	var clearance: Array[Dictionary] = []
	var leading_center := edge.get("current_center_world", current_points[current_points.size() >> 1]) as Vector3
	var leading_normal := edge.get("outward_normal_world", Vector3.DOWN) as Vector3
	for region_id in CLEARANCE_REGION_IDS:
		var region := _find_region(tool_snapshot, region_id)
		if not region.is_empty():
			clearance.append_array(_clearance_capsules(region, leading_center, leading_normal))
	var native_paths: Array[Dictionary] = []
	if model_id == "sy135":
		native_paths = _build_sy135_native_paths(tool_snapshot)
		if native_paths.is_empty():
			rejected["reason"] = "empty_native_sweep"
			return rejected
	var all_capsules := capsules + clearance
	var area := _capsule_bounds(all_capsules)
	var native_area := _native_path_bounds(native_paths)
	if native_area.size != Vector3.ZERO:
		area = native_area if area.size == Vector3.ZERO else area.merge(native_area)
	if not _area_is_editable(area):
		rejected["reason"] = "protected_or_out_of_zone"
		return rejected
	var proposal := CutProposal.create({
		"generation": generation,
		"fixed_tick_begin": fixed_tick,
		"fixed_tick_end": fixed_tick,
		"sequence": sequence,
		"model_id": model_id,
		"authority_epoch": authority_epoch,
		"tool_hash": tool_hash,
		"area_voxels": area,
		"capsules": capsules,
		"clearance_capsules": clearance,
		"native_paths": native_paths,
		"probe_world": leading_center,
		"quality_flags": [
			"continuous_half_voxel_subdivision",
			"constrained_clearance",
			"native_sdf_path" if not native_paths.is_empty() else "exact_sdf_fallback",
			"authorized_swept_occupancy" if not native_paths.is_empty() else "capsule_surface_only",
			"overburden_cleanup" if _has_native_role(native_paths, "overburden_cleanup") else "no_overburden_cleanup",
		],
	})
	if not proposal.is_valid():
		rejected["reason"] = "proposal_validation_failed"
		return rejected
	return {
		"accepted": true,
		"engaged": true,
		"reason": "accepted",
		"proposal": proposal,
		"minimum_sdf": minimum_sdf,
		"into_material_m": maximum_into,
	}


func _segment_sweep_capsules(region: Dictionary, clearance: bool) -> Array[Dictionary]:
	var previous := _typed_points(region.get("previous_points", []))
	var current := _typed_points(region.get("current_points", []))
	var result: Array[Dictionary] = []
	if previous.size() != current.size() or previous.is_empty():
		return result
	var maximum_motion := 0.0
	for index in previous.size():
		maximum_motion = maxf(maximum_motion, previous[index].distance_to(current[index]))
	var segments := maxi(1, ceili(maximum_motion / (voxel_scale_m * 0.5)))
	var radius_world := _shape_radius_world(region)
	var radius_voxels := maxf(radius_world / voxel_scale_m, CLEARANCE_RADIUS_VOXELS if clearance else MIN_EDGE_RADIUS_VOXELS)
	var prior_sample: Array[Vector3] = []
	for step in range(segments + 1):
		var alpha := float(step) / float(segments)
		var sample: Array[Vector3] = []
		for index in previous.size():
			sample.append(previous[index].lerp(current[index], alpha))
		for index in range(sample.size() - 1):
			_append_capsule(result, sample[index], sample[index + 1], radius_voxels, String(region.get("region_id", "")))
		if not prior_sample.is_empty():
			for index in sample.size():
				_append_capsule(result, prior_sample[index], sample[index], radius_voxels, String(region.get("region_id", "")))
		prior_sample = sample
	return result


func _clearance_capsules(region: Dictionary, leading_center: Vector3, leading_normal: Vector3) -> Array[Dictionary]:
	var previous := _typed_points(region.get("previous_points", []))
	var current := _typed_points(region.get("current_points", []))
	var result: Array[Dictionary] = []
	if previous.size() != current.size() or previous.is_empty() or leading_normal.length_squared() < 0.5:
		return result
	var normal := leading_normal.normalized()
	for index in current.size():
		if (current[index] - leading_center).dot(normal) > voxel_scale_m * 0.25:
			continue
		_append_capsule(result, previous[index], current[index], CLEARANCE_RADIUS_VOXELS, "clearance:%s" % String(region.get("region_id", "")))
	return result


func _build_sy135_native_paths(tool_snapshot: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for region_id in CUT_REGION_IDS:
		var cut_region := _find_region(tool_snapshot, region_id)
		if not cut_region.is_empty():
			var leading_path := _region_swept_path(cut_region, "leading_edge")
			if not leading_path.is_empty():
				result.append(leading_path)
	var inner := _find_region(tool_snapshot, "inner_shell")
	if not inner.is_empty():
		result.append_array(_box_surface_paths(
			inner,
			OCCUPANCY_WIDTH_FRACTIONS,
			OCCUPANCY_HEIGHT_FRACTIONS,
			"bucket_occupancy",
			NATIVE_SURFACE_RADIUS_VOXELS,
		))
		result.append_array(_overburden_cleanup_paths(inner))
	var floor := _find_region(tool_snapshot, "floor_wear_plate")
	if not floor.is_empty():
		result.append_array(_box_surface_paths(
			floor,
			OCCUPANCY_WIDTH_FRACTIONS,
			[0.0],
			"bucket_floor",
			NATIVE_SURFACE_RADIUS_VOXELS,
		))
	return _combine_native_paths_by_role(result)


func _region_swept_path(region: Dictionary, role: String) -> Dictionary:
	var swept := _typed_points(region.get("swept_points", []))
	var points_per_sample := maxi(1, int(region.get("points_per_sample", 0)))
	if swept.size() < 2 or swept.size() % points_per_sample != 0:
		return {}
	var points := PackedVector3Array()
	var sample_count := int(swept.size() / points_per_sample)
	for sample_index in sample_count:
		for point_offset in points_per_sample:
			var source_index := point_offset if sample_index % 2 == 0 else points_per_sample - 1 - point_offset
			points.append(WorkZoneConfig.world_to_voxel(
				swept[sample_index * points_per_sample + source_index],
				voxel_scale_m,
			))
	return _native_path(
		"%s:%s" % [role, String(region.get("region_id", ""))],
		role,
		points,
		maxf(_shape_radius_world(region) / voxel_scale_m, MIN_EDGE_RADIUS_VOXELS),
	)


func _box_surface_paths(
	region: Dictionary,
	width_fractions: Array,
	height_fractions: Array,
	role: String,
	radius_voxels: float
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var dimensions := _box_half_dimensions(region)
	if dimensions == Vector3.ZERO:
		return result
	var transforms := _sweep_transforms(region)
	if transforms.size() < 2:
		return result
	for width_value in width_fractions:
		var width_fraction := float(width_value)
		for height_value in height_fractions:
			var height_fraction := float(height_value)
			var points := PackedVector3Array()
			for sample_index in transforms.size():
				var transform := transforms[sample_index]
				var first_z := -dimensions.z * 0.92 if sample_index % 2 == 0 else dimensions.z * 0.92
				var second_z := -first_z
				points.append(WorkZoneConfig.world_to_voxel(
					transform * Vector3(dimensions.x * width_fraction, dimensions.y * height_fraction, first_z),
					voxel_scale_m,
				))
				points.append(WorkZoneConfig.world_to_voxel(
					transform * Vector3(dimensions.x * width_fraction, dimensions.y * height_fraction, second_z),
					voxel_scale_m,
				))
			result.append(_native_path(
				"%s:%s:%+.2f:%+.2f" % [role, String(region.get("region_id", "")), width_fraction, height_fraction],
				role,
				points,
				radius_voxels,
			))
	return result


func _overburden_cleanup_paths(inner_region: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var dimensions := _box_half_dimensions(inner_region)
	if dimensions == Vector3.ZERO:
		return result
	var transforms := _sweep_transforms(inner_region)
	if transforms.size() < 2:
		return result
	var cleanup_top_y := WorkZoneConfig.INITIAL_SURFACE_Y + voxel_scale_m * 0.5
	for width_value in OCCUPANCY_WIDTH_FRACTIONS:
		var width_fraction := float(width_value)
		for depth_value in OVERBURDEN_DEPTH_FRACTIONS:
			var depth_fraction := float(depth_value)
			var points := PackedVector3Array()
			var penetrated := false
			for sample_index in transforms.size():
				var transform := transforms[sample_index]
				var lower := transform * Vector3(
					dimensions.x * width_fraction,
					dimensions.y * 0.82,
					dimensions.z * depth_fraction,
				)
				if lower.y >= WorkZoneConfig.INITIAL_SURFACE_Y - voxel_scale_m * 1.5:
					continue
				penetrated = true
				var upper := Vector3(lower.x, cleanup_top_y, lower.z)
				if sample_index % 2 == 0:
					points.append(WorkZoneConfig.world_to_voxel(lower, voxel_scale_m))
					points.append(WorkZoneConfig.world_to_voxel(upper, voxel_scale_m))
				else:
					points.append(WorkZoneConfig.world_to_voxel(upper, voxel_scale_m))
					points.append(WorkZoneConfig.world_to_voxel(lower, voxel_scale_m))
			if penetrated and points.size() >= 2:
				result.append(_native_path(
					"overburden:%+.2f:%+.2f" % [width_fraction, depth_fraction],
					"overburden_cleanup",
					points,
					NATIVE_OVERBURDEN_RADIUS_VOXELS,
				))
	return result


func _sweep_transforms(region: Dictionary) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	var previous := region.get("previous_transform", Transform3D()) as Transform3D
	var current := region.get("current_transform", Transform3D()) as Transform3D
	if not previous.is_finite() or not current.is_finite():
		return result
	var maximum_motion := previous.origin.distance_to(current.origin)
	var samples := clampi(ceili(maximum_motion / (voxel_scale_m * 0.65)) + 1, 2, NATIVE_MAX_SWEEP_SAMPLES)
	for index in samples:
		var alpha := float(index) / float(maxi(1, samples - 1))
		result.append(previous.interpolate_with(current, alpha))
	return result


func _box_half_dimensions(region: Dictionary) -> Vector3:
	var shape := region.get("shape", {}) as Dictionary
	var raw := shape.get("size_m", []) as Array
	if String(shape.get("kind", "")) != "box" or raw.size() != 3:
		return Vector3.ZERO
	return Vector3(float(raw[0]), float(raw[1]), float(raw[2])) * 0.5


func _native_path(path_id: String, role: String, points: PackedVector3Array, radius_voxels: float) -> Dictionary:
	var radii := PackedFloat32Array()
	radii.resize(points.size())
	radii.fill(radius_voxels)
	return {
		"path_id": path_id,
		"role": role,
		"components": [role],
		"points_voxels": points,
		"radii_voxels": radii,
	}


func _combine_native_paths_by_role(paths: Array[Dictionary]) -> Array[Dictionary]:
	var combined: Array[Dictionary] = []
	var indexes: Dictionary = {}
	for path in paths:
		var role := String(path.get("role", ""))
		if not indexes.has(role):
			indexes[role] = combined.size()
			combined.append({
				"path_id": "%s:combined" % role,
				"role": role,
				"components": [role],
				"points_voxels": PackedVector3Array(),
				"radii_voxels": PackedFloat32Array(),
			})
		var combined_index := int(indexes[role])
		var target := combined[combined_index]
		var target_points := target.get("points_voxels", PackedVector3Array()) as PackedVector3Array
		var target_radii := target.get("radii_voxels", PackedFloat32Array()) as PackedFloat32Array
		var source_points := path.get("points_voxels", PackedVector3Array()) as PackedVector3Array
		var source_radii := path.get("radii_voxels", PackedFloat32Array()) as PackedFloat32Array
		for point_index in source_points.size():
			target_points.append(source_points[point_index])
			target_radii.append(source_radii[point_index])
		target["points_voxels"] = target_points
		target["radii_voxels"] = target_radii
		combined[combined_index] = target
	return combined


func _native_path_bounds(paths: Array[Dictionary]) -> AABB:
	var bounds := AABB()
	for path in paths:
		var points := path.get("points_voxels", PackedVector3Array()) as PackedVector3Array
		var radii := path.get("radii_voxels", PackedFloat32Array()) as PackedFloat32Array
		for index in points.size():
			var radius := float(radii[index])
			var point_bounds := AABB(points[index] - Vector3.ONE * radius, Vector3.ONE * radius * 2.0)
			bounds = point_bounds if bounds.size == Vector3.ZERO else bounds.merge(point_bounds)
	return bounds


func _has_native_role(paths: Array[Dictionary], role: String) -> bool:
	for path in paths:
		if String(path.get("role", "")) == role or (path.get("components", []) as Array).has(role):
			return true
	return false


func _append_capsule(result: Array[Dictionary], a_world: Vector3, b_world: Vector3, radius_voxels: float, source: String) -> void:
	result.append({
		"kind": "capsule",
		"a_voxels": WorkZoneConfig.world_to_voxel(a_world, voxel_scale_m),
		"b_voxels": WorkZoneConfig.world_to_voxel(b_world, voxel_scale_m),
		"radius_voxels": radius_voxels,
		"source": source,
	})


func _capsule_bounds(capsules: Array[Dictionary]) -> AABB:
	if capsules.is_empty():
		return AABB()
	var first := capsules[0]
	var radius := float(first["radius_voxels"])
	var bounds := AABB((first["a_voxels"] as Vector3) - Vector3.ONE * radius, Vector3.ONE * radius * 2.0)
	for capsule in capsules:
		radius = float(capsule["radius_voxels"])
		bounds = bounds.expand((capsule["a_voxels"] as Vector3) - Vector3.ONE * radius)
		bounds = bounds.expand((capsule["a_voxels"] as Vector3) + Vector3.ONE * radius)
		bounds = bounds.expand((capsule["b_voxels"] as Vector3) - Vector3.ONE * radius)
		bounds = bounds.expand((capsule["b_voxels"] as Vector3) + Vector3.ONE * radius)
	return bounds


func _area_is_editable(area_voxels: AABB) -> bool:
	var minimum_world := WorkZoneConfig.voxel_to_world(area_voxels.position, voxel_scale_m)
	var maximum_world := WorkZoneConfig.voxel_to_world(area_voxels.end, voxel_scale_m)
	var editable := WorkZoneConfig.editable_world_bounds(voxel_scale_m)
	return editable.has_point(minimum_world) and editable.has_point(maximum_world - Vector3.ONE * 0.0001)


func _find_region(tool_snapshot: Dictionary, region_id: String) -> Dictionary:
	for value in tool_snapshot.get("regions", []):
		if value is Dictionary and String((value as Dictionary).get("region_id", "")) == region_id:
			return value as Dictionary
	return {}


func _typed_points(values: Variant) -> Array[Vector3]:
	var points: Array[Vector3] = []
	if not values is Array:
		return points
	for value in values:
		if value is Vector3 and (value as Vector3).is_finite():
			points.append(value as Vector3)
	return points


func _shape_radius_world(region: Dictionary) -> float:
	var shape := region.get("shape", {}) as Dictionary
	return float(shape.get("radius_m", voxel_scale_m * MIN_EDGE_RADIUS_VOXELS))

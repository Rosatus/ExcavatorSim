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
const CUT_REGION_IDS := ["teeth_main_edge", "left_side_cutter", "right_side_cutter"]
const CLEARANCE_REGION_IDS := ["floor_wear_plate", "inner_shell"]

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
	var all_capsules := capsules + clearance
	var area := _capsule_bounds(all_capsules)
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
		"probe_world": leading_center,
		"quality_flags": ["continuous_half_voxel_subdivision", "constrained_clearance"],
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

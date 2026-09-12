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
	sdf_sampler: Callable,
	contact_sampler: Callable = Callable(),
	batch_contact_sampler: Callable = Callable()
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
		# A committed brush clears its own contact probes. Keep the established
		# episode through a pause in that cavity, without submitting an air cut.
		rejected["engaged"] = was_engaged and model_id == "sy135" \
			and valid_samples == current_points.size() and _within_lift_exit_envelope(tool_snapshot)
		return rejected
	if maximum_motion > MAX_TELEPORT_M:
		rejected["reason"] = "teleported"
		return rejected
	if valid_samples != current_points.size():
		rejected["reason"] = "sdf_unavailable"
		return rejected
	var air_limit := EXIT_AIR_SDF if was_engaged else ENTER_AIR_SDF
	var into_threshold := -MIN_INTO_MATERIAL_M if was_engaged else MIN_INTO_MATERIAL_M
	# A previously authorized cut must finish the trailing roof sweep while the
	# teeth lift out. Teeth-only entry tests cannot decide that the whole bucket
	# has left the soil. Never use this continuation to start an unengaged cut.
	var finishing_lift := false
	if was_engaged and model_id == "sy135":
		# Exit contact needs occupancy only; the leading edge still needs normals.
		finishing_lift = _has_lift_exit_contact(tool_snapshot,
			contact_sampler if contact_sampler.is_valid() else sdf_sampler, true, batch_contact_sampler)
	# Contact decides whether this frame cuts; the geometric exit decides
	# when the episode ends. Clearing one frame must not disable later contact.
	var retain_lift := was_engaged and model_id == "sy135" \
		and _has_upward_motion(tool_snapshot) and _within_lift_exit_envelope(tool_snapshot)
	if minimum_sdf > air_limit and not finishing_lift:
		rejected["reason"] = "above_ground"
		rejected["engaged"] = retain_lift
		return rejected
	if maximum_into < into_threshold and not finishing_lift:
		rejected["reason"] = "separating"
		rejected["engaged"] = retain_lift
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
		native_paths = _build_sy135_native_paths(tool_snapshot, finishing_lift)
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
			"engaged_lift_exit" if finishing_lift else "leading_front_admission",
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


func _within_lift_exit_envelope(tool_snapshot: Dictionary) -> bool:
	var inner := _find_region(tool_snapshot, "inner_shell")
	var half := _box_half_dimensions(inner)
	var current := inner.get("current_transform", Transform3D.IDENTITY) as Transform3D
	if half == Vector3.ZERO or not current.is_finite():
		return false
	var bounds := current * AABB(-half, half * 2.0)
	if bounds.position.y < WorkZoneConfig.INITIAL_SURFACE_Y:
		return true
	for point in _lip_bridge_points(tool_snapshot, 1.0):
		if point.y < WorkZoneConfig.INITIAL_SURFACE_Y:
			return true
	return false


func _has_upward_motion(tool_snapshot: Dictionary) -> bool:
	var inner := _find_region(tool_snapshot, "inner_shell")
	var previous := inner.get("previous_transform", Transform3D.IDENTITY) as Transform3D
	var current := inner.get("current_transform", Transform3D.IDENTITY) as Transform3D
	var edge := _find_region(tool_snapshot, "teeth_main_edge")
	var previous_edge := edge.get("previous_center_world", previous.origin) as Vector3
	var current_edge := edge.get("current_center_world", current.origin) as Vector3
	return maxf(current.origin.y - previous.origin.y, current_edge.y - previous_edge.y) > MIN_INTO_MATERIAL_M


func _has_lift_exit_contact(
	tool_snapshot: Dictionary,
	sdf_sampler: Callable,
	require_lift: bool = true,
	batch_sampler: Callable = Callable()
) -> bool:
	var inner := _find_region(tool_snapshot, "inner_shell")
	var dimensions := _box_half_dimensions(inner)
	if dimensions == Vector3.ZERO:
		return false
	var previous := inner.get("previous_transform", Transform3D.IDENTITY) as Transform3D
	var current := inner.get("current_transform", Transform3D.IDENTITY) as Transform3D
	if require_lift and not _has_upward_motion(tool_snapshot):
		return false
	var direct_samples := 0
	var pending_voxels: Dictionary = {}
	# Use the world-vertical lower envelope, not the box's local +Y face.
	# The latter may be airborne while the rotated bottom is still in soil.
	for alpha in [0.0, 0.5, 1.0]:
		var transform := previous.interpolate_with(current, float(alpha))
		var lower_points := _roof_lower_points(transform, dimensions)
		lower_points.append_array(_lip_bridge_points(tool_snapshot, float(alpha)))
		for lower in lower_points:
			if lower.y > WorkZoneConfig.INITIAL_SURFACE_Y:
				continue
			# Check the same vertical column emitted by cleanup. Surface-only
			# contact misses thin remnants after the original roof was removed.
			var top_y := WorkZoneConfig.INITIAL_SURFACE_Y - voxel_scale_m * 0.25
			var steps := clampi(ceili(absf(top_y - lower.y) / voxel_scale_m), 1, 32)
			for step in range(steps + 1):
				var point := Vector3(lower.x, lerpf(lower.y, top_y, float(step) / steps), lower.z)
				# Keep the cheap early exit when the first probes already touch soil.
				# Otherwise collect exactly the old rounded samples and read them in
				# one bounded batch, instead of thousands of script/native calls.
				if batch_sampler.is_valid() and direct_samples >= 8:
					if not point.is_finite():
						continue
					var voxel := WorkZoneConfig.world_to_voxel(point, voxel_scale_m)
					pending_voxels[Vector3i(round(voxel.x), round(voxel.y), round(voxel.z))] = true
					continue
				direct_samples += 1
				var value: Variant = sdf_sampler.call(point)
				if value is Dictionary and bool(value.get("valid", false)) and float(value.get("sdf", INF)) <= 0.0:
					return true
	return bool(batch_sampler.call(pending_voxels)) if not pending_voxels.is_empty() else false


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


func _build_sy135_native_paths(tool_snapshot: Dictionary, finishing_lift: bool = false) -> Array[Dictionary]:
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
		result.append_array(_overburden_cleanup_paths(inner, finishing_lift))
	var floor := _find_region(tool_snapshot, "floor_wear_plate")
	if not floor.is_empty():
		result.append_array(_box_surface_paths(
			floor,
			OCCUPANCY_WIDTH_FRACTIONS,
			[0.0],
			"bucket_floor",
			NATIVE_SURFACE_RADIUS_VOXELS,
		))
	var combined := _combine_native_paths_by_role(result)
	# Preserve lip path boundaries: joining the old wear-plate lane's end to
	# the lip's opposite corner would cut an unintended diagonal connector.
	combined.append_array(_lip_bridge_paths(tool_snapshot, finishing_lift))
	return combined


func _lip_bridge_points(tool_snapshot: Dictionary, alpha: float) -> Array[Vector3]:
	# The contract's cavity and short wear plate stop behind the tooth line.
	# Cover the working lip between those two edges, not an enlarged cavity.
	var result: Array[Vector3] = []
	var edge := _find_region(tool_snapshot, "teeth_main_edge")
	var floor := _find_region(tool_snapshot, "floor_wear_plate")
	var half := _box_half_dimensions(floor)
	var previous := _typed_points(edge.get("previous_points", []))
	var current := _typed_points(edge.get("current_points", []))
	if half == Vector3.ZERO or previous.size() != 3 or current.size() != 3:
		return result
	var floor_previous := floor.get("previous_transform", Transform3D.IDENTITY) as Transform3D
	var floor_current := floor.get("current_transform", Transform3D.IDENTITY) as Transform3D
	var transform := floor_previous.interpolate_with(floor_current, alpha)
	var tooth_left := previous[0].lerp(current[0], alpha)
	var tooth_right := previous[2].lerp(current[2], alpha)
	var tooth_center := (tooth_left + tooth_right) * 0.5
	var front_z := half.z
	if (transform * Vector3(0, 0, -half.z)).distance_squared_to(tooth_center) < (transform * Vector3(0, 0, half.z)).distance_squared_to(tooth_center):
		front_z = -half.z
	var floor_left := transform * Vector3(-half.x, 0, front_z)
	var floor_right := transform * Vector3(half.x, 0, front_z)
	if floor_left.distance_squared_to(tooth_left) > floor_right.distance_squared_to(tooth_left):
		var swap := floor_left
		floor_left = floor_right
		floor_right = swap
	var spacing := NATIVE_SURFACE_RADIUS_VOXELS * voxel_scale_m * 1.2
	var width_steps := maxi(1, ceili(tooth_left.distance_to(tooth_right) / spacing))
	var depth_steps := maxi(1, ceili(maxf(tooth_left.distance_to(floor_left), tooth_right.distance_to(floor_right)) / spacing))
	for width in range(width_steps + 1):
		var fraction := float(width) / width_steps
		var tooth := tooth_left.lerp(tooth_right, fraction)
		var plate := floor_left.lerp(floor_right, fraction)
		for depth in range(depth_steps + 1):
			var along := float(depth if width % 2 == 0 else depth_steps - depth) / depth_steps
			result.append(tooth.lerp(plate, along))
	return result


func _lip_bridge_paths(tool_snapshot: Dictionary, finishing_lift: bool) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var transforms := _sweep_transforms(_find_region(tool_snapshot, "floor_wear_plate"))
	var surface := PackedVector3Array()
	var roof := PackedVector3Array()
	var cutoff := WorkZoneConfig.INITIAL_SURFACE_Y - (0.0 if finishing_lift else voxel_scale_m * 1.5)
	for index in transforms.size():
		var points := _lip_bridge_points(tool_snapshot, float(index) / maxi(1, transforms.size() - 1))
		if index % 2 == 1:
			points.reverse()
		for point in points:
			_append_distinct_path_point(surface, point)
			if point.y >= cutoff:
				continue
			var upper := Vector3(point.x, WorkZoneConfig.INITIAL_SURFACE_Y + voxel_scale_m * 0.5, point.z)
			var reverse := (roof.size() / 2) % 2 == 1
			_append_distinct_path_point(roof, upper if reverse else point)
			_append_distinct_path_point(roof, point if reverse else upper)
	if surface.size() >= 2:
		result.append(_native_path("floor:tooth_lip", "bucket_floor", surface, NATIVE_SURFACE_RADIUS_VOXELS))
	if roof.size() >= 2:
		result.append(_native_path("overburden:tooth_lip", "overburden_cleanup", roof, NATIVE_OVERBURDEN_RADIUS_VOXELS))
	return result


func _append_distinct_path_point(points: PackedVector3Array, world: Vector3) -> void:
	var point := WorkZoneConfig.world_to_voxel(world, voxel_scale_m)
	if points.is_empty() or points[points.size() - 1].distance_squared_to(point) > 0.00000001:
		points.append(point)


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
	# Round lanes must cover the diagonal between neighbours, not merely
	# overlap along each axis. Reserve radius for temporal subdivision too.
	if role == "bucket_occupancy":
		width_fractions = _coverage_fractions(dimensions.x, radius_voxels)
		height_fractions = _coverage_fractions(dimensions.y, radius_voxels)
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


func _coverage_fractions(half_extent: float, radius_voxels: float) -> Array:
	var count := maxi(1, ceili(2.0 * half_extent / (radius_voxels * voxel_scale_m * 1.2)))
	var fractions: Array = []
	for index in count:
		fractions.append(-1.0 + (2.0 * index + 1.0) / count)
	return fractions


func _roof_lower_points(transform: Transform3D, half: Vector3) -> Array[Vector3]:
	var result: Array[Vector3] = []
	var bounds := transform * AABB(-half, half * 2.0)
	var inverse := transform.affine_inverse()
	var direction := inverse.basis * Vector3.UP
	var spacing := NATIVE_OVERBURDEN_RADIUS_VOXELS * voxel_scale_m * 1.2
	var count_x := maxi(1, ceili(bounds.size.x / spacing))
	var count_z := maxi(1, ceili(bounds.size.z / spacing))
	for ix in count_x:
		for iz in count_z:
			var world := Vector3(bounds.position.x + bounds.size.x * (ix + 0.5) / count_x,
				transform.origin.y, bounds.position.z + bounds.size.z * (iz + 0.5) / count_z)
			var local := inverse * world
			var lower := -INF
			var upper := INF
			var intersects := true
			for axis in 3:
				if absf(direction[axis]) < 0.000001:
					if absf(local[axis]) > half[axis]:
						intersects = false
						break
					continue
				var a := (-half[axis] - local[axis]) / direction[axis]
				var b := (half[axis] - local[axis]) / direction[axis]
				lower = maxf(lower, minf(a, b))
				upper = minf(upper, maxf(a, b))
			if intersects and lower <= upper:
				result.append(world + Vector3.UP * lower)
	return result


func _overburden_cleanup_paths(inner_region: Dictionary, finishing_lift: bool = false) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var dimensions := _box_half_dimensions(inner_region)
	if dimensions == Vector3.ZERO:
		return result
	var cleanup_top_y := WorkZoneConfig.INITIAL_SURFACE_Y + voxel_scale_m * 0.5
	var cutoff_y := WorkZoneConfig.INITIAL_SURFACE_Y if finishing_lift else WorkZoneConfig.INITIAL_SURFACE_Y - voxel_scale_m * 1.5
	var points := PackedVector3Array()
	for transform in _sweep_transforms(inner_region):
		for lower in _roof_lower_points(transform, dimensions):
			if lower.y >= cutoff_y:
				continue
			var upper := Vector3(lower.x, cleanup_top_y, lower.z)
			# Alternate vertical direction so connections remain inside the
			# sampled lower-envelope/roof region. Do not emit degenerate pairs.
			var reverse := (points.size() / 2) % 2 == 1
			points.append(WorkZoneConfig.world_to_voxel(upper if reverse else lower, voxel_scale_m))
			points.append(WorkZoneConfig.world_to_voxel(lower if reverse else upper, voxel_scale_m))
	if points.size() >= 2:
		result.append(_native_path("overburden:lower_envelope", "overburden_cleanup", points, NATIVE_OVERBURDEN_RADIUS_VOXELS))
	return result


func _sweep_transforms(region: Dictionary) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	var previous := region.get("previous_transform", Transform3D()) as Transform3D
	var current := region.get("current_transform", Transform3D()) as Transform3D
	if not previous.is_finite() or not current.is_finite():
		return result
	var maximum_motion := previous.origin.distance_to(current.origin)
	var rotation := previous.basis.get_rotation_quaternion().angle_to(current.basis.get_rotation_quaternion())
	maximum_motion += _box_half_dimensions(region).length() * absf(rotation)
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

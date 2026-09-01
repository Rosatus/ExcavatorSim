class_name BucketSoilTool
extends RefCounted

## Pure full-bucket semantic composer/classifier. It reads accepted bucket poses,
## terrain samples, and fill state. It owns no scene body and has no mutation API.

const SNAPSHOT_SCHEMA_VERSION := "bucket-soil-tool-snapshot-v1"
const TELEMETRY_SCHEMA_VERSION := "bucket-soil-tool-shadow-v1"
const NONE := "none"

var configured := false
var model_id := ""
var validation_error := ""
var _tool: Dictionary = {}
var _regions: Array[Dictionary] = []


func configure(contract: Dictionary) -> bool:
	reset()
	var candidate_model := String(contract.get("model_id", ""))
	var descriptor := SoilContractDescriptor.from_dictionary_for_test(contract)
	if candidate_model.is_empty() or not descriptor.is_valid_for(candidate_model):
		validation_error = descriptor.validation_error()
		return false
	model_id = candidate_model
	_tool = descriptor.tool_contract()
	for value in _tool.get("regions", []):
		_regions.append((value as Dictionary).duplicate(true))
	configured = true
	return true


func reset() -> void:
	configured = false
	model_id = ""
	validation_error = ""
	_tool.clear()
	_regions.clear()


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
		var previous_transform := previous_bucket_frame * _debug_local_transform(region)
		var current_transform := current_bucket_frame * _debug_local_transform(region)
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


func classify(
	snapshot: Dictionary,
	terrain_state: TerrainState,
	fill_ratio: float,
	interaction: Dictionary
) -> Dictionary:
	var result := {
		"schema_version": TELEMETRY_SCHEMA_VERSION,
		"valid": false,
		"reason": "snapshot_unavailable",
		"model_id": model_id,
		"identity": String(snapshot.get("identity", "")),
		"sweep_sample_count": int(snapshot.get("sweep_sample_count", 0)),
		"fill_ratio": clampf(fill_ratio, 0.0, 1.5),
		"candidates": [],
		"quality_flags": [],
	}
	if not configured or not bool(snapshot.get("valid", false)) or snapshot.get("model_id") != model_id:
		(result["quality_flags"] as Array).append("soil_tool_snapshot_unavailable")
		return result
	var candidates: Array[Dictionary] = []
	for region_value in snapshot.get("regions", []):
		if region_value is Dictionary:
			candidates.append(_classify_region(region_value as Dictionary, terrain_state, fill_ratio, interaction))
	candidates.sort_custom(_candidate_less)
	result["valid"] = true
	result["reason"] = "ok"
	result["candidates"] = candidates
	if terrain_state == null:
		(result["quality_flags"] as Array).append("terrain_unavailable")
	return result


func _classify_region(
	region: Dictionary,
	terrain_state: TerrainState,
	fill_ratio: float,
	interaction: Dictionary
) -> Dictionary:
	var motion := region.get("motion_world", Vector3.ZERO) as Vector3
	var outward := region.get("outward_normal_world", Vector3.UP) as Vector3
	var minimum_sweep := float(interaction.get("minimum_sweep_m", 0.004))
	var tolerance := float(interaction.get("contact_tolerance_m", 0.12))
	var maximum_depth := float(interaction.get("maximum_cut_depth_m", 0.08))
	var best_penetration := -INF
	var maximum_observed_penetration := -INF
	var best_point := Vector3.ZERO
	var best_sample_index := -1
	var points_per_sample := maxi(1, int(region.get("points_per_sample", 1)))
	var swept_points := region.get("swept_points", []) as Array
	if terrain_state != null:
		for point_index in swept_points.size():
			var point := swept_points[point_index] as Vector3
			var surface := terrain_state.sample_surface_bilinear_at(Vector2(point.x, point.z))
			if is_nan(surface):
				continue
			var penetration := surface - point.y
			maximum_observed_penetration = maxf(maximum_observed_penetration, penetration)
			var sample_index := point_index / points_per_sample
			if (
				penetration >= 0.001 and penetration <= maximum_depth + tolerance
				and (best_sample_index < 0 or sample_index < best_sample_index or (sample_index == best_sample_index and penetration > best_penetration))
			):
				best_penetration = penetration
				best_point = point
				best_sample_index = sample_index
	var terrain_normal := _terrain_normal(terrain_state, best_point)
	var overlap := best_sample_index >= 0
	var moving_into_surface := -motion.dot(terrain_normal)
	var tangential_motion := motion.slide(terrain_normal).length()
	var resting := motion.length() < minimum_sweep
	var separating := moving_into_surface < -minimum_sweep * 0.1 and tangential_motion < minimum_sweep
	var stable_roles := region.get("stable_soil_roles", []) as Array
	var active_roles := region.get("active_soil_roles", []) as Array
	var classification := NONE
	var role_scope := NONE
	if active_roles.has("contain") and fill_ratio > 0.000001:
		classification = "contain"
		role_scope = "active"
	elif active_roles.has("dump") and fill_ratio > 0.000001:
		var opening_down_dot := outward.dot(Vector3.DOWN)
		var dump_threshold := float(interaction.get("dump_opening_down_dot", 0.3))
		var spill_threshold := float(interaction.get("spill_opening_down_dot", dump_threshold - 0.25))
		if opening_down_dot > dump_threshold:
			classification = "dump"
			role_scope = "active"
		elif active_roles.has("spill") and opening_down_dot > spill_threshold and fill_ratio > 0.45:
			classification = "spill"
			role_scope = "active"
	elif active_roles.has("entry") and overlap and not resting and motion.dot(-outward) > minimum_sweep * 0.25:
		classification = "entry"
		role_scope = "active"
	elif overlap and not resting and not separating and not stable_roles.is_empty():
		classification = _stable_classification(region, stable_roles, motion, outward, terrain_normal, minimum_sweep, moving_into_surface, tangential_motion, best_penetration, maximum_depth)
		if classification != NONE:
			role_scope = "stable"
	var sample_count := maxi(1, int(region.get("sweep_sample_count", 0)))
	if sample_count == 1:
		sample_count = maxi(1, ceili(float(swept_points.size()) / float(points_per_sample)))
	var travel_fraction := 1.0
	if best_sample_index >= 0 and sample_count > 1:
		travel_fraction = clampf(float(best_sample_index) / float(sample_count - 1), 0.0, 1.0)
	return {
		"order": int(region.get("order", 0)),
		"region_id": String(region.get("region_id", "")),
		"region_kind": String(region.get("kind", "")),
		"classification": classification,
		"role_scope": role_scope,
		"overlap": overlap,
		"penetration_m": maxf(0.0, best_penetration) if overlap else maxf(0.0, maximum_observed_penetration) if not is_inf(maximum_observed_penetration) else 0.0,
		"motion_m": motion.length(),
		"moving_into_surface_m": moving_into_surface,
		"travel_fraction": travel_fraction,
		"point_world": best_point,
		"terrain_normal_world": terrain_normal,
		"outward_normal_world": outward,
		"quality": "terrain_sample" if terrain_state != null and best_sample_index >= 0 else "terrain_unavailable",
	}


func _stable_classification(
	region: Dictionary,
	roles: Array,
	motion: Vector3,
	outward: Vector3,
	terrain_normal: Vector3,
	minimum_sweep: float,
	moving_into_surface: float,
	tangential_motion: float,
	penetration: float,
	maximum_depth: float
) -> String:
	var kind := String(region.get("kind", ""))
	if roles.has("cut") and (moving_into_surface > minimum_sweep * 0.1 or tangential_motion >= minimum_sweep):
		return "cut"
	if kind == "side_cutter" and roles.has("side_cut") and (tangential_motion >= minimum_sweep or moving_into_surface > minimum_sweep * 0.1):
		return "side_cut"
	if kind == "floor":
		if roles.has("scrape") and tangential_motion >= minimum_sweep:
			return "scrape"
		if roles.has("grade") and moving_into_surface > minimum_sweep * 0.1:
			return "grade"
	if kind == "outer_shell":
		var face_advance := -motion.dot(outward)
		if roles.has("compact") and moving_into_surface > minimum_sweep and tangential_motion < minimum_sweep and penetration > maximum_depth * 0.2:
			return "compact"
		if roles.has("push") and face_advance > minimum_sweep * 0.25:
			return "push"
		if roles.has("back_drag") and face_advance < -minimum_sweep * 0.25 and tangential_motion >= minimum_sweep:
			return "back_drag"
		if roles.has("side_cut") and tangential_motion >= minimum_sweep:
			return "side_cut"
		if roles.has("grade") and (tangential_motion >= minimum_sweep or absf(outward.dot(terrain_normal)) > 0.2):
			return "grade"
	return NONE


func _sample_count(previous: Transform3D, current: Transform3D) -> int:
	return int(_sweep_sampling(previous, current)["sample_count"])


func _sweep_sampling(previous: Transform3D, current: Transform3D) -> Dictionary:
	var sweep := _tool.get("sweep", {}) as Dictionary
	var translation_step := float(sweep.get("maximum_translation_step_m", 0.08))
	var rotation_step := deg_to_rad(float(sweep.get("maximum_rotation_step_degrees", 4.0)))
	var maximum_samples := int(sweep.get("maximum_samples", 12))
	var distance_segments := ceili(previous.origin.distance_to(current.origin) / translation_step)
	var rotation := previous.basis.get_rotation_quaternion().angle_to(current.basis.get_rotation_quaternion())
	# Rotation about bucket_link can move the teeth/floor much farther than the
	# frame origin. Bound the most distant semantic point as well so a four-degree
	# bucket rotation cannot jump across the terrain working band between samples.
	var semantic_arc := 2.0 * _maximum_semantic_radius_m() * sin(rotation * 0.5)
	distance_segments = maxi(distance_segments, ceili(semantic_arc / translation_step))
	var rotation_segments := ceili(rotation / rotation_step)
	var required_sample_count := maxi(1, maxi(distance_segments, rotation_segments)) + 1
	return {
		"sample_count": clampi(required_sample_count, 2, maximum_samples),
		"required_sample_count": required_sample_count,
		"discontinuous": required_sample_count > maximum_samples,
	}


func _local_sample_points(region: Dictionary) -> Array[Vector3]:
	var center := _vector3(region["center_godot"])
	var outward := _vector3(region["outward_normal_godot"])
	var shape := region["shape"] as Dictionary
	var points: Array[Vector3] = []
	match String(shape.get("kind", "")):
		"segment":
			var axis := _vector3(shape["axis_godot"])
			var half_length := float(shape["half_length_m"])
			var radius := float(shape["radius_m"])
			for alpha in [-1.0, 0.0, 1.0]:
				points.append(center + axis * half_length * alpha + outward * radius)
		"plane":
			var size := shape["size_m"] as Array
			var width := _vector3(shape["width_axis_godot"]) * float(size[0]) * 0.5
			var height := _vector3(shape["height_axis_godot"]) * float(size[1]) * 0.5
			points = [center, center - width - height, center + width - height, center - width + height, center + width + height]
		_:
			var raw_size := shape.get("size_m", [0.1, 0.1, 0.1]) as Array
			var half := Vector3(float(raw_size[0]), float(raw_size[1]), float(raw_size[2])) * 0.5
			var local_transform := _debug_local_transform(region)
			points.append(local_transform.origin)
			for x_sign in [-1.0, 1.0]:
				for y_sign in [-1.0, 1.0]:
					for z_sign in [-1.0, 1.0]:
						points.append(local_transform * Vector3(half.x * x_sign, half.y * y_sign, half.z * z_sign))
	return points


func _debug_local_transform(region: Dictionary) -> Transform3D:
	var center := _vector3(region["center_godot"])
	var outward := _vector3(region["outward_normal_godot"])
	var shape := region["shape"] as Dictionary
	var basis := Basis.IDENTITY
	if shape.get("kind") == "segment":
		var axis := _vector3(shape["axis_godot"])
		var side := outward.cross(axis).normalized()
		basis = Basis(side, outward, axis).orthonormalized()
	elif shape.get("kind") == "plane":
		var width := _vector3(shape["width_axis_godot"])
		var height := _vector3(shape["height_axis_godot"])
		basis = Basis(width, width.cross(height).normalized(), height).orthonormalized()
	elif shape.get("kind") == "box":
		# Contract boxes store their thickness in the dominant outward axis. The
		# floor/back normals are intentionally diagonal, so leaving Basis.IDENTITY
		# turns their real sloped plates into horizontal bucket-link boxes.
		if absf(outward.x) > maxf(absf(outward.y), absf(outward.z)):
			var axis_x := outward.normalized()
			var axis_y := Vector3.UP
			if absf(axis_x.dot(axis_y)) > 0.95:
				axis_y = Vector3.FORWARD
			axis_y = (axis_y - axis_x * axis_x.dot(axis_y)).normalized()
			basis = Basis(axis_x, axis_y, axis_x.cross(axis_y).normalized()).orthonormalized()
		else:
			var axis_x := Vector3.RIGHT
			axis_x = (axis_x - outward * outward.dot(axis_x)).normalized()
			var axis_y := outward.normalized()
			basis = Basis(axis_x, axis_y, axis_x.cross(axis_y).normalized()).orthonormalized()
	return Transform3D(basis, center)


func _maximum_semantic_radius_m() -> float:
	var maximum_radius := 0.0
	for region in _regions:
		for point in _local_sample_points(region):
			maximum_radius = maxf(maximum_radius, point.length())
	return maximum_radius


func _bounds_for_points(points: Array[Vector3]) -> AABB:
	if points.is_empty():
		return AABB()
	var bounds := AABB(points[0], Vector3.ZERO)
	for point in points:
		bounds = bounds.expand(point)
	return bounds


func _terrain_normal(state: TerrainState, point: Vector3) -> Vector3:
	if state == null or not point.is_finite():
		return Vector3.UP
	var p := Vector2(point.x, point.z)
	var spacing := state.spacing_m
	var left := state.sample_surface_bilinear_at(p - Vector2(spacing, 0.0))
	var right := state.sample_surface_bilinear_at(p + Vector2(spacing, 0.0))
	var rear := state.sample_surface_bilinear_at(p - Vector2(0.0, spacing))
	var front := state.sample_surface_bilinear_at(p + Vector2(0.0, spacing))
	if not is_finite(left) or not is_finite(right) or not is_finite(rear) or not is_finite(front):
		return Vector3.UP
	return Vector3((left - right) / (2.0 * spacing), 1.0, (rear - front) / (2.0 * spacing)).normalized()


func _candidate_less(first: Dictionary, second: Dictionary) -> bool:
	var first_order := int(first.get("order", 0))
	var second_order := int(second.get("order", 0))
	if first_order != second_order:
		return first_order < second_order
	return String(first.get("region_id", "")) < String(second.get("region_id", ""))


func _vector3(value: Variant) -> Vector3:
	var data := value as Array
	return Vector3(float(data[0]), float(data[1]), float(data[2]))

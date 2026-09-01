class_name BucketSurfaceSweep
extends RefCounted

## Pure continuous semantic surface rasterizer. It consumes the accepted
## previous/current BucketSoilTool snapshot and an immutable TerrainState
## snapshot, then emits one canonical unique-cell patch. It owns no authority
## and has no mutation API.

const RESULT_SCHEMA_VERSION := "bucket-surface-sweep-v2"
const MINIMUM_HEIGHT_CHANGE_M := 0.0005
const ACTION_PRIORITY := {
	"grade": 0,
	"scrape": 1,
	"side_cut": 2,
	"cut": 3,
}


func build_patch(
	tool_snapshot: Dictionary,
	classification: Dictionary,
	terrain_snapshot: Dictionary,
	interaction: Dictionary,
	tick: int
) -> Dictionary:
	var result := _base_result(tool_snapshot, terrain_snapshot, tick)
	if not bool(tool_snapshot.get("valid", false)):
		result["reason"] = "tool_snapshot_unavailable"
		return result
	if bool(tool_snapshot.get("sweep_discontinuous", false)):
		result["reason"] = "sweep_discontinuous"
		(result["quality_flags"] as Array).append("sweep_discontinuous")
		return result
	var stable: PackedFloat32Array = terrain_snapshot.get("stable_heights", PackedFloat32Array())
	var loose: PackedFloat32Array = terrain_snapshot.get("loose_depth", PackedFloat32Array())
	var compaction: PackedFloat32Array = terrain_snapshot.get("soil_compaction", PackedFloat32Array())
	var row_count := int(terrain_snapshot.get("rows", 0))
	var column_count := int(terrain_snapshot.get("columns", 0))
	var spacing := float(terrain_snapshot.get("spacing_m", 0.0))
	if row_count < 2 or column_count < 2 or stable.size() != row_count * column_count or loose.size() != stable.size() or spacing <= 0.0:
		result["reason"] = "terrain_snapshot_invalid"
		return result
	var context := {
		"stable": stable,
		"loose": loose,
		"compaction": compaction if compaction.size() == stable.size() else PackedFloat32Array(),
		"rows": row_count,
		"columns": column_count,
		"spacing": spacing,
		"origin_xz": terrain_snapshot.get("origin_xz", Vector2.ZERO) as Vector2,
		"maximum_cut_depth_m": float(interaction.get("maximum_cut_depth_m", 0.08)),
		"offers": {},
		"coverage": {},
	}
	var candidates := _candidate_map(classification)
	var eligible_regions := 0
	var rasterized_primitives := 0
	for region_value in tool_snapshot.get("regions", []):
		if not region_value is Dictionary:
			continue
		var region := region_value as Dictionary
		var action := _eligible_action(region, candidates.get(String(region.get("region_id", "")), {}), interaction)
		if action.is_empty():
			continue
		eligible_regions += 1
		rasterized_primitives += _rasterize_region(region, action, context, int(tool_snapshot.get("sweep_sample_count", 2)))
	var spike_closure_count := _close_isolated_spikes(context)
	var rows := _canonical_rows(context)
	result["eligible_region_count"] = eligible_regions
	result["rasterized_primitive_count"] = rasterized_primitives
	result["covered_cell_count"] = (context["coverage"] as Dictionary).size()
	result["changed_cell_count"] = rows.size()
	result["spike_closure_count"] = spike_closure_count
	if spike_closure_count > 0:
		(result["quality_flags"] as Array).append("isolated_spike_closed")
	if rows.is_empty():
		result["reason"] = "no_eligible_cells"
		return result
	var patch := {
		"schema_version": SoilCellPatch.SCHEMA_VERSION,
		"generation": int(terrain_snapshot.get("world_generation", -1)),
		"base_revision": int(terrain_snapshot.get("terrain_revision", -1)),
		"tick": tick,
		"tool_identity": String(tool_snapshot.get("identity", "")),
		"rows": rows,
	}
	var metrics := SoilCellPatch.volume_metrics(patch, terrain_snapshot)
	var removed_stable_m3 := float(metrics.get("stable_removed_m3", 0.0))
	var removed_loose_m3 := float(metrics.get("loose_removed_m3", 0.0))
	patch["removed_stable_m3"] = removed_stable_m3
	patch["removed_loose_m3"] = removed_loose_m3
	patch["dirty_rect_cells"] = SoilCellPatch.dirty_rect(rows, column_count)
	patch["patch_hash"] = SoilCellPatch.compute_hash(patch)
	var validation := SoilCellPatch.validate_for_snapshot(patch, terrain_snapshot)
	if not bool(validation.get("valid", false)):
		result["reason"] = "patch_%s" % String(validation.get("reason", "invalid"))
		return result
	result["valid"] = true
	result["reason"] = "ok"
	result["patch"] = patch
	result["patch_hash"] = patch["patch_hash"]
	result["removed_stable_m3"] = removed_stable_m3
	result["removed_loose_m3"] = removed_loose_m3
	return result


func _base_result(tool_snapshot: Dictionary, terrain_snapshot: Dictionary, tick: int) -> Dictionary:
	return {
		"schema_version": RESULT_SCHEMA_VERSION,
		"valid": false,
		"reason": "unavailable",
		"generation": int(terrain_snapshot.get("world_generation", -1)),
		"base_revision": int(terrain_snapshot.get("terrain_revision", -1)),
		"tick": tick,
		"tool_identity": String(tool_snapshot.get("identity", "")),
		"patch": {},
		"patch_hash": "",
		"eligible_region_count": 0,
		"rasterized_primitive_count": 0,
		"covered_cell_count": 0,
		"changed_cell_count": 0,
		"spike_closure_count": 0,
		"removed_stable_m3": 0.0,
		"removed_loose_m3": 0.0,
		"quality_flags": [],
	}


func _candidate_map(classification: Dictionary) -> Dictionary:
	var result := {}
	for value in classification.get("candidates", []):
		if value is Dictionary:
			var candidate := value as Dictionary
			result[String(candidate.get("region_id", ""))] = candidate
	return result


func _eligible_action(region: Dictionary, candidate_value: Variant, interaction: Dictionary) -> String:
	var roles := region.get("stable_soil_roles", []) as Array
	if roles.is_empty():
		return ""
	var motion := region.get("motion_world", Vector3.ZERO) as Vector3
	var minimum_sweep := float(interaction.get("minimum_sweep_m", 0.004))
	if motion.length() < minimum_sweep:
		return ""
	var candidate := candidate_value as Dictionary if candidate_value is Dictionary else {}
	var role_scope := String(candidate.get("role_scope", ""))
	var classified := String(candidate.get("classification", ""))
	if role_scope == "stable" and ACTION_PRIORITY.has(classified):
		return classified
	# An explicit active classification remains a hard deny. A `none` candidate,
	# however, only means the old sparse probe missed the narrow contact band;
	# the continuous rasterizer must be allowed to prove surface overlap itself.
	if role_scope not in ["", "none"]:
		return ""
	var outward := region.get("outward_normal_world", Vector3.UP) as Vector3
	var moving_into_surface := -motion.dot(Vector3.UP)
	var tangential_motion := motion.slide(Vector3.UP).length()
	var kind := String(region.get("kind", ""))
	if roles.has("cut") and (motion.dot(outward) > minimum_sweep * 0.1 or moving_into_surface > minimum_sweep * 0.1):
		return "cut"
	if kind == "side_cutter" and roles.has("side_cut") and tangential_motion >= minimum_sweep:
		return "side_cut"
	if kind == "floor":
		if roles.has("scrape") and tangential_motion >= minimum_sweep:
			return "scrape"
		if roles.has("grade") and moving_into_surface > minimum_sweep * 0.1:
			return "grade"
	if kind == "outer_shell":
		if roles.has("side_cut") and tangential_motion >= minimum_sweep:
			return "side_cut"
		if roles.has("grade") and (tangential_motion >= minimum_sweep or moving_into_surface > minimum_sweep * 0.1):
			return "grade"
	return ""


func _rasterize_region(region: Dictionary, action: String, context: Dictionary, requested_samples: int) -> int:
	var previous := region.get("previous_transform", Transform3D.IDENTITY) as Transform3D
	var current := region.get("current_transform", Transform3D.IDENTITY) as Transform3D
	if not previous.is_finite() or not current.is_finite():
		return 0
	var sample_count := clampi(requested_samples, 2, 64)
	var profiles: Array[Dictionary] = []
	for sample_index in sample_count:
		var alpha := float(sample_index) / float(sample_count - 1)
		profiles.append(_surface_profile(region, previous.interpolate_with(current, alpha), current))
	var primitive_count := 0
	for sample_index in profiles.size():
		var profile := profiles[sample_index]
		primitive_count += _rasterize_profile(profile, region, action, context)
		if sample_index > 0:
			primitive_count += _rasterize_between(profiles[sample_index - 1], profile, region, action, context)
	return primitive_count


func _surface_profile(region: Dictionary, transform: Transform3D, current_transform: Transform3D) -> Dictionary:
	var shape := region.get("shape", {}) as Dictionary
	var kind := String(shape.get("kind", ""))
	if kind == "segment":
		var half_length := float(shape.get("half_length_m", 0.0))
		return {
			"kind": kind,
			"radius_m": float(shape.get("radius_m", 0.0)),
			"points": [transform.origin - transform.basis.z * half_length, transform.origin + transform.basis.z * half_length],
		}
	if kind == "plane":
		var plane_size := shape.get("size_m", [0.0, 0.0]) as Array
		var width := transform.basis.x * float(plane_size[0]) * 0.5
		var height := transform.basis.z * float(plane_size[1]) * 0.5
		return {"kind": kind, "radius_m": 0.0, "points": [transform.origin - width - height, transform.origin + width - height, transform.origin + width + height, transform.origin - width + height]}
	var raw_size := shape.get("size_m", [0.0, 0.0, 0.0]) as Array
	var half := Vector3(float(raw_size[0]), float(raw_size[1]), float(raw_size[2])) * 0.5
	var outward_world := region.get("outward_normal_world", Vector3.UP) as Vector3
	var local_outward := current_transform.basis.inverse() * outward_world
	var axis := 0
	if absf(local_outward.y) > absf(local_outward.x):
		axis = 1
	if absf(local_outward.z) > absf(local_outward[axis]):
		axis = 2
	var sign_value := 1.0 if local_outward[axis] >= 0.0 else -1.0
	var local_points: Array[Vector3] = []
	if axis == 0:
		local_points = [Vector3(sign_value * half.x, -half.y, -half.z), Vector3(sign_value * half.x, half.y, -half.z), Vector3(sign_value * half.x, half.y, half.z), Vector3(sign_value * half.x, -half.y, half.z)]
	elif axis == 1:
		local_points = [Vector3(-half.x, sign_value * half.y, -half.z), Vector3(half.x, sign_value * half.y, -half.z), Vector3(half.x, sign_value * half.y, half.z), Vector3(-half.x, sign_value * half.y, half.z)]
	else:
		local_points = [Vector3(-half.x, -half.y, sign_value * half.z), Vector3(half.x, -half.y, sign_value * half.z), Vector3(half.x, half.y, sign_value * half.z), Vector3(-half.x, half.y, sign_value * half.z)]
	var points: Array[Vector3] = []
	for point in local_points:
		points.append(transform * point)
	return {"kind": "box", "radius_m": 0.0, "points": points}


func _rasterize_profile(profile: Dictionary, region: Dictionary, action: String, context: Dictionary) -> int:
	var points := profile.get("points", []) as Array
	if String(profile.get("kind", "")) == "segment" and points.size() == 2:
		_rasterize_line(points[0], points[1], float(profile.get("radius_m", 0.0)), region, action, context)
		return 1
	if points.size() != 4:
		return 0
	_rasterize_triangle(points[0], points[1], points[2], region, action, context)
	_rasterize_triangle(points[0], points[2], points[3], region, action, context)
	for edge in 4:
		_rasterize_line(points[edge], points[(edge + 1) % 4], 0.0, region, action, context)
	return 6


func _rasterize_between(previous: Dictionary, current: Dictionary, region: Dictionary, action: String, context: Dictionary) -> int:
	var first := previous.get("points", []) as Array
	var second := current.get("points", []) as Array
	if first.size() != second.size() or first.is_empty():
		return 0
	var primitive_count := 0
	if first.size() == 2:
		_rasterize_triangle(first[0], first[1], second[1], region, action, context)
		_rasterize_triangle(first[0], second[1], second[0], region, action, context)
		primitive_count += 2
	for index in first.size():
		_rasterize_line(first[index], second[index], maxf(float(previous.get("radius_m", 0.0)), float(current.get("radius_m", 0.0))), region, action, context)
		primitive_count += 1
	if first.size() == 4:
		for edge in 4:
			var next := (edge + 1) % 4
			_rasterize_triangle(first[edge], first[next], second[next], region, action, context)
			_rasterize_triangle(first[edge], second[next], second[edge], region, action, context)
			primitive_count += 2
	return primitive_count


func _rasterize_line(start: Vector3, finish: Vector3, physical_radius: float, region: Dictionary, action: String, context: Dictionary) -> void:
	var spacing := float(context["spacing"])
	var coverage_radius := maxf(physical_radius, 0.0) + spacing * 0.55
	var min_x := minf(start.x, finish.x) - coverage_radius
	var max_x := maxf(start.x, finish.x) + coverage_radius
	var min_z := minf(start.z, finish.z) - coverage_radius
	var max_z := maxf(start.z, finish.z) + coverage_radius
	var bounds := _world_bounds(min_x, max_x, min_z, max_z, context)
	var a := Vector2(start.x, start.z)
	var b := Vector2(finish.x, finish.z)
	var delta := b - a
	var length_squared := delta.length_squared()
	for row in range(bounds.position.y, bounds.end.y):
		for column in range(bounds.position.x, bounds.end.x):
			var point := _world_xz(column, row, context)
			var alpha := clampf((point - a).dot(delta) / length_squared, 0.0, 1.0) if length_squared > 0.00000001 else 0.0
			if point.distance_to(a.lerp(b, alpha)) > coverage_radius:
				continue
			var target_y := lerpf(start.y, finish.y, alpha) - maxf(physical_radius, 0.0)
			_offer_cell(row * int(context["columns"]) + column, target_y, region, action, context)


func _rasterize_triangle(a3: Vector3, b3: Vector3, c3: Vector3, region: Dictionary, action: String, context: Dictionary) -> void:
	var a := Vector2(a3.x, a3.z)
	var b := Vector2(b3.x, b3.z)
	var c := Vector2(c3.x, c3.z)
	var denominator := (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
	if absf(denominator) < 0.00000001:
		return
	# A height sample represents a square support cell, not a dimensionless
	# point. Expand by just over half a cell and project misses onto the nearest
	# triangle edge; this keeps a one-metre bucket continuous on the product
	# 0.5 m grid without growing an arbitrary circular brush.
	var coverage_radius := float(context["spacing"]) * 0.55
	var bounds := _world_bounds(minf(a.x, minf(b.x, c.x)) - coverage_radius, maxf(a.x, maxf(b.x, c.x)) + coverage_radius, minf(a.y, minf(b.y, c.y)) - coverage_radius, maxf(a.y, maxf(b.y, c.y)) + coverage_radius, context)
	for row in range(bounds.position.y, bounds.end.y):
		for column in range(bounds.position.x, bounds.end.x):
			var point := _world_xz(column, row, context)
			var wa := ((b.y - c.y) * (point.x - c.x) + (c.x - b.x) * (point.y - c.y)) / denominator
			var wb := ((c.y - a.y) * (point.x - c.x) + (a.x - c.x) * (point.y - c.y)) / denominator
			var wc := 1.0 - wa - wb
			var target_y := 0.0
			if wa >= -0.00001 and wb >= -0.00001 and wc >= -0.00001:
				target_y = wa * a3.y + wb * b3.y + wc * c3.y
			else:
				var nearest := _nearest_triangle_edge(point, a, b, c, a3.y, b3.y, c3.y)
				if float(nearest["distance"]) > coverage_radius:
					continue
				target_y = float(nearest["height"])
			_offer_cell(row * int(context["columns"]) + column, target_y, region, action, context)


func _nearest_triangle_edge(point: Vector2, a: Vector2, b: Vector2, c: Vector2, ay: float, by: float, cy: float) -> Dictionary:
	var best := {"distance": INF, "height": 0.0}
	for edge in [[a, b, ay, by], [b, c, by, cy], [c, a, cy, ay]]:
		var start := edge[0] as Vector2
		var finish := edge[1] as Vector2
		var delta := finish - start
		var alpha := clampf((point - start).dot(delta) / delta.length_squared(), 0.0, 1.0) if delta.length_squared() > 0.00000001 else 0.0
		var distance := point.distance_to(start.lerp(finish, alpha))
		if distance < float(best["distance"]):
			best = {"distance": distance, "height": lerpf(float(edge[2]), float(edge[3]), alpha)}
	return best


func _offer_cell(index: int, target_y: float, region: Dictionary, action: String, context: Dictionary) -> void:
	var stable := context["stable"] as PackedFloat32Array
	var loose := context["loose"] as PackedFloat32Array
	var surface := stable[index] + loose[index]
	if not is_finite(target_y):
		return
	_record_coverage(index, target_y, region, action, context)
	if target_y >= surface - MINIMUM_HEIGHT_CHANGE_M:
		return
	var maximum_cut := maxf(0.0, float(context["maximum_cut_depth_m"]))
	var compaction := context["compaction"] as PackedFloat32Array
	if compaction.size() == stable.size():
		maximum_cut *= lerpf(1.0, 0.55, clampf(float(compaction[index]), 0.0, 1.0))
	var accepted_target := maxf(target_y, surface - maximum_cut)
	var offers := context["offers"] as Dictionary
	var region_id := String(region.get("region_id", ""))
	if offers.has(index):
		var existing := offers[index] as Dictionary
		var difference := accepted_target - float(existing["target_surface"])
		if difference < -MINIMUM_HEIGHT_CHANGE_M:
			existing["target_surface"] = accepted_target
			existing["action"] = action
		elif absf(difference) <= MINIMUM_HEIGHT_CHANGE_M and int(ACTION_PRIORITY.get(action, -1)) > int(ACTION_PRIORITY.get(String(existing["action"]), -1)):
			existing["action"] = action
		var contributors := existing["contributors"] as Array
		if not contributors.has(region_id):
			contributors.append(region_id)
		offers[index] = existing
	else:
		offers[index] = {"target_surface": accepted_target, "action": action, "contributors": [region_id]}


func _record_coverage(index: int, target_y: float, region: Dictionary, action: String, context: Dictionary) -> void:
	var coverage := context["coverage"] as Dictionary
	var region_id := String(region.get("region_id", ""))
	if coverage.has(index):
		var existing := coverage[index] as Dictionary
		if target_y < float(existing["target_surface"]):
			existing["target_surface"] = target_y
		if int(ACTION_PRIORITY.get(action, -1)) > int(ACTION_PRIORITY.get(String(existing["action"]), -1)):
			existing["action"] = action
		var contributors := existing["contributors"] as Array
		if not contributors.has(region_id):
			contributors.append(region_id)
		coverage[index] = existing
	else:
		coverage[index] = {"target_surface": target_y, "action": action, "contributors": [region_id]}


## Closes only a one-cell peak fully enclosed by four already-cut cardinal
## neighbors and independently proven inside the swept primitive coverage. The
## decision uses a frozen offer set so closure cannot flood-fill beyond a hole.
func _close_isolated_spikes(context: Dictionary) -> int:
	var offers := context["offers"] as Dictionary
	var coverage := context["coverage"] as Dictionary
	var stable := context["stable"] as PackedFloat32Array
	var loose := context["loose"] as PackedFloat32Array
	var columns := int(context["columns"])
	var rows := int(context["rows"])
	var maximum_cut := maxf(0.0, float(context["maximum_cut_depth_m"]))
	var frozen := offers.duplicate(true)
	var closures: Array[Dictionary] = []
	var covered_indices: Array[int] = []
	for index_value in coverage.keys():
		covered_indices.append(int(index_value))
	covered_indices.sort()
	for index in covered_indices:
		var row: int = index / columns
		var column: int = index % columns
		if row <= 0 or row >= rows - 1 or column <= 0 or column >= columns - 1:
			continue
		var neighbors := [index - 1, index + 1, index - columns, index + columns]
		var neighbor_target := -INF
		var contributors: Array = (coverage[index] as Dictionary).get("contributors", []).duplicate()
		var action := String((coverage[index] as Dictionary).get("action", "grade"))
		var enclosed := true
		for neighbor in neighbors:
			if not frozen.has(neighbor):
				enclosed = false
				break
			var neighbor_offer := frozen[neighbor] as Dictionary
			neighbor_target = maxf(neighbor_target, float(neighbor_offer["target_surface"]))
			if int(ACTION_PRIORITY.get(String(neighbor_offer["action"]), -1)) > int(ACTION_PRIORITY.get(action, -1)):
				action = String(neighbor_offer["action"])
			for contributor in neighbor_offer["contributors"] as Array:
				if not contributors.has(contributor):
					contributors.append(contributor)
		if not enclosed:
			continue
		var original_surface := float(stable[index]) + float(loose[index])
		var current_target := float((frozen[index] as Dictionary)["target_surface"]) if frozen.has(index) else original_surface
		if current_target - neighbor_target <= MINIMUM_HEIGHT_CHANGE_M:
			continue
		var closed_target := maxf(neighbor_target, original_surface - maximum_cut)
		if current_target - closed_target <= MINIMUM_HEIGHT_CHANGE_M:
			continue
		contributors.sort()
		closures.append({
			"index": index,
			"target_surface": closed_target,
			"action": action,
			"contributors": contributors,
		})
	for closure in closures:
		offers[int(closure["index"])] = {
			"target_surface": float(closure["target_surface"]),
			"action": String(closure["action"]),
			"contributors": (closure["contributors"] as Array).duplicate(),
		}
	return closures.size()


func _canonical_rows(context: Dictionary) -> Array[Dictionary]:
	var offers := context["offers"] as Dictionary
	var indices: Array[int] = []
	for index_value in offers.keys():
		indices.append(int(index_value))
	indices.sort()
	var stable := context["stable"] as PackedFloat32Array
	var loose := context["loose"] as PackedFloat32Array
	var rows: Array[Dictionary] = []
	for index in indices:
		var offer := offers[index] as Dictionary
		var original_stable := float(stable[index])
		var original_loose := float(loose[index])
		var cut_depth := original_stable + original_loose - float(offer["target_surface"])
		if cut_depth <= MINIMUM_HEIGHT_CHANGE_M:
			continue
		var loose_removed := minf(original_loose, cut_depth)
		var contributors := offer["contributors"] as Array
		contributors.sort()
		rows.append({
			"index": index,
			"original_stable_height": original_stable,
			"original_loose_depth": original_loose,
			"target_stable_height": original_stable - (cut_depth - loose_removed),
			"target_loose_depth": original_loose - loose_removed,
			"action": String(offer["action"]),
			"contributing_region_ids": contributors.duplicate(),
		})
	return rows


func _world_bounds(min_x: float, max_x: float, min_z: float, max_z: float, context: Dictionary) -> Rect2i:
	var origin := context["origin_xz"] as Vector2
	var spacing := float(context["spacing"])
	var columns := int(context["columns"])
	var rows := int(context["rows"])
	var min_column := clampi(floori((min_x - origin.x) / spacing), 0, columns - 1)
	var max_column := clampi(ceili((max_x - origin.x) / spacing), 0, columns - 1)
	var min_row := clampi(floori((min_z - origin.y) / spacing), 0, rows - 1)
	var max_row := clampi(ceili((max_z - origin.y) / spacing), 0, rows - 1)
	return Rect2i(min_column, min_row, max_column - min_column + 1, max_row - min_row + 1)


func _world_xz(column: int, row: int, context: Dictionary) -> Vector2:
	var origin := context["origin_xz"] as Vector2
	var spacing := float(context["spacing"])
	return Vector2(origin.x + float(column) * spacing, origin.y + float(row) * spacing)

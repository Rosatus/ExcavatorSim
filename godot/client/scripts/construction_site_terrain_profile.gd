class_name ConstructionSiteTerrainProfile
extends RefCounted

## Deterministic, disposable Terrain3D presentation for a medium earthwork site.
##
## The complete 64 m site is copied from TerrainState without modification so
## visible ground and authoritative machine support share one footprint. The
## central work pad remains the primary excavation/dressing exclusion zone.

const SITE_EXTENT_M := 64.0
## Terrain3D 1.0.2 requires initialized texture slots even when the project
## shader override does not sample them. These retained resources are bootstrap
## inputs only; product color/classification comes from worksite_soil_common.
const INITIALIZATION_ASSETS_PATH := "res://assets/terrain/terrain3d_demo_assets.tres"

const MATERIAL_WORKSITE_SOIL := 0


func build_maps(snapshot: Dictionary) -> Dictionary:
	if not _is_snapshot_valid(snapshot):
		return {}
	var logical_rows := int(snapshot["rows"])
	var logical_columns := int(snapshot["columns"])
	var spacing := float(snapshot["spacing_m"])
	var authority_origin: Vector2 = snapshot["origin_xz"]
	var authority_surface: PackedFloat32Array = snapshot["surface"]
	var site_rows := _site_samples(spacing, logical_rows)
	var site_columns := _site_samples(spacing, logical_columns)
	var site_origin := Vector2(
		-0.5 * float(site_columns - 1) * spacing,
		-0.5 * float(site_rows - 1) * spacing
	)
	var authority_max := Vector2(
		authority_origin.x + float(logical_columns - 1) * spacing,
		authority_origin.y + float(logical_rows - 1) * spacing
	)
	var work_pad_origin := Vector2(-TerrainState.WORK_PAD_HALF_EXTENT_M, -TerrainState.WORK_PAD_HALF_EXTENT_M)
	var work_pad_max := Vector2(TerrainState.WORK_PAD_HALF_EXTENT_M, TerrainState.WORK_PAD_HALF_EXTENT_M)
	var surface := PackedFloat32Array()
	var height_bytes := PackedByteArray()
	var control_bytes := PackedByteArray()
	var cell_count := site_rows * site_columns
	surface.resize(cell_count)
	height_bytes.resize(cell_count * 4)
	control_bytes.resize(cell_count * 4)
	for row in site_rows:
		var z := site_origin.y + float(row) * spacing
		for column in site_columns:
			var x := site_origin.x + float(column) * spacing
			var position := Vector2(x, z)
			var index := row * site_columns + column
			var height := _presentation_height(
				position,
				authority_surface,
				logical_rows,
				logical_columns,
				spacing,
				authority_origin,
				authority_max
			)
			surface[index] = height
			height_bytes.encode_float(index * 4, height)
			control_bytes.encode_u32(
				index * 4,
				_control_code(position, work_pad_origin, work_pad_max)
			)
	return {
		"rows": site_rows,
		"columns": site_columns,
		"spacing_m": spacing,
		"origin_xz": site_origin,
		"surface": surface,
		"height_bytes": height_bytes,
		"control_bytes": control_bytes,
		"authority_origin_xz": authority_origin,
		"authority_max_xz": authority_max,
		"logical_origin_xz": work_pad_origin,
		"logical_max_xz": work_pad_max,
		"material_roles": get_material_roles(),
	}


func create_assets() -> Object:
	return load(INITIALIZATION_ASSETS_PATH) if ResourceLoader.exists(INITIALIZATION_ASSETS_PATH) else null


func get_material_roles() -> PackedStringArray:
	return PackedStringArray([
		"Project Procedural Worksite Soil",
	])


func build_dressing(maps: Dictionary) -> Dictionary:
	if not maps.has_all(["rows", "columns", "spacing_m", "origin_xz", "surface", "logical_origin_xz", "logical_max_xz"]):
		return {}
	var rock_layout := [
		Vector2(-21.0, -16.0), Vector2(-18.5, -18.0), Vector2(-15.5, -15.5),
		Vector2(-22.0, -10.5), Vector2(-18.0, 7.0), Vector2(-20.5, 12.0),
		Vector2(-17.5, 16.0), Vector2(13.0, -15.0), Vector2(16.0, -14.0),
		Vector2(19.5, -10.0), Vector2(22.0, -6.5), Vector2(18.0, 24.0),
		Vector2(23.5, 25.5), Vector2(-25.0, 22.0), Vector2(-28.0, 17.0),
		Vector2(27.0, -23.0), Vector2(-24.0, -25.0), Vector2(4.0, -27.0),
	]
	return {
		"rocks": _dressing_entries(rock_layout, maps, 701, Vector2(0.12, 0.26)),
	}


func build_worksite_layout(maps: Dictionary) -> Dictionary:
	if not maps.has_all(["rows", "columns", "spacing_m", "origin_xz", "surface", "logical_origin_xz", "logical_max_xz"]):
		return {}
	var result := {
		"barriers": [],
		"stakes": [],
		"route_markers": [],
		"track_marks": [],
		"pipes": [],
		"aggregate": [],
		"signs": [],
	}
	for position in [Vector2(-14.0, -8.0), Vector2(-14.0, 0.0), Vector2(-14.0, 8.0)]:
		(result["barriers"] as Array).append(_layout_entry(position, maps, 0.0))
	for x in [-9.0, -4.5, 0.0, 4.5, 9.0]:
		(result["stakes"] as Array).append(_layout_entry(Vector2(x, -12.5), maps, 0.0))
		(result["stakes"] as Array).append(_layout_entry(Vector2(x, 12.5), maps, PI))
	var route_start := Vector2(13.0, 7.0)
	var route_end := Vector2(30.0, 19.0)
	var route_direction := (route_end - route_start).normalized()
	var route_side := Vector2(-route_direction.y, route_direction.x)
	for step in 4:
		var center := route_start.lerp(route_end, (float(step) + 0.5) / 4.0)
		(result["route_markers"] as Array).append(_layout_entry(center + route_side * 4.25, maps, -route_direction.angle()))
		(result["route_markers"] as Array).append(_layout_entry(center - route_side * 4.25, maps, -route_direction.angle()))
	for z in [11.5, 13.0, 14.5, 16.0, 17.5, 19.0]:
		(result["track_marks"] as Array).append(_layout_entry(Vector2(-1.15, z), maps, 0.0))
		(result["track_marks"] as Array).append(_layout_entry(Vector2(1.15, z), maps, 0.0))
	for layer in 2:
		for column in 3:
			var offset := Vector2(float(column) * 1.45, float(layer) * 0.78)
			(result["pipes"] as Array).append(_layout_entry(Vector2(-22.0, 18.0) + offset, maps, PI * 0.5))
	for offset in [Vector2.ZERO, Vector2(1.4, 0.3), Vector2(-1.2, 0.5), Vector2(0.6, 1.2), Vector2(-0.5, 1.4)]:
		(result["aggregate"] as Array).append(_layout_entry(Vector2(20.5, -18.5) + offset, maps, 0.0))
	(result["signs"] as Array).append(_layout_entry(Vector2(-14.0, 13.0), maps, PI * 0.5))
	return result


func sample_presentation_height(maps: Dictionary, position: Vector2) -> float:
	return _sample_map_height(maps, position)


static func decode_control(code: int) -> Dictionary:
	return {
		"base_id": (code >> 27) & 0x1f,
		"overlay_id": (code >> 22) & 0x1f,
		"blend": float((code >> 14) & 0xff) / 255.0,
	}


func _presentation_height(
	position: Vector2,
	logical_surface: PackedFloat32Array,
	logical_rows: int,
	logical_columns: int,
	spacing: float,
	logical_origin: Vector2,
	logical_max: Vector2
) -> float:
	var clamped := Vector2(
		clampf(position.x, logical_origin.x, logical_max.x),
		clampf(position.y, logical_origin.y, logical_max.y)
	)
	var logical_height := _sample_bilinear(
		logical_surface,
		logical_rows,
		logical_columns,
		spacing,
		logical_origin,
		clamped
	)
	if position.x >= logical_origin.x and position.x <= logical_max.x \
		and position.y >= logical_origin.y and position.y <= logical_max.y:
		return logical_height
	var outside_distance := _distance_outside_rect(position, logical_origin, logical_max)
	var context_weight := _smoothstep(0.0, 3.0, outside_distance)
	return logical_height + TerrainState.construction_site_baseline_height(position) * context_weight


func _control_code(_position: Vector2, _logical_origin: Vector2, _logical_max: Vector2) -> int:
	# The project-owned shader classifies compacted/loose/damp soil directly
	# from world height and normal. Terrain3D still requires a control map for
	# holes, but production presentation no longer selects demo texture zones.
	return _encode_control(MATERIAL_WORKSITE_SOIL, MATERIAL_WORKSITE_SOIL, 0.0)


func _sample_bilinear(surface: PackedFloat32Array, rows: int, columns: int, spacing: float, origin: Vector2, position: Vector2) -> float:
	var column_f := clampf((position.x - origin.x) / spacing, 0.0, float(columns - 1))
	var row_f := clampf((position.y - origin.y) / spacing, 0.0, float(rows - 1))
	var column_0 := floori(column_f)
	var row_0 := floori(row_f)
	var column_1 := mini(columns - 1, column_0 + 1)
	var row_1 := mini(rows - 1, row_0 + 1)
	var tx := column_f - float(column_0)
	var tz := row_f - float(row_0)
	var top := lerpf(surface[row_0 * columns + column_0], surface[row_0 * columns + column_1], tx)
	var bottom := lerpf(surface[row_1 * columns + column_0], surface[row_1 * columns + column_1], tx)
	return lerpf(top, bottom, tz)


func _site_samples(spacing: float, logical_samples: int) -> int:
	var samples := maxi(logical_samples, roundi(SITE_EXTENT_M / spacing) + 1)
	if samples % 2 != logical_samples % 2:
		samples += 1
	return samples


func _distance_outside_rect(position: Vector2, minimum: Vector2, maximum: Vector2) -> float:
	var dx := maxf(maxf(minimum.x - position.x, 0.0), position.x - maximum.x)
	var dz := maxf(maxf(minimum.y - position.y, 0.0), position.y - maximum.y)
	return Vector2(dx, dz).length()


func _distance_to_segment(point: Vector2, start: Vector2, finish: Vector2) -> float:
	var segment := finish - start
	var length_squared := segment.length_squared()
	if is_zero_approx(length_squared):
		return point.distance_to(start)
	var t := clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_to(start + segment * t)


func _gaussian(position: Vector2, center: Vector2, sigma: Vector2) -> float:
	var dx := (position.x - center.x) / sigma.x
	var dz := (position.y - center.y) / sigma.y
	return exp(-0.5 * (dx * dx + dz * dz))


func _smoothstep(edge_0: float, edge_1: float, value: float) -> float:
	var t := clampf((value - edge_0) / (edge_1 - edge_0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _encode_control(base_id: int, overlay_id: int, blend: float) -> int:
	var blend_byte := clampi(roundi(clampf(blend, 0.0, 1.0) * 255.0), 0, 255)
	return ((base_id & 0x1f) << 27) | ((overlay_id & 0x1f) << 22) | (blend_byte << 14)


func _texture_noise(x: int, y: int, seed: int) -> float:
	var value := x * 374761393 + y * 668265263 + seed * 69069
	value = (value ^ (value >> 13)) * 1274126177
	value = value ^ (value >> 16)
	return float(value & 0xffff) / 65535.0


func _dressing_entries(layout: Array, maps: Dictionary, seed: int, scale_range: Vector2) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for index in layout.size():
		var xz: Vector2 = layout[index]
		var scale_noise := _texture_noise(index, seed, seed + 31)
		var yaw_noise := _texture_noise(index, seed + 1, seed + 47)
		entries.append({
			"position": Vector3(xz.x, _sample_map_height(maps, xz), xz.y),
			"yaw": yaw_noise * TAU,
			"scale": lerpf(scale_range.x, scale_range.y, scale_noise),
		})
	return entries


func _layout_entry(position: Vector2, maps: Dictionary, yaw: float) -> Dictionary:
	return {
		"position": Vector3(position.x, _sample_map_height(maps, position), position.y),
		"yaw": yaw,
	}


func _sample_map_height(maps: Dictionary, position: Vector2) -> float:
	return _sample_bilinear(
		maps["surface"] as PackedFloat32Array,
		int(maps["rows"]),
		int(maps["columns"]),
		float(maps["spacing_m"]),
		maps["origin_xz"] as Vector2,
		position
	)


func _is_snapshot_valid(snapshot: Dictionary) -> bool:
	if not snapshot.has_all(["rows", "columns", "spacing_m", "origin_xz", "surface"]):
		return false
	var rows := int(snapshot["rows"])
	var columns := int(snapshot["columns"])
	var spacing := float(snapshot["spacing_m"])
	return rows >= 2 and columns >= 2 and spacing > 0.0 \
		and snapshot["surface"] is PackedFloat32Array \
		and (snapshot["surface"] as PackedFloat32Array).size() == rows * columns

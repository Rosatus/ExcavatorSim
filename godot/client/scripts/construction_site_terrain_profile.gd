class_name ConstructionSiteTerrainProfile
extends RefCounted

## Deterministic, disposable Terrain3D presentation for a medium earthwork site.
##
## The central logical patch is copied from TerrainState without modification.
## Everything outside it is visual context and must never be written back to
## TerrainState or used for BucketSoilState volume accounting.

const SITE_EXTENT_M := 64.0
const TEXTURE_SIZE := 128

const MATERIAL_DISTURBED_SOIL := 0
const MATERIAL_COMPACTED_TRACK := 1
const MATERIAL_GRASS_EDGE := 2
const MATERIAL_DAMP_SOIL := 3


func build_maps(snapshot: Dictionary) -> Dictionary:
	if not _is_snapshot_valid(snapshot):
		return {}
	var logical_rows := int(snapshot["rows"])
	var logical_columns := int(snapshot["columns"])
	var spacing := float(snapshot["spacing_m"])
	var logical_origin: Vector2 = snapshot["origin_xz"]
	var logical_surface: PackedFloat32Array = snapshot["surface"]
	var site_rows := _site_samples(spacing, logical_rows)
	var site_columns := _site_samples(spacing, logical_columns)
	var site_origin := Vector2(
		-0.5 * float(site_columns - 1) * spacing,
		-0.5 * float(site_rows - 1) * spacing
	)
	var logical_max := Vector2(
		logical_origin.x + float(logical_columns - 1) * spacing,
		logical_origin.y + float(logical_rows - 1) * spacing
	)
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
				logical_surface,
				logical_rows,
				logical_columns,
				spacing,
				logical_origin,
				logical_max
			)
			surface[index] = height
			height_bytes.encode_float(index * 4, height)
			control_bytes.encode_u32(
				index * 4,
				_control_code(position, logical_origin, logical_max)
			)
	return {
		"rows": site_rows,
		"columns": site_columns,
		"spacing_m": spacing,
		"origin_xz": site_origin,
		"surface": surface,
		"height_bytes": height_bytes,
		"control_bytes": control_bytes,
		"logical_origin_xz": logical_origin,
		"logical_max_xz": logical_max,
		"material_roles": get_material_roles(),
	}


func create_assets() -> Object:
	if not ClassDB.class_exists("Terrain3DAssets") or not ClassDB.class_exists("Terrain3DTextureAsset"):
		return null
	var assets: Object = ClassDB.instantiate("Terrain3DAssets")
	if not (assets is Object) or not (assets as Object).has_method("set_texture"):
		return null
	for material_id in range(4):
		var texture_asset := _create_texture_asset(material_id)
		if texture_asset == null:
			return null
		(assets as Object).call("set_texture", material_id, texture_asset)
	return assets as Object


func get_material_roles() -> PackedStringArray:
	return PackedStringArray([
		"Disturbed Soil",
		"Compacted Haul Track",
		"Grass Edge",
		"Damp Soil",
	])


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
	return logical_height + _context_height_offset(position) * context_weight


func _context_height_offset(position: Vector2) -> float:
	var gentle_grade := 0.07 * sin(position.x * 0.12) * cos(position.y * 0.09)
	var north_spoil := 1.55 * _gaussian(position, Vector2(-16.5, -13.0), Vector2(4.6, 3.8))
	var east_spoil := 1.15 * _gaussian(position, Vector2(16.0, -11.0), Vector2(4.0, 3.4))
	var west_berm := 0.85 * _gaussian(position, Vector2(-18.0, 10.5), Vector2(2.4, 8.5))
	var damp_low := -0.32 * _gaussian(position, Vector2(15.0, 16.0), Vector2(7.0, 6.0))
	return gentle_grade + north_spoil + east_spoil + west_berm + damp_low


func _control_code(position: Vector2, logical_origin: Vector2, logical_max: Vector2) -> int:
	if position.x >= logical_origin.x and position.x <= logical_max.x \
		and position.y >= logical_origin.y and position.y <= logical_max.y:
		return _encode_control(MATERIAL_DISTURBED_SOIL, MATERIAL_DISTURBED_SOIL, 0.0)
	var radial := position.length()
	var grass_blend := _smoothstep(22.0, 29.0, radial)
	var haul_distance := _distance_to_segment(position, Vector2(8.0, 4.0), Vector2(31.0, 20.0))
	var haul_blend := 1.0 - _smoothstep(2.2, 4.2, haul_distance)
	var damp_blend := 1.0 - _smoothstep(4.0, 8.5, position.distance_to(Vector2(15.0, 16.0)))
	var overlay_id := MATERIAL_DISTURBED_SOIL
	var blend := 0.0
	if grass_blend > blend:
		overlay_id = MATERIAL_GRASS_EDGE
		blend = grass_blend
	if haul_blend > 0.08 and haul_blend >= grass_blend * 0.65:
		overlay_id = MATERIAL_COMPACTED_TRACK
		blend = haul_blend
	if damp_blend > 0.12:
		overlay_id = MATERIAL_DAMP_SOIL
		blend = damp_blend
	return _encode_control(MATERIAL_DISTURBED_SOIL, overlay_id, blend)


func _create_texture_asset(material_id: int) -> Object:
	var texture_asset: Object = ClassDB.instantiate("Terrain3DTextureAsset")
	if not (texture_asset is Object):
		return null
	var definition := _material_definition(material_id)
	var albedo_image := Image.create_empty(TEXTURE_SIZE, TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	var normal_image := Image.create_empty(TEXTURE_SIZE, TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	for y in TEXTURE_SIZE:
		for x in TEXTURE_SIZE:
			var noise := _texture_noise(x, y, int(definition["seed"]))
			var left := _texture_noise(posmod(x - 1, TEXTURE_SIZE), y, int(definition["seed"]))
			var right := _texture_noise((x + 1) % TEXTURE_SIZE, y, int(definition["seed"]))
			var up := _texture_noise(x, posmod(y - 1, TEXTURE_SIZE), int(definition["seed"]))
			var down := _texture_noise(x, (y + 1) % TEXTURE_SIZE, int(definition["seed"]))
			var base: Color = definition["color"]
			var variation := (noise - 0.5) * float(definition["variation"])
			var albedo := Color(
				clampf(base.r + variation, 0.0, 1.0),
				clampf(base.g + variation, 0.0, 1.0),
				clampf(base.b + variation, 0.0, 1.0),
				clampf(0.35 + noise * 0.3, 0.0, 1.0)
			)
			var normal_strength := float(definition["normal_strength"])
			var nx := clampf(0.5 + (left - right) * normal_strength, 0.0, 1.0)
			var ny := clampf(0.5 + (up - down) * normal_strength, 0.0, 1.0)
			albedo_image.set_pixel(x, y, albedo)
			normal_image.set_pixel(x, y, Color(nx, ny, 1.0, float(definition["roughness"])))
	albedo_image.generate_mipmaps()
	normal_image.generate_mipmaps()
	_set_property(texture_asset as Object, "name", String(definition["name"]))
	_set_property(texture_asset as Object, "albedo_texture", ImageTexture.create_from_image(albedo_image))
	_set_property(texture_asset as Object, "normal_texture", ImageTexture.create_from_image(normal_image))
	_set_property(texture_asset as Object, "uv_scale", float(definition["uv_scale"]))
	_set_property(texture_asset as Object, "detiling_rotation", float(definition["detiling_rotation"]))
	_set_property(texture_asset as Object, "normal_depth", float(definition["normal_depth"]))
	_set_property(texture_asset as Object, "ao_strength", float(definition["ao_strength"]))
	return texture_asset as Object


func _material_definition(material_id: int) -> Dictionary:
	match material_id:
		MATERIAL_COMPACTED_TRACK:
			return _definition("Compacted Haul Track", "#71604b", 0.12, 0.82, 0.22, 0.12, 0.08, 0.65, 1.0, 211)
		MATERIAL_GRASS_EDGE:
			return _definition("Grass Edge", "#53633b", 0.16, 0.92, 0.34, 0.16, 0.14, 0.9, 1.25, 307)
		MATERIAL_DAMP_SOIL:
			return _definition("Damp Soil", "#40362d", 0.09, 0.68, 0.25, 0.11, 0.06, 0.75, 1.4, 401)
		_:
			return _definition("Disturbed Soil", "#6b4e35", 0.15, 0.94, 0.38, 0.1, 0.1, 1.0, 1.55, 101)


func _definition(name: String, color: String, variation: float, roughness: float, normal_strength: float, uv_scale: float, detiling_rotation: float, normal_depth: float, ao_strength: float, seed: int) -> Dictionary:
	return {
		"name": name,
		"color": Color(color),
		"variation": variation,
		"roughness": roughness,
		"normal_strength": normal_strength,
		"uv_scale": uv_scale,
		"detiling_rotation": detiling_rotation,
		"normal_depth": normal_depth,
		"ao_strength": ao_strength,
		"seed": seed,
	}


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


func _set_property(object: Object, property_name: String, value: Variant) -> void:
	for property in object.get_property_list():
		if String(property.get("name", "")) == property_name:
			object.set(property_name, value)
			return


func _is_snapshot_valid(snapshot: Dictionary) -> bool:
	if not snapshot.has_all(["rows", "columns", "spacing_m", "origin_xz", "surface"]):
		return false
	var rows := int(snapshot["rows"])
	var columns := int(snapshot["columns"])
	var spacing := float(snapshot["spacing_m"])
	return rows >= 2 and columns >= 2 and spacing > 0.0 \
		and snapshot["surface"] is PackedFloat32Array \
		and (snapshot["surface"] as PackedFloat32Array).size() == rows * columns

extends SceneTree


func _init() -> void:
	quit(_run())


func _run() -> int:
	var state := TerrainState.new(24681357)
	var snapshot := state.surface_snapshot()
	var profile := ConstructionSiteTerrainProfile.new()
	var maps := profile.build_maps(snapshot)
	if maps.is_empty():
		return _fail("construction-site maps build from a TerrainState snapshot")
	if int(maps["rows"]) != 129 or int(maps["columns"]) != 129:
		return _fail("default construction site is 64 m square at 0.5 m spacing")
	if snapshot["origin_xz"] != Vector2(-32.0, -32.0) or maps["authority_origin_xz"] != snapshot["origin_xz"]:
		return _fail("visible site and authoritative terrain share the same footprint")
	if (maps["height_bytes"] as PackedByteArray).size() != 129 * 129 * 4:
		return _fail("presentation height bytes match the site grid")
	if (maps["control_bytes"] as PackedByteArray).size() != 129 * 129 * 4:
		return _fail("control bytes match the site grid")
	var parity_error := _check_logical_patch_parity(snapshot, maps)
	if parity_error != "":
		return _fail(parity_error)
	var zone_error := _check_material_zones(maps)
	if zone_error != "":
		return _fail(zone_error)
	var dressing_error := _check_dressing(profile, maps)
	if dressing_error != "":
		return _fail(dressing_error)
	var layout_error := _check_worksite_layout(profile, maps)
	if layout_error != "":
		return _fail(layout_error)
	var assets := profile.create_assets()
	if assets == null or not assets.has_method("get_texture_count") or int(assets.call("get_texture_count")) != 2:
		return _fail("construction site loads the two official Terrain3D demo texture assets")
	var texture_error := _check_texture_detail(assets)
	if texture_error != "":
		return _fail(texture_error)
	print("Construction-site terrain profile contracts passed.")
	return 0


func _check_logical_patch_parity(snapshot: Dictionary, maps: Dictionary) -> String:
	var logical_rows := int(snapshot["rows"])
	var logical_columns := int(snapshot["columns"])
	var logical_spacing := float(snapshot["spacing_m"])
	var logical_origin: Vector2 = snapshot["origin_xz"]
	var logical_surface: PackedFloat32Array = snapshot["surface"]
	var site_columns := int(maps["columns"])
	var site_origin: Vector2 = maps["origin_xz"]
	var site_surface: PackedFloat32Array = maps["surface"]
	for row in logical_rows:
		for column in logical_columns:
			var x := logical_origin.x + float(column) * logical_spacing
			var z := logical_origin.y + float(row) * logical_spacing
			var site_column := roundi((x - site_origin.x) / logical_spacing)
			var site_row := roundi((z - site_origin.y) / logical_spacing)
			var logical_index := row * logical_columns + column
			var site_index := site_row * site_columns + site_column
			if site_surface[site_index] != logical_surface[logical_index]:
				return "central logical height samples remain exact"
	return ""


func _check_material_zones(maps: Dictionary) -> String:
	var center := _control_at(maps, Vector2.ZERO)
	if int(center["base_id"]) != 0 or int(center["overlay_id"]) != 0:
		return "logical work pad uses disturbed soil"
	var haul := _control_at(maps, Vector2(23.0, 14.0))
	if int(haul["base_id"]) != 0 or int(haul["overlay_id"]) != 0:
		return "access corridor keeps the demo bare-ground material"
	var grass := _control_at(maps, Vector2(-29.0, 0.0))
	if int(grass["base_id"]) != 1 or int(grass["overlay_id"]) != 1:
		return "outer terrain uses the official demo grass material"
	return ""


func _control_at(maps: Dictionary, position: Vector2) -> Dictionary:
	var spacing := float(maps["spacing_m"])
	var origin: Vector2 = maps["origin_xz"]
	var columns := int(maps["columns"])
	var column := roundi((position.x - origin.x) / spacing)
	var row := roundi((position.y - origin.y) / spacing)
	var code := (maps["control_bytes"] as PackedByteArray).decode_u32((row * columns + column) * 4)
	return ConstructionSiteTerrainProfile.decode_control(code)


func _check_dressing(profile: ConstructionSiteTerrainProfile, maps: Dictionary) -> String:
	var dressing := profile.build_dressing(maps)
	var rocks: Array = dressing.get("rocks", [])
	if rocks.size() != 18:
		return "site dressing uses 18 official demo rocks"
	var logical_minimum: Vector2 = maps["logical_origin_xz"]
	var logical_maximum: Vector2 = maps["logical_max_xz"]
	for entry in rocks:
		var position: Vector3 = entry["position"]
		if not is_finite(position.y):
			return "site dressing samples finite presentation heights"
		if position.x >= logical_minimum.x and position.x <= logical_maximum.x \
			and position.z >= logical_minimum.y and position.z <= logical_maximum.y:
			return "site dressing remains outside the logical excavation patch"
	return ""


func _check_texture_detail(assets: Object) -> String:
	if not assets.has_method("get_texture"):
		return "Terrain3D assets expose generated texture slots"
	var texture: Variant = assets.call("get_texture", 0)
	if not (texture is Object):
		return "disturbed-soil texture asset is available"
	var albedo: Variant = (texture as Object).get("albedo_texture")
	if not (albedo is Texture2D) or (albedo as Texture2D).get_size() != Vector2(1024.0, 1024.0):
		return "official demo PBR texture detail remains available"
	return ""


func _check_worksite_layout(profile: ConstructionSiteTerrainProfile, maps: Dictionary) -> String:
	var first := profile.build_worksite_layout(maps)
	var second := profile.build_worksite_layout(maps)
	var expected := {
		"barriers": 3,
		"stakes": 10,
		"route_markers": 8,
		"track_marks": 12,
		"pipes": 6,
		"aggregate": 5,
		"signs": 1,
	}
	if first != second:
		return "code-native worksite layout is deterministic"
	var logical_minimum := maps["logical_origin_xz"] as Vector2
	var logical_maximum := maps["logical_max_xz"] as Vector2
	for key in expected:
		var entries := first.get(key, []) as Array
		if entries.size() != int(expected[key]):
			return "%s uses its bounded cue count" % key
		for entry in entries:
			var position := (entry as Dictionary)["position"] as Vector3
			if not is_finite(position.y):
				return "%s samples finite shared presentation height" % key
			if position.x >= logical_minimum.x and position.x <= logical_maximum.x \
				and position.z >= logical_minimum.y and position.z <= logical_maximum.y:
				return "%s remains outside the logical excavation patch" % key
	return ""


func _fail(message: String) -> int:
	push_error("Construction-site terrain check failed: %s" % message)
	return 1

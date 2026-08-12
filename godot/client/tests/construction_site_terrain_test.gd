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
	var assets := profile.create_assets()
	if assets == null or not assets.has_method("get_texture_count") or int(assets.call("get_texture_count")) != 4:
		return _fail("construction site creates four project-owned Terrain3D texture assets")
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
	if int(haul["overlay_id"]) != 1 or float(haul["blend"]) < 0.5:
		return "access corridor uses compacted haul-track material"
	var grass := _control_at(maps, Vector2(-29.0, 0.0))
	if int(grass["overlay_id"]) != 2 or float(grass["blend"]) < 0.7:
		return "outer undisturbed edge uses grass material"
	var damp := _control_at(maps, Vector2(15.0, 16.0))
	if int(damp["overlay_id"]) != 3 or float(damp["blend"]) < 0.8:
		return "drainage low point uses damp-soil material"
	return ""


func _control_at(maps: Dictionary, position: Vector2) -> Dictionary:
	var spacing := float(maps["spacing_m"])
	var origin: Vector2 = maps["origin_xz"]
	var columns := int(maps["columns"])
	var column := roundi((position.x - origin.x) / spacing)
	var row := roundi((position.y - origin.y) / spacing)
	var code := (maps["control_bytes"] as PackedByteArray).decode_u32((row * columns + column) * 4)
	return ConstructionSiteTerrainProfile.decode_control(code)


func _fail(message: String) -> int:
	push_error("Construction-site terrain check failed: %s" % message)
	return 1

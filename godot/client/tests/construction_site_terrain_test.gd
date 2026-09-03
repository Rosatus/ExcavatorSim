extends SceneTree

const VoxelZone = preload("res://scripts/voxel_work_zone_config.gd")


func _init() -> void:
	quit(_run())


func _run() -> int:
	var state := TerrainState.new(24681357)
	var snapshot := state.surface_snapshot()
	var profile := ConstructionSiteTerrainProfile.new()
	var maps := profile.build_maps(snapshot)
	if maps.is_empty():
		return _fail("construction-site maps build from a TerrainState snapshot")
	if int(maps["rows"]) != 161 or int(maps["columns"]) != 129:
		return _fail("default construction site is 64 x 80 m at 0.5 m spacing")
	if snapshot["origin_xz"] != Vector2(-32.0, -32.0) or maps["authority_origin_xz"] != snapshot["origin_xz"]:
		return _fail("visible site and authoritative terrain share the same footprint")
	if (maps["height_bytes"] as PackedByteArray).size() != 129 * 161 * 4:
		return _fail("presentation height bytes match the site grid")
	if (maps["control_bytes"] as PackedByteArray).size() != 129 * 161 * 4:
		return _fail("control bytes match the site grid")
	var coverage_error := _check_voxel_zone_coverage(maps)
	if coverage_error != "":
		return _fail(coverage_error)
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
		return _fail("Terrain3D retains two initialization texture slots for native readiness")
	var roles := profile.get_material_roles()
	if roles != PackedStringArray(["Project Procedural Worksite Soil"]):
		return _fail("construction site exposes one project-owned procedural material role")
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


func _check_voxel_zone_coverage(maps: Dictionary) -> String:
	var rows := int(maps["rows"])
	var columns := int(maps["columns"])
	var spacing := float(maps["spacing_m"])
	var origin := maps["origin_xz"] as Vector2
	var presentation_maximum := origin + Vector2(
		float(columns - 1) * spacing,
		float(rows - 1) * spacing,
	)
	var zone_minimum := Vector2(VoxelZone.MIN_WORLD.x, VoxelZone.MIN_WORLD.z)
	var zone_maximum := Vector2(VoxelZone.MAX_WORLD.x, VoxelZone.MAX_WORLD.z)
	if origin.x > zone_minimum.x or origin.y > zone_minimum.y \
			or presentation_maximum.x < zone_maximum.x or presentation_maximum.y < zone_maximum.y:
		return "Terrain3D presentation domain contains the complete voxel work zone"
	return ""


func _check_material_zones(maps: Dictionary) -> String:
	var controls := maps["control_bytes"] as PackedByteArray
	var cell_count := int(maps["rows"]) * int(maps["columns"])
	var columns := int(maps["columns"])
	var spacing := float(maps["spacing_m"])
	var origin := maps["origin_xz"] as Vector2
	var hole_count := 0
	for index in cell_count:
		var code := controls.decode_u32(index * 4)
		var decoded := ConstructionSiteTerrainProfile.decode_control(code)
		if int(decoded["base_id"]) != 0 or int(decoded["overlay_id"]) != 0:
			return "every control-map cell selects project procedural soil"
		var position := Vector2(
			origin.x + float(index % columns) * spacing,
			origin.y + float(index / columns) * spacing,
		)
		var is_hole := ((code >> 2) & 0x1) != 0
		if is_hole != VoxelZone.owns_hard_surface_cell(position):
			return "Terrain3D holes match the voxel ownership mask exactly"
		if is_hole:
			hole_count += 1
	if hole_count == 0:
		return "voxel ownership creates a bounded Terrain3D hole"
	return ""


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
		if VoxelZone.owns_world_xz(Vector2(position.x, position.z)):
			return "site dressing remains outside voxel soil ownership"
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
	for key in expected:
		var entries := first.get(key, []) as Array
		if entries.size() != int(expected[key]):
			return "%s uses its bounded cue count" % key
		for entry in entries:
			var position := (entry as Dictionary)["position"] as Vector3
			if not is_finite(position.y):
				return "%s samples finite shared presentation height" % key
			if VoxelZone.owns_world_xz(Vector2(position.x, position.z)):
				return "%s remains outside voxel soil ownership" % key
	return ""


func _fail(message: String) -> int:
	push_error("Construction-site terrain check failed: %s" % message)
	return 1

extends SceneTree
## --headless --path godot/client --script ../../tools/bake_bucket_soil.gd
## -- res://resources/attachments/<tool>_soil_bake.json [--check]
const Geometry = preload("res://scripts/bucket_soil_geometry.gd")
const Fill = preload("res://scripts/bucket_fill_surface.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		return _fail("provide a bucket-soil-bake-v1 recipe resource path")
	var recipe: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	var result := bake(recipe)
	if result.has("error"):
		return _fail(result.error)
	var outputs: Dictionary = result.outputs
	if "--check" in args:
		for path in outputs:
			if FileAccess.get_file_as_string(path) != outputs[path]:
				return _fail("generated resource drift: " + path)
		print("bucket soil bake check: PASS")
	else:
		# All inputs, geometry, generated profile and contract have passed before
		# touching any file. Write the catalog last so it pins final resources.
		for path in outputs:
			var file := FileAccess.open(path, FileAccess.WRITE)
			if file == null:
				return _fail("cannot write " + path)
			file.store_string(outputs[path])
			file.close()
		print("bucket soil bake: PASS ", result.summary)
	quit(0)


func bake(recipe: Variant) -> Dictionary:
	var error := _validate_recipe(recipe)
	if not error.is_empty():
		return {"error": error}
	var packed := load(recipe.asset_path) as PackedScene
	if packed == null:
		return {"error": "asset is not an imported PackedScene"}
	var asset := packed.instantiate() as Node3D
	root.add_child(asset)
	var result := _measure(asset, recipe)
	asset.free()
	return result


func _measure(asset: Node3D, recipe: Dictionary) -> Dictionary:
	var tool_root := _unique_node(asset, recipe.root_node) as Node3D
	if tool_root == null:
		return {"error": "root_node must identify exactly one Node3D"}
	var raw_rim: Array = []
	for anchor in recipe.mouth_anchors:
		var mesh := _unique_node(tool_root, anchor.node) as MeshInstance3D
		if mesh == null:
			return {"error": "missing/ambiguous mouth anchor mesh: " + String(anchor.node)}
		var point := _nearest_vertex(tool_root, mesh, Geometry.vector(anchor.near_tool_local))
		if point.distance_to(Geometry.vector(anchor.near_tool_local)) > float(recipe.anchor_tolerance_m):
			return {"error": "mouth anchor moved beyond tolerance: " + String(anchor.node)}
		raw_rim.append(Geometry.array(point))
	var mouth := Geometry.mouth(raw_rim)
	if mouth.is_empty():
		return {"error": "measured mouth is not one convex planar polygon"}
	var opening_frame: Transform3D = mouth.transform
	var geometry := {"schema_version": "bucket-soil-geometry-v1",
		"mouth_polygon_godot": raw_rim, "cavity_depth_m": recipe.cavity_depth_m,
		"fill_profile_path": recipe.profile_path, "fill_profile_sha256": "",
		"source_glb_path": recipe.asset_path, "source_glb_sha256": recipe.asset_sha256}
	var cavity := Geometry.cavity(geometry)
	var inverse := cavity.affine_inverse()
	var rim: Array = []
	for point in mouth.points:
		rim.append(Geometry.array(inverse * point))
	var rim_height := float(recipe.cavity_depth_m) * 0.5
	var columns := int(recipe.columns)
	var rows := int(recipe.rows)
	var x_bounds := Vector2(recipe.x_bounds[0], recipe.x_bounds[1])
	var z_bounds: Vector2 = mouth.z_bounds + Vector2(-1, 1) * float(recipe.z_padding_m)
	if x_bounds.x >= mouth.x_bounds.x or x_bounds.y <= mouth.x_bounds.y:
		return {"error": "grid must include the mouth plus a dry perimeter"}
	var faces := PackedVector3Array()
	for name in recipe.lining_nodes:
		var mesh := _unique_node(tool_root, name) as MeshInstance3D
		if mesh == null or mesh.mesh == null:
			return {"error": "missing/ambiguous lining mesh: " + String(name)}
		var transform := inverse * tool_root.global_transform.affine_inverse() * mesh.global_transform
		for point in mesh.mesh.get_faces():
			faces.append(transform * point)
	var floors: Array[float] = []
	var measured_count := 0
	for row in rows:
		for column in columns:
			var x := lerpf(x_bounds.x, x_bounds.y, float(column) / (columns - 1))
			var z := lerpf(z_bounds.x, z_bounds.y, float(row) / (rows - 1))
			var height := _footprint_height(faces, x, z,
				(x_bounds.y - x_bounds.x) / (columns - 1) * 0.5,
				(z_bounds.y - z_bounds.x) / (rows - 1) * 0.5)
			if not is_finite(height) or row in [0, rows - 1] or column in [0, columns - 1] or not _inside_mouth(x, z, rim):
				height = rim_height + 0.04
			else:
				measured_count += 1
			floors.append(height)
	var contract: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(recipe.contract_path))
	contract["fill_profile_id"] = recipe.fill_profile_id
	contract["soil_geometry"] = geometry
	contract.interaction["release_opening_down_dot"] = recipe.release_opening_down_dot
	var opening: Dictionary = contract.proxies.opening
	opening.center_godot = Geometry.array(opening_frame.origin)
	opening.normal_godot = Geometry.array(opening_frame.basis.y)
	opening.up_godot = opening.normal_godot
	opening.size_m = [mouth.size.x, mouth.size.y]
	contract.proxies.cavity.center_godot = Geometry.array(cavity.origin)
	contract.proxies.cavity.up_godot = opening.normal_godot
	contract.proxies.cavity.size_m = [mouth.size.x, recipe.cavity_depth_m, mouth.size.y]
	for region in contract.bucket_tool.regions:
		if region.region_id == "opening":
			region.center_godot = opening.center_godot
			region.outward_normal_godot = opening.normal_godot
			region.shape.size_m = opening.size_m
			region.shape.width_axis_godot = Geometry.array(opening_frame.basis.x)
			region.shape.height_axis_godot = Geometry.array(opening_frame.basis.z)
		elif region.region_id == "inner_shell":
			region.center_godot = contract.proxies.cavity.center_godot
			region.outward_normal_godot = opening.normal_godot
			region.shape.size_m = contract.proxies.cavity.size_m
	var profile := {"schema_version": "bucket-fill-profile-v1", "model_id": recipe.fill_profile_id,
		"source_sha256": recipe.asset_sha256, "coordinate_space": "cavity_local", "growth_direction_y": 1.0,
		"cavity_center_godot": Geometry.array(cavity.origin), "cavity_up_godot": opening.normal_godot,
		"columns": columns, "rows": rows, "x_bounds": [x_bounds.x, x_bounds.y], "z_bounds": [z_bounds.x, z_bounds.y],
		"rim_height": rim_height, "body_opening_rim_cavity_local": rim,
		"clip_to_mouth_polygon": true,
		"sampling": "maximum imported lining height over each grid-point footprint", "floor_heights": floors}
	var profile_text := JSON.stringify(profile, "  ", false) + "\n"
	geometry.fill_profile_sha256 = profile_text.sha256_text()
	var geometry_error := Geometry.validate(geometry, contract, false)
	if geometry_error.is_empty():
		geometry_error = Geometry.validate_profile(profile, geometry, contract)
	if not geometry_error.is_empty():
		return {"error": geometry_error}
	# Validate the remaining shared soil contract independently before output
	# files exist; geometry/profile validation above owns the new resource chain.
	var base_contract := contract.duplicate(true)
	base_contract.erase("soil_geometry")
	var descriptor := SoilContractDescriptor.from_dictionary_for_test(base_contract)
	if not descriptor.is_valid_for(String(contract.model_id)):
		return {"error": descriptor.validation_error()}
	var fill := Fill.new()
	if not fill._configure_profile(profile) or fill.build_arrays(1.0).is_empty():
		return {"error": "lining has no usable contained fill volume"}
	var contract_text := JSON.stringify(contract, "  ", false) + "\n"
	var catalog_text := FileAccess.get_file_as_string(recipe.catalog_path)
	var catalog: Dictionary = JSON.parse_string(catalog_text)
	var matched := false
	var native_model := String(recipe.get("catalog_kind", "tool")) == "model"
	for tool in catalog.get("models" if native_model else "tools", []):
		if tool.get("model_id" if native_model else "tool_id") == recipe.tool_id:
			if tool.get("soil_contract_path") != recipe.contract_path or tool.get("glb_path" if native_model else "tool_glb_path") != recipe.asset_path \
					or tool.get("glb_sha256" if native_model else "tool_glb_sha256") != recipe.asset_sha256:
				return {"error": "recipe and catalog asset/contract disagree"}
			if not tool.get("soil_contract_sha256") is String or String(tool.soil_contract_sha256).length() != 64 \
					or catalog_text.count(String(tool.soil_contract_sha256)) != 1 or matched:
				return {"error": "catalog tool/hash must identify one distinct entry"}
			catalog_text = catalog_text.replace(String(tool.soil_contract_sha256), contract_text.sha256_text())
			matched = true
	if not matched:
		return {"error": "tool_id missing from catalog"}
	return {"outputs": {recipe.profile_path: profile_text, recipe.contract_path: contract_text, recipe.catalog_path: catalog_text},
		"summary": {"samples": measured_count, "normal": opening.normal_godot, "profile": recipe.profile_path}}


func _validate_recipe(value: Variant) -> String:
	if not value is Dictionary or value.get("schema_version") != "bucket-soil-bake-v1":
		return "expected bucket-soil-bake-v1 recipe"
	for key in ["asset_path", "contract_path", "profile_path", "catalog_path"]:
		if not value.get(key) is String or not value[key].begins_with("res://") or ".." in value[key]:
			return "invalid resource path: " + key
	var output_paths := [value.contract_path, value.profile_path, value.catalog_path]
	for path in output_paths:
		if output_paths.count(path) != 1 or path == value.asset_path or not path.ends_with(".json"):
			return "outputs must be distinct JSON resources"
	for key in ["asset_path", "contract_path", "catalog_path"]:
		if not FileAccess.file_exists(value[key]):
			return "missing resource: " + key
	if value.get("asset_sha256") != FileAccess.get_sha256(value.asset_path):
		return "source GLB hash mismatch; inspect the new asset before changing its pin"
	for key in ["tool_id", "fill_profile_id", "root_node"]:
		if not value.get(key) is String or value[key].is_empty():
			return "missing " + key
	for key in ["columns", "rows"]:
		if not Geometry.number(value.get(key)) or float(value[key]) != floorf(value[key]) or int(value[key]) < 5 or int(value[key]) > 129:
			return "grid dimensions must be integers in [5,129]"
	for key in ["anchor_tolerance_m", "cavity_depth_m", "z_padding_m"]:
		if not Geometry.number(value.get(key)) or float(value[key]) <= 0:
			return "invalid positive parameter: " + key
	if not Geometry.number(value.get("release_opening_down_dot")) or float(value.release_opening_down_dot) < 0.15 or float(value.release_opening_down_dot) >= 1.0:
		return "release threshold must be within [0.15,1)"
	if not value.get("x_bounds") is Array or value.x_bounds.size() != 2 \
			or not Geometry.number(value.x_bounds[0]) or not Geometry.number(value.x_bounds[1]) or value.x_bounds[0] >= value.x_bounds[1]:
		return "invalid x_bounds"
	if not value.get("lining_nodes") is Array or value.lining_nodes.is_empty():
		return "lining_nodes must select imported meshes"
	for name in value.lining_nodes:
		if not name is String or name.is_empty() or value.lining_nodes.count(name) != 1:
			return "lining names must be unique nonempty strings"
	if not value.get("mouth_anchors") is Array or value.mouth_anchors.size() < 3 or value.mouth_anchors.size() > 32:
		return "mouth requires 3 to 32 anchors"
	for anchor in value.mouth_anchors:
		if not anchor is Dictionary or not anchor.get("node") is String or not Geometry.valid_vector(anchor.get("near_tool_local")):
			return "invalid mouth anchor"
	var contract: Variant = JSON.parse_string(FileAccess.get_file_as_string(value.contract_path))
	if not contract is Dictionary:
		return "contract must be JSON object"
	var base: Dictionary = contract.duplicate(true)
	base.erase("soil_geometry")
	var descriptor := SoilContractDescriptor.from_dictionary_for_test(base)
	if not descriptor.is_valid_for(String(base.get("model_id", ""))):
		return "base contract: " + descriptor.validation_error()
	var catalog: Variant = JSON.parse_string(FileAccess.get_file_as_string(value.catalog_path))
	var catalog_kind := String(value.get("catalog_kind", "tool"))
	if catalog_kind not in ["tool", "model"]:
		return "catalog_kind must be tool or model"
	if not catalog is Dictionary or not catalog.get("models" if catalog_kind == "model" else "tools") is Array:
		return "invalid catalog"
	return ""


func _unique_node(root_node: Node, name: String) -> Node:
	var matches: Array[Node] = []
	if root_node.name == name:
		matches.append(root_node)
	for child in root_node.find_children("*", "", true, false):
		if child.name == name:
			matches.append(child)
	return matches[0] if matches.size() == 1 else null


func _inside_mouth(x: float, z: float, rim: Array) -> bool:
	var polygon := PackedVector2Array()
	for point in rim:
		polygon.append(Vector2(point[0], point[2]))
	return Geometry2D.is_point_in_polygon(Vector2(x, z), polygon)


func _nearest_vertex(tool_root: Node3D, mesh: MeshInstance3D, target: Vector3) -> Vector3:
	var transform := tool_root.global_transform.affine_inverse() * mesh.global_transform
	var nearest := Vector3.INF
	var distance := INF
	for vertex in mesh.mesh.get_faces():
		var point := transform * vertex
		if point.distance_squared_to(target) < distance:
			nearest = point
			distance = point.distance_squared_to(target)
	return nearest


func _footprint_height(faces: PackedVector3Array, x: float, z: float, half_x: float, half_z: float) -> float:
	var height := -INF
	for index in range(0, faces.size(), 3):
		var a := faces[index]
		var b := faces[index + 1]
		var c := faces[index + 2]
		if maxf(a.x, maxf(b.x, c.x)) < x - half_x or minf(a.x, minf(b.x, c.x)) > x + half_x \
				or maxf(a.z, maxf(b.z, c.z)) < z - half_z or minf(a.z, minf(b.z, c.z)) > z + half_z:
			continue
		var polygon: Array[Vector3] = [a, b, c]
		polygon = _clip(polygon, 0, x - half_x, true)
		polygon = _clip(polygon, 0, x + half_x, false)
		polygon = _clip(polygon, 2, z - half_z, true)
		polygon = _clip(polygon, 2, z + half_z, false)
		for point in polygon:
			height = maxf(height, point.y)
	return height


func _clip(points: Array[Vector3], axis: int, bound: float, keep_greater: bool) -> Array[Vector3]:
	var result: Array[Vector3] = []
	if points.is_empty():
		return result
	var previous := points.back() as Vector3
	var previous_inside := previous[axis] >= bound if keep_greater else previous[axis] <= bound
	for point in points:
		var inside := point[axis] >= bound if keep_greater else point[axis] <= bound
		if inside != previous_inside:
			result.append(previous.lerp(point, (bound - previous[axis]) / (point[axis] - previous[axis])))
		if inside:
			result.append(point)
		previous = point
		previous_inside = inside
	return result


func _fail(message: String) -> void:
	push_error(message)
	quit(1)

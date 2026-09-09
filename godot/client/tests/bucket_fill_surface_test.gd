extends SceneTree

const FillSurface = preload("res://scripts/bucket_fill_surface.gd")
const BucketMaterials = preload("res://scripts/bucket_visual_materials.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	for model in ["sy135", "sy205"]:
		if not _check_model(model):
			quit(1)
			return
	if not await _check_lifecycle():
		quit(1)
		return
	print("bucket_fill_surface_test: PASS")
	quit(0)


func _check_model(model: String) -> bool:
	var contract: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://resources/models/%s_soil_contract.json" % model))
	var profile: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FillSurface.PROFILE_PATHS[model]))
	var path := "res://assets/visual/%s_excavator_godot.glb" % model.to_upper()
	if FileAccess.get_sha256(path) != profile["source_sha256"]:
		return _fail("%s measured fill profile no longer matches the GLB" % model)
	if profile["cavity_center_godot"] != contract["proxies"]["cavity"]["center_godot"] or profile["cavity_up_godot"] != contract["proxies"]["cavity"]["up_godot"]:
		return _fail("%s cavity-local coordinates drifted" % model)
	var surface := FillSurface.new()
	if not surface.configure(model, Vector3.ONE) or not surface.build_arrays(0.0).is_empty():
		return _fail("%s profile initialization/empty fill failed" % model)
	# The front/rear samples cancel symmetric mound relief; the deterministic
	# ripple can contribute at most 18 mm across the pair.
	var front_relief: float = surface._surface_relief(0.0, -0.25)
	var rear_relief: float = surface._surface_relief(0.0, 0.40)
	if model == "sy135" and front_relief - rear_relief < 0.045:
		return _fail("SY135 free surface does not advance toward the cutting edge")
	if model == "sy205" and not is_zero_approx(surface._forward_slope):
		return _fail("SY135 tilt leaked into SY205")
	var previous_volume := 0.0
	var volumes: Array[float] = []
	for ratio in [0.005, 0.05, 0.25, 0.5, 0.75, 1.0]:
		var arrays := surface.build_arrays(ratio)
		if arrays.is_empty():
			return _fail("%s positive stock disappeared" % model)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for vertex in vertices:
			if vertex.y * float(profile["growth_direction_y"]) > float(profile["rim_height"]) + 0.00001:
				return _fail("%s fill crossed the dry rim at %.3f stock" % [model, ratio])
		var volume := 0.0
		var edges: Dictionary = {}
		for index in range(0, vertices.size(), 3):
			var a := vertices[index]
			var b := vertices[index + 1]
			var c := vertices[index + 2]
			var face_normal := (c - a).cross(b - a)
			if not a.is_finite() or face_normal.length_squared() < 1.0e-20:
				return _fail("%s emitted invalid/degenerate geometry" % model)
			if face_normal.normalized().dot(normals[index] + normals[index + 1] + normals[index + 2]) <= 0.0:
				return _fail("%s winding and lighting normals disagree" % model)
			volume += a.dot(b.cross(c)) / 6.0
			for edge in [[a, b], [b, c], [c, a]]:
				var key_a := _point_key(edge[0])
				var key_b := _point_key(edge[1])
				if key_a == key_b:
					continue
				var key := key_a + ":" + key_b if key_a < key_b else key_b + ":" + key_a
				edges[key] = int(edges.get(key, 0)) + 1
		for edge in edges:
			if int(edges[edge]) != 2:
				return _fail("%s fill is not a closed solid at ratio %.3f: %s has %s faces" % [model, ratio, edge, edges[edge]])
		volume = absf(volume)
		if volume <= previous_volume:
			return _fail("%s increasing stock did not grow the contained solid" % model)
		previous_volume = volume
		volumes.append(volume)
		var repeated := surface.build_arrays(ratio)
		if repeated[Mesh.ARRAY_VERTEX] != vertices:
			return _fail("%s soil surface changed randomly at fixed stock" % model)
	if volumes[1] / volumes.back() > 0.08 or volumes[0] / volumes.back() > 0.015:
		return _fail("%s low stock became a large minimum-sized block" % model)
	var asset := load(path).instantiate() as Node3D
	root.add_child(asset)
	var mesh_node := asset.find_child("bucket", true, false) as MeshInstance3D
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://resources/visual/%s_visual_manifest.json" % model))
	var source := mesh_node.mesh.surface_get_material(0) as StandardMaterial3D
	var color_before := source.albedo_color
	BucketMaterials.apply(asset, manifest, model)
	var material := mesh_node.get_active_material(0) as StandardMaterial3D
	if model == "sy135":
		if material == source or material.albedo_color.get_luminance() <= color_before.get_luminance() or material.emission_enabled:
			asset.free()
			return _fail("SY135 dark lining did not receive an isolated lit PBR correction")
		var corrected_color := material.albedo_color
		BucketMaterials.apply(asset, manifest, model)
		if (mesh_node.get_active_material(0) as StandardMaterial3D).albedo_color != corrected_color or source.albedo_color != color_before:
			asset.free()
			return _fail("bucket material correction accumulated or mutated imported material")
	elif material != source:
		asset.free()
		return _fail("SY205 atlas was overwritten with SY135's untextured material")
	var contact_ok := _check_imported_contact(mesh_node, contract, profile, surface)
	asset.free()
	if not contact_ok:
		return false
	print(model, " volumes m3 (visual only): ", volumes)
	return true


func _check_imported_contact(mesh_node: MeshInstance3D, contract: Dictionary, profile: Dictionary, surface: RefCounted) -> bool:
	var center_raw: Array = contract["proxies"]["cavity"]["center_godot"]
	var up_raw: Array = contract["proxies"]["cavity"]["up_godot"]
	var center := Vector3(center_raw[0], center_raw[1], center_raw[2])
	var up := Vector3(up_raw[0], up_raw[1], up_raw[2]).normalized()
	var cavity := Transform3D(Basis(Vector3.RIGHT, up, Vector3.RIGHT.cross(up)), center)
	var mesh_to_cavity := cavity.affine_inverse() * mesh_node.transform
	var arrays := mesh_node.mesh.surface_get_arrays(0)
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var direction := float(profile["growth_direction_y"])
	var samples := 0
	# Independently intersect the imported triangles, not the baked JSON mesh.
	for row in [10, 14, 18, 22]:
		for column in [6, 12, 18]:
			var point: Vector2 = surface._grid_position(column, row)
			var start := Vector3(point.x, direction * 2.0, point.y)
			var end := Vector3(point.x, -direction * 2.0, point.y)
			var measured := -INF
			for index in range(0, indices.size(), 3):
				var hit: Variant = Geometry3D.segment_intersects_triangle(start, end,
					mesh_to_cavity * positions[indices[index]],
					mesh_to_cavity * positions[indices[index + 1]],
					mesh_to_cavity * positions[indices[index + 2]])
				if hit is Vector3:
					measured = maxf(measured, (hit as Vector3).y * direction)
			var floor_height := float(profile["floor_heights"][row * int(profile["columns"]) + column])
			if not is_finite(measured) or absf(measured - floor_height) > 0.002:
				return _fail("%s fill floor is not on the imported lining at %s: %s vs %s" % [profile["model_id"], point, floor_height, measured])
			samples += 1
	return samples == 12


func _check_lifecycle() -> bool:
	var effects := SoilEffects.new()
	effects.excavation_world_path = NodePath()
	effects.max_clods = 1
	effects.max_visual_mounds = 1
	root.add_child(effects)
	await process_frame
	var mesh_id := effects._fill_array_mesh.get_instance_id()
	for model in ["sy135", "sy205", "sy135"]:
		var contract: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://resources/models/%s_soil_contract.json" % model))
		var transform := Transform3D(Basis(Vector3.RIGHT, 0.73), Vector3(2.0, 3.0, -1.0))
		var current := {"cavity": transform}
		effects._update_fill({"fill_ratio": 0.5}, current, contract)
		if not effects._fill_mesh.visible or effects._last_fill_model_id != model or effects._fill_array_mesh.get_instance_id() != mesh_id or not effects._fill_mesh.global_transform.is_equal_approx(transform):
			effects.free()
			return _fail("model switch/rotation did not rebuild the correct lining using the reusable mesh")
		var rebuilds := effects._fill_rebuild_count
		effects._update_fill({"fill_ratio": 0.5}, current, {})
		if effects._fill_mesh.visible:
			effects.free()
			return _fail("missing cavity contract retained visible fill")
		effects._update_fill({"fill_ratio": 0.5}, current, contract)
		if effects._fill_rebuild_count != rebuilds + 1:
			effects.free()
			return _fail("restored contract reused invalidated fill state")
		effects._update_fill({"fill_ratio": 0.0}, current, contract)
		if effects._fill_mesh.visible:
			effects.free()
			return _fail("empty bucket retained visible soil")
		effects._update_fill({"fill_ratio": 0.01}, current, contract)
		if not effects._fill_mesh.visible:
			effects.free()
			return _fail("first sub-quantum layer after empty was not rebuilt")
	effects.clear_for_generation(1)
	var cleared := not effects._fill_mesh.visible
	effects.free()
	return cleared or _fail("generation reset retained fill")


func _point_key(point: Vector3) -> String:
	return "%d,%d,%d" % [roundi(point.x * 100000.0), roundi(point.y * 100000.0), roundi(point.z * 100000.0)]


func _fail(message: String) -> bool:
	push_error(message)
	return false

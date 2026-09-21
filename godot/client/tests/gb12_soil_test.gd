extends SceneTree

const Fill = preload("res://scripts/bucket_fill_surface.gd")
const ASSET := "res://assets/visual/GB12_S50_Bucket.glb"
const CONTRACT := "res://resources/attachments/gb12_s50_soil_contract.json"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var contract: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CONTRACT))
	var profile: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(contract.soil_geometry.fill_profile_path))
	assert(profile.source_sha256 == FileAccess.get_sha256(ASSET))
	assert(SoilContractDescriptor.from_dictionary_for_test(contract).is_valid_for("gb12_s50"))
	assert(profile.cavity_center_godot == contract.proxies.cavity.center_godot)
	assert(profile.cavity_up_godot == contract.proxies.cavity.up_godot)
	var imported := load(ASSET).instantiate() as Node3D
	root.add_child(imported)
	var tool_root := imported.find_child("GB12_ROOT", true, false) as Node3D
	var up := _vec(contract.proxies.cavity.up_godot)
	var local := Transform3D(Basis(Vector3.RIGHT, up, Vector3.RIGHT.cross(up)), _vec(contract.proxies.cavity.center_godot))
	var faces := PackedVector3Array()
	for mesh: MeshInstance3D in imported.find_children("*", "MeshInstance3D", true, false):
		var selected := false
		for part in ["continuous rolled bowl", "tapered cheek", "crown beam", "lip top land", "internal tapered gusset"]:
			selected = selected or part in String(mesh.name)
		if not selected:
			continue
		var transform := local.affine_inverse() * tool_root.global_transform.affine_inverse() * mesh.global_transform
		for point in mesh.mesh.get_faces():
			faces.append(transform * point)
	var surface := Fill.new()
	assert(surface.configure_contract(contract, Vector3.ONE))
	var previous_volume := 0.0
	for ratio in [0.005, 0.05, 0.25, 0.5, 0.75, 1.0]:
		var arrays := surface.build_arrays(ratio)
		assert(not arrays.is_empty(), "GB12 positive fill must be visible")
		var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var edges := {}
		var vertex_ids := {}
		var unique_points: Array[Vector3] = []
		var volume := 0.0
		for index in range(0, points.size(), 3):
			var a := points[index]
			var b := points[index + 1]
			var c := points[index + 2]
			volume += a.dot(b.cross(c)) / 6.0
			assert((c - a).cross(b - a).dot(normals[index]) > 0.0)
			for point in [a, b, c]:
				assert(point.y <= float(profile.rim_height) - 0.0649, "fill crosses GB12 mouth")
			for edge in [[a, b], [b, c], [c, a]]:
				for point in edge:
					if not vertex_ids.has(point):
						vertex_ids[point] = vertex_ids.size()
						unique_points.append(point)
				var key_a := int(vertex_ids[edge[0]])
				var key_b := int(vertex_ids[edge[1]])
				if key_a == key_b:
					continue
				var key := Vector2i(mini(key_a, key_b), maxi(key_a, key_b))
				edges[key] = int(edges.get(key, 0)) + 1
			# Sample corners, edges and interior independently against the actual
			# imported lining; cover both skins and sharp lip/side transitions.
			if (index / 3) % 19 == 0:
				for point in [a, b, c, (a + b) * 0.5, (b + c) * 0.5, (c + a) * 0.5, (a + b + c) / 3.0]:
					var lining := _height(faces, point.x, point.z)
					assert(is_finite(lining) and point.y >= lining - 0.0005,
						"GB12 fill outside lining: ratio=%s point=%s lining=%s" % [ratio, point, lining])
		for key in edges:
			# The builder drops faces with squared area < 1e-20. Allow only
			# sub-20-micron sliver edges from that floating-point degeneracy.
			assert(edges[key] == 2 or unique_points[key.x].distance_to(unique_points[key.y]) < 0.00002,
				"GB12 fill must be closed: ratio=%s edge=%s length=%s count=%s" % [ratio, key, unique_points[key.x].distance_to(unique_points[key.y]), edges[key]])
		assert(absf(volume) > previous_volume, "stock must grow volume monotonically")
		previous_volume = absf(volume)
		assert(surface.build_arrays(ratio)[Mesh.ARRAY_VERTEX] == points)
	print("GB12 full visual volume: ", previous_volume)
	imported.free()
	if not await _check_live_attachment():
		quit(1)
		return
	print("gb12_soil_test: PASS")
	quit(0)


func _check_live_attachment() -> bool:
	var host := Node3D.new()
	root.add_child(host)
	var visual_root := Node3D.new()
	visual_root.name = "PresentationRoot"
	host.add_child(visual_root)
	var client := MotionClient.new()
	client.name = "MotionClient"
	client.auto_connect = false
	client.auto_reconnect = false
	client.desired_model_id = "sy135"
	host.add_child(client)
	var presentation := MotionPresentation.new()
	presentation.name = "MotionPresentation"
	host.add_child(presentation)
	var rig := AttachmentRig.new()
	rig.motion_presentation_path = NodePath("../MotionPresentation")
	host.add_child(rig)
	var effects := SoilEffects.new()
	effects.excavation_world_path = NodePath()
	effects.max_clods = 0
	effects.max_visual_mounds = 0
	host.add_child(effects)
	await process_frame
	assert(presentation.activate_model_for_test("sy135"))
	assert(presentation.set_authority_profile_for_test(AuthorityProfile.PYTHON_KINEMATIC))
	assert(rig.request_tool("gb12"))
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/sy135_frame_parity_cases.json"))
	assert(presentation.apply_pose_for_test(fixture.poses.zero))
	var contract := presentation.get_soil_contract()
	assert(contract.model_id == "sy135" and contract.fill_profile_id == "gb12_s50")
	var frame := rig.active_tool_node()
	var local := presentation.get_soil_proxy_local_transform("cavity")
	effects._update_fill({"fill_ratio": 0.5}, {"cavity": frame.global_transform * local}, contract)
	assert(effects._fill_mesh.visible and effects._last_fill_profile_id == "gb12_s50")
	assert(effects._fill_mesh.get_parent() == frame)
	var rebuilds := effects._fill_rebuild_count
	var authority := VoxelExcavationAuthority.new()
	var zone := VoxelWorkZone.new() # No terrain needed for above-volume gate checks.
	authority._work_zone = zone
	# Place above voxel bounds so only the real mouth orientation gates release.
	var bucket := presentation.get_frame_node("bucket_link")
	bucket.global_position = Vector3(0, 100, 18)
	var saw_open := false
	var saw_closed := false
	for tilt in [-45.0, 0.0, 45.0]:
		for rotation in [-180.0, -90.0, 0.0, 90.0]:
			for curl in [0.0, 60.0, 120.0, 175.0]:
				bucket.global_basis = Basis(Vector3.RIGHT, deg_to_rad(curl))
				rig._tilt_deg = tilt
				rig._rotate_deg = rotation
				rig._apply_pose()
				presentation.sample_bucket_pose_fixed(0, 0)
				var pose := presentation.sample_bucket_pose_fixed(0, 0)
				assert(pose.valid)
				var normal := frame.global_basis * _vec(contract.proxies.opening.normal_godot)
				assert((pose.opening_normal_world as Vector3).is_equal_approx(normal))
				authority._dump_gate_hold_s = 0.0
				authority._update_dump_gate_diagnostics(pose, 0.06)
				assert(not authority._dump_gate_active, "confirmation must remain")
				authority._update_dump_gate_diagnostics(pose, 0.06)
				var expected := normal.dot(Vector3.DOWN) >= 0.15
				assert(authority._dump_gate_active == expected, "GB12 gate must follow tilt/rotation/curl")
				saw_open = saw_open or expected
				saw_closed = saw_closed or not expected
				assert(effects._fill_mesh.global_transform.is_equal_approx(frame.global_transform * local))
	assert(saw_open and saw_closed and effects._fill_rebuild_count == rebuilds)
	# At 0.2 the GB12 gate opens but the unchanged native gate stays closed.
	var normal := Vector3(sqrt(0.96), -0.2, 0)
	var pose := {"valid": true, "contract": contract, "opening_normal_world": normal,
		"current": {"opening": Transform3D(Basis(Quaternion(Vector3.UP, normal)), Vector3(0, 100, 18))}}
	for i in 2:
		authority._update_dump_gate_diagnostics(pose, 0.06)
	assert(authority._dump_gate_active)
	authority._engaged = true
	authority._update_dump_gate_diagnostics(pose, 0.1)
	assert(not authority._dump_gate_active, "cut engagement still suppresses release")
	authority._engaged = false
	pose.contract = SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	authority._update_dump_gate_diagnostics(pose, 0.1)
	assert(is_equal_approx(authority._effective_dump_threshold, 0.5) and not authority._dump_gate_active)
	assert(rig.request_tool("standard_bucket"))
	assert(not effects._fill_mesh.visible)
	effects._update_fill({"fill_ratio": 0.5}, {"cavity": Transform3D.IDENTITY}, contract)
	assert(not effects._fill_mesh.visible, "stale GB12 stock must not appear in native bucket")
	var native := presentation.get_soil_contract()
	effects._update_fill({"fill_ratio": 0.5}, {"cavity": Transform3D.IDENTITY}, native)
	assert(effects._fill_mesh.visible and effects._last_fill_profile_id == "sy135")
	assert(rig.request_tool("gb12"))
	effects._update_fill({"fill_ratio": 0.5}, {"cavity": Transform3D.IDENTITY}, native)
	assert(not effects._fill_mesh.visible, "stale native stock must not appear in GB12")
	zone.free()
	host.free()
	return true


func _height(faces: PackedVector3Array, x: float, z: float) -> float:
	var height := -INF
	for index in range(0, faces.size(), 3):
		var hit: Variant = Geometry3D.segment_intersects_triangle(Vector3(x, 2, z), Vector3(x, -2, z), faces[index], faces[index + 1], faces[index + 2])
		if hit is Vector3:
			height = maxf(height, (hit as Vector3).y)
	return height


func _vec(value: Array) -> Vector3:
	return Vector3(value[0], value[1], value[2])





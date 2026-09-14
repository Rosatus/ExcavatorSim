extends SceneTree

var failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://resources/visual/sy205_visual_manifest.json"))
	var asset := load("res://assets/visual/SY205_excavator_godot.glb").instantiate() as Node3D
	root.add_child(asset)
	var bucket := asset.get_node(manifest["frame_map"]["bucket_link"]["node_path"]) as Node3D
	var arm := asset.get_node(manifest["frame_map"]["arm_link"]["node_path"]) as Node3D
	var mesh := asset.get_node(manifest["frame_map"]["bucket_link"]["visual_nodes"][0]) as MeshInstance3D
	var vertices: Array[Vector3] = []
	var faces: Array[Vector3] = []
	for point in mesh.mesh.get_faces():
		faces.append(bucket.to_local(mesh.to_global(point)))
	var bounds := AABB()
	for surface in mesh.mesh.get_surface_count():
		for vertex in mesh.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]:
			var local := bucket.to_local(mesh.to_global(vertex))
			bounds = AABB(local, Vector3.ZERO) if vertices.is_empty() else bounds.expand(local)
			vertices.append(local)
	var descriptor := SoilContractDescriptor.load_for_model("sy205")
	if descriptor == null or not descriptor.is_valid_for("sy205"):
		failures.append("SY205 soil descriptor/hash rejected")
	else:
		var proxies: Dictionary = descriptor.to_dictionary()["proxies"]
		var teeth := _v(proxies["cutting_edge"]["center_godot"])
		# The five tooth tips are the imported bucket's maximum-Y vertex band.
		# The old max-negative-Z candidate selected the curved back, not teeth.
		var tips := Vector3.ZERO
		var count := 0
		for vertex in vertices:
			if vertex.y > bounds.end.y - 0.01:
				tips += vertex
				count += 1
		tips /= float(count)
		if Vector2(teeth.y, teeth.z).distance_to(Vector2(tips.y, tips.z)) > 0.02:
			failures.append("cutting edge is detached from imported tooth tips")
		for name in ["cutting_edge", "top_edge"]:
			var center := _v(proxies[name]["center_godot"])
			for side in [-1.0, 1.0]:
				if _surface_distance(center + Vector3.RIGHT * float(proxies[name]["half_width_m"]) * side, faces) > 0.16:
					failures.append("%s endpoint is detached from its mesh rim" % name)
		var mouth := _v(proxies["opening"]["center_godot"])
		var rim := _v(proxies["top_edge"]["center_godot"])
		var normal := _v(proxies["opening"]["normal_godot"])
		if mouth.distance_to((teeth + rim) * 0.5) > 0.02 or absf(normal.dot((teeth - rim).normalized())) > 0.01:
			failures.append("opening plane does not span the measured rim and teeth")
		for region in descriptor.tool_contract()["regions"]:
			if region["region_id"] in ["left_side_cutter", "right_side_cutter", "floor_wear_plate", "outer_left_side", "outer_right_side"]:
				if _surface_distance(_v(region["center_godot"]), faces) > 0.16:
					failures.append("%s center is detached from the mesh surface" % region["region_id"])
		var sweeper := BucketProxySweeper.new()
		var cavity: Dictionary = proxies["cavity"]
		var cavity_transform := sweeper._proxy_local_transform(cavity)
		var cavity_half := _v(cavity["size_m"]) * 0.5
		for x in [-1, 1]:
			for y in [-1, 1]:
				for z in [-1, 1]:
					if not bounds.grow(0.12).has_point(cavity_transform * (cavity_half * Vector3(x, y, z))):
						failures.append("cavity extends beyond imported bucket bounds")
		for name in ["shell", "rear_support"]:
			var proxy: Dictionary = proxies[name]
			var center := _v(proxy["center_godot"])
			if not bounds.grow(0.02).has_point(center):
				failures.append("%s center is outside the bucket mesh bounds" % name)
			if _surface_distance(center, faces) > 0.16:
				failures.append("%s blocker is detached from the bucket surface" % name)
			if name == "shell":
				var transform := sweeper._proxy_local_transform(proxy)
				var half := _v(proxy["size_m"]) * 0.5
				for x in [-1, 1]:
					for y in [-1, 1]:
						for z in [-1, 1]:
							if not bounds.grow(0.12).has_point(transform * (half * Vector3(x, y, z))):
								failures.append("blocking shell extends beyond mesh tolerance")
	var rig := PhysicsRigDescriptor.load_for_model("sy205")
	var limits: Array = rig.joints()[3]["limit_rad"]
	if float(limits[0]) < deg_to_rad(-20.01) or float(limits[1]) < deg_to_rad(94.99):
		failures.append("bucket lost its curl clearance/dump range exception")
	if descriptor != null and descriptor.is_valid_for("sy205"):
		var contract := descriptor.to_dictionary()
		var normal := _v(contract["proxies"]["opening"]["normal_godot"])
		var maximum_angle := float(limits[1]) + float(rig.joints()[1]["limit_rad"][1]) + float(rig.joints()[2]["limit_rad"][1])
		if (Basis(Vector3.LEFT, maximum_angle) * normal).dot(Vector3.DOWN) <= float(contract["interaction"]["dump_opening_down_dot"]):
			failures.append("corrected opening cannot reach a dumping orientation")
	var pins: Dictionary = manifest["passive_linkage"]["pin_paths_relative_to_arm"]
	var a := arm.to_local((arm.get_node(pins["A"]) as Node3D).global_position)
	var b := arm.to_local((arm.get_node(pins["B"]) as Node3D).global_position)
	var c_node := arm.get_node(pins["C"]) as Node3D
	var c := arm.to_local(c_node.global_position)
	var ab := Vector2(a.y, a.z).distance_to(Vector2(b.y, b.z))
	var ac := Vector2(a.y, a.z).distance_to(Vector2(c.y, c.z))
	for degree in range(-20, 96):
		bucket.basis = Basis(Vector3.LEFT, deg_to_rad(float(degree)))
		c = arm.to_local(c_node.global_position)
		var bc := Vector2(b.y, b.z).distance_to(Vector2(c.y, c.z))
		if bc > ab + ac or bc < absf(ab - ac):
			failures.append("passive linkage unreachable at %s degrees" % degree)
		for vertex in vertices:
			var rotated := bucket.basis * vertex
			# Exclude the shared pin neighborhood. Above it, the stick lies
			# inside x +/-0.18, z >= -0.088 in the imported bucket rest frame.
			if absf(rotated.x) < 0.18 and rotated.y > 0.55 and rotated.z > -0.12:
				failures.append("bucket enters the stick envelope at %s degrees" % degree)
				break
	asset.free()
	if failures.is_empty():
		print("sy205_bucket_geometry_test: PASS (imported teeth, blockers, full-range clearance/linkage)")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)

func _v(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))

func _surface_distance(point: Vector3, faces: Array[Vector3]) -> float:
	var nearest := INF
	for index in range(0, faces.size(), 3):
		var a := faces[index]
		var b := faces[index + 1]
		var c := faces[index + 2]
		var normal := (b - a).cross(c - a).normalized()
		var hit: Variant = Geometry3D.segment_intersects_triangle(point + normal * 3.0, point - normal * 3.0, a, b, c)
		if hit is Vector3:
			nearest = minf(nearest, point.distance_to(hit))
		for edge in [[a, b], [b, c], [c, a]]:
			nearest = minf(nearest, point.distance_to(Geometry3D.get_closest_point_to_segment(point, edge[0], edge[1])))
	return nearest

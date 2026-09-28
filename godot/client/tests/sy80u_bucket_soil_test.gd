extends SceneTree
## Regresses stale rim coordinates against the imported mesh, not the baked grid.
const Fill = preload("res://scripts/bucket_fill_surface.gd")
const Geometry = preload("res://scripts/bucket_soil_geometry.gd")
const Release = preload("res://scripts/bucket_soil_release.gd")
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var descriptor := SoilContractDescriptor.load_for_model("sy80u")
	if descriptor == null or not descriptor.is_valid_for("sy80u"):
		push_error("SY80U catalog/contract rejected")
		quit(1)
		return
	var contract := descriptor.to_dictionary()
	var geometry: Dictionary = contract.soil_geometry
	_check(FileAccess.get_sha256(geometry.source_glb_path) == geometry.source_glb_sha256, "source hash")
	var imported := load(geometry.source_glb_path).instantiate() as Node3D
	root.add_child(imported)
	var bucket := imported.find_child("PIVOT_BUCKET_JOINT", true, false) as Node3D
	var mesh := bucket.find_child("bucket", true, false) as MeshInstance3D
	var transform := bucket.global_transform.affine_inverse() * mesh.global_transform
	var local := Geometry.cavity(geometry)
	var faces := PackedVector3Array()
	var bucket_faces := PackedVector3Array()
	var bounds := AABB()
	for vertex in mesh.mesh.get_faces():
		var point := transform * vertex
		bounds = AABB(point, Vector3.ZERO) if bucket_faces.is_empty() else bounds.expand(point)
		bucket_faces.append(point)
		faces.append(local.affine_inverse() * point)
	for raw in geometry.mouth_polygon_godot:
		var anchor := Geometry.vector(raw)
		var distance := INF
		for point in bucket_faces:
			distance = minf(distance, anchor.distance_to(point))
		_check(distance < 0.002, "mouth anchor detached from source")
		_check(absf(anchor.x) < 0.394, "mouth uses inner edge, not outside cheeks")
		_check(anchor.z > -0.82, "tooth tips cannot define contained mouth")
	_check(Release.threshold(contract.interaction) == 0.5, "native release threshold changed")
	for angles in [Vector3.ZERO, Vector3(0.9, -0.3, 0.4), Vector3(-1.7, 0.8, -0.6)]:
		var pose := Transform3D(Basis.from_euler(angles), Vector3(4, 2, -3))
		var mouth: Transform3D = Geometry.mouth(geometry.mouth_polygon_godot).transform
		var normal := Release.opening_normal({"contract": contract, "current": {"opening": pose * mouth}})
		_check(normal.distance_to(pose.basis * Geometry.vector(contract.proxies.opening.normal_godot)) < 0.0001, "opening release axis")
	var surface := Fill.new()
	_check(surface.configure_contract(contract, Vector3.ONE), "fill profile failed")
	var previous_volume := 0.0
	var rim_height := float(geometry.cavity_depth_m) * 0.5
	for ratio in [0.005, 0.05, 0.25, 0.5, 0.75, 1.0]:
		var arrays := surface.build_arrays(ratio)
		_check(not arrays.is_empty(), "positive stock invisible")
		if arrays.is_empty():
			continue
		var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var volume := 0.0
		var edges := {}
		var ids := {}
		var unique: Array[Vector3] = []
		for index in range(0, points.size(), 3):
			var a := points[index]
			var b := points[index + 1]
			var c := points[index + 2]
			volume += a.dot(b.cross(c)) / 6.0
			_check((c - a).cross(b - a).dot(normals[index]) > 0, "inverted fill face")
			for point in [a, b, c]:
				_check(point.y <= rim_height - 0.0649, "fill crossed measured mouth")
				_check(bounds.grow(0.002).has_point(local * point), "soil slab outside bucket bounds")
			for edge in [[a, b], [b, c], [c, a]]:
				for point in edge:
					if not ids.has(point):
						ids[point] = ids.size()
						unique.append(point)
				var key := Vector2i(mini(ids[edge[0]], ids[edge[1]]), maxi(ids[edge[0]], ids[edge[1]]))
				edges[key] = int(edges.get(key, 0)) + 1
			if (index / 3) % 19 == 0:
				for point in [a, b, c, (a + b) * 0.5, (b + c) * 0.5, (a + c) * 0.5, (a + b + c) / 3]:
					var lining := _height(faces, point.x, point.z)
					_check(is_finite(lining) and point.y >= lining - 0.0005, "soil penetrated actual mesh lining")
		for key in edges:
			_check(edges[key] == 2 or unique[key.x].distance_to(unique[key.y]) < 0.00002, "open fill solid")
		_check(absf(volume) > previous_volume, "fill volume must grow with stock")
		previous_volume = absf(volume)
		_check(surface.build_arrays(ratio)[Mesh.ARRAY_VERTEX] == points, "nondeterministic fill")
	# Contact proxies follow imported teeth, inner side rims and physical plates.
	var tooth := Geometry.vector(contract.proxies.cutting_edge.center_godot)
	_check(absf(tooth.z - bounds.position.z) < 0.002, "teeth detached from source tips")
	var tool := BucketSoilTool.new()
	_check(tool.configure(contract), "tool configuration")
	for region in contract.bucket_tool.regions:
		if region.region_id in ["left_side_cutter", "right_side_cutter"]:
			var center := Geometry.vector(region.center_godot)
			var delta := Geometry.vector(region.shape.axis_godot) * float(region.shape.half_length_m)
			for point in [center - delta, center + delta]:
				_check(_surface_distance(point, bucket_faces) < 0.035, "side blade endpoint detached")
		elif region.region_id in ["floor_wear_plate", "outer_back"]:
			var frame := tool.region_local_transform(region)
			var half := Geometry.vector(region.shape.size_m) * 0.5
			for x in [-1, 0, 1]:
				for z in [-1, 0, 1]:
					_check(_surface_distance(frame * Vector3(half.x * x, 0, half.z * z), bucket_faces) < 0.05, "plate proxy detached from shell")
	imported.free()
	for failure in failures:
		push_error(failure)
	print("sy80u_bucket_soil_test: ", "PASS" if failures.is_empty() else "FAIL", " full visual volume=", previous_volume)
	quit(0 if failures.is_empty() else 1)


func _height(faces: PackedVector3Array, x: float, z: float) -> float:
	var height := -INF
	for index in range(0, faces.size(), 3):
		var hit: Variant = Geometry3D.segment_intersects_triangle(Vector3(x, 2, z), Vector3(x, -2, z), faces[index], faces[index + 1], faces[index + 2])
		if hit is Vector3:
			height = maxf(height, hit.y)
	return height


func _surface_distance(point: Vector3, faces: PackedVector3Array) -> float:
	var nearest := INF
	for index in range(0, faces.size(), 3):
		var a := faces[index]
		var b := faces[index + 1]
		var c := faces[index + 2]
		var normal := (b - a).cross(c - a).normalized()
		var hit: Variant = Geometry3D.segment_intersects_triangle(point + normal * 2, point - normal * 2, a, b, c)
		if hit is Vector3:
			nearest = minf(nearest, point.distance_to(hit))
		for edge in [[a, b], [b, c], [c, a]]:
			nearest = minf(nearest, point.distance_to(Geometry3D.get_closest_point_to_segment(point, edge[0], edge[1])))
	return nearest


func _check(condition: bool, message: String) -> void:
	if not condition and not failures.has(message):
		failures.append(message)

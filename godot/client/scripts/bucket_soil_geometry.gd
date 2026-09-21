extends RefCounted
## Shared, data-only mouth frame for baking, presentation and contract checks.
## v1 supports one convex planar opening and a lining representable as a height field.


static func mouth(raw: Variant) -> Dictionary:
	if not raw is Array or raw.size() < 3 or raw.size() > 32:
		return {}
	var points: Array[Vector3] = []
	var center := Vector3.ZERO
	for value in raw:
		if not valid_vector(value):
			return {}
		var point := vector(value)
		points.append(point)
		center += point
	center /= points.size()
	var width := points[1] - points[0]
	var normal := Vector3.ZERO
	for index in points.size():
		normal += (points[index] - center).cross(points[(index + 1) % points.size()] - center)
	if width.length() < 0.001 or normal.length() < 0.000001:
		return {}
	width = width.normalized()
	normal = normal.normalized()
	var depth := width.cross(normal).normalized()
	var basis := Basis(width, normal, depth).orthonormalized()
	var x_bounds := Vector2(INF, -INF)
	var z_bounds := Vector2(INF, -INF)
	for index in points.size():
		var a := points[index]
		var b := points[(index + 1) % points.size()]
		if a.distance_to(b) < 0.001 or absf(normal.dot(a - center)) > 0.002:
			return {}
		# Every other vertex must be on the inside of every edge. This also
		# rejects self-crossing/nonconvex polygons instead of inventing a mouth.
		for point in points:
			if (b - a).cross(point - a).dot(normal) < -0.000001:
				return {}
		var local := basis.inverse() * (a - center)
		x_bounds = Vector2(minf(x_bounds.x, local.x), maxf(x_bounds.y, local.x))
		z_bounds = Vector2(minf(z_bounds.x, local.z), maxf(z_bounds.y, local.z))
	return {"transform": Transform3D(basis, center), "points": points,
		"size": Vector2(x_bounds.y - x_bounds.x, z_bounds.y - z_bounds.x),
		"x_bounds": x_bounds, "z_bounds": z_bounds}


static func cavity(geometry: Dictionary) -> Transform3D:
	var shape := mouth(geometry.get("mouth_polygon_godot"))
	if shape.is_empty():
		return Transform3D.IDENTITY
	var frame: Transform3D = shape.transform
	frame.origin -= frame.basis.y * float(geometry.get("cavity_depth_m", 0.0)) * 0.5
	return frame


static func validate(geometry: Variant, contract: Dictionary, check_resources: bool = true) -> String:
	if not geometry is Dictionary:
		return "must be an object"
	var fields := ["schema_version", "mouth_polygon_godot", "cavity_depth_m",
		"fill_profile_path", "fill_profile_sha256", "source_glb_path", "source_glb_sha256"]
	for key in fields:
		if not geometry.has(key):
			return "missing " + key
	for key in geometry:
		if not fields.has(key):
			return "unknown field " + String(key)
	if geometry.schema_version != "bucket-soil-geometry-v1":
		return "unsupported schema"
	var shape := mouth(geometry.mouth_polygon_godot)
	if shape.is_empty():
		return "mouth must be a convex planar polygon with distinct ordered vertices"
	if not number(geometry.cavity_depth_m) or float(geometry.cavity_depth_m) <= 0.0:
		return "cavity depth must be positive"
	var frame: Transform3D = shape.transform
	var cavity_frame := cavity(geometry)
	var proxies: Dictionary = contract.get("proxies", {})
	for name in ["opening", "cavity"]:
		var proxy: Dictionary = proxies.get(name, {})
		var expected := frame if name == "opening" else cavity_frame
		if not valid_vector(proxy.get("center_godot")) or not vector(proxy.center_godot).is_equal_approx(expected.origin):
			return name + " center disagrees with mouth"
		if not valid_vector(proxy.get("up_godot")) or vector(proxy.up_godot).distance_to(frame.basis.y) > 0.0001:
			return name + " up disagrees with mouth"
	if not valid_vector(proxies.opening.get("normal_godot")) or vector(proxies.opening.normal_godot).distance_to(frame.basis.y) > 0.0001:
		return "opening normal disagrees with mouth"
	var opening_size: Array = proxies.opening.get("size_m", [])
	var cavity_size: Array = proxies.cavity.get("size_m", [])
	if opening_size.size() != 2 or cavity_size.size() != 3:
		return "invalid proxy sizes"
	if Vector2(opening_size[0], opening_size[1]).distance_to(shape.size) > 0.0001 \
			or vector(cavity_size).distance_to(Vector3(shape.size.x, geometry.cavity_depth_m, shape.size.y)) > 0.0001:
		return "proxy sizes disagree with mouth"
	for region in (contract.get("bucket_tool", {}) as Dictionary).get("regions", []):
		if region.get("region_id") in ["opening", "inner_shell"]:
			var expected := frame if region.region_id == "opening" else cavity_frame
			if not valid_vector(region.get("center_godot")) or vector(region.center_godot).distance_to(expected.origin) > 0.0001:
				return "semantic region center disagrees with mouth"
			if not valid_vector(region.get("outward_normal_godot")) or vector(region.outward_normal_godot).distance_to(frame.basis.y) > 0.0001:
				return "semantic region normal disagrees with mouth"
			if region.region_id == "opening":
				var axes: Dictionary = region.get("shape", {})
				if not valid_vector(axes.get("width_axis_godot")) or not valid_vector(axes.get("height_axis_godot")) \
						or vector(axes.width_axis_godot).distance_to(frame.basis.x) > 0.0001 or vector(axes.height_axis_godot).distance_to(frame.basis.z) > 0.0001:
					return "semantic opening axes disagree with mouth"
	for prefix in ["fill_profile", "source_glb"]:
		var path: Variant = geometry[prefix + "_path"]
		var hash_value: Variant = geometry[prefix + "_sha256"]
		if not path is String or not path.begins_with("res://") or ".." in path:
			return prefix + " path must be a project resource"
		if not hash_value is String or hash_value.length() != 64 or not hash_value.is_valid_hex_number(false):
			return prefix + " hash must be SHA-256"
		if check_resources and (not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != hash_value):
			return prefix + " resource hash mismatch"
	if not check_resources:
		return ""
	var profile: Variant = JSON.parse_string(FileAccess.get_file_as_string(geometry.fill_profile_path))
	return validate_profile(profile, geometry, contract)


static func validate_profile(profile: Variant, geometry: Dictionary, contract: Dictionary) -> String:
	if not profile is Dictionary or profile.get("schema_version") != "bucket-fill-profile-v1":
		return "invalid fill profile"
	if profile.get("coordinate_space") != "cavity_local" or profile.get("growth_direction_y") != 1.0:
		return "generated fill must grow along cavity +Y"
	if profile.get("clip_to_mouth_polygon") != true:
		return "generated fill must clip to the authoritative mouth"
	for dimension in ["columns", "rows"]:
		if not number(profile.get(dimension)) or float(profile[dimension]) != floorf(profile[dimension]) or int(profile[dimension]) < 3 or int(profile[dimension]) > 129:
			return "invalid profile grid"
	for key in ["x_bounds", "z_bounds"]:
		var bounds: Variant = profile.get(key)
		if not bounds is Array or bounds.size() != 2 or not number(bounds[0]) or not number(bounds[1]) or bounds[0] >= bounds[1]:
			return "invalid profile bounds"
	if not number(profile.get("rim_height")) or absf(float(profile.rim_height) - float(geometry.cavity_depth_m) * 0.5) > 0.0001:
		return "invalid profile rim height"
	var floors: Variant = profile.get("floor_heights")
	if not floors is Array or floors.size() != int(profile.columns) * int(profile.rows):
		return "invalid profile floor grid"
	for height in floors:
		if not number(height):
			return "nonfinite profile floor"
	if profile.get("model_id") != contract.get("fill_profile_id") or profile.get("source_sha256") != geometry.source_glb_sha256:
		return "fill profile identity/source mismatch"
	var frame := cavity(geometry)
	if not valid_vector(profile.get("cavity_center_godot")) or vector(profile.cavity_center_godot).distance_to(frame.origin) > 0.0001:
		return "fill profile cavity center mismatch"
	if not valid_vector(profile.get("cavity_up_godot")) or vector(profile.cavity_up_godot).distance_to(frame.basis.y) > 0.0001:
		return "fill profile cavity up mismatch"
	var rim: Variant = profile.get("body_opening_rim_cavity_local")
	if not rim is Array or rim.size() != geometry.mouth_polygon_godot.size():
		return "fill profile rim mismatch"
	for index in rim.size():
		if not valid_vector(rim[index]) or (frame * vector(rim[index])).distance_to(vector(geometry.mouth_polygon_godot[index])) > 0.0001:
			return "fill profile rim mismatch"
	return ""


static func vector(value: Array) -> Vector3:
	return Vector3(value[0], value[1], value[2])


static func array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]


static func number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))


static func valid_vector(value: Variant) -> bool:
	return value is Array and value.size() == 3 and number(value[0]) and number(value[1]) and number(value[2])

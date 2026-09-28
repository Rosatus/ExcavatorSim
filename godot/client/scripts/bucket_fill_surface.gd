extends RefCounted
## Disposable visual solid clipped between the measured lining and a soil surface.
## Profiles are in cavity-local coordinates; they never change the soil contract.

const PROFILE_PATHS := {
	"sy135": "res://resources/visual/sy135_bucket_fill_profile.json",
	"sy135neo": "res://resources/visual/sy135neo_bucket_fill_profile.json",
	"sy80u": "res://resources/visual/sy80u_bucket_fill_profile.json",
	"sy205": "res://resources/visual/sy205_bucket_fill_profile.json",
}
const SURFACE_RELIEF_M := 0.065
const CONTACT_OVERLAP_M := 0.002
const LINING_CLEARANCE_M := 0.003
const Geometry = preload("res://scripts/bucket_soil_geometry.gd")

var _columns := 0
var _rows := 0
var _direction := 1.0
var _body_opening := Plane()
var _has_body_opening := false
var _mouth_boundary: Array[Vector2] = []
var _x_bounds := Vector2.ZERO
var _z_bounds := Vector2.ZERO
var _floors := PackedFloat32Array()
var _relief := PackedFloat32Array()
var _minimum_level := 0.0
var _full_level := 0.0
var _full_weight := 0.0
var _vertices := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()
var _indices := PackedInt32Array()
var _appearance: Dictionary = {}


func configure_contract(contract: Dictionary, cavity_size: Vector3) -> bool:
	_full_weight = 0.0
	if not contract.has("soil_geometry"):
		return configure(String(contract.get("fill_profile_id", contract.get("model_id", ""))), cavity_size)
	var geometry: Variant = contract.soil_geometry
	if not Geometry.validate(geometry, contract).is_empty():
		return false
	var profile: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(geometry.fill_profile_path))
	return _configure_profile(profile)


func configure(model_id: String, cavity_size: Vector3) -> bool:
	_full_weight = 0.0
	var profile: Dictionary
	if PROFILE_PATHS.has(model_id):
		profile = JSON.parse_string(FileAccess.get_file_as_string(PROFILE_PATHS[model_id])) as Dictionary
	elif model_id.is_empty():
		# Anonymous legacy/test snapshots have no asset to calibrate against.
		profile = _generic_profile(cavity_size)
	else:
		return false
	return _configure_profile(profile)


func _configure_profile(profile: Dictionary) -> bool:
	_full_weight = 0.0
	_columns = int(profile.get("columns", 0))
	_rows = int(profile.get("rows", 0))
	_floors = PackedFloat32Array(profile.get("floor_heights", []))
	if _columns < 3 or _rows < 3 or _floors.size() != _columns * _rows:
		return false
	_direction = float(profile["growth_direction_y"])
	_x_bounds = Vector2(float(profile["x_bounds"][0]), float(profile["x_bounds"][1]))
	_z_bounds = Vector2(float(profile["z_bounds"][0]), float(profile["z_bounds"][1]))
	var rim: Array = profile.get("body_opening_rim_cavity_local", [])
	_has_body_opening = rim.size() >= 3
	_mouth_boundary.clear()
	if bool(profile.get("clip_to_mouth_polygon", false)):
		for point in rim:
			_mouth_boundary.append(Vector2(point[0], point[2]))
	_full_level = float(profile["rim_height"]) - SURFACE_RELIEF_M
	if _has_body_opening:
		var points: Array[Vector3] = []
		for point in rim:
			points.append(Vector3(point[0], point[1], point[2]))
		_body_opening = Plane(points[0], points[1], points[2])
		if not _mouth_boundary.is_empty():
			var measured := Geometry.mouth(rim)
			if measured.is_empty():
				return false
			var frame: Transform3D = measured.transform
			_body_opening = Plane(frame.basis.y, frame.origin)
		if absf(_body_opening.normal.y) < 0.001:
			return false
		# The measured body rim excludes teeth. Move the free plane inward by
		# the existing clearance, without rotating or translating the lining.
		_full_level = _direction * _body_opening.d / _body_opening.normal.y - SURFACE_RELIEF_M / absf(_body_opening.normal.y)
	_minimum_level = INF
	_full_weight = 0.0
	if _has_body_opening:
		# A linear grid cell can bridge the sharp lip/back-wall transitions
		# between ray samples. Use the surrounding lining envelope so that
		# those interpolated triangles remain on the cavity side of the shell.
		var measured := _floors.duplicate()
		for row in _rows:
			for column in _columns:
				var index := row * _columns + column
				for neighbor_row in range(maxi(0, row - 1), mini(_rows, row + 2)):
					for neighbor_column in range(maxi(0, column - 1), mini(_columns, column + 2)):
						_floors[index] = maxf(_floors[index], measured[neighbor_row * _columns + neighbor_column])
	_relief.resize(_floors.size())
	for row in _rows:
		for column in _columns:
			var index := row * _columns + column
			var point := _grid_position(column, row)
			# SY135's thin lining cannot hide an outward contact overlap. Move
			# the clipping floor inward too, so the closed edge stays contained.
			if _has_body_opening:
				_floors[index] += LINING_CLEARANCE_M
			_relief[index] = _surface_relief(point.x, point.y)
			_minimum_level = minf(_minimum_level, _floors[index] - _relief[index])
			_full_weight += maxf(0.0, _full_level + _relief[index] - _floors[index])
	return _full_weight > 0.0


func build_arrays(fill_ratio: float) -> Array:
	# Shared vertices occur in adjacent triangles and both skins. Cache only
	# within this build: clipped x/z positions can change with the fill level.
	_appearance.clear()
	_vertices.clear()
	_normals.clear()
	_colors.clear()
	_indices.clear()
	if fill_ratio <= 0.0 or _full_weight <= 0.0:
		return []
	# Invert a bounded volume estimate. Raising this one level adds material at
	# every occupied sample instead of scaling a floating lump in three axes.
	var low := _minimum_level
	var high := _full_level
	var target := clampf(fill_ratio, 0.0, 1.0) * _full_weight
	for iteration in 14:
		var middle := (low + high) * 0.5
		var weight := 0.0
		for index in _floors.size():
			weight += maxf(0.0, middle + _relief[index] - _floors[index])
		if weight < target:
			low = middle
		else:
			high = middle
	var level := (low + high) * 0.5
	var samples: Array[Vector4] = []
	for row in _rows:
		for column in _columns:
			samples.append(_sample(column, row, level))
	for row in _rows - 1:
		for column in _columns - 1:
			var index := row * _columns + column
			var a := samples[index]
			var b := samples[index + 1]
			var c := samples[index + _columns]
			var d := samples[index + _columns + 1]
			_append_clipped([a, c, b])
			_append_clipped([b, c, d])
	if _vertices.is_empty():
		return []
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _vertices
	arrays[Mesh.ARRAY_NORMAL] = _normals
	arrays[Mesh.ARRAY_COLOR] = _colors
	arrays[Mesh.ARRAY_INDEX] = _indices
	return arrays


func _grid_position(column: int, row: int) -> Vector2:
	return Vector2(
		lerpf(_x_bounds.x, _x_bounds.y, float(column) / float(_columns - 1)),
		lerpf(_z_bounds.x, _z_bounds.y, float(row) / float(_rows - 1))
	)


func _sample(column: int, row: int, level: float) -> Vector4:
	var index := row * _columns + column
	var point := _grid_position(column, row)
	# x/z position, lining height, soil height (along the growth direction).
	return Vector4(point.x, point.y, _floors[index], level + _relief[index])


func _append_clipped(triangle: Array[Vector4]) -> void:
	var polygon: Array[Vector4] = []
	var previous := triangle.back() as Vector4
	var previous_depth := previous.w - previous.z
	for current in triangle:
		var depth := current.w - current.z
		if (depth > 0.0) != (previous_depth > 0.0):
			polygon.append(_intersection(previous, current))
		if depth > 0.0:
			polygon.append(current)
		previous = current
		previous_depth = depth
	if not _mouth_boundary.is_empty():
		polygon = _clip_to_mouth(polygon)
	# At every clipped edge top == bottom, so the two skins close without a
	# rectangular skirt. Profile borders are above the maximum soil surface.
	for index in range(1, polygon.size() - 1):
		_append_face(polygon[0], polygon[index], polygon[index + 1], true)
		_append_face(polygon[0], polygon[index], polygon[index + 1], false)


func _clip_to_mouth(polygon: Array[Vector4]) -> Array[Vector4]:
	var signed_area := 0.0
	for index in _mouth_boundary.size():
		signed_area += _mouth_boundary[index].cross(_mouth_boundary[(index + 1) % _mouth_boundary.size()])
	for index in _mouth_boundary.size():
		if polygon.is_empty():
			break
		var start := _mouth_boundary[index]
		var edge := _mouth_boundary[(index + 1) % _mouth_boundary.size()] - start
		var clipped: Array[Vector4] = []
		var previous := polygon.back() as Vector4
		var previous_distance := edge.cross(Vector2(previous.x, previous.y) - start) * signf(signed_area)
		for point in polygon:
			var distance := edge.cross(Vector2(point.x, point.y) - start) * signf(signed_area)
			if (distance >= 0.0) != (previous_distance >= 0.0):
				var hit := previous.lerp(point, previous_distance / (previous_distance - distance))
				# A clipped perimeter must close top against bottom. The baker
				# keeps lining above full level outside the mouth, so this is a
				# final bound for interpolated cells at the polygon boundary.
				hit.w = hit.z
				clipped.append(hit)
			if distance >= 0.0:
				clipped.append(point)
			previous = point
			previous_distance = distance
		polygon = clipped
	return polygon


func _intersection(a: Vector4, b: Vector4) -> Vector4:
	# Adjacent triangles traverse their shared edge in opposite directions.
	# Canonical endpoint order gives them exactly the same clipped vertex.
	if a.x > b.x or (a.x == b.x and a.y > b.y):
		var swap := a
		a = b
		b = swap
	var depth_a := a.w - a.z
	var depth_b := b.w - b.z
	var edge := a.lerp(b, depth_a / (depth_a - depth_b))
	edge.w = edge.z
	return edge


func _append_face(a: Vector4, b: Vector4, c: Vector4, top: bool) -> void:
	var points: Array[Vector3] = [_position(a, top), _position(b, top), _position(c, top)]
	var normal := (points[2] - points[0]).cross(points[1] - points[0])
	if normal.length_squared() < 1.0e-20:
		return
	var outward_y := _direction if top else -_direction
	# Godot front faces are clockwise. Winding and supplied normals must agree,
	# including SY135's negative growth direction and the underside.
	if normal.y * outward_y < 0.0:
		points.reverse()
		normal = -normal
	var face_normal := normal.normalized()
	for point in points:
		var key := Vector2(point.x, point.z)
		if not _appearance.has(key):
			var shade := 0.94 + 0.055 * sin(point.x * 23.0 + point.z * 17.0) * sin(point.z * 29.0 - point.x * 11.0)
			_appearance[key] = [_surface_normal(point.x, point.z), Color(shade, shade, shade, 1.0)]
		var appearance: Array = _appearance[key]
		_indices.append(_vertices.size())
		_vertices.append(point)
		_normals.append(appearance[0] if top else face_normal)
		_colors.append(appearance[1])


func _position(sample: Vector4, top: bool) -> Vector3:
	var overlap := 0.0 if _has_body_opening else CONTACT_OVERLAP_M
	var height := sample.w if top else sample.z - overlap * clampf((sample.w - sample.z) / 0.01, 0.0, 1.0)
	return Vector3(sample.x, _direction * height, sample.y)


func _surface_relief(x: float, z: float) -> float:
	if _has_body_opening:
		return -_direction * (_body_opening.normal.x * x + _body_opening.normal.z * z) / _body_opening.normal.y
	var nx := (x - (_x_bounds.x + _x_bounds.y) * 0.5) / ((_x_bounds.y - _x_bounds.x) * 0.5)
	var nz := (z - (_z_bounds.x + _z_bounds.y) * 0.5) / ((_z_bounds.y - _z_bounds.x) * 0.5)
	var mound := maxf(0.0, (1.0 - nx * nx) * (1.0 - nz * nz))
	return 0.014 + 0.035 * mound + 0.009 * sin(x * 19.0 + z * 7.0) * sin(z * 13.0 - x * 4.0)


func _surface_normal(x: float, z: float) -> Vector3:
	const STEP := 0.005
	var dx := (_surface_relief(x + STEP, z) - _surface_relief(x - STEP, z)) / (2.0 * STEP)
	var dz := (_surface_relief(x, z + STEP) - _surface_relief(x, z - STEP)) / (2.0 * STEP)
	return Vector3(-dx, _direction, -dz).normalized()


func _generic_profile(size: Vector3) -> Dictionary:
	var floors: Array[float] = []
	for row in 9:
		for column in 9:
			var x := float(column - 4) / 4.0
			var z := float(row - 4) / 4.0
			floors.append(size.y * (-0.44 + 0.16 * (x * x + z * z)) if row > 0 and row < 8 and column > 0 and column < 8 else size.y * 0.5)
	return {
		"columns": 9, "rows": 9, "growth_direction_y": 1.0,
		"x_bounds": [-0.48 * size.x, 0.48 * size.x],
		"z_bounds": [-0.48 * size.z, 0.48 * size.z],
		"rim_height": 0.4 * size.y, "floor_heights": floors,
	}

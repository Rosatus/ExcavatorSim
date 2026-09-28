extends "res://scripts/bucket_fill_surface.gd"

## Frozen pre-cache mesh generation for exact vertex/normal/color/index parity.

func build_arrays(fill_ratio: float) -> Array:
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
	for row in _rows - 1:
		for column in _columns - 1:
			var a := _sample(column, row, level)
			var b := _sample(column + 1, row, level)
			var c := _sample(column, row + 1, level)
			var d := _sample(column + 1, row + 1, level)
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
	for point in points:
		_indices.append(_vertices.size())
		_vertices.append(point)
		_normals.append(_surface_normal(point.x, point.z) if top else normal.normalized())
		var shade := 0.94 + 0.055 * sin(point.x * 23.0 + point.z * 17.0) * sin(point.z * 29.0 - point.x * 11.0)
		_colors.append(Color(shade, shade, shade, 1.0))


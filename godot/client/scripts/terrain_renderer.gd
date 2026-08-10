class_name TerrainRenderer
extends MeshInstance3D

## A generation-gated derived mesh owner. It never writes to TerrainState.
var _pending_snapshot: Dictionary = {}
var _latest_queued_generation := -1
var _latest_queued_revision := -1
var _applied_generation := -1
var _applied_revision := -1


func queue_snapshot(snapshot: Dictionary) -> bool:
	if not _is_snapshot_valid(snapshot):
		return false
	var generation := int(snapshot["world_generation"])
	var revision := int(snapshot["terrain_revision"])
	if generation < _latest_queued_generation:
		return false
	if generation == _latest_queued_generation and revision <= _latest_queued_revision:
		return false
	_pending_snapshot = snapshot.duplicate(true)
	_pending_snapshot["surface"] = (snapshot["surface"] as PackedFloat32Array).duplicate()
	_pending_snapshot["surface_bytes"] = (snapshot["surface_bytes"] as PackedByteArray).duplicate()
	_latest_queued_generation = generation
	_latest_queued_revision = revision
	return true


func apply_pending() -> bool:
	if _pending_snapshot.is_empty():
		return false
	var snapshot := _pending_snapshot
	_pending_snapshot = {}
	var generation := int(snapshot["world_generation"])
	var revision := int(snapshot["terrain_revision"])
	if generation != _latest_queued_generation or revision != _latest_queued_revision:
		return false
	if generation < _applied_generation or (generation == _applied_generation and revision <= _applied_revision):
		return false
	var derived_mesh := _build_mesh(snapshot)
	if derived_mesh == null:
		return false
	mesh = derived_mesh
	_applied_generation = generation
	_applied_revision = revision
	return true


func get_applied_identity() -> Vector2i:
	return Vector2i(_applied_generation, _applied_revision)


func _build_mesh(snapshot: Dictionary) -> ArrayMesh:
	var rows := int(snapshot["rows"])
	var columns := int(snapshot["columns"])
	var spacing := float(snapshot["spacing_m"])
	var origin: Vector2 = snapshot["origin_xz"]
	var surface: PackedFloat32Array = snapshot["surface"]
	if rows < 2 or columns < 2 or surface.size() != rows * columns or spacing <= 0.0:
		return null
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	vertices.resize(surface.size())
	normals.resize(surface.size())
	uvs.resize(surface.size())
	for row in rows:
		for column in columns:
			var index := row * columns + column
			vertices[index] = Vector3(origin.x + float(column) * spacing, surface[index], origin.y + float(row) * spacing)
			uvs[index] = Vector2(float(column) / float(columns - 1), float(row) / float(rows - 1))
			normals[index] = _normal_at(surface, rows, columns, row, column, spacing)
	var indices := PackedInt32Array()
	indices.resize((rows - 1) * (columns - 1) * 6)
	var write_index := 0
	for row in range(rows - 1):
		for column in range(columns - 1):
			var top_left := row * columns + column
			var bottom_left := top_left + columns
			indices[write_index] = top_left
			indices[write_index + 1] = bottom_left
			indices[write_index + 2] = top_left + 1
			indices[write_index + 3] = top_left + 1
			indices[write_index + 4] = bottom_left
			indices[write_index + 5] = bottom_left + 1
			write_index += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result


func _normal_at(surface: PackedFloat32Array, rows: int, columns: int, row: int, column: int, spacing: float) -> Vector3:
	var left := surface[row * columns + max(0, column - 1)]
	var right := surface[row * columns + min(columns - 1, column + 1)]
	var up := surface[max(0, row - 1) * columns + column]
	var down := surface[min(rows - 1, row + 1) * columns + column]
	var x_span := spacing * float(2 if column > 0 and column < columns - 1 else 1)
	var z_span := spacing * float(2 if row > 0 and row < rows - 1 else 1)
	return Vector3(-(right - left) / x_span, 1.0, -(down - up) / z_span).normalized()


func _is_snapshot_valid(snapshot: Dictionary) -> bool:
	return snapshot.has_all(["world_generation", "terrain_revision", "rows", "columns", "spacing_m", "origin_xz", "surface", "surface_bytes"])

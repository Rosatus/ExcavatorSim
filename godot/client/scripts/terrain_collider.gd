class_name TerrainCollider
extends Node3D

## Optional derived collision. It is fail-open and never feeds contact back to
## TerrainState or the Python service.
@export var enabled := false
@export var chunk_size_cells := 32

var available := false
var _pending_snapshot: Dictionary = {}
var _queued_generation := -1
var _queued_revision := -1
var _applied_generation := -1
var _applied_revision := -1
var _body: StaticBody3D


func queue_snapshot(snapshot: Dictionary) -> bool:
	if not _is_snapshot_valid(snapshot):
		return false
	var generation := int(snapshot["world_generation"])
	var revision := int(snapshot["terrain_revision"])
	if generation < _queued_generation or (generation == _queued_generation and revision <= _queued_revision):
		return false
	_pending_snapshot = snapshot.duplicate(true)
	_pending_snapshot["surface"] = (snapshot["surface"] as PackedFloat32Array).duplicate()
	_queued_generation = generation
	_queued_revision = revision
	return true


func apply_pending() -> bool:
	if _pending_snapshot.is_empty():
		return false
	var snapshot := _pending_snapshot
	_pending_snapshot = {}
	var generation := int(snapshot["world_generation"])
	var revision := int(snapshot["terrain_revision"])
	if generation != _queued_generation or revision != _queued_revision:
		return false
	if generation < _applied_generation or (generation == _applied_generation and revision <= _applied_revision):
		return false
	if not enabled:
		available = false
		# Keep the pending copy so enabling the optional adapter later can build
		# the latest generation without requiring a second terrain mutation.
		_pending_snapshot = snapshot
		return false
	var next_body := _build_body(snapshot)
	if next_body == null:
		available = false
		return false
	add_child(next_body)
	if _body != null:
		_body.queue_free()
	_body = next_body
	available = true
	_applied_generation = generation
	_applied_revision = revision
	return true


func disable_for_test() -> void:
	enabled = false
	available = false
	if _body != null:
		_body.queue_free()
		_body = null
	_pending_snapshot.clear()
	_queued_generation = -1
	_queued_revision = -1
	_applied_generation = -1
	_applied_revision = -1


func get_applied_identity() -> Vector2i:
	return Vector2i(_applied_generation, _applied_revision)


func _build_body(snapshot: Dictionary) -> StaticBody3D:
	var rows := int(snapshot["rows"])
	var columns := int(snapshot["columns"])
	var spacing := float(snapshot["spacing_m"])
	var origin: Vector2 = snapshot["origin_xz"]
	var surface: PackedFloat32Array = snapshot["surface"]
	if rows < 2 or columns < 2 or surface.size() != rows * columns or spacing <= 0.0:
		return null
	var body := StaticBody3D.new()
	body.name = "TerrainStaticCollider"
	var chunk_size := maxi(2, chunk_size_cells)
	for row_start in range(0, rows - 1, chunk_size):
		for column_start in range(0, columns - 1, chunk_size):
			var faces := PackedVector3Array()
			var row_end := mini(rows - 1, row_start + chunk_size)
			var column_end := mini(columns - 1, column_start + chunk_size)
			for row in range(row_start, row_end):
				for column in range(column_start, column_end):
					var top_left := row * columns + column
					var bottom_left := top_left + columns
					faces.append(_vertex(origin, spacing, row, column, surface[top_left]))
					faces.append(_vertex(origin, spacing, row + 1, column, surface[bottom_left]))
					faces.append(_vertex(origin, spacing, row, column + 1, surface[top_left + 1]))
					faces.append(_vertex(origin, spacing, row, column + 1, surface[top_left + 1]))
					faces.append(_vertex(origin, spacing, row + 1, column, surface[bottom_left]))
					faces.append(_vertex(origin, spacing, row + 1, column + 1, surface[bottom_left + 1]))
			if faces.is_empty():
				continue
			var collision := CollisionShape3D.new()
			var shape := ConcavePolygonShape3D.new()
			shape.set_faces(faces)
			collision.shape = shape
			collision.name = "Chunk_%d_%d" % [row_start, column_start]
			body.add_child(collision)
	return body if body.get_child_count() > 0 else null


func _vertex(origin: Vector2, spacing: float, row: int, column: int, height: float) -> Vector3:
	return Vector3(origin.x + float(column) * spacing, height, origin.y + float(row) * spacing)


func _is_snapshot_valid(snapshot: Dictionary) -> bool:
	return snapshot.has_all(["world_generation", "terrain_revision", "rows", "columns", "spacing_m", "origin_xz", "surface"])

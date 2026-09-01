class_name TerrainCollider
extends Node3D

## Optional derived collision. It is fail-open and never feeds contact back to
## TerrainState or the Python service.
##
## Ordinary revisions swap only dirty chunk shapes transactionally: replacement
## shapes are built before anything is touched, then installed into the stable
## StaticBody3D, and the applied (generation, revision) identity advances only
## after every dirty chunk is installed. A failed install retains the previous
## chunks and leaves the identity behind so contact queries fail closed until a
## full rebuild succeeds.
@export var enabled := false
@export var chunk_size_cells := 16

var available := false
## True while the last accepted revision could not be fully installed. The
## applied identity intentionally lags so consumers fail closed.
var is_stale := false
var _pending_snapshot: Dictionary = {}
var _pending_full := true
var _queued_generation := -1
var _queued_revision := -1
var _applied_generation := -1
var _applied_revision := -1
var _body: StaticBody3D
## Stable chunk partition keyed by Vector2i(row_start, column_start).
var _chunks: Dictionary = {}
var _prepared_snapshot: Dictionary = {}
var _prepared_replacements: Dictionary = {}
var _prepared_full := false
var _fail_next_prepare_for_test := false
var _fail_next_install_for_test := false


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
	_pending_full = _requires_full_rebuild(snapshot)
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
	if not _ensure_body():
		is_stale = _applied_revision >= 0
		available = false
		_roll_back_queue_gate()
		return false
	if not _install_chunks(snapshot, _pending_full):
		# Retain the previous chunks and keep the old identity so bucket
		# queries and tracked support fail closed until a full rebuild
		# succeeds. available reports "converged body exists", so it drops
		# even though the retired geometry is still physically present.
		is_stale = true
		available = false
		# Roll the queue gate back to the applied identity so the same or any
		# later revision can be re-queued for recovery.
		_roll_back_queue_gate()
		return false
	is_stale = false
	available = true
	_applied_generation = generation
	_applied_revision = revision
	return true


## Builds every collision shape for a candidate terrain revision without
## advancing collision identity or mutating installed chunks.
func prepare_snapshot(snapshot: Dictionary) -> bool:
	discard_prepared()
	if _fail_next_prepare_for_test:
		_fail_next_prepare_for_test = false
		return false
	if not enabled or not _is_snapshot_valid(snapshot):
		return false
	var generation := int(snapshot["world_generation"])
	var revision := int(snapshot["terrain_revision"])
	if generation < _applied_generation or (generation == _applied_generation and revision <= _applied_revision):
		return false
	var full_rebuild := _requires_full_rebuild(snapshot)
	var replacements := _build_chunk_replacements(snapshot, full_rebuild)
	if replacements.is_empty():
		return false
	_prepared_snapshot = snapshot.duplicate(true)
	_prepared_snapshot["surface"] = (snapshot["surface"] as PackedFloat32Array).duplicate()
	_prepared_replacements = replacements
	_prepared_full = full_rebuild
	return true


## Installs a previously prepared candidate. No geometry construction remains
## in this phase; a successful return makes the revision query-eligible.
func install_prepared(snapshot: Dictionary) -> bool:
	if _prepared_snapshot.is_empty():
		return false
	if _fail_next_install_for_test:
		_fail_next_install_for_test = false
		discard_prepared()
		return false
	var generation := int(snapshot.get("world_generation", -1))
	var revision := int(snapshot.get("terrain_revision", -1))
	if generation != int(_prepared_snapshot.get("world_generation", -2)) or revision != int(_prepared_snapshot.get("terrain_revision", -2)):
		discard_prepared()
		return false
	if String(snapshot.get("snapshot_sha256", "")) != String(_prepared_snapshot.get("snapshot_sha256", "")):
		discard_prepared()
		return false
	if not _ensure_body() or not _install_replacements(_prepared_replacements, _prepared_full):
		discard_prepared()
		is_stale = true
		available = false
		return false
	_applied_generation = generation
	_applied_revision = revision
	_queued_generation = generation
	_queued_revision = revision
	is_stale = false
	available = true
	discard_prepared()
	return true


## Compensates a scheduler invariant failure after a prepared candidate was
## installed but before TerrainState accepted it. This deliberately permits
## restoring the immediately previous identity and rebuilds every chunk.
func restore_snapshot(snapshot: Dictionary) -> bool:
	discard_prepared()
	if not enabled or not _is_snapshot_valid(snapshot):
		return false
	var replacements := _build_chunk_replacements(snapshot, true)
	if replacements.is_empty() or not _ensure_body() or not _install_replacements(replacements, true):
		is_stale = true
		available = false
		return false
	_applied_generation = int(snapshot["world_generation"])
	_applied_revision = int(snapshot["terrain_revision"])
	_queued_generation = _applied_generation
	_queued_revision = _applied_revision
	is_stale = false
	available = true
	return true


func discard_prepared() -> void:
	_prepared_snapshot.clear()
	_prepared_replacements.clear()
	_prepared_full = false


func fail_next_prepare_for_test() -> void:
	_fail_next_prepare_for_test = true


func fail_next_install_for_test() -> void:
	_fail_next_install_for_test = true


## Restores the queue gate to the last successfully applied identity.
func _roll_back_queue_gate() -> void:
	if _applied_revision >= 0:
		_queued_generation = _applied_generation
		_queued_revision = _applied_revision


func disable_for_test() -> void:
	enabled = false
	available = false
	is_stale = false
	if _body != null:
		_body.queue_free()
		_body = null
	_chunks.clear()
	_pending_snapshot.clear()
	discard_prepared()
	_pending_full = true
	_queued_generation = -1
	_queued_revision = -1
	_applied_generation = -1
	_applied_revision = -1


func get_applied_identity() -> Vector2i:
	return Vector2i(_applied_generation, _applied_revision)


func get_chunk_count() -> int:
	return _chunks.size()


func get_chunk_shape(key: Vector2i) -> CollisionShape3D:
	return _chunks.get(key)


func get_status_snapshot() -> Dictionary:
	return {
		"enabled": enabled,
		"available": available,
		"is_stale": is_stale,
		"chunk_count": _chunks.size(),
		"applied_generation": _applied_generation,
		"applied_revision": _applied_revision,
		"prepared_generation": int(_prepared_snapshot.get("world_generation", -1)),
		"prepared_revision": int(_prepared_snapshot.get("terrain_revision", -1)),
	}


func _ensure_body() -> bool:
	if _body != null and is_instance_valid(_body):
		return true
	# One stable body owns every chunk for the lifetime of this collider;
	# revisions never replace it.
	_body = StaticBody3D.new()
	_body.name = "TerrainStaticCollider"
	add_child(_body)
	return true


## Installs the snapshot's collision chunks. Full rebuilds replace every chunk
## shape; ordinary patches rebuild only the chunks overlapped by the dirty halo
## rectangle (which already includes the one-cell seam ring). All replacement
## shapes are built before any node is mutated, so a build failure cannot leave
## a half-swapped state behind.
func _install_chunks(snapshot: Dictionary, full_rebuild: bool) -> bool:
	var replacements := _build_chunk_replacements(snapshot, full_rebuild)
	if replacements.is_empty():
		return false
	return _install_replacements(replacements, full_rebuild)


func _build_chunk_replacements(snapshot: Dictionary, full_rebuild: bool) -> Dictionary:
	var rows := int(snapshot["rows"])
	var columns := int(snapshot["columns"])
	var spacing := float(snapshot["spacing_m"])
	var origin: Vector2 = snapshot["origin_xz"]
	var surface: PackedFloat32Array = snapshot["surface"]
	if rows < 2 or columns < 2 or surface.size() != rows * columns or spacing <= 0.0:
		return {}
	var chunk := maxi(2, chunk_size_cells)
	var target_keys: Array[Vector2i] = []
	if full_rebuild:
		for row_start in range(0, rows - 1, chunk):
			for column_start in range(0, columns - 1, chunk):
				target_keys.append(Vector2i(row_start, column_start))
	else:
		target_keys = _dirty_chunk_keys(snapshot, rows, columns, chunk)
		if target_keys.is_empty():
			return {}
	# Build phase: construct every replacement shape without touching nodes.
	var replacements: Dictionary = {}
	for key in target_keys:
		var shape := _build_chunk_shape(key, rows, columns, spacing, origin, surface, chunk)
		if shape == null:
			return {}
		replacements[key] = shape
	return replacements


func _install_replacements(replacements: Dictionary, full_rebuild: bool) -> bool:
	# Swap phase: install replacements, add missing chunks, retire obsolete ones.
	for key in replacements:
		var node := _chunks.get(key) as CollisionShape3D
		if node == null or not is_instance_valid(node):
			node = CollisionShape3D.new()
			node.name = "Chunk_%d_%d" % [key.x, key.y]
			_chunks[key] = node
			_body.add_child(node)
		node.shape = replacements[key]
	if full_rebuild:
		for key in _chunks.keys():
			if not replacements.has(key):
				var retired := _chunks[key] as CollisionShape3D
				if retired != null and is_instance_valid(retired):
					retired.queue_free()
				_chunks.erase(key)
	return true


## Maps the dirty halo rectangle onto affected chunk keys plus the neighboring
## ring of shared-edge chunks.
func _dirty_chunk_keys(snapshot: Dictionary, rows: int, columns: int, chunk: int) -> Array[Vector2i]:
	var keys: Array[Vector2i] = []
	var dirty: Rect2i = snapshot.get("dirty_rect_with_halo", Rect2i())
	if dirty.size.x <= 0 or dirty.size.y <= 0:
		return keys
	var chunk_rows := ceili(float(rows - 1) / float(chunk))
	var chunk_columns := ceili(float(columns - 1) / float(chunk))
	var min_row_chunk := clampi(dirty.position.y / chunk, 0, chunk_rows - 1)
	var max_row_chunk := clampi((dirty.position.y + dirty.size.y - 1) / chunk, 0, chunk_rows - 1)
	var min_column_chunk := clampi(dirty.position.x / chunk, 0, chunk_columns - 1)
	var max_column_chunk := clampi((dirty.position.x + dirty.size.x - 1) / chunk, 0, chunk_columns - 1)
	for row_chunk in range(min_row_chunk, max_row_chunk + 1):
		for column_chunk in range(min_column_chunk, max_column_chunk + 1):
			keys.append(Vector2i(row_chunk * chunk, column_chunk * chunk))
	return keys


func _build_chunk_shape(
	key: Vector2i,
	rows: int,
	columns: int,
	spacing: float,
	origin: Vector2,
	surface: PackedFloat32Array,
	chunk: int
) -> ConcavePolygonShape3D:
	var row_start := key.x
	var column_start := key.y
	if row_start >= rows - 1 or column_start >= columns - 1:
		return null
	var faces := PackedVector3Array()
	var row_end := mini(rows - 1, row_start + chunk)
	var column_end := mini(columns - 1, column_start + chunk)
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
		return null
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	return shape


func _requires_full_rebuild(snapshot: Dictionary) -> bool:
	if bool(snapshot.get("full_refresh", true)):
		return true
	if int(snapshot["world_generation"]) != _applied_generation:
		return true
	if int(snapshot["terrain_revision"]) != _applied_revision + 1:
		return true
	var dirty: Rect2i = snapshot.get("dirty_rect_with_halo", Rect2i())
	return dirty.size.x <= 0 or dirty.size.y <= 0


func _vertex(origin: Vector2, spacing: float, row: int, column: int, height: float) -> Vector3:
	return Vector3(origin.x + float(column) * spacing, height, origin.y + float(row) * spacing)


func _is_snapshot_valid(snapshot: Dictionary) -> bool:
	return snapshot.has_all(["world_generation", "terrain_revision", "rows", "columns", "spacing_m", "origin_xz", "surface"])

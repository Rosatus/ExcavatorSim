class_name TerrainRenderer
extends MeshInstance3D

const VoxelZone = preload("res://scripts/voxel_work_zone_config.gd")

## A generation-gated derived mesh owner. It never writes to TerrainState.
##
## Vertex/index arrays are cached so ordinary revisions update only the dirty
## vertices plus a one-cell normal halo and replace just the derived surface
## resource, instead of recomputing the whole grid.
const WORKSITE_SOIL_SHADER := "res://assets/terrain/shaders/worksite_soil_fallback.gdshader"

var _pending_snapshot: Dictionary = {}
var _pending_full := true
var _latest_queued_epoch := ""
var _latest_queued_generation := -1
var _latest_queued_revision := -1
var _applied_epoch := ""
var _applied_generation := -1
var _applied_revision := -1
var _retired_epochs: Dictionary = {}
var full_rebuild_count := 0
var patch_count := 0
var patch_failure_count := 0
var full_failure_count := 0
var _soil_material: ShaderMaterial
var _test_grid_material: ShaderMaterial
var _test_mode := false
var _cached_vertices := PackedVector3Array()
var _cached_normals := PackedVector3Array()
var _cached_uvs := PackedVector2Array()
var _cached_indices := PackedInt32Array()
var _cached_rows := 0
var _cached_columns := 0


func _ready() -> void:
	_ensure_soil_material()


func queue_snapshot(snapshot: Dictionary) -> bool:
	if not _is_snapshot_valid(snapshot):
		return false
	var epoch := String(snapshot["terrain_epoch"])
	if _retired_epochs.has(epoch):
		return false
	var generation := int(snapshot["world_generation"])
	var revision := int(snapshot["terrain_revision"])
	if epoch == _latest_queued_epoch and (generation < _latest_queued_generation or \
			(generation == _latest_queued_generation and revision <= _latest_queued_revision)):
		return false
	if not _latest_queued_epoch.is_empty() and epoch != _latest_queued_epoch:
		_retired_epochs[_latest_queued_epoch] = true
	_pending_snapshot = _copy_snapshot(snapshot)
	_latest_queued_epoch = epoch
	_latest_queued_generation = generation
	_latest_queued_revision = revision
	_pending_full = _requires_full_rebuild(snapshot)
	return true


func queue_full_resync(snapshot: Dictionary) -> bool:
	if not _is_snapshot_valid(snapshot):
		return false
	var epoch := String(snapshot["terrain_epoch"])
	var generation := int(snapshot["world_generation"])
	var revision := int(snapshot["terrain_revision"])
	if _retired_epochs.has(epoch):
		return false
	if epoch == _applied_epoch and (generation < _applied_generation or \
			(generation == _applied_generation and revision < _applied_revision)):
		return false
	if not _latest_queued_epoch.is_empty() and epoch != _latest_queued_epoch:
		_retired_epochs[_latest_queued_epoch] = true
	_pending_snapshot = _copy_snapshot(snapshot)
	_latest_queued_epoch = epoch
	_latest_queued_generation = generation
	_latest_queued_revision = revision
	_pending_full = true
	return true


func apply_pending() -> bool:
	if _pending_snapshot.is_empty():
		return false
	var snapshot := _pending_snapshot
	_pending_snapshot = {}
	var epoch := String(snapshot["terrain_epoch"])
	var generation := int(snapshot["world_generation"])
	var revision := int(snapshot["terrain_revision"])
	if epoch != _latest_queued_epoch or generation != _latest_queued_generation or revision != _latest_queued_revision:
		return false
	if epoch == _applied_epoch and (generation < _applied_generation or \
			(generation == _applied_generation and (revision < _applied_revision or \
				(revision == _applied_revision and not _pending_full)))):
		return false
	var applied := false
	if not _pending_full and _can_patch(snapshot):
		applied = _apply_patch_mesh(snapshot)
		if not applied:
			patch_failure_count += 1
	if not applied:
		applied = _apply_full_mesh(snapshot)
	if not applied:
		full_failure_count += 1
		# Roll the queue gate back so the same or any later revision can be
		# re-queued after a recovery.
		if not _applied_epoch.is_empty():
			_retired_epochs.erase(_applied_epoch)
			_latest_queued_epoch = _applied_epoch
			_latest_queued_generation = _applied_generation
			_latest_queued_revision = _applied_revision
		return false
	_applied_epoch = epoch
	_applied_generation = generation
	_applied_revision = revision
	return true


func get_applied_identity() -> Vector2i:
	return Vector2i(_applied_generation, _applied_revision)


func get_applied_epoch() -> String:
	return _applied_epoch


func get_status_snapshot() -> Dictionary:
	return {
		"queued_epoch": _latest_queued_epoch,
		"queued_generation": _latest_queued_generation,
		"queued_revision": _latest_queued_revision,
		"applied_epoch": _applied_epoch,
		"applied_generation": _applied_generation,
		"applied_revision": _applied_revision,
		"full_rebuild_count": full_rebuild_count,
		"patch_count": patch_count,
		"patch_failure_count": patch_failure_count,
		"full_failure_count": full_failure_count,
		"cached_rows": _cached_rows,
		"cached_columns": _cached_columns,
		"material_kind": "test_black_white_grid" if _test_mode else ("procedural_worksite_soil" if _soil_material != null else "unavailable"),
		"shader_source": _soil_material.shader.resource_path if _soil_material != null and _soil_material.shader != null else "",
		"test_mode": _test_mode,
	}


func set_test_mode(value: bool) -> bool:
	_test_mode = value
	_ensure_soil_material()
	_ensure_test_grid_material()
	var array_mesh := mesh as ArrayMesh
	if array_mesh != null and array_mesh.get_surface_count() > 0:
		array_mesh.surface_set_material(0, _test_grid_material if _test_mode else _soil_material)
	return true


## Full rebuild: recompute every vertex/normal and repopulate the cache.
func _apply_full_mesh(snapshot: Dictionary) -> bool:
	var rows := int(snapshot["rows"])
	var columns := int(snapshot["columns"])
	var spacing := float(snapshot["spacing_m"])
	var origin: Vector2 = snapshot["origin_xz"]
	var surface: PackedFloat32Array = snapshot["surface"]
	if rows < 2 or columns < 2 or surface.size() != rows * columns or spacing <= 0.0:
		return false
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
			var cell_center := Vector2(
				origin.x + (float(column) + 0.5) * spacing,
				origin.y + (float(row) + 0.5) * spacing,
			)
			if VoxelZone.owns_hard_surface_cell(cell_center):
				continue
			var top_left := row * columns + column
			var bottom_left := top_left + columns
			indices[write_index] = top_left
			indices[write_index + 1] = top_left + 1
			indices[write_index + 2] = bottom_left
			indices[write_index + 3] = top_left + 1
			indices[write_index + 4] = bottom_left + 1
			indices[write_index + 5] = bottom_left
			write_index += 6
	indices.resize(write_index)
	if not _publish_surface(vertices, normals, uvs, indices):
		return false
	_cached_vertices = vertices
	_cached_normals = normals
	_cached_uvs = uvs
	_cached_indices = indices
	_cached_rows = rows
	_cached_columns = columns
	full_rebuild_count += 1
	return true


## Ordinary-revision path: rewrite only dirty vertex heights and recompute
## normals over the one-cell halo, then republish the derived surface from the
## cached arrays.
func _apply_patch_mesh(snapshot: Dictionary) -> bool:
	var rows := int(snapshot["rows"])
	var columns := int(snapshot["columns"])
	var spacing := float(snapshot["spacing_m"])
	var origin: Vector2 = snapshot["origin_xz"]
	var surface: PackedFloat32Array = snapshot["surface"]
	if rows != _cached_rows or columns != _cached_columns \
			or surface.size() != _cached_vertices.size() or spacing <= 0.0:
		return false
	var dirty: Rect2i = snapshot.get("dirty_rect_cells", Rect2i())
	if dirty.size.x <= 0 or dirty.size.y <= 0 \
			or dirty.position.x < 0 or dirty.position.y < 0 \
			or dirty.position.x + dirty.size.x > columns \
			or dirty.position.y + dirty.size.y > rows:
		return false
	for row in range(dirty.position.y, dirty.position.y + dirty.size.y):
		for column in range(dirty.position.x, dirty.position.x + dirty.size.x):
			var index := row * columns + column
			_cached_vertices[index] = Vector3(origin.x + float(column) * spacing, surface[index], origin.y + float(row) * spacing)
	# Normals depend on neighbor samples, so recompute them over the halo ring.
	var normal_min_x := maxi(dirty.position.x - 1, 0)
	var normal_max_x := mini(dirty.position.x + dirty.size.x, columns - 1)
	var normal_min_y := maxi(dirty.position.y - 1, 0)
	var normal_max_y := mini(dirty.position.y + dirty.size.y, rows - 1)
	for row in range(normal_min_y, normal_max_y + 1):
		for column in range(normal_min_x, normal_max_x + 1):
			var index := row * columns + column
			_cached_normals[index] = _normal_at(surface, rows, columns, row, column, spacing)
	if not _publish_surface(_cached_vertices, _cached_normals, _cached_uvs, _cached_indices):
		return false
	patch_count += 1
	return true


func _can_patch(snapshot: Dictionary) -> bool:
	if bool(snapshot.get("full_refresh", true)):
		return false
	if String(snapshot["terrain_epoch"]) != _applied_epoch:
		return false
	if int(snapshot["world_generation"]) != _applied_generation:
		return false
	if int(snapshot["terrain_revision"]) != _applied_revision + 1:
		return false
	if _cached_rows < 2 or _cached_columns < 2 or _cached_indices.is_empty():
		return false
	var dirty: Rect2i = snapshot.get("dirty_rect_cells", Rect2i())
	return dirty.size.x > 0 and dirty.size.y > 0


func _requires_full_rebuild(snapshot: Dictionary) -> bool:
	if bool(snapshot.get("full_refresh", true)):
		return true
	if String(snapshot["terrain_epoch"]) != _applied_epoch:
		return true
	if int(snapshot["world_generation"]) != _applied_generation:
		return true
	if int(snapshot["terrain_revision"]) != _applied_revision + 1:
		return true
	var dirty: Rect2i = snapshot.get("dirty_rect_cells", Rect2i())
	return dirty.size.x <= 0 or dirty.size.y <= 0


## Replaces only the derived surface resource; topology and material are stable.
func _publish_surface(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array
) -> bool:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_ensure_soil_material()
	_ensure_test_grid_material()
	result.surface_set_material(0, _test_grid_material if _test_mode else _soil_material)
	mesh = result
	return true


func _ensure_soil_material() -> void:
	if _soil_material != null:
		return
	var shader := load(WORKSITE_SOIL_SHADER) as Shader
	if shader == null:
		return
	_soil_material = ShaderMaterial.new()
	_soil_material.shader = shader


func _ensure_test_grid_material() -> void:
	if _test_grid_material != null:
		return
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded;

varying vec3 grid_world_position;

void vertex() {
	grid_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 cell = floor(grid_world_position.xz);
	float checker = mod(cell.x + cell.y, 2.0);
	vec2 within = abs(fract(grid_world_position.xz) - vec2(0.5));
	float line = smoothstep(0.46, 0.495, max(within.x, within.y));
	vec3 tile = mix(vec3(0.055), vec3(0.86), checker);
	ALBEDO = mix(tile, vec3(0.015), line);
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
"""
	_test_grid_material = ShaderMaterial.new()
	_test_grid_material.shader = shader


func _normal_at(surface: PackedFloat32Array, rows: int, columns: int, row: int, column: int, spacing: float) -> Vector3:
	var left := surface[row * columns + max(0, column - 1)]
	var right := surface[row * columns + min(columns - 1, column + 1)]
	var up := surface[max(0, row - 1) * columns + column]
	var down := surface[min(rows - 1, row + 1) * columns + column]
	var x_span := spacing * float(2 if column > 0 and column < columns - 1 else 1)
	var z_span := spacing * float(2 if row > 0 and row < rows - 1 else 1)
	return Vector3(-(right - left) / x_span, 1.0, -(down - up) / z_span).normalized()


func _is_snapshot_valid(snapshot: Dictionary) -> bool:
	return snapshot.has_all(["terrain_epoch", "world_generation", "terrain_revision", "rows", "columns", "spacing_m", "origin_xz", "surface", "surface_bytes"])


func _copy_snapshot(snapshot: Dictionary) -> Dictionary:
	var copied := snapshot.duplicate(true)
	copied["surface"] = (snapshot["surface"] as PackedFloat32Array).duplicate()
	copied["surface_bytes"] = (snapshot["surface_bytes"] as PackedByteArray).duplicate()
	return copied

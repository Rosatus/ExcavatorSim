class_name TerrainRenderer
extends MeshInstance3D

## A generation-gated derived mesh owner. It never writes to TerrainState.
##
## Vertex/index arrays are cached so ordinary revisions update only the dirty
## vertices plus a one-cell normal halo and replace just the derived surface
## resource, instead of recomputing the whole grid.
var _pending_snapshot: Dictionary = {}
var _pending_full := true
var _latest_queued_generation := -1
var _latest_queued_revision := -1
var _applied_generation := -1
var _applied_revision := -1
var _soil_material: ShaderMaterial
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
	_pending_full = _requires_full_rebuild(snapshot)
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
	var applied := false
	if not _pending_full and _can_patch(snapshot):
		applied = _apply_patch_mesh(snapshot)
	if not applied:
		applied = _apply_full_mesh(snapshot)
	if not applied:
		# Roll the queue gate back so the same or any later revision can be
		# re-queued after a recovery.
		if _applied_revision >= 0:
			_latest_queued_generation = _applied_generation
			_latest_queued_revision = _applied_revision
		return false
	_applied_generation = generation
	_applied_revision = revision
	return true


func get_applied_identity() -> Vector2i:
	return Vector2i(_applied_generation, _applied_revision)


func get_status_snapshot() -> Dictionary:
	return {
		"applied_generation": _applied_generation,
		"applied_revision": _applied_revision,
		"cached_rows": _cached_rows,
		"cached_columns": _cached_columns,
		"material_kind": "procedural_worksite_soil" if _soil_material != null else "unavailable",
	}


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
			var top_left := row * columns + column
			var bottom_left := top_left + columns
			indices[write_index] = top_left
			indices[write_index + 1] = top_left + 1
			indices[write_index + 2] = bottom_left
			indices[write_index + 3] = top_left + 1
			indices[write_index + 4] = bottom_left + 1
			indices[write_index + 5] = bottom_left
			write_index += 6
	if not _publish_surface(vertices, normals, uvs, indices):
		return false
	_cached_vertices = vertices
	_cached_normals = normals
	_cached_uvs = uvs
	_cached_indices = indices
	_cached_rows = rows
	_cached_columns = columns
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
	return _publish_surface(_cached_vertices, _cached_normals, _cached_uvs, _cached_indices)


func _can_patch(snapshot: Dictionary) -> bool:
	if bool(snapshot.get("full_refresh", true)):
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
	result.surface_set_material(0, _soil_material)
	mesh = result
	return true


func _ensure_soil_material() -> void:
	if _soil_material != null:
		return
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

varying vec3 site_world_position;
varying vec3 site_normal;

float site_hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float site_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = site_hash(cell);
	float b = site_hash(cell + vec2(1.0, 0.0));
	float c = site_hash(cell + vec2(0.0, 1.0));
	float d = site_hash(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	site_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	site_normal = normalize(NORMAL);
}

void fragment() {
	vec2 xz = site_world_position.xz;
	float macro = site_noise(xz * 0.13) * 0.65 + site_noise(xz * 0.72) * 0.35;
	float disturbed = smoothstep(0.012, 0.22, abs(site_world_position.y));
	float slope = clamp(1.0 - site_normal.y, 0.0, 1.0);
	float damp_low = 1.0 - smoothstep(0.0, 7.5, distance(xz, vec2(7.0, 7.0)));
	float track_lane = 1.0 - smoothstep(0.36, 1.15, abs(abs(xz.x) - 1.15));
	vec3 compacted = vec3(0.31, 0.245, 0.185);
	vec3 loose = vec3(0.49, 0.345, 0.225);
	vec3 damp = vec3(0.205, 0.19, 0.16);
	vec3 soil = mix(compacted, loose, max(disturbed, slope * 0.42));
	soil = mix(soil, compacted * 0.88, track_lane * (1.0 - disturbed) * 0.42);
	soil = mix(soil, damp, damp_low * 0.62);
	float view_distance = distance(CAMERA_POSITION_WORLD, site_world_position);
	float breakup = mix(0.88 + macro * 0.24, 0.94 + macro * 0.12, smoothstep(14.0, 42.0, view_distance));
	ALBEDO = soil * breakup;
	ROUGHNESS = mix(0.98, 0.82, damp_low * 0.45);
	METALLIC = 0.0;
	SPECULAR = mix(0.18, 0.34, damp_low);
}
"""
	_soil_material = ShaderMaterial.new()
	_soil_material.shader = shader


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

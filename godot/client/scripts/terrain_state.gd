class_name TerrainState
extends RefCounted

## Godot-owned, deterministic terrain authority.  Meshes are always derived
## from snapshots of these two Float32 layers.
const ALGORITHM_VERSION := "godot-terrain-state-v2-flat"
const DEFAULT_SEED := 24681357
const DEFAULT_ROWS := 41
const DEFAULT_COLUMNS := 41
const DEFAULT_SPACING_M := 0.5
const MAX_CELLS := 50000

var seed: int
var rows: int
var columns: int
var spacing_m: float
var origin_xz := Vector2.ZERO
var terrain_epoch := ""
var terrain_revision := 0
var world_generation := 0

var stable_heights := PackedFloat32Array()
var loose_depth := PackedFloat32Array()
var _baseline_stable := PackedFloat32Array()
var _pending_brushes: Array[Dictionary] = []
var _last_enqueued_sequence := -1


func _init(seed_value: int = DEFAULT_SEED, requested_rows: int = DEFAULT_ROWS, requested_columns: int = DEFAULT_COLUMNS, requested_spacing_m: float = DEFAULT_SPACING_M) -> void:
	seed = clampi(seed_value, 0, 0xffffffff)
	rows = clampi(requested_rows, 2, 201)
	columns = clampi(requested_columns, 2, 201)
	if rows * columns > MAX_CELLS:
		columns = maxi(2, MAX_CELLS / rows)
	spacing_m = clampf(requested_spacing_m, 0.25, 1.0)
	origin_xz = Vector2(-0.5 * float(columns - 1) * spacing_m, -0.5 * float(rows - 1) * spacing_m)
	terrain_epoch = _sha256(("%s|%d|%d|%d|%.6f" % [ALGORITHM_VERSION, seed, rows, columns, spacing_m]).to_utf8_buffer())
	_generate_baseline()


func enqueue_brush(sequence: int, center_xz: Vector2, radius_m: float, delta_m: float) -> bool:
	if sequence <= _last_enqueued_sequence or radius_m <= 0.0:
		return false
	if not _is_finite(center_xz.x) or not _is_finite(center_xz.y) or not _is_finite(radius_m) or not _is_finite(delta_m):
		return false
	_pending_brushes.append({
		"sequence": sequence,
		"center_xz": center_xz,
		"radius_m": radius_m,
		"delta_m": delta_m,
	})
	_last_enqueued_sequence = sequence
	return true


func step_fixed() -> bool:
	if _pending_brushes.is_empty():
		return false
	_pending_brushes.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return int(left["sequence"]) < int(right["sequence"]))
	var changed := false
	for command in _pending_brushes:
		if _apply_brush(command):
			terrain_revision += 1
			changed = true
	_pending_brushes.clear()
	return changed


func reset() -> void:
	stable_heights = _baseline_stable.duplicate()
	loose_depth = PackedFloat32Array()
	loose_depth.resize(_baseline_stable.size())
	_pending_brushes.clear()
	_last_enqueued_sequence = -1
	terrain_revision += 1
	world_generation += 1


func surface_snapshot() -> Dictionary:
	var surface := get_surface()
	var bytes := surface_to_bytes(surface)
	return {
		"algorithm_version": ALGORITHM_VERSION,
		"seed": seed,
		"rows": rows,
		"columns": columns,
		"spacing_m": spacing_m,
		"origin_xz": origin_xz,
		"terrain_epoch": terrain_epoch,
		"terrain_revision": terrain_revision,
		"world_generation": world_generation,
		"surface": surface,
		"surface_bytes": bytes,
		"snapshot_sha256": _sha256(bytes),
	}


func get_surface() -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(stable_heights.size())
	for index in result.size():
		result[index] = stable_heights[index] + loose_depth[index]
	return result


func is_inside_grid(world_xz: Vector2) -> bool:
	return world_xz.x >= origin_xz.x and world_xz.y >= origin_xz.y \
		and world_xz.x <= origin_xz.x + float(columns - 1) * spacing_m \
		and world_xz.y <= origin_xz.y + float(rows - 1) * spacing_m


func sample_surface_at(world_xz: Vector2) -> float:
	if not is_inside_grid(world_xz):
		return NAN
	var column := clampi(roundi((world_xz.x - origin_xz.x) / spacing_m), 0, columns - 1)
	var row := clampi(roundi((world_xz.y - origin_xz.y) / spacing_m), 0, rows - 1)
	var index := row * columns + column
	return stable_heights[index] + loose_depth[index]


func sample_surface_bilinear_at(world_xz: Vector2) -> float:
	if not is_inside_grid(world_xz):
		return NAN
	var grid_x := (world_xz.x - origin_xz.x) / spacing_m
	var grid_z := (world_xz.y - origin_xz.y) / spacing_m
	var column0 := clampi(floori(grid_x), 0, columns - 1)
	var row0 := clampi(floori(grid_z), 0, rows - 1)
	var column1 := mini(column0 + 1, columns - 1)
	var row1 := mini(row0 + 1, rows - 1)
	var weight_x := clampf(grid_x - float(column0), 0.0, 1.0)
	var weight_z := clampf(grid_z - float(row0), 0.0, 1.0)
	var top_left := stable_heights[row0 * columns + column0] + loose_depth[row0 * columns + column0]
	var top_right := stable_heights[row0 * columns + column1] + loose_depth[row0 * columns + column1]
	var bottom_left := stable_heights[row1 * columns + column0] + loose_depth[row1 * columns + column0]
	var bottom_right := stable_heights[row1 * columns + column1] + loose_depth[row1 * columns + column1]
	return lerpf(lerpf(top_left, top_right, weight_x), lerpf(bottom_left, bottom_right, weight_x), weight_z)


func estimate_brush_volume(center_xz: Vector2, radius_m: float, delta_m: float) -> float:
	if radius_m <= 0.0 or not _is_finite(center_xz.x) or not _is_finite(center_xz.y) or not _is_finite(radius_m) or not _is_finite(delta_m):
		return 0.0
	var volume := 0.0
	var cell_area := spacing_m * spacing_m
	for row in rows:
		var z := origin_xz.y + float(row) * spacing_m
		for column in columns:
			var x := origin_xz.x + float(column) * spacing_m
			var distance := Vector2(x, z).distance_to(center_xz)
			if distance > radius_m:
				continue
			var amount := delta_m * (1.0 - distance / radius_m)
			if is_zero_approx(amount):
				continue
			var index := row * columns + column
			if amount > 0.0:
				volume += amount * cell_area
				continue
			var remaining := -amount
			var loose_taken := minf(loose_depth[index], remaining)
			remaining -= loose_taken
			var stable_floor := _baseline_stable[index] - 3.0
			var stable_taken := minf(maxf(0.0, stable_heights[index] - stable_floor), remaining)
			volume += (loose_taken + stable_taken) * cell_area
	return volume


func surface_to_bytes(surface: PackedFloat32Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(surface.size() * 4)
	for index in surface.size():
		bytes.encode_float(index * 4, surface[index])
	return bytes


func get_pending_count() -> int:
	return _pending_brushes.size()


func get_last_enqueued_sequence() -> int:
	return _last_enqueued_sequence


func _generate_baseline() -> void:
	_baseline_stable = PackedFloat32Array()
	_baseline_stable.resize(rows * columns)
	stable_heights = _baseline_stable.duplicate()
	loose_depth = PackedFloat32Array()
	loose_depth.resize(_baseline_stable.size())


func _apply_brush(command: Dictionary) -> bool:
	var center: Vector2 = command["center_xz"]
	var radius: float = command["radius_m"]
	var delta: float = command["delta_m"]
	var changed := false
	for row in rows:
		var z := origin_xz.y + float(row) * spacing_m
		for column in columns:
			var x := origin_xz.x + float(column) * spacing_m
			var distance := Vector2(x, z).distance_to(center)
			if distance > radius:
				continue
			var amount := delta * (1.0 - distance / radius)
			if is_zero_approx(amount):
				continue
			var index := row * columns + column
			if amount > 0.0:
				loose_depth[index] += amount
				changed = true
			else:
				var remaining := -amount
				var loose_taken := minf(loose_depth[index], remaining)
				if loose_taken > 0.0:
					loose_depth[index] -= loose_taken
					remaining -= loose_taken
					changed = true
				if remaining > 0.0:
					var lowered := maxf(_baseline_stable[index] - 3.0, stable_heights[index] - remaining)
					if lowered != stable_heights[index]:
						stable_heights[index] = lowered
						changed = true
	return changed


func _sha256(bytes: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(bytes)
	return hashing.finish().hex_encode()


func _is_finite(value: float) -> bool:
	return not is_nan(value) and not is_inf(value)

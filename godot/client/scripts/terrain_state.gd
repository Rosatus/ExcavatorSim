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
## One-cell normal/seam halo published with every dirty rectangle so derived
## mesh/collider consumers can rebuild normals and shared chunk edges.
const DIRTY_HALO_CELLS := 1

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
## Dirty bookkeeping for incremental derived updates. Rectangles live in grid
## space as Rect2i(position=(min_column, min_row), size=(columns, rows)).
## _dirty_revision records which terrain_revision the rectangles describe;
## reset invalidates them so the next snapshot requests a full refresh.
var _dirty_revision := -1
var _dirty_rect_cells := Rect2i()
var _dirty_rect_with_halo := Rect2i()
var _last_apply_changed := false


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


## Materializes an isolated terrain authority from an immutable surface
## snapshot. Shadow simulations use this instead of borrowing the product
## TerrainState, so their scheduler can exercise the real terrain transaction
## path without acquiring product write authority.
static func from_surface_snapshot(snapshot: Dictionary) -> TerrainState:
	var snapshot_rows := int(snapshot.get("rows", 0))
	var snapshot_columns := int(snapshot.get("columns", 0))
	var snapshot_spacing := float(snapshot.get("spacing_m", 0.0))
	var surface: PackedFloat32Array = snapshot.get("surface", PackedFloat32Array())
	if snapshot_rows < 2 or snapshot_columns < 2 or surface.size() != snapshot_rows * snapshot_columns:
		return null
	var clone := TerrainState.new(
		int(snapshot.get("seed", DEFAULT_SEED)),
		snapshot_rows,
		snapshot_columns,
		snapshot_spacing,
	)
	clone.origin_xz = snapshot.get("origin_xz", clone.origin_xz) as Vector2
	clone.terrain_epoch = String(snapshot.get("terrain_epoch", clone.terrain_epoch))
	clone.terrain_revision = maxi(0, int(snapshot.get("terrain_revision", 0)))
	clone.world_generation = maxi(0, int(snapshot.get("world_generation", 0)))
	clone.stable_heights = surface.duplicate()
	clone._baseline_stable = surface.duplicate()
	clone.loose_depth = PackedFloat32Array()
	clone.loose_depth.resize(surface.size())
	clone._pending_brushes.clear()
	clone._last_enqueued_sequence = -1
	clone._dirty_revision = -1
	clone._dirty_rect_cells = Rect2i()
	clone._dirty_rect_with_halo = Rect2i()
	return clone


func enqueue_brush(sequence: int, center_xz: Vector2, radius_m: float, delta_m: float, normalize_center := false) -> bool:
	if sequence <= _last_enqueued_sequence or radius_m <= 0.0:
		return false
	if not _is_finite(center_xz.x) or not _is_finite(center_xz.y) or not _is_finite(radius_m) or not _is_finite(delta_m):
		return false
	_pending_brushes.append({
		"sequence": sequence,
		"center_xz": center_xz,
		"radius_m": radius_m,
		"delta_m": delta_m,
		"normalize_center": normalize_center,
	})
	_last_enqueued_sequence = sequence
	return true


func next_brush_sequence() -> int:
	return _last_enqueued_sequence + 1


func step_fixed() -> bool:
	if _pending_brushes.is_empty():
		return false
	_pending_brushes.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return int(left["sequence"]) < int(right["sequence"]))
	var changed := false
	var batch_min := Vector2i(2147483647, 2147483647)
	var batch_max := Vector2i(-2147483648, -2147483648)
	for command in _pending_brushes:
		var brush_rect := _apply_brush(command)
		if brush_rect.size.x > 0 and brush_rect.size.y > 0:
			batch_min = batch_min.min(brush_rect.position)
			batch_max = batch_max.max(brush_rect.position + brush_rect.size - Vector2i.ONE)
		if _last_apply_changed:
			changed = true
	_pending_brushes.clear()
	if changed:
		# One accepted fixed-step batch advances the revision exactly once so
		# each scheduler flush produces one contiguous, patchable identity.
		terrain_revision += 1
		_publish_dirty_bounds(batch_min, batch_max)
	return changed


func reset() -> void:
	stable_heights = _baseline_stable.duplicate()
	loose_depth = PackedFloat32Array()
	loose_depth.resize(_baseline_stable.size())
	_pending_brushes.clear()
	_last_enqueued_sequence = -1
	_dirty_revision = -1
	_dirty_rect_cells = Rect2i()
	_dirty_rect_with_halo = Rect2i()
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
		"full_refresh": not is_dirty_rect_current(),
		"dirty_rect_cells": _dirty_rect_cells,
		"dirty_rect_with_halo": _dirty_rect_with_halo,
		"dirty_revision": _dirty_revision,
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


## True when the published dirty rectangles describe exactly the transition
## into the current terrain_revision. Consumers combine this with their own
## applied identity to decide between patch and full materialization.
func is_dirty_rect_current() -> bool:
	return _dirty_revision == terrain_revision


func get_dirty_rect_cells() -> Rect2i:
	return _dirty_rect_cells


func get_dirty_rect_with_halo() -> Rect2i:
	return _dirty_rect_with_halo


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
	var bounds := _brush_cell_bounds(center_xz, radius_m)
	for row in range(bounds.position.y, bounds.end.y):
		var z := origin_xz.y + float(row) * spacing_m
		for column in range(bounds.position.x, bounds.end.x):
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


## Applies one brush bounded to its clamped grid rectangle. Returns the touched
## cell rectangle (empty when the brush misses the grid) and records whether any
## cell actually changed in _last_apply_changed.
func _apply_brush(command: Dictionary) -> Rect2i:
	var center: Vector2 = command["center_xz"]
	var radius: float = command["radius_m"]
	var delta: float = command["delta_m"]
	var normalize_center := bool(command.get("normalize_center", false))
	_last_apply_changed = false
	var bounds := _brush_cell_bounds(center, radius)
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		return Rect2i()
	# Center-exact normalization: rasterized falloff plus bilinear sampling
	# otherwise yields only a fraction of the requested delta at the brush
	# center, which breaks the analytic dig invariant (surface must yield
	# exactly as deep as the edge presses). Distribute the exact center drop
	# across the four surrounding cells proportionally to their squared
	# bilinear weights; all other cells keep the plain falloff.
	var corner_amounts := {}
	if normalize_center and not is_zero_approx(delta):
		var grid_x := (center.x - origin_xz.x) / spacing_m
		var grid_z := (center.y - origin_xz.y) / spacing_m
		var column0 := clampi(floori(grid_x), 0, columns - 1)
		var row0 := clampi(floori(grid_z), 0, rows - 1)
		var column1 := mini(column0 + 1, columns - 1)
		var row1 := mini(row0 + 1, rows - 1)
		var weight_x := clampf(grid_x - float(column0), 0.0, 1.0)
		var weight_z := clampf(grid_z - float(row0), 0.0, 1.0)
		var weights := {
			row0 * columns + column0: (1.0 - weight_x) * (1.0 - weight_z),
			row0 * columns + column1: weight_x * (1.0 - weight_z),
			row1 * columns + column0: (1.0 - weight_x) * weight_z,
			row1 * columns + column1: weight_x * weight_z,
		}
		var squared_sum := 0.0
		for weight_value in weights.values():
			squared_sum += float(weight_value) * float(weight_value)
		if squared_sum > 0.000001:
			for index_key in weights:
				corner_amounts[index_key] = delta * float(weights[index_key]) / squared_sum
	for row in range(bounds.position.y, bounds.end.y):
		var z := origin_xz.y + float(row) * spacing_m
		for column in range(bounds.position.x, bounds.end.x):
			var x := origin_xz.x + float(column) * spacing_m
			var distance := Vector2(x, z).distance_to(center)
			if distance > radius:
				continue
			var index := row * columns + column
			var amount: float = delta * (1.0 - distance / radius)
			if corner_amounts.has(index):
				amount = corner_amounts[index]
			if is_zero_approx(amount):
				continue
			if amount > 0.0:
				loose_depth[index] += amount
				_last_apply_changed = true
			else:
				var remaining := -amount
				var loose_taken := minf(loose_depth[index], remaining)
				if loose_taken > 0.0:
					loose_depth[index] -= loose_taken
					remaining -= loose_taken
					_last_apply_changed = true
				if remaining > 0.0:
					var lowered := maxf(_baseline_stable[index] - 3.0, stable_heights[index] - remaining)
					if lowered != stable_heights[index]:
						stable_heights[index] = lowered
						_last_apply_changed = true
	return bounds


## Clamped grid-cell bounding rectangle for a circular brush. Grid space is
## Rect2i(position=(min_column, min_row), size=(columns, rows)).
func _brush_cell_bounds(center_xz: Vector2, radius_m: float) -> Rect2i:
	if not _is_finite(center_xz.x) or not _is_finite(center_xz.y) or not _is_finite(radius_m) or radius_m <= 0.0:
		return Rect2i()
	var min_column := clampi(floori((center_xz.x - radius_m - origin_xz.x) / spacing_m), 0, columns - 1)
	var max_column := clampi(ceili((center_xz.x + radius_m - origin_xz.x) / spacing_m), 0, columns - 1)
	var min_row := clampi(floori((center_xz.y - radius_m - origin_xz.y) / spacing_m), 0, rows - 1)
	var max_row := clampi(ceili((center_xz.y + radius_m - origin_xz.y) / spacing_m), 0, rows - 1)
	if max_column < min_column or max_row < min_row:
		return Rect2i()
	return Rect2i(min_column, min_row, max_column - min_column + 1, max_row - min_row + 1)


func _publish_dirty_bounds(min_cell: Vector2i, max_cell: Vector2i) -> void:
	if max_cell.x < min_cell.x or max_cell.y < min_cell.y:
		return
	_dirty_rect_cells = Rect2i(min_cell, max_cell - min_cell + Vector2i.ONE)
	var halo_min := Vector2i(
		maxi(min_cell.x - DIRTY_HALO_CELLS, 0),
		maxi(min_cell.y - DIRTY_HALO_CELLS, 0)
	)
	var halo_max := Vector2i(
		mini(max_cell.x + DIRTY_HALO_CELLS, columns - 1),
		mini(max_cell.y + DIRTY_HALO_CELLS, rows - 1)
	)
	_dirty_rect_with_halo = Rect2i(halo_min, halo_max - halo_min + Vector2i.ONE)
	_dirty_revision = terrain_revision


func _sha256(bytes: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(bytes)
	return hashing.finish().hex_encode()


func _is_finite(value: float) -> bool:
	return not is_nan(value) and not is_inf(value)

class_name TerrainCommitScheduler
extends RefCounted

## Sole production owner for applying queued terrain deltas and refreshing its
## render/collision derivatives. Producers only submit immutable brush records.

const DEFAULT_COMMIT_HZ := 12.0
const DEFAULT_MAX_LATENCY_S := 0.15
const DEFAULT_VOLUME_THRESHOLD_M3 := 0.018
const MAX_PENDING_BRUSHES := 256

var terrain_state: TerrainState
var terrain_world: TerrainWorld
var terrain_collider: TerrainCollider
var commit_interval_s := 1.0 / DEFAULT_COMMIT_HZ
var maximum_latency_s := DEFAULT_MAX_LATENCY_S
var volume_threshold_m3 := DEFAULT_VOLUME_THRESHOLD_M3

var _pending: Array[Dictionary] = []
var _elapsed_s := 0.0
var _oldest_age_s := 0.0
var _queued_volume_m3 := 0.0
var _generation := 0
var _flush_count := 0
var _last_flush_brushes := 0
var _last_flush_revision := -1
var _last_flush_dirty_rect := Rect2i()
var _last_flush_dirty_halo := Rect2i()
var _collider_prepare_rejections := 0
var _collider_install_failures := 0
var _collider_rollback_failures := 0
var _last_cell_patch_flush_us := 0
var _max_cell_patch_flush_us := 0


func _init(state: TerrainState, world: TerrainWorld = null, collider: TerrainCollider = null) -> void:
	terrain_state = state
	terrain_world = world
	terrain_collider = collider
	_generation = state.world_generation if state != null else 0


func queue_brush(
	sequence: int,
	center_xz: Vector2,
	radius_m: float,
	delta_m: float,
	generation: int,
	transfer_id: String,
	normalize_center := false
) -> bool:
	if terrain_state == null or generation != _generation or transfer_id.is_empty():
		return false
	if _pending.size() >= MAX_PENDING_BRUSHES or _has_pending_cell_patch():
		return false
	for pending_brush in _pending:
		if String(pending_brush.get("transfer_id", "")) == transfer_id:
			return false
	if sequence < 0 or radius_m <= 0.0 or not _finite_vector2(center_xz):
		return false
	if not _finite(radius_m) or not _finite(delta_m) or is_zero_approx(delta_m):
		return false
	var estimated_volume := terrain_state.estimate_brush_volume(center_xz, radius_m, delta_m)
	if estimated_volume <= 0.0:
		return false
	_pending.append({
		"kind": "brush",
		"sequence": sequence,
		"center_xz": center_xz,
		"radius_m": radius_m,
		"delta_m": delta_m,
		"generation": generation,
		"transfer_id": transfer_id,
		"estimated_volume_m3": estimated_volume,
		"normalize_center": normalize_center,
	})
	_queued_volume_m3 += estimated_volume
	return true


## Queues one atomic unique-cell patch. Product v2 cutting never translates
## this record into overlapping legacy brushes.
func queue_cell_patch(
	sequence: int,
	patch: Dictionary,
	generation: int,
	transfer_id: String
) -> bool:
	if terrain_state == null or generation != _generation or transfer_id.is_empty() or sequence < 0:
		return false
	if not _pending.is_empty():
		return false
	var validation := terrain_state.validate_cell_patch(patch)
	if not bool(validation.get("valid", false)):
		return false
	var metrics := SoilCellPatch.volume_metrics(patch, terrain_state.cell_patch_read_snapshot())
	var estimated_volume := float(metrics.get("absolute_change_m3", 0.0))
	if not _finite(estimated_volume) or estimated_volume <= 0.0:
		return false
	_pending.append({
		"kind": "cell_patch",
		"sequence": sequence,
		"patch": patch.duplicate(true),
		"generation": generation,
		"transfer_id": transfer_id,
		"estimated_volume_m3": estimated_volume,
	})
	_queued_volume_m3 = estimated_volume
	return true


func step_fixed(delta: float, force: bool = false) -> Dictionary:
	if terrain_state == null:
		return _result(false, "terrain_unavailable")
	if terrain_state.world_generation != _generation:
		reset_for_generation(terrain_state.world_generation)
		return _result(false, "generation_changed")
	_elapsed_s += maxf(delta, 0.0)
	if not _pending.is_empty():
		_oldest_age_s += maxf(delta, 0.0)
	if _pending.is_empty():
		return _result(false, "idle")
	var due := force or _elapsed_s >= commit_interval_s or _oldest_age_s >= maximum_latency_s or _queued_volume_m3 >= volume_threshold_m3
	if not due:
		return _result(false, "batched")
	return _flush()


func reset_for_generation(generation: int) -> void:
	_pending.clear()
	_queued_volume_m3 = 0.0
	_elapsed_s = 0.0
	_oldest_age_s = 0.0
	_generation = maxi(generation, 0)
	_last_flush_brushes = 0
	_last_flush_dirty_rect = Rect2i()
	_last_flush_dirty_halo = Rect2i()


func reset_world() -> bool:
	if terrain_state == null or terrain_world == null:
		return false
	_pending.clear()
	if not terrain_world.reset_state_for_scheduler():
		return false
	reset_for_generation(terrain_state.world_generation)
	refresh_derivatives()
	terrain_world.notify_world_reset_from_scheduler()
	return true


func get_status_snapshot() -> Dictionary:
	return {
		"generation": _generation,
		"pending_brushes": _pending.size(),
		"pending_operations": _pending.size(),
		"pending_cell_patches": _pending_cell_patch_count(),
		"queued_volume_m3": _queued_volume_m3,
		"oldest_age_s": _oldest_age_s,
		"commit_interval_s": commit_interval_s,
		"maximum_latency_s": maximum_latency_s,
		"volume_threshold_m3": volume_threshold_m3,
		"flush_count": _flush_count,
		"last_flush_brushes": _last_flush_brushes,
		"last_flush_revision": _last_flush_revision,
		"last_flush_dirty_rect_cells": _last_flush_dirty_rect,
		"last_flush_dirty_rect_with_halo": _last_flush_dirty_halo,
		"collider_prepare_rejections": _collider_prepare_rejections,
		"collider_install_failures": _collider_install_failures,
		"collider_rollback_failures": _collider_rollback_failures,
		"last_cell_patch_flush_us": _last_cell_patch_flush_us,
		"max_cell_patch_flush_us": _max_cell_patch_flush_us,
	}


func refresh_derivatives() -> bool:
	if terrain_state == null:
		return false
	var snapshot := terrain_state.surface_snapshot()
	var applied := false
	if terrain_world != null:
		applied = terrain_world.rebuild_mesh_from_snapshot(snapshot) or applied
	if terrain_collider != null:
		terrain_collider.queue_snapshot(snapshot)
		applied = terrain_collider.apply_pending() or applied
	return applied


func refresh_collider_derivative() -> bool:
	if terrain_state == null or terrain_collider == null:
		return false
	var snapshot := terrain_state.surface_snapshot()
	terrain_collider.queue_snapshot(snapshot)
	return terrain_collider.apply_pending()


func _flush() -> Dictionary:
	_pending.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return int(left["sequence"]) < int(right["sequence"]))
	if _pending.size() == 1 and String(_pending[0].get("kind", "brush")) == "cell_patch":
		return _flush_cell_patch(_pending[0])
	var queued := 0
	var committed_transfer_ids: Array[String] = []
	var rejected_transfer_ids: Array[String] = []
	for brush in _pending:
		if int(brush["generation"]) != _generation:
			rejected_transfer_ids.append(String(brush["transfer_id"]))
			continue
		var terrain_sequence := terrain_state.next_brush_sequence()
		var accepted := false
		if String(brush.get("kind", "brush")) == "cell_patch":
			accepted = terrain_state.enqueue_cell_patch(terrain_sequence, brush["patch"] as Dictionary)
		else:
			accepted = terrain_state.enqueue_brush(
				terrain_sequence,
				brush["center_xz"],
				float(brush["radius_m"]),
				float(brush["delta_m"]),
				bool(brush.get("normalize_center", false))
			)
		if accepted:
			queued += 1
			committed_transfer_ids.append(String(brush["transfer_id"]))
		else:
			rejected_transfer_ids.append(String(brush["transfer_id"]))
	_pending.clear()
	_queued_volume_m3 = 0.0
	_elapsed_s = 0.0
	_oldest_age_s = 0.0
	if queued == 0 or not terrain_state.step_fixed():
		_last_flush_brushes = 0
		var rejected_result := _result(false, "terrain_rejected")
		rejected_result["rejected_transfer_ids"] = rejected_transfer_ids + committed_transfer_ids
		return rejected_result
	refresh_derivatives()
	_flush_count += 1
	_last_flush_brushes = queued
	_last_flush_revision = terrain_state.terrain_revision
	_last_flush_dirty_rect = terrain_state.get_dirty_rect_cells()
	_last_flush_dirty_halo = terrain_state.get_dirty_rect_with_halo()
	var result := _result(true, "committed")
	result["committed_transfer_ids"] = committed_transfer_ids
	result["rejected_transfer_ids"] = rejected_transfer_ids
	return result


func _flush_cell_patch(operation: Dictionary) -> Dictionary:
	var flush_started_us := Time.get_ticks_usec()
	var transfer_id := String(operation.get("transfer_id", ""))
	var cell_patch := operation.get("patch", {}) as Dictionary
	var rejected_transfer_ids: Array[String] = []
	if int(operation.get("generation", -1)) != _generation:
		rejected_transfer_ids.append(transfer_id)
		_pending.clear()
		var stale := _result(false, "generation_changed")
		stale["rejected_transfer_ids"] = rejected_transfer_ids
		return stale
	var validation := terrain_state.validate_cell_patch(cell_patch)
	if not bool(validation.get("valid", false)):
		rejected_transfer_ids.append(transfer_id)
		_pending.clear()
		var invalid := _result(false, "terrain_rejected")
		invalid["rejected_transfer_ids"] = rejected_transfer_ids
		return invalid
	var candidate := {}
	var collider_prepared := false
	if terrain_collider != null and terrain_collider.enabled:
		candidate = terrain_state.preview_cell_patch(cell_patch)
		if candidate.is_empty():
			rejected_transfer_ids.append(transfer_id)
			_pending.clear()
			var preview_invalid := _result(false, "terrain_rejected")
			preview_invalid["rejected_transfer_ids"] = rejected_transfer_ids
			return preview_invalid
		collider_prepared = terrain_collider.prepare_snapshot(candidate)
		if not collider_prepared:
			_collider_prepare_rejections += 1
			rejected_transfer_ids.append(transfer_id)
			_pending.clear()
			_queued_volume_m3 = 0.0
			_elapsed_s = 0.0
			_oldest_age_s = 0.0
			var prepare_rejected := _result(false, "collider_prepare_rejected")
			prepare_rejected["rejected_transfer_ids"] = rejected_transfer_ids
			return prepare_rejected
	var terrain_sequence := terrain_state.next_brush_sequence()
	# Install the fully prepared Jolt derivative before the authoritative layer
	# write. Both operations are synchronous inside one fixed-step boundary, so
	# physics cannot observe the candidate until the next tick. An install
	# failure therefore leaves TerrainState bytes and revision untouched.
	if collider_prepared and not terrain_collider.install_prepared(candidate):
		_collider_install_failures += 1
		rejected_transfer_ids.append(transfer_id)
		_pending.clear()
		_queued_volume_m3 = 0.0
		_elapsed_s = 0.0
		_oldest_age_s = 0.0
		var install_failed := _result(false, "collider_install_rejected")
		install_failed["rejected_transfer_ids"] = rejected_transfer_ids
		return install_failed
	var queued := terrain_state.enqueue_cell_patch(terrain_sequence, cell_patch)
	_pending.clear()
	_queued_volume_m3 = 0.0
	_elapsed_s = 0.0
	_oldest_age_s = 0.0
	if not queued or not terrain_state.step_fixed():
		# Validation and original-value comparison already succeeded before the
		# collider install. Reaching this branch is an internal invariant fault.
		# TerrainState has not changed on this branch, so materialize the rare
		# rollback snapshot only after the invariant fault instead of paying for
		# it on every successful cut.
		if collider_prepared and not terrain_collider.restore_snapshot(terrain_state.surface_snapshot()):
			_collider_rollback_failures += 1
		rejected_transfer_ids.append(transfer_id)
		var terrain_rejected := _result(false, "post_install_terrain_invariant")
		terrain_rejected["rejected_transfer_ids"] = rejected_transfer_ids
		return terrain_rejected
	var committed_snapshot := terrain_state.surface_snapshot()
	# Renderer/Terrain3D consume the same immutable revision. Collider queueing
	# is a no-op here because its prepared identity is already current.
	if terrain_world != null:
		terrain_world.rebuild_mesh_from_snapshot(committed_snapshot)
	_flush_count += 1
	_last_flush_brushes = 1
	_last_flush_revision = terrain_state.terrain_revision
	_last_flush_dirty_rect = terrain_state.get_dirty_rect_cells()
	_last_flush_dirty_halo = terrain_state.get_dirty_rect_with_halo()
	_last_cell_patch_flush_us = Time.get_ticks_usec() - flush_started_us
	_max_cell_patch_flush_us = maxi(_max_cell_patch_flush_us, _last_cell_patch_flush_us)
	var result := _result(true, "committed")
	result["committed_transfer_ids"] = [transfer_id]
	result["collider_prepared"] = collider_prepared
	return result


func _result(changed: bool, reason: String) -> Dictionary:
	var result := get_status_snapshot()
	result["changed"] = changed
	result["reason"] = reason
	result["committed_transfer_ids"] = []
	result["rejected_transfer_ids"] = []
	return result


func _finite_vector2(value: Vector2) -> bool:
	return _finite(value.x) and _finite(value.y)


func _finite(value: float) -> bool:
	return not is_nan(value) and not is_inf(value)


func _has_pending_cell_patch() -> bool:
	return _pending_cell_patch_count() > 0


func _pending_cell_patch_count() -> int:
	var count := 0
	for operation in _pending:
		if String(operation.get("kind", "brush")) == "cell_patch":
			count += 1
	return count

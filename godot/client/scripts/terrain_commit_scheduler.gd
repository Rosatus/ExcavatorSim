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
	transfer_id: String
) -> bool:
	if terrain_state == null or generation != _generation or transfer_id.is_empty():
		return false
	if _pending.size() >= MAX_PENDING_BRUSHES:
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
		"sequence": sequence,
		"center_xz": center_xz,
		"radius_m": radius_m,
		"delta_m": delta_m,
		"generation": generation,
		"transfer_id": transfer_id,
		"estimated_volume_m3": estimated_volume,
	})
	_queued_volume_m3 += estimated_volume
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
		"queued_volume_m3": _queued_volume_m3,
		"oldest_age_s": _oldest_age_s,
		"commit_interval_s": commit_interval_s,
		"maximum_latency_s": maximum_latency_s,
		"volume_threshold_m3": volume_threshold_m3,
		"flush_count": _flush_count,
		"last_flush_brushes": _last_flush_brushes,
		"last_flush_revision": _last_flush_revision,
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
	var queued := 0
	var committed_transfer_ids: Array[String] = []
	var rejected_transfer_ids: Array[String] = []
	for brush in _pending:
		if int(brush["generation"]) != _generation:
			rejected_transfer_ids.append(String(brush["transfer_id"]))
			continue
		var terrain_sequence := terrain_state.next_brush_sequence()
		if terrain_state.enqueue_brush(
			terrain_sequence,
			brush["center_xz"],
			float(brush["radius_m"]),
			float(brush["delta_m"])
		):
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
	var result := _result(true, "committed")
	result["committed_transfer_ids"] = committed_transfer_ids
	result["rejected_transfer_ids"] = rejected_transfer_ids
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

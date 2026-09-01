class_name ActiveSoilPersistentField
extends RefCounted

## Persistent material field used by the bounded active-soil patch. Shadow mode
## owns an isolated clone; product mode borrows the selected TerrainState and its
## sole TerrainCommitScheduler without taking lifecycle ownership of either.

const SCHEMA_VERSION := "active-soil-persistent-field-v1"
const MIN_VOLUME_M3 := 0.000001
const DEFAULT_BRUSH_RADIUS_M := 0.34
const MATERIAL_PRESETS := {
	"loose": {"id": 0, "compaction": 0.18},
	"compact": {"id": 1, "compaction": 0.78},
	"sand": {"id": 2, "compaction": 0.08},
	"damp": {"id": 3, "compaction": 0.42},
}

var terrain_state: TerrainState
var scheduler: TerrainCommitScheduler
var material_preset := "loose"
var source_epoch := ""
var source_revision := -1
var source_generation := -1
var write_scope := "shadow"

var _material_ids := PackedByteArray()
var _compaction := PackedFloat32Array()
var _transaction_sequence := 0
var _activated_volume_m3 := 0.0
var _settled_volume_m3 := 0.0
var _rejected_volume_m3 := 0.0
var _flux_solver := LooseSoilFluxSolver.new()
var _flux_commit_count := 0
var _flux_rejection_count := 0
var _flux_moved_volume_m3 := 0.0
var _last_flux_result: Dictionary = {}
var _pending_flux_frontier: Dictionary = {}
var _pending_flux_impulse := Vector2.ZERO
var _pending_flux_steps := 0


func configure(source_snapshot: Dictionary, preset: String = "loose") -> bool:
	clear()
	if not MATERIAL_PRESETS.has(preset):
		return false
	terrain_state = TerrainState.from_surface_snapshot(source_snapshot)
	if terrain_state == null:
		return false
	scheduler = TerrainCommitScheduler.new(terrain_state)
	scheduler.commit_interval_s = 0.0
	scheduler.maximum_latency_s = 0.0
	scheduler.volume_threshold_m3 = 0.0
	write_scope = "shadow"
	return _configure_metadata(source_snapshot, preset)


func configure_product(state: TerrainState, product_scheduler: TerrainCommitScheduler, preset: String = "loose") -> bool:
	clear()
	if state == null or product_scheduler == null or product_scheduler.terrain_state != state or not MATERIAL_PRESETS.has(preset):
		return false
	terrain_state = state
	scheduler = product_scheduler
	write_scope = "product"
	return _configure_metadata(state.surface_snapshot(), preset)


func _configure_metadata(source_snapshot: Dictionary, preset: String) -> bool:
	material_preset = preset
	source_epoch = String(source_snapshot.get("terrain_epoch", ""))
	source_revision = int(source_snapshot.get("terrain_revision", -1))
	source_generation = int(source_snapshot.get("world_generation", -1))
	var cell_count := terrain_state.rows * terrain_state.columns
	_material_ids.resize(cell_count)
	_compaction.resize(cell_count)
	var preset_data := MATERIAL_PRESETS[preset] as Dictionary
	_material_ids.fill(int(preset_data["id"]))
	_compaction.fill(float(preset_data["compaction"]))
	return true


func clear() -> void:
	terrain_state = null
	scheduler = null
	material_preset = "loose"
	source_epoch = ""
	source_revision = -1
	source_generation = -1
	write_scope = "shadow"
	_material_ids = PackedByteArray()
	_compaction = PackedFloat32Array()
	_transaction_sequence = 0
	_activated_volume_m3 = 0.0
	_settled_volume_m3 = 0.0
	_rejected_volume_m3 = 0.0
	_flux_commit_count = 0
	_flux_rejection_count = 0
	_flux_moved_volume_m3 = 0.0
	_last_flux_result.clear()
	_pending_flux_frontier.clear()
	_pending_flux_impulse = Vector2.ZERO
	_pending_flux_steps = 0


func activate_volume(center_xz: Vector2, requested_volume_m3: float, radius_m: float = DEFAULT_BRUSH_RADIUS_M, transfer_hint: String = "") -> Dictionary:
	return _commit_volume("activate", center_xz, requested_volume_m3, radius_m, transfer_hint)


func settle_volume(center_xz: Vector2, requested_volume_m3: float, radius_m: float = DEFAULT_BRUSH_RADIUS_M, transfer_hint: String = "") -> Dictionary:
	return _commit_settlement_patch(center_xz, requested_volume_m3, radius_m, transfer_hint)


func sample_surface_at(world_xz: Vector2) -> float:
	return terrain_state.sample_surface_bilinear_at(world_xz) if terrain_state != null else NAN


func sample_material_id_at(world_xz: Vector2) -> int:
	var index := _cell_index(world_xz)
	return int(_material_ids[index]) if index >= 0 else -1


func sample_compaction_at(world_xz: Vector2) -> float:
	var index := _cell_index(world_xz)
	return float(_compaction[index]) if index >= 0 else NAN


func surface_snapshot() -> Dictionary:
	return terrain_state.surface_snapshot() if terrain_state != null else {}


func compaction_snapshot() -> PackedFloat32Array:
	return _compaction.duplicate()


## Synchronous copy-on-write view used only while building the current sweep.
## Product code must use compaction_snapshot() when retaining the data.
func compaction_read_view() -> PackedFloat32Array:
	return _compaction


func get_status_snapshot() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"configured": terrain_state != null and scheduler != null,
		"material_preset": material_preset,
		"write_scope": write_scope,
		"source_epoch": source_epoch,
		"source_revision": source_revision,
		"source_generation": source_generation,
		"field_revision": terrain_state.terrain_revision if terrain_state != null else -1,
		"field_generation": terrain_state.world_generation if terrain_state != null else -1,
		"shadow_revision": terrain_state.terrain_revision if terrain_state != null and write_scope == "shadow" else -1,
		"shadow_generation": terrain_state.world_generation if terrain_state != null and write_scope == "shadow" else -1,
		"activated_volume_m3": _activated_volume_m3,
		"settled_volume_m3": _settled_volume_m3,
		"rejected_volume_m3": _rejected_volume_m3,
		"net_active_volume_m3": _activated_volume_m3 - _settled_volume_m3,
		"material_cell_count": _material_ids.size(),
		"estimated_memory_bytes": _material_ids.size() + _compaction.size() * 4,
		"flux_commit_count": _flux_commit_count,
		"flux_rejection_count": _flux_rejection_count,
		"flux_moved_volume_m3": _flux_moved_volume_m3,
		"pending_flux_cell_count": _pending_flux_frontier.size(),
		"pending_flux_steps": _pending_flux_steps,
		"last_flux_result": _last_flux_result.duplicate(true),
	}


func _commit_volume(kind: String, center_xz: Vector2, requested_volume_m3: float, radius_m: float, transfer_hint: String) -> Dictionary:
	var rejected := {
		"accepted": false,
		"kind": kind,
		"requested_volume_m3": requested_volume_m3,
		"committed_volume_m3": 0.0,
		"reason": "invalid_request",
	}
	if terrain_state == null or scheduler == null:
		rejected["reason"] = "field_unavailable"
		return rejected
	if requested_volume_m3 <= MIN_VOLUME_M3 or radius_m <= 0.0 or not terrain_state.is_inside_grid(center_xz):
		_rejected_volume_m3 += maxf(requested_volume_m3, 0.0)
		return rejected
	var sign_value := -1.0 if kind == "activate" else 1.0
	var unit_volume := terrain_state.estimate_brush_volume(center_xz, radius_m, sign_value)
	if unit_volume <= MIN_VOLUME_M3:
		rejected["reason"] = "empty_support"
		_rejected_volume_m3 += requested_volume_m3
		return rejected
	var delta_m := sign_value * requested_volume_m3 / unit_volume
	var estimated_volume := terrain_state.estimate_brush_volume(center_xz, radius_m, delta_m)
	if estimated_volume <= MIN_VOLUME_M3:
		rejected["reason"] = "empty_transaction"
		_rejected_volume_m3 += requested_volume_m3
		return rejected
	# Negative brushes can hit their three-metre safety floor. One correction
	# keeps the committed amount conservative without exposing cell mutation.
	if kind == "activate" and estimated_volume < requested_volume_m3 * 0.999:
		delta_m *= requested_volume_m3 / estimated_volume
		estimated_volume = terrain_state.estimate_brush_volume(center_xz, radius_m, delta_m)
	var before_stable_volume := _layer_volume(terrain_state.stable_heights)
	var before_loose_volume := _layer_volume(terrain_state.loose_depth)
	var sequence := _transaction_sequence
	_transaction_sequence += 1
	var transfer_id := "active-patch:%d:%s:%s" % [sequence, kind, transfer_hint]
	if not scheduler.queue_brush(
		sequence,
		center_xz,
		radius_m,
		delta_m,
		terrain_state.world_generation,
		transfer_id,
	):
		rejected["reason"] = "scheduler_rejected"
		_rejected_volume_m3 += requested_volume_m3
		return rejected
	var commit := scheduler.step_fixed(0.0, true)
	if not bool(commit.get("changed", false)) or not (commit.get("committed_transfer_ids", []) as Array).has(transfer_id):
		rejected["reason"] = String(commit.get("reason", "commit_rejected"))
		_rejected_volume_m3 += requested_volume_m3
		return rejected
	if kind == "activate":
		_activated_volume_m3 += estimated_volume
	else:
		_settled_volume_m3 += estimated_volume
	var after_stable_volume := _layer_volume(terrain_state.stable_heights)
	var after_loose_volume := _layer_volume(terrain_state.loose_depth)
	var stable_volume := maxf(0.0, before_stable_volume - after_stable_volume) if kind == "activate" else 0.0
	var loose_volume := (
		maxf(0.0, before_loose_volume - after_loose_volume)
		if kind == "activate"
		else maxf(0.0, after_loose_volume - before_loose_volume)
	)
	_update_compaction(center_xz, radius_m, kind == "settle")
	if kind == "settle":
		_relax_loose_soil(center_xz, radius_m)
	return {
		"accepted": true,
		"kind": kind,
		"requested_volume_m3": requested_volume_m3,
		"committed_volume_m3": estimated_volume,
		"stable_volume_m3": stable_volume,
		"loose_volume_m3": loose_volume,
		"transfer_id": transfer_id,
		"reason": "committed",
	}


## Deposits loose material through one absolute unique-cell patch. The returned
## committed amount is derived from the quantized row targets that TerrainState
## will install, never from a brush estimate.
func _commit_settlement_patch(center_xz: Vector2, requested_volume_m3: float, radius_m: float, transfer_hint: String) -> Dictionary:
	var rejected := {
		"accepted": false,
		"kind": "settle",
		"requested_volume_m3": requested_volume_m3,
		"committed_volume_m3": 0.0,
		"reason": "invalid_request",
	}
	if terrain_state == null or scheduler == null:
		rejected["reason"] = "field_unavailable"
		return rejected
	if requested_volume_m3 <= MIN_VOLUME_M3 or radius_m <= 0.0 or not terrain_state.is_inside_grid(center_xz):
		_rejected_volume_m3 += maxf(requested_volume_m3, 0.0)
		return rejected
	var snapshot := terrain_state.cell_patch_read_snapshot()
	var stable := snapshot["stable_heights"] as PackedFloat32Array
	var loose := snapshot["loose_depth"] as PackedFloat32Array
	var support := _settlement_support(center_xz, radius_m)
	if support.is_empty():
		rejected["reason"] = "empty_support"
		_rejected_volume_m3 += requested_volume_m3
		return rejected
	var total_weight := 0.0
	for cell in support:
		total_weight += float((cell as Dictionary)["weight"])
	if total_weight <= 0.0:
		rejected["reason"] = "empty_support"
		_rejected_volume_m3 += requested_volume_m3
		return rejected
	var cell_area := terrain_state.spacing_m * terrain_state.spacing_m
	var patch_rows: Array[Dictionary] = []
	var committed_volume := 0.0
	for cell in support:
		var index := int((cell as Dictionary)["index"])
		var original_loose := float(loose[index])
		var target_loose := _as_float32(original_loose + requested_volume_m3 * float((cell as Dictionary)["weight"]) / total_weight / cell_area)
		if target_loose <= original_loose:
			continue
		committed_volume += (target_loose - original_loose) * cell_area
		patch_rows.append({
			"index": index,
			"original_stable_height": float(stable[index]),
			"original_loose_depth": original_loose,
			"target_stable_height": float(stable[index]),
			"target_loose_depth": target_loose,
			"action": "settle_loose",
			"contributing_region_ids": ["active_soil_settlement"],
		})
	if patch_rows.is_empty() or committed_volume <= MIN_VOLUME_M3:
		rejected["reason"] = "empty_transaction"
		_rejected_volume_m3 += requested_volume_m3
		return rejected
	# Float32 layer storage can leave a small allocation residual. Assign it to
	# the last canonical row so metadata and the installed layer remain exact.
	var last_row := patch_rows[patch_rows.size() - 1]
	var residual := requested_volume_m3 - committed_volume
	if not is_zero_approx(residual):
		var previous_target := float(last_row["target_loose_depth"])
		var corrected_target := _as_float32(maxf(float(last_row["original_loose_depth"]), previous_target + residual / cell_area))
		last_row["target_loose_depth"] = corrected_target
		patch_rows[patch_rows.size() - 1] = last_row
		committed_volume += (corrected_target - previous_target) * cell_area
	var sequence := _transaction_sequence
	_transaction_sequence += 1
	var transfer_id := "active-patch:%d:settle:%s" % [sequence, transfer_hint]
	var cell_patch := {
		"schema_version": SoilCellPatch.SCHEMA_VERSION,
		"generation": terrain_state.world_generation,
		"base_revision": terrain_state.terrain_revision,
		"tick": sequence,
		"tool_identity": transfer_id,
		"rows": patch_rows,
		"removed_stable_m3": 0.0,
		"removed_loose_m3": 0.0,
		"added_loose_m3": committed_volume,
		"dirty_rect_cells": SoilCellPatch.dirty_rect(patch_rows, terrain_state.columns),
	}
	cell_patch["patch_hash"] = SoilCellPatch.compute_hash(cell_patch)
	if not scheduler.queue_cell_patch(sequence, cell_patch, terrain_state.world_generation, transfer_id):
		rejected["reason"] = "scheduler_rejected"
		_rejected_volume_m3 += requested_volume_m3
		return rejected
	var commit := scheduler.step_fixed(0.0, true)
	if not bool(commit.get("changed", false)) or not (commit.get("committed_transfer_ids", []) as Array).has(transfer_id):
		rejected["reason"] = String(commit.get("reason", "commit_rejected"))
		_rejected_volume_m3 += requested_volume_m3
		return rejected
	_settled_volume_m3 += committed_volume
	_update_compaction(center_xz, radius_m, true)
	_relax_loose_soil(center_xz, radius_m)
	return {
		"accepted": true,
		"kind": "settle",
		"requested_volume_m3": requested_volume_m3,
		"committed_volume_m3": committed_volume,
		"stable_volume_m3": 0.0,
		"loose_volume_m3": committed_volume,
		"transfer_id": transfer_id,
		"reason": "committed",
	}


func _settlement_support(center_xz: Vector2, radius_m: float) -> Array[Dictionary]:
	var support: Array[Dictionary] = []
	var min_column := clampi(floori((center_xz.x - radius_m - terrain_state.origin_xz.x) / terrain_state.spacing_m), 0, terrain_state.columns - 1)
	var max_column := clampi(ceili((center_xz.x + radius_m - terrain_state.origin_xz.x) / terrain_state.spacing_m), 0, terrain_state.columns - 1)
	var min_row := clampi(floori((center_xz.y - radius_m - terrain_state.origin_xz.y) / terrain_state.spacing_m), 0, terrain_state.rows - 1)
	var max_row := clampi(ceili((center_xz.y + radius_m - terrain_state.origin_xz.y) / terrain_state.spacing_m), 0, terrain_state.rows - 1)
	for row in range(min_row, max_row + 1):
		for column in range(min_column, max_column + 1):
			var cell_world := terrain_state.origin_xz + Vector2(float(column), float(row)) * terrain_state.spacing_m
			var distance := cell_world.distance_to(center_xz)
			if distance >= radius_m:
				continue
			var normalized := 1.0 - distance / radius_m
			support.append({"index": row * terrain_state.columns + column, "weight": normalized * normalized})
	if support.is_empty():
		var column := clampi(roundi((center_xz.x - terrain_state.origin_xz.x) / terrain_state.spacing_m), 0, terrain_state.columns - 1)
		var row := clampi(roundi((center_xz.y - terrain_state.origin_xz.y) / terrain_state.spacing_m), 0, terrain_state.rows - 1)
		support.append({"index": row * terrain_state.columns + column, "weight": 1.0})
	return support


func _as_float32(value: float) -> float:
	var packed := PackedFloat32Array()
	packed.append(value)
	return float(packed[0])


func _relax_loose_soil(center_xz: Vector2, radius_m: float) -> void:
	if terrain_state == null or scheduler == null:
		return
	var halo_radius := radius_m + terrain_state.spacing_m * 2.0
	var min_column := clampi(floori((center_xz.x - halo_radius - terrain_state.origin_xz.x) / terrain_state.spacing_m), 0, terrain_state.columns - 1)
	var max_column := clampi(ceili((center_xz.x + halo_radius - terrain_state.origin_xz.x) / terrain_state.spacing_m), 0, terrain_state.columns - 1)
	var min_row := clampi(floori((center_xz.y - halo_radius - terrain_state.origin_xz.y) / terrain_state.spacing_m), 0, terrain_state.rows - 1)
	var max_row := clampi(ceili((center_xz.y + halo_radius - terrain_state.origin_xz.y) / terrain_state.spacing_m), 0, terrain_state.rows - 1)
	var frontier: Array[int] = []
	for row in range(min_row, max_row + 1):
		for column in range(min_column, max_column + 1):
			frontier.append(row * terrain_state.columns + column)
	_schedule_flux_frontier(frontier, Vector2.ZERO)
	step_pending_flux()


func schedule_tool_flux(dirty_rect_cells: Rect2i, horizontal_impulse_xz: Vector2) -> bool:
	if terrain_state == null or dirty_rect_cells.size.x <= 0 or dirty_rect_cells.size.y <= 0:
		return false
	var minimum := Vector2i(
		maxi(0, dirty_rect_cells.position.x - 2),
		maxi(0, dirty_rect_cells.position.y - 2),
	)
	var maximum := Vector2i(
		mini(terrain_state.columns - 1, dirty_rect_cells.end.x + 1),
		mini(terrain_state.rows - 1, dirty_rect_cells.end.y + 1),
	)
	var frontier: Array[int] = []
	for row in range(minimum.y, maximum.y + 1):
		for column in range(minimum.x, maximum.x + 1):
			frontier.append(row * terrain_state.columns + column)
	_schedule_flux_frontier(frontier, horizontal_impulse_xz)
	return not _pending_flux_frontier.is_empty()


func step_pending_flux() -> Dictionary:
	if _pending_flux_frontier.is_empty():
		return {"changed": false, "reason": "frontier_empty"}
	var frontier: Array[int] = []
	for index_value in _pending_flux_frontier.keys():
		frontier.append(int(index_value))
	frontier.sort()
	var result := _commit_flux(frontier, _pending_flux_impulse)
	_pending_flux_steps += 1
	var reason := String(result.get("reason", "unavailable"))
	if reason == "below_repose":
		_pending_flux_frontier.clear()
		_pending_flux_impulse = Vector2.ZERO
		_pending_flux_steps = 0
	elif bool(result.get("changed", false)):
		# Tool bias is an impulse, not a permanent force. Repose-only passes may
		# continue on the retained deterministic frontier in later ticks.
		_pending_flux_impulse = Vector2.ZERO
	return result


func _schedule_flux_frontier(frontier: Array[int], horizontal_impulse_xz: Vector2) -> void:
	if terrain_state == null:
		return
	for index in frontier:
		if index >= 0 and index < terrain_state.rows * terrain_state.columns:
			_pending_flux_frontier[index] = true
	_pending_flux_impulse += horizontal_impulse_xz.limit_length(1.0)
	_pending_flux_impulse = _pending_flux_impulse.limit_length(1.0)


func _commit_flux(frontier: Array[int], horizontal_impulse_xz: Vector2) -> Dictionary:
	var sequence := _transaction_sequence
	_transaction_sequence += 1
	var result := _flux_solver.build_patch(
		terrain_state.cell_patch_read_snapshot(),
		_compaction,
		material_preset,
		frontier,
		sequence,
		LooseSoilFluxSolver.DEFAULT_PASSES,
		horizontal_impulse_xz,
	)
	_last_flux_result = {
		"valid": bool(result.get("valid", false)),
		"reason": String(result.get("reason", "unavailable")),
		"changed_cell_count": int(result.get("changed_cell_count", 0)),
		"moved_volume_m3": float(result.get("moved_volume_m3", 0.0)),
		"passes": int(result.get("passes", 0)),
	}
	if not bool(result.get("valid", false)):
		return {"changed": false, "reason": String(result.get("reason", "invalid"))}
	var cell_patch := result.get("patch", {}) as Dictionary
	var transfer_id := "active-patch:%d:repose:%s" % [sequence, String(cell_patch.get("patch_hash", ""))]
	if not scheduler.queue_cell_patch(sequence, cell_patch, terrain_state.world_generation, transfer_id):
		_flux_rejection_count += 1
		_last_flux_result["reason"] = "scheduler_rejected"
		return {"changed": false, "reason": "scheduler_rejected"}
	var commit := scheduler.step_fixed(0.0, true)
	if not bool(commit.get("changed", false)) or not (commit.get("committed_transfer_ids", []) as Array).has(transfer_id):
		_flux_rejection_count += 1
		_last_flux_result["reason"] = String(commit.get("reason", "commit_rejected"))
		return {"changed": false, "reason": _last_flux_result["reason"]}
	_flux_commit_count += 1
	_flux_moved_volume_m3 += float(result.get("moved_volume_m3", 0.0))
	_last_flux_result["reason"] = "committed"
	return {"changed": true, "reason": "committed", "moved_volume_m3": float(result.get("moved_volume_m3", 0.0))}


func _layer_volume(layer: PackedFloat32Array) -> float:
	if terrain_state == null:
		return 0.0
	var total := 0.0
	var cell_area := terrain_state.spacing_m * terrain_state.spacing_m
	for value in layer:
		total += float(value) * cell_area
	return total


func _update_compaction(center_xz: Vector2, radius_m: float, settling: bool) -> void:
	if terrain_state == null:
		return
	var preset_target := float((MATERIAL_PRESETS[material_preset] as Dictionary)["compaction"])
	var min_column := clampi(floori((center_xz.x - radius_m - terrain_state.origin_xz.x) / terrain_state.spacing_m), 0, terrain_state.columns - 1)
	var max_column := clampi(ceili((center_xz.x + radius_m - terrain_state.origin_xz.x) / terrain_state.spacing_m), 0, terrain_state.columns - 1)
	var min_row := clampi(floori((center_xz.y - radius_m - terrain_state.origin_xz.y) / terrain_state.spacing_m), 0, terrain_state.rows - 1)
	var max_row := clampi(ceili((center_xz.y + radius_m - terrain_state.origin_xz.y) / terrain_state.spacing_m), 0, terrain_state.rows - 1)
	for row in range(min_row, max_row + 1):
		for column in range(min_column, max_column + 1):
			var cell_world := terrain_state.origin_xz + Vector2(float(column), float(row)) * terrain_state.spacing_m
			var distance := cell_world.distance_to(center_xz)
			if distance > radius_m:
				continue
			var index := row * terrain_state.columns + column
			var influence := 1.0 - distance / radius_m
			var target := clampf(preset_target + (0.08 if settling else -0.08), 0.0, 1.0)
			_compaction[index] = lerpf(_compaction[index], target, influence * 0.3)


func _cell_index(world_xz: Vector2) -> int:
	if terrain_state == null or not terrain_state.is_inside_grid(world_xz):
		return -1
	var column := clampi(roundi((world_xz.x - terrain_state.origin_xz.x) / terrain_state.spacing_m), 0, terrain_state.columns - 1)
	var row := clampi(roundi((world_xz.y - terrain_state.origin_xz.y) / terrain_state.spacing_m), 0, terrain_state.rows - 1)
	return row * terrain_state.columns + column

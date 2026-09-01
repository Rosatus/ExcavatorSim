class_name SoilInteractionAuthority
extends RefCounted

## Generation-scoped sole writer for the conservative material lifecycle. In
## shadow mode it observes beside legacy product truth; in active_patch mode its
## ledger and ActiveSoilPatch are the selected product material authority.

const SCHEMA_VERSION := "soil-interaction-authority-v1"
const TRANSACTION_SCHEMA_VERSION := "soil-material-transaction-v1"
const EPSILON_M3 := 0.000001
const MAX_JOURNAL_ROWS := 512
const MAX_DISPLACEMENT_PER_TICK_M3 := 0.025
const COMPARTMENTS := ["persistent_stable", "persistent_loose", "active", "bucket", "released"]
const DISPLACEMENT_ACTIONS := ["cut", "side_cut", "scrape", "grade"]

var mode := "shadow"
var configured := false
var model_id := ""
var generation := -1
var material_preset := "loose"
var bucket_capacity_m3 := 0.0
var nominal_capacity_m3 := 0.0
var material_density_kg_m3 := 1600.0
var spill_opening_down_dot := 0.05
var dump_opening_down_dot := 0.3

var _grid_dimensions := Vector3i.ONE
var _cell_capacity_m3 := 0.0
var _cell_fill := PackedFloat32Array()
var _compartment_volume := {
	"persistent_stable": 0.0,
	"persistent_loose": 0.0,
	"active": 0.0,
	"bucket": 0.0,
	"released": 0.0,
}
var _transaction_sequence := 0
var _last_tick := -1
var _journal: Array[Dictionary] = []
var _residuals: Dictionary = {}
var _seen_inputs: Dictionary = {}
var _accepted_moved_volume_m3 := 0.0
var _rejected_volume_m3 := 0.0
var _invariant_failure_count := 0
var _overflow_volume_m3 := 0.0
var _last_surface_patch: Dictionary = {}
var _surface_patch_commits := 0
var _surface_patch_rejections := 0


func configure(
	contract: Dictionary,
	requested_generation: int,
	requested_material: String = "loose",
	requested_mode: String = "shadow"
) -> bool:
	clear()
	if (
		contract.get("schema_version", "") != "excavator-soil-contract-v1"
		or requested_generation < 0
		or requested_material not in ["loose", "compact", "sand", "damp"]
		or requested_mode not in ["shadow", "active_patch"]
	):
		return false
	var grid := contract.get("cell_grid", []) as Array
	if grid.size() != 3:
		return false
	_grid_dimensions = Vector3i(int(grid[0]), int(grid[1]), int(grid[2]))
	if _grid_dimensions.x < 2 or _grid_dimensions.y < 2 or _grid_dimensions.z < 2:
		return false
	bucket_capacity_m3 = float(contract.get("heaped_capacity_m3", 0.0))
	nominal_capacity_m3 = float(contract.get("nominal_capacity_m3", 0.0))
	material_density_kg_m3 = float(contract.get("material_density_kg_m3", 0.0))
	var interaction := contract.get("interaction", {}) as Dictionary
	spill_opening_down_dot = float(interaction.get("spill_opening_down_dot", 0.05))
	dump_opening_down_dot = float(interaction.get("dump_opening_down_dot", 0.3))
	if bucket_capacity_m3 <= EPSILON_M3 or nominal_capacity_m3 <= EPSILON_M3 or material_density_kg_m3 <= 0.0:
		return false
	if (
		spill_opening_down_dot < -1.0
		or spill_opening_down_dot > 1.0
		or dump_opening_down_dot < -1.0
		or dump_opening_down_dot > 1.0
		or spill_opening_down_dot >= dump_opening_down_dot
	):
		return false
	var cell_count := _grid_dimensions.x * _grid_dimensions.y * _grid_dimensions.z
	_cell_fill.resize(cell_count)
	_cell_capacity_m3 = bucket_capacity_m3 / float(cell_count)
	model_id = String(contract.get("model_id", ""))
	generation = requested_generation
	material_preset = requested_material
	mode = requested_mode
	configured = not model_id.is_empty()
	return configured


func clear() -> void:
	mode = "shadow"
	configured = false
	model_id = ""
	generation = -1
	material_preset = "loose"
	bucket_capacity_m3 = 0.0
	nominal_capacity_m3 = 0.0
	material_density_kg_m3 = 1600.0
	spill_opening_down_dot = 0.05
	dump_opening_down_dot = 0.3
	_grid_dimensions = Vector3i.ONE
	_cell_capacity_m3 = 0.0
	_cell_fill = PackedFloat32Array()
	_compartment_volume = {"persistent_stable": 0.0, "persistent_loose": 0.0, "active": 0.0, "bucket": 0.0, "released": 0.0}
	_transaction_sequence = 0
	_last_tick = -1
	_journal.clear()
	_residuals.clear()
	_seen_inputs.clear()
	_accepted_moved_volume_m3 = 0.0
	_rejected_volume_m3 = 0.0
	_invariant_failure_count = 0
	_overflow_volume_m3 = 0.0
	_last_surface_patch.clear()
	_surface_patch_commits = 0
	_surface_patch_rejections = 0


func step_fixed(
	delta: float,
	tick: int,
	tool_snapshot: Dictionary,
	tool_classification: Dictionary,
	patch: ActiveSoilPatch,
	focus_world: Vector3,
	surface_sweep_result: Dictionary = {},
	terrain_scheduler: TerrainCommitScheduler = null,
	solver_mode: String = "point_brush_v1"
) -> Dictionary:
	if not configured or patch == null or patch.generation < 0:
		return {"changed": false, "reason": "authority_unavailable"}
	if tick < _last_tick:
		return {"changed": false, "reason": "stale_tick"}
	var input_key := "%d:%d:%s" % [generation, tick, String(tool_snapshot.get("identity", ""))]
	if _seen_inputs.has(input_key):
		return {"changed": false, "reason": "duplicate_tick"}
	_seen_inputs[input_key] = true
	while _seen_inputs.size() > 512:
		_seen_inputs.erase(_seen_inputs.keys()[0])
	_last_tick = tick
	var before_sequence := _transaction_sequence
	_consume_patch_settlements(patch, tick)
	_capture_contained_soil(patch, tick)
	_overflow_volume_m3 = maxf(0.0, float(patch.get_status_snapshot().get("contained_volume_m3", 0.0)))
	_release_bucket_soil(delta, tick, tool_snapshot, patch)
	var surface_commit := {"changed": false, "reason": "solver_not_selected"}
	if solver_mode == "point_brush_v1":
		_activate_full_tool_displacement(delta, tick, tool_snapshot, tool_classification, patch)
	elif solver_mode == "surface_patch_v2_shadow":
		_observe_surface_patch(surface_sweep_result)
		_activate_full_tool_displacement(delta, tick, tool_snapshot, tool_classification, patch)
		surface_commit["reason"] = "shadow_observed"
	elif solver_mode == "surface_patch_v2":
		surface_commit = _activate_surface_patch(delta, tick, tool_snapshot, surface_sweep_result, patch, terrain_scheduler)
		_schedule_classified_loose_flux(delta, tool_snapshot, tool_classification, patch)
	_capture_scoop_flux(tick, tool_snapshot, tool_classification, patch)
	_settle_bucket_cells(tool_snapshot, delta)
	patch.step_fixed(delta, focus_world, tool_snapshot)
	_consume_patch_settlements(patch, tick)
	_capture_contained_soil(patch, tick)
	_overflow_volume_m3 = maxf(0.0, float(patch.get_status_snapshot().get("contained_volume_m3", 0.0)))
	var result := {
		"changed": _transaction_sequence != before_sequence,
		"reason": "stepped",
		"transactions": _transaction_sequence - before_sequence,
		"ledger_identity": _ledger_identity(),
	}
	result["surface_patch_commit"] = surface_commit
	return result


func _schedule_classified_loose_flux(
	delta: float,
	tool_snapshot: Dictionary,
	classification: Dictionary,
	patch: ActiveSoilPatch,
) -> void:
	var state := patch.persistent_field.terrain_state
	if state == null:
		return
	for candidate_value in classification.get("candidates", []):
		var candidate := candidate_value as Dictionary
		var action := String(candidate.get("classification", "none"))
		if action not in ["push", "back_drag", "grade"] or String(candidate.get("role_scope", "none")) != "stable":
			continue
		var region := _find_region(tool_snapshot.get("regions", []) as Array, String(candidate.get("region_id", "")))
		if region.is_empty():
			continue
		var motion := region.get("motion_world", Vector3.ZERO) as Vector3
		var impulse := Vector2(motion.x, motion.z) / maxf(delta, 0.0001)
		if impulse.length_squared() <= 0.000001:
			continue
		var minimum := Vector2(INF, INF)
		var maximum := Vector2(-INF, -INF)
		for point_value in region.get("swept_points", []):
			var point := point_value as Vector3
			minimum = minimum.min(Vector2(point.x, point.z))
			maximum = maximum.max(Vector2(point.x, point.z))
		if not minimum.is_finite() or not maximum.is_finite():
			continue
		var min_column := clampi(floori((minimum.x - state.origin_xz.x) / state.spacing_m), 0, state.columns - 1)
		var max_column := clampi(ceili((maximum.x - state.origin_xz.x) / state.spacing_m), 0, state.columns - 1)
		var min_row := clampi(floori((minimum.y - state.origin_xz.y) / state.spacing_m), 0, state.rows - 1)
		var max_row := clampi(ceili((maximum.y - state.origin_xz.y) / state.spacing_m), 0, state.rows - 1)
		patch.schedule_loose_flux(Rect2i(min_column, min_row, max_column - min_column + 1, max_row - min_row + 1), impulse)


func get_status_snapshot() -> Dictionary:
	var bucket_volume := float(_compartment_volume["bucket"])
	var drift := 0.0
	for compartment in COMPARTMENTS:
		drift += float(_compartment_volume[compartment])
	var latest: Dictionary = _journal.back().duplicate(true) if not _journal.is_empty() else {}
	return {
		"schema_version": SCHEMA_VERSION,
		"mode": mode,
		"configured": configured,
		"model_id": model_id,
		"generation": generation,
		"material_preset": material_preset,
		"ledger_identity": _ledger_identity(),
		"transaction_sequence": _transaction_sequence,
		"last_tick": _last_tick,
		"compartments_m3": _compartment_volume.duplicate(true),
		"conservation_drift_m3": drift,
		"accepted_moved_volume_m3": _accepted_moved_volume_m3,
		"rejected_volume_m3": _rejected_volume_m3,
		"residual_volume_m3": _residual_total(),
		"invariant_failure_count": _invariant_failure_count,
		"overflow_volume_m3": _overflow_volume_m3,
		"bucket_capacity_m3": bucket_capacity_m3,
		"nominal_capacity_m3": nominal_capacity_m3,
		"bucket_volume_m3": bucket_volume,
		"payload_mass_kg": bucket_volume * material_density_kg_m3,
		"fill_ratio": bucket_volume / bucket_capacity_m3 if bucket_capacity_m3 > EPSILON_M3 else 0.0,
		"occupied_cells": _occupied_cell_count(),
		"cell_count": _cell_fill.size(),
		"cell_grid": [_grid_dimensions.x, _grid_dimensions.y, _grid_dimensions.z],
		"fill_profile": _build_fill_profile(),
		"center_of_mass_local": _center_of_mass_local(),
		"journal_size": _journal.size(),
		"last_transaction": latest,
		"snapshot_sha256": _snapshot_hash(),
		"surface_patch_commits": _surface_patch_commits,
		"surface_patch_rejections": _surface_patch_rejections,
		"last_surface_patch": _last_surface_patch.duplicate(true),
	}


func get_journal_snapshot() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for row in _journal:
		result.append(row.duplicate(true))
	return result


## Converts every transient compartment into persistent loose terrain before
## an ordinary model/pose authority boundary. A world reset is separately
## destructive and does not call this path.
func settle_all_for_boundary(patch: ActiveSoilPatch, tick: int, origin_world: Vector3) -> Dictionary:
	if not configured or patch == null or patch.generation != generation:
		return {"drained": false, "reason": "authority_unavailable"}
	patch.flush_all()
	_consume_patch_settlements(patch, tick)
	var bucket_volume := float(_compartment_volume["bucket"])
	if bucket_volume > EPSILON_M3:
		var transfer_hint := "%d:%d:boundary-release" % [generation, tick]
		var release_event := {
			"center": Vector2(origin_world.x, origin_world.z),
			"tooth_world": origin_world,
			"tooth_velocity": Vector3.ZERO,
			"volume_m3": bucket_volume,
		}
		var reservation := patch.reserve_predebited_volume(release_event, transfer_hint, "released")
		if not bool(reservation.get("accepted", false)):
			return {"drained": false, "reason": String(reservation.get("reason", "reservation_rejected"))}
		var debited := _remove_bucket_volume(bucket_volume)
		if absf(debited - bucket_volume) > _transaction_tolerance(bucket_volume):
			patch.cancel_predebited_volume(transfer_hint)
			if debited > EPSILON_M3:
				_add_bucket_volume(debited)
			_invariant_failure_count += 1
			return {"drained": false, "reason": "bucket_debit_invariant"}
		var injection := patch.commit_predebited_volume(transfer_hint)
		if not bool(injection.get("accepted", false)):
			_add_bucket_volume(debited)
			_invariant_failure_count += 1
			return {"drained": false, "reason": String(injection.get("reason", "release_commit_failed"))}
		var injected := float(injection.get("volume_m3", 0.0))
		if absf(injected - debited) > _transaction_tolerance(debited):
			_invariant_failure_count += 1
			return {"drained": false, "reason": "release_volume_invariant"}
		_record_transaction(tick, "boundary_release", "bucket", "released", bucket_volume, debited, origin_world, Vector3.ZERO, {
			"aggregate_id": String(injection.get("aggregate_id", "")),
		})
	patch.flush_all()
	_consume_patch_settlements(patch, tick)
	var patch_status := patch.get_status_snapshot()
	var remaining_mobile := float(patch_status.get("active_volume_m3", 0.0))
	var remaining_bucket := float(_compartment_volume["bucket"])
	var remaining_active := float(_compartment_volume["active"])
	var remaining_released := float(_compartment_volume["released"])
	var drained := (
		remaining_mobile <= EPSILON_M3
		and remaining_bucket <= EPSILON_M3
		and remaining_active <= EPSILON_M3
		and remaining_released <= EPSILON_M3
	)
	return {
		"drained": drained,
		"reason": "drained" if drained else "transient_material_remaining",
		"remaining_mobile_m3": remaining_mobile,
		"remaining_bucket_m3": remaining_bucket,
		"remaining_active_m3": remaining_active,
		"remaining_released_m3": remaining_released,
	}


func _activate_full_tool_displacement(
	delta: float,
	tick: int,
	tool_snapshot: Dictionary,
	classification: Dictionary,
	patch: ActiveSoilPatch
) -> void:
	if not bool(tool_snapshot.get("valid", false)) or not bool(classification.get("valid", false)):
		return
	var regions_by_id := {}
	for region_value in tool_snapshot.get("regions", []):
		var region := region_value as Dictionary
		regions_by_id[String(region.get("region_id", ""))] = region
	var best := {}
	var best_requested := 0.0
	var best_priority := -1
	for candidate_value in classification.get("candidates", []):
		var candidate := candidate_value as Dictionary
		var action := String(candidate.get("classification", "none"))
		if action not in DISPLACEMENT_ACTIONS or String(candidate.get("role_scope", "none")) != "stable":
			continue
		var region_id := String(candidate.get("region_id", ""))
		var region := regions_by_id.get(region_id, {}) as Dictionary
		var requested := _candidate_volume(candidate, region)
		var priority := 4 - DISPLACEMENT_ACTIONS.find(action)
		if priority > best_priority or (priority == best_priority and requested > best_requested):
			best_priority = priority
			best_requested = requested
			best = {"candidate": candidate, "region": region, "action": action}
	if best.is_empty():
		return
	var candidate := best["candidate"] as Dictionary
	var region := best["region"] as Dictionary
	var action := String(best["action"])
	var residual_key := "%s:%s" % [String(candidate.get("region_id", "")), action]
	var requested_with_residual := best_requested + float(_residuals.get(residual_key, 0.0))
	if requested_with_residual <= EPSILON_M3:
		_residuals[residual_key] = requested_with_residual
		return
	var origin := candidate.get("point_world", region.get("current_center_world", Vector3.ZERO)) as Vector3
	var velocity := (region.get("motion_world", Vector3.ZERO) as Vector3) / maxf(delta, 0.0001)
	var input_id := "%d:%d:%s:%s" % [generation, tick, String(candidate.get("region_id", "")), action]
	var injection := patch.inject_tool_volume({
		"center": Vector2(origin.x, origin.z),
		"tooth_world": origin,
		"tooth_velocity": velocity,
		"volume_m3": requested_with_residual,
	}, input_id)
	if not bool(injection.get("accepted", false)):
		_record_transaction(tick, action, "persistent_stable", "active", requested_with_residual, 0.0, origin, velocity, {
			"region_id": String(candidate.get("region_id", "")),
			"reason": String(injection.get("reason", "patch_rejected")),
		})


		return
	var accepted := float(injection.get("volume_m3", 0.0))
	var stable_source := float(injection.get("stable_source_volume_m3", 0.0))
	var loose_source := float(injection.get("loose_source_volume_m3", 0.0))
	var source_total := stable_source + loose_source
	if absf(source_total - accepted) > _transaction_tolerance(accepted):
		_invariant_failure_count += 1
		if source_total > EPSILON_M3:
			var scale := accepted / source_total
			stable_source *= scale
			loose_source *= scale
	_residuals[residual_key] = maxf(0.0, requested_with_residual - accepted)
	var metadata := {
		"region_id": String(candidate.get("region_id", "")),
		"aggregate_id": String(injection.get("aggregate_id", "")),
	}
	if stable_source > EPSILON_M3:
		_record_transaction(tick, action, "persistent_stable", "active", stable_source, stable_source, origin, velocity, metadata)
	if loose_source > EPSILON_M3:
		_record_transaction(tick, action, "persistent_loose", "active", loose_source, loose_source, origin, velocity, metadata)
	var rejected := maxf(0.0, requested_with_residual - accepted)
	if rejected > EPSILON_M3:
		_record_transaction(tick, action, "persistent_stable", "active", rejected, 0.0, origin, velocity, {
			"region_id": String(candidate.get("region_id", "")),
			"reason": "activation_residual",
		})


func _observe_surface_patch(surface_sweep_result: Dictionary) -> void:
	_last_surface_patch = {
		"valid": bool(surface_sweep_result.get("valid", false)),
		"reason": String(surface_sweep_result.get("reason", "unavailable")),
		"patch_hash": String(surface_sweep_result.get("patch_hash", "")),
		"changed_cell_count": int(surface_sweep_result.get("changed_cell_count", 0)),
		"removed_stable_m3": float(surface_sweep_result.get("removed_stable_m3", 0.0)),
		"removed_loose_m3": float(surface_sweep_result.get("removed_loose_m3", 0.0)),
	}


func _activate_surface_patch(
	delta: float,
	tick: int,
	tool_snapshot: Dictionary,
	surface_sweep_result: Dictionary,
	active_patch: ActiveSoilPatch,
	terrain_scheduler: TerrainCommitScheduler
) -> Dictionary:
	_observe_surface_patch(surface_sweep_result)
	if not bool(surface_sweep_result.get("valid", false)):
		return {"changed": false, "reason": String(surface_sweep_result.get("reason", "surface_patch_unavailable"))}
	if terrain_scheduler == null or terrain_scheduler.terrain_state == null:
		_surface_patch_rejections += 1
		return {"changed": false, "reason": "terrain_scheduler_unavailable"}
	var cell_patch := surface_sweep_result.get("patch", {}) as Dictionary
	var validation := terrain_scheduler.terrain_state.validate_cell_patch(cell_patch)
	if not bool(validation.get("valid", false)):
		_surface_patch_rejections += 1
		return {"changed": false, "reason": "terrain_%s" % String(validation.get("reason", "patch_rejected"))}
	var metrics := SoilCellPatch.volume_metrics(cell_patch, terrain_scheduler.terrain_state.cell_patch_read_snapshot())
	var stable_volume := float(metrics.get("stable_removed_m3", 0.0))
	var loose_volume := float(metrics.get("loose_removed_m3", 0.0))
	var requested := stable_volume + loose_volume
	if requested <= EPSILON_M3:
		return {"changed": false, "reason": "empty_surface_patch"}
	var dirty := cell_patch.get("dirty_rect_cells", Rect2i()) as Rect2i
	var state := terrain_scheduler.terrain_state
	var center_xz := Vector2(
		state.origin_xz.x + (float(dirty.position.x) + float(dirty.size.x - 1) * 0.5) * state.spacing_m,
		state.origin_xz.y + (float(dirty.position.y) + float(dirty.size.y - 1) * 0.5) * state.spacing_m,
	)
	var surface_y := state.sample_surface_bilinear_at(center_xz)
	var origin := Vector3(center_xz.x, surface_y if is_finite(surface_y) else 0.0, center_xz.y)
	var velocity := Vector3.ZERO
	var contributing_regions: Array[String] = []
	for row_value in cell_patch.get("rows", []):
		var row := row_value as Dictionary
		for region_value in row.get("contributing_region_ids", []):
			var region_id := String(region_value)
			if not contributing_regions.has(region_id):
				contributing_regions.append(region_id)
	contributing_regions.sort()
	for region_id in contributing_regions:
		var region := _find_region(tool_snapshot.get("regions", []) as Array, region_id)
		if not region.is_empty():
			velocity = region.get("motion_world", Vector3.ZERO) as Vector3 / maxf(delta, 0.0001)
			break
	var patch_hash := String(cell_patch.get("patch_hash", ""))
	var reservation := active_patch.reserve_predebited_tool_volume({
		"center": center_xz,
		"tooth_world": origin,
		"tooth_velocity": velocity,
		"volume_m3": requested,
	}, patch_hash)
	if not bool(reservation.get("accepted", false)):
		_surface_patch_rejections += 1
		return {"changed": false, "reason": String(reservation.get("reason", "active_capacity_rejected"))}
	if not terrain_scheduler.queue_cell_patch(tick, cell_patch, generation, patch_hash):
		active_patch.cancel_predebited_tool_volume(patch_hash)
		_surface_patch_rejections += 1
		return {"changed": false, "reason": "terrain_queue_rejected"}
	var terrain_commit := terrain_scheduler.step_fixed(0.0, true)
	if not bool(terrain_commit.get("changed", false)):
		active_patch.cancel_predebited_tool_volume(patch_hash)
		_surface_patch_rejections += 1
		return {"changed": false, "reason": "terrain_commit_rejected", "terrain_commit": terrain_commit}
	var activation := active_patch.commit_predebited_tool_volume(patch_hash)
	if not bool(activation.get("accepted", false)):
		# This path is guarded by the reservation and therefore indicates an
		# internal invariant failure after the authoritative terrain write.
		_invariant_failure_count += 1
		_surface_patch_rejections += 1
		return {"changed": true, "reason": "post_commit_activation_invariant", "terrain_commit": terrain_commit}
	var metadata := {
		"patch_hash": patch_hash,
		"changed_cell_count": int(surface_sweep_result.get("changed_cell_count", 0)),
		"contributing_region_ids": contributing_regions,
		"aggregate_id": String(activation.get("aggregate_id", "")),
	}
	if stable_volume > EPSILON_M3:
		_record_transaction(tick, "surface_cut", "persistent_stable", "active", stable_volume, stable_volume, origin, velocity, metadata)
	if loose_volume > EPSILON_M3:
		_record_transaction(tick, "surface_cut", "persistent_loose", "active", loose_volume, loose_volume, origin, velocity, metadata)
	active_patch.schedule_loose_flux(dirty, Vector2(velocity.x, velocity.z))
	_surface_patch_commits += 1
	return {"changed": true, "reason": "surface_patch_committed", "terrain_commit": terrain_commit, "patch_hash": patch_hash}


func _capture_contained_soil(patch: ActiveSoilPatch, tick: int) -> void:
	var available := _bucket_available_volume()
	if available <= EPSILON_M3:
		return
	var extraction := patch.extract_contained_volume(available)
	if not bool(extraction.get("accepted", false)):
		return
	var requested := float(extraction.get("volume_m3", 0.0))
	var accepted := _add_bucket_volume(requested)
	if absf(accepted - requested) > _transaction_tolerance(requested):
		_invariant_failure_count += 1
		var restored := patch.restore_extracted_volume(extraction, requested - accepted, "%d:%d:contained-rollback" % [generation, tick])
		if not restored:
			_invariant_failure_count += 1
	_record_transaction(
		tick,
		"bucket_entry",
		"active",
		"bucket",
		requested,
		accepted,
		extraction.get("origin_world", Vector3.ZERO) as Vector3,
		extraction.get("velocity_world", Vector3.ZERO) as Vector3,
		{"reason": "opening_flux"},
	)


func _capture_scoop_flux(
	tick: int,
	tool_snapshot: Dictionary,
	classification: Dictionary,
	patch: ActiveSoilPatch,
) -> void:
	if not bool(tool_snapshot.get("valid", false)) or not bool(classification.get("valid", false)):
		return
	var available := _bucket_available_volume()
	var active_volume := maxf(0.0, float(_compartment_volume["active"]))
	if available <= EPSILON_M3 or active_volume <= EPSILON_M3:
		return
	var opening := _find_region(tool_snapshot.get("regions", []) as Array, "opening")
	if opening.is_empty():
		return
	var opening_down_dot := (
		(opening.get("outward_normal_world", Vector3.UP) as Vector3).dot(Vector3.DOWN)
	)
	if opening_down_dot > spill_opening_down_dot:
		return
	var best_motion := 0.0
	var best_action := "none"
	var best_region := ""
	for value in classification.get("candidates", []):
		var candidate := value as Dictionary
		var action := String(candidate.get("classification", "none"))
		if action not in DISPLACEMENT_ACTIONS or String(candidate.get("role_scope", "none")) != "stable":
			continue
		var motion := maxf(0.0, float(candidate.get("motion_m", 0.0)))
		if motion > best_motion:
			best_motion = motion
			best_action = action
			best_region = String(candidate.get("region_id", ""))
	if best_motion < 0.002:
		return
	var requested := minf(
		minf(available, active_volume * 0.6),
		bucket_capacity_m3 * clampf(best_motion, 0.0, 0.08) * 0.35,
	)
	var extraction := patch.extract_scoop_volume(
		requested,
		tool_snapshot.get("regions", []) as Array,
	)
	if not bool(extraction.get("accepted", false)):
		return
	var moved := float(extraction.get("volume_m3", 0.0))
	var accepted := _add_bucket_volume(moved)
	if absf(accepted - moved) > _transaction_tolerance(moved):
		_invariant_failure_count += 1
		var restored := patch.restore_extracted_volume(extraction, moved - accepted, "%d:%d:scoop-rollback" % [generation, tick])
		if not restored:
			_invariant_failure_count += 1
	_record_transaction(
		tick,
		"bucket_entry",
		"active",
		"bucket",
		moved,
		accepted,
		extraction.get("origin_world", Vector3.ZERO) as Vector3,
		extraction.get("velocity_world", Vector3.ZERO) as Vector3,
		{"reason": "scoop_flux", "action": best_action, "region_id": best_region},
	)


func _release_bucket_soil(delta: float, tick: int, tool_snapshot: Dictionary, patch: ActiveSoilPatch) -> void:
	var bucket_volume := float(_compartment_volume["bucket"])
	if bucket_volume <= EPSILON_M3 or not bool(tool_snapshot.get("valid", false)):
		return
	var opening := _find_region(tool_snapshot.get("regions", []) as Array, "opening")
	if opening.is_empty():
		return
	var opening_down_dot := (opening.get("outward_normal_world", Vector3.UP) as Vector3).dot(Vector3.DOWN)
	if opening_down_dot <= spill_opening_down_dot:
		return
	var exposure := clampf(
		(opening_down_dot - spill_opening_down_dot)
		/ maxf(0.01, 1.0 - spill_opening_down_dot),
		0.0,
		1.0,
	)
	var requested := minf(bucket_volume, bucket_capacity_m3 * lerpf(0.06, 1.35, exposure) * maxf(delta, 0.0))
	if requested <= EPSILON_M3 or not patch.can_accept_volume(requested):
		return
	var origin := opening.get("current_center_world", Vector3.ZERO) as Vector3
	var velocity := (opening.get("motion_world", Vector3.ZERO) as Vector3) / maxf(delta, 0.0001)
	velocity += Vector3.DOWN * lerpf(0.15, 0.8, exposure)
	var transfer_hint := "%d:%d:release" % [generation, tick]
	var release_event := {
		"center": Vector2(origin.x, origin.z),
		"tooth_world": origin,
		"tooth_velocity": velocity,
		"volume_m3": requested,
	}
	var reservation := patch.reserve_predebited_volume(release_event, transfer_hint, "released")
	if not bool(reservation.get("accepted", false)):
		_record_transaction(tick, "spill_or_dump", "bucket", "released", requested, 0.0, origin, velocity, {
			"reason": String(reservation.get("reason", "patch_rejected")),
		})
		return
	var debited := _remove_bucket_volume(requested)
	if absf(debited - requested) > _transaction_tolerance(requested):
		_invariant_failure_count += 1
		patch.cancel_predebited_volume(transfer_hint)
		if debited > EPSILON_M3:
			_add_bucket_volume(debited)
		return
	var injection := patch.commit_predebited_volume(transfer_hint)
	if not bool(injection.get("accepted", false)):
		_invariant_failure_count += 1
		_add_bucket_volume(debited)
		_record_transaction(tick, "spill_or_dump", "bucket", "released", requested, 0.0, origin, velocity, {
			"reason": String(injection.get("reason", "post_debit_commit_failed")),
		})
		return
	var accepted := float(injection.get("volume_m3", 0.0))
	if absf(accepted - debited) > _transaction_tolerance(debited):
		_invariant_failure_count += 1
	_record_transaction(tick, "dump" if opening_down_dot > dump_opening_down_dot else "spill", "bucket", "released", requested, debited, origin, velocity, {
		"opening_down_dot": opening_down_dot,
		"aggregate_id": String(injection.get("aggregate_id", "")),
	})


func _consume_patch_settlements(patch: ActiveSoilPatch, tick: int) -> void:
	for event in patch.consume_settlement_events():
		var source := String(event.get("compartment", "active"))
		if source not in ["active", "released"]:
			source = "active"
		var volume := float(event.get("volume_m3", 0.0))
		if volume <= EPSILON_M3:
			continue
		var available := float(_compartment_volume[source])
		var accepted := volume
		if volume > available + _transaction_tolerance(volume):
			_invariant_failure_count += 1
			accepted = minf(volume, maxf(available, 0.0))
		_record_transaction(
			tick,
			"settle",
			source,
			"persistent_loose",
			volume,
			accepted,
			event.get("origin_world", Vector3.ZERO) as Vector3,
			event.get("velocity_world", Vector3.ZERO) as Vector3,
			{"aggregate_id": String(event.get("aggregate_id", ""))},
		)


func _record_transaction(
	tick: int,
	kind: String,
	source: String,
	destination: String,
	requested_volume_m3: float,
	accepted_volume_m3: float,
	origin_world: Vector3,
	velocity_world: Vector3,
	metadata: Dictionary
) -> void:
	if source not in COMPARTMENTS or destination not in COMPARTMENTS or source == destination:
		_invariant_failure_count += 1
		return
	var accepted := clampf(accepted_volume_m3, 0.0, maxf(requested_volume_m3, 0.0))
	var transaction_id := "%d:%d" % [generation, _transaction_sequence]
	var source_delta := -accepted
	var destination_delta := accepted
	_compartment_volume[source] = float(_compartment_volume[source]) + source_delta
	_compartment_volume[destination] = float(_compartment_volume[destination]) + destination_delta
	for bounded_compartment in ["active", "bucket", "released"]:
		if absf(float(_compartment_volume[bounded_compartment])) <= _transaction_tolerance(accepted):
			_compartment_volume[bounded_compartment] = 0.0
	_accepted_moved_volume_m3 += accepted
	_rejected_volume_m3 += maxf(0.0, requested_volume_m3 - accepted)
	var deltas := {}
	deltas[source] = source_delta
	deltas[destination] = destination_delta
	var row := {
		"schema_version": TRANSACTION_SCHEMA_VERSION,
		"transaction_id": transaction_id,
		"sequence": _transaction_sequence,
		"tick": tick,
		"generation": generation,
		"model_id": model_id,
		"material_preset": material_preset,
		"kind": kind,
		"source": source,
		"destination": destination,
		"requested_volume_m3": requested_volume_m3,
		"accepted_volume_m3": accepted,
		"rejected_volume_m3": maxf(0.0, requested_volume_m3 - accepted),
		"deltas_m3": deltas,
		"resulting_compartments_m3": _compartment_volume.duplicate(true),
		"origin_world_m": [origin_world.x, origin_world.y, origin_world.z],
		"velocity_world_m_s": [velocity_world.x, velocity_world.y, velocity_world.z],
		"metadata": metadata.duplicate(true),
	}
	row["transaction_sha256"] = _transaction_hash(row)
	_journal.append(row)
	if _journal.size() > MAX_JOURNAL_ROWS:
		_journal.pop_front()
	_transaction_sequence += 1
	if absf(source_delta + destination_delta) > _transaction_tolerance(accepted):
		_invariant_failure_count += 1


func _candidate_volume(candidate: Dictionary, region: Dictionary) -> float:
	var action := String(candidate.get("classification", "none"))
	var penetration := clampf(float(candidate.get("penetration_m", 0.0)), 0.0, 0.25)
	var motion := clampf(float(candidate.get("motion_m", 0.0)), 0.0, 0.8)
	var width := _region_width(region.get("shape", {}) as Dictionary)
	var action_factor := float({"cut": 0.70, "side_cut": 0.42, "scrape": 0.34, "grade": 0.20}.get(action, 0.0))
	return minf(MAX_DISPLACEMENT_PER_TICK_M3, penetration * maxf(motion, 0.003) * width * action_factor)


func _region_width(shape: Dictionary) -> float:
	match String(shape.get("kind", "")):
		"segment":
			return maxf(0.02, float(shape.get("half_length_m", 0.05)) * 2.0)
		"box":
			var size := shape.get("size_m", [0.1, 0.1, 0.1]) as Array
			return maxf(0.02, float(size[0]))
		"plane":
			var size := shape.get("size_m", [0.1, 0.1]) as Array
			return maxf(0.02, float(size[0]))
	return 0.05


func _add_bucket_volume(requested: float) -> float:
	var remaining := minf(maxf(requested, 0.0), bucket_capacity_m3 - float(_compartment_volume["bucket"]))
	var accepted := remaining
	for index in _cell_fill.size():
		if remaining <= EPSILON_M3:
			break
		var free := (1.0 - _cell_fill[index]) * _cell_capacity_m3
		var moved := minf(free, remaining)
		_cell_fill[index] += moved / _cell_capacity_m3
		remaining -= moved
	return accepted - remaining


func _bucket_available_volume() -> float:
	var ledger_free := maxf(0.0, bucket_capacity_m3 - float(_compartment_volume["bucket"]))
	var cell_free := 0.0
	for fill in _cell_fill:
		cell_free += maxf(0.0, 1.0 - float(fill)) * _cell_capacity_m3
	return minf(ledger_free, cell_free)


func _remove_bucket_volume(requested: float) -> float:
	var remaining := minf(maxf(requested, 0.0), float(_compartment_volume["bucket"]))
	var removed := remaining
	for reverse_index in _cell_fill.size():
		if remaining <= EPSILON_M3:
			break
		var index := _cell_fill.size() - reverse_index - 1
		var occupied := _cell_fill[index] * _cell_capacity_m3
		var moved := minf(occupied, remaining)
		_cell_fill[index] -= moved / _cell_capacity_m3
		remaining -= moved
	return removed - remaining


func _settle_bucket_cells(tool_snapshot: Dictionary, delta: float) -> void:
	if float(_compartment_volume["bucket"]) <= EPSILON_M3:
		return
	var inner := _find_region(tool_snapshot.get("regions", []) as Array, "inner_shell")
	if inner.is_empty():
		return
	var cavity := inner.get("current_transform", Transform3D.IDENTITY) as Transform3D
	var gravity_local := cavity.basis.inverse() * Vector3.DOWN
	if gravity_local.is_zero_approx():
		return
	gravity_local = gravity_local.normalized()
	var ordered: Array[int] = []
	for index in _cell_fill.size():
		ordered.append(index)
	ordered.sort_custom(func(left: int, right: int) -> bool: return _cell_center_local(left).dot(gravity_local) > _cell_center_local(right).dot(gravity_local))
	var target := PackedFloat32Array()
	target.resize(_cell_fill.size())
	var remaining := float(_compartment_volume["bucket"])
	for index in ordered:
		var volume := minf(_cell_capacity_m3, remaining)
		target[index] = volume / _cell_capacity_m3
		remaining -= volume
	var blend := clampf(maxf(delta, 0.0) * 8.0, 0.0, 1.0)
	for index in _cell_fill.size():
		_cell_fill[index] = lerpf(_cell_fill[index], target[index], blend)
	_normalize_cells(float(_compartment_volume["bucket"]))


func _normalize_cells(expected_volume: float) -> void:
	var actual := 0.0
	for fill in _cell_fill:
		actual += float(fill) * _cell_capacity_m3
	if actual <= EPSILON_M3:
		return
	var scale := expected_volume / actual
	for index in _cell_fill.size():
		_cell_fill[index] = clampf(_cell_fill[index] * scale, 0.0, 1.0)


func _occupied_cell_count() -> int:
	var result := 0
	for fill in _cell_fill:
		result += 1 if fill > 0.0001 else 0
	return result


func _build_fill_profile() -> PackedFloat32Array:
	var profile := PackedFloat32Array()
	var expected_cell_count := _grid_dimensions.x * _grid_dimensions.y * _grid_dimensions.z
	# Status can be queried re-entrantly by ProductSession/UI while a clean
	# generation boundary clears and replaces this authority. A transitional or
	# unconfigured object must publish an empty profile, never index stale grid
	# dimensions into an already-cleared cell array.
	if not configured or expected_cell_count <= 0 or _cell_fill.size() != expected_cell_count:
		return profile
	profile.resize(_grid_dimensions.x * _grid_dimensions.z)
	for z in _grid_dimensions.z:
		for x in _grid_dimensions.x:
			var fill := 0.0
			for y in _grid_dimensions.y:
				fill += _cell_fill[(z * _grid_dimensions.y + y) * _grid_dimensions.x + x]
			profile[z * _grid_dimensions.x + x] = fill / float(_grid_dimensions.y)
	return profile


func _center_of_mass_local() -> Vector3:
	if float(_compartment_volume["bucket"]) <= EPSILON_M3:
		return Vector3.ZERO
	var weighted := Vector3.ZERO
	var weight := 0.0
	for index in _cell_fill.size():
		weighted += _cell_center_local(index) * _cell_fill[index]
		weight += _cell_fill[index]
	return weighted / weight if weight > 0.0 else Vector3.ZERO


func _cell_center_local(index: int) -> Vector3:
	var x := index % _grid_dimensions.x
	var yz := index / _grid_dimensions.x
	var y := yz % _grid_dimensions.y
	var z := yz / _grid_dimensions.y
	return Vector3(
		(float(x) + 0.5) / float(_grid_dimensions.x) - 0.5,
		(float(y) + 0.5) / float(_grid_dimensions.y) - 0.5,
		(float(z) + 0.5) / float(_grid_dimensions.z) - 0.5,
	)


func _find_region(regions: Array, region_id: String) -> Dictionary:
	for value in regions:
		var region := value as Dictionary
		if String(region.get("region_id", "")) == region_id:
			return region
	return {}


func _residual_total() -> float:
	var total := 0.0
	for value in _residuals.values():
		total += float(value)
	return total


func _ledger_identity() -> String:
	return "%s:%d:%d" % [model_id, generation, _transaction_sequence]


func _transaction_tolerance(volume: float) -> float:
	return maxf(EPSILON_M3, absf(volume) * 0.001)


func _transaction_hash(row: Dictionary) -> String:
	var origin := row["origin_world_m"] as Array
	var velocity := row["velocity_world_m_s"] as Array
	var resulting := row["resulting_compartments_m3"] as Dictionary
	var canonical := "%s|%d|%d|%s|%s|%s|%s|%s|%.9f|%.9f|%.9f|%.9f,%.9f,%.9f|%.9f,%.9f,%.9f|%.9f,%.9f,%.9f,%.9f,%.9f" % [
		String(row["transaction_id"]), int(row["tick"]), int(row["generation"]), String(row["model_id"]), String(row["material_preset"]),
		String(row["kind"]), String(row["source"]), String(row["destination"]),
		float(row["requested_volume_m3"]), float(row["accepted_volume_m3"]), float(row["rejected_volume_m3"]),
		float(origin[0]), float(origin[1]), float(origin[2]), float(velocity[0]), float(velocity[1]), float(velocity[2]),
		float(resulting["persistent_stable"]), float(resulting["persistent_loose"]), float(resulting["active"]), float(resulting["bucket"]), float(resulting["released"]),
	]
	return _sha256(canonical.to_utf8_buffer())


func _snapshot_hash() -> String:
	var canonical := "%s|%.9f|%.9f|%.9f|%.9f|%.9f|%d" % [
		_ledger_identity(),
		float(_compartment_volume["persistent_stable"]),
		float(_compartment_volume["persistent_loose"]),
		float(_compartment_volume["active"]),
		float(_compartment_volume["bucket"]),
		float(_compartment_volume["released"]),
		_invariant_failure_count,
	]
	return _sha256(canonical.to_utf8_buffer())


func _sha256(bytes: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(bytes)
	return hashing.finish().hex_encode()

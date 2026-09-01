class_name ArcadeExcavationStamp
extends RefCounted

## Visual-first excavation writer. It converts only the cutting-edge swept band
## into aggressive absolute terrain targets, coalesces cells for 100 ms, then
## commits one canonical patch. It owns no active, loose or conserved soil.

const SCHEMA_VERSION := "arcade-excavation-stamp-v1"
const ARCADE_BUCKET_LOAD_STATE_SCRIPT := preload("res://scripts/arcade_bucket_load_state.gd")
const COMMIT_INTERVAL_S := 0.1
const ENTER_BAND_M := 0.22
const EXIT_BAND_M := 0.35
const MINIMUM_MOVEMENT_M := 0.002
const TELEPORT_DISTANCE_M := 2.0
const WIDTH_MULTIPLIER := 1.25
const MINIMUM_VISIBLE_CUT_M := 0.18
const MAXIMUM_DEPTH_PER_COMMIT_M := 0.45
const RESPONSE_BIAS_M := 0.08
const SUPPORT_RADIUS_FACTOR := 0.62
const MAX_INTERPOLATION_STEPS := 64
const VISUAL_FILL_GAIN := 1.0
const LOAD_EPSILON_M3 := 0.000001

var terrain_state: TerrainState
var terrain_scheduler: TerrainCommitScheduler
var load_state: Variant = ARCADE_BUCKET_LOAD_STATE_SCRIPT.new()
var contract: Dictionary = {}
var configured := false
var generation := -1
var model_id := ""

var _pending_targets: Dictionary = {}
var _elapsed_s := 0.0
var _engaged := false
var _window_sequence := 0
var _last_result: Dictionary = {"changed": false, "reason": "unconfigured"}
var _last_patch: Dictionary = {}
var _engaged_ticks := 0
var _covered_cells := 0
var _coalesced_cells := 0
var _accepted_commits := 0
var _rejected_commits := 0
var _teleport_resets := 0
var _last_build_us := 0
var _last_commit_us := 0
var _max_build_us := 0
var _max_commit_us := 0


func configure(state: TerrainState, scheduler: TerrainCommitScheduler, soil_contract: Dictionary) -> bool:
	if state == null or scheduler == null or soil_contract.is_empty():
		return false
	var requested_model := String(soil_contract.get("model_id", ""))
	var cutting := (soil_contract.get("proxies", {}) as Dictionary).get("cutting_edge", {}) as Dictionary
	if requested_model.is_empty() or float(cutting.get("half_width_m", 0.0)) <= 0.0:
		return false
	if not load_state.configure(soil_contract, state.world_generation):
		return false
	terrain_state = state
	terrain_scheduler = scheduler
	contract = soil_contract.duplicate(true)
	generation = state.world_generation
	model_id = requested_model
	_pending_targets.clear()
	_elapsed_s = 0.0
	_engaged = false
	_window_sequence = 0
	_last_result = {"changed": false, "reason": "configured"}
	_last_patch.clear()
	configured = true
	return true


func clear() -> void:
	_pending_targets.clear()
	_elapsed_s = 0.0
	_engaged = false
	_last_result = {"changed": false, "reason": "cleared"}
	_last_patch.clear()
	load_state.clear()
	terrain_state = null
	terrain_scheduler = null
	contract.clear()
	configured = false
	generation = -1
	model_id = ""


func step_fixed(delta: float, pose_snapshot: Dictionary, tick: int) -> Dictionary:
	if not configured or terrain_state == null or terrain_scheduler == null:
		return _result(false, "unconfigured")
	if terrain_state.world_generation != generation:
		return _result(false, "generation_changed")
	var step_started_us := Time.get_ticks_usec()
	var built := build_proposals(pose_snapshot, terrain_state.cell_patch_read_snapshot(), _engaged)
	_last_build_us = Time.get_ticks_usec() - step_started_us
	_max_build_us = maxi(_max_build_us, _last_build_us)
	if bool(built.get("teleport_reset", false)):
		_teleport_resets += 1
		_engaged = false
	else:
		_engaged = bool(built.get("engaged", false))
	if _engaged:
		_engaged_ticks += 1
	var proposals := built.get("proposals", {}) as Dictionary
	var build_summary := built.duplicate(false)
	build_summary.erase("proposals")
	_covered_cells = int(built.get("covered_cell_count", 0))
	for index_value in proposals.keys():
		var index := int(index_value)
		var target := float(proposals[index_value])
		if _pending_targets.has(index):
			_pending_targets[index] = minf(float(_pending_targets[index]), target)
			_coalesced_cells += 1
		else:
			_pending_targets[index] = target
	_elapsed_s += maxf(delta, 0.0)
	var dump_result := _try_dump(pose_snapshot, tick)
	var commit_result := {"changed": false, "reason": "not_due"}
	if _elapsed_s + 0.000001 >= COMMIT_INTERVAL_S:
		_elapsed_s = fmod(_elapsed_s, COMMIT_INTERVAL_S)
		if not _pending_targets.is_empty():
			commit_result = _flush_pending(tick, String(pose_snapshot.get("identity", "arcade")))
	var interaction := "dump" if bool(dump_result.get("changed", false)) else ("cut" if _engaged else ("carry" if float(load_state.get_status_snapshot().get("fill_ratio", 0.0)) > 0.0 else "idle"))
	var changed := bool(commit_result.get("changed", false)) or bool(dump_result.get("changed", false))
	_last_result = {
		"changed": changed,
		"visual_changed": _engaged or bool(dump_result.get("changed", false)),
		"reason": String(dump_result.get("reason", commit_result.get("reason", built.get("reason", "idle")))) if bool(dump_result.get("changed", false)) else String(commit_result.get("reason", built.get("reason", "idle"))),
		"interaction_state": interaction,
		"engaged": _engaged,
		"flow_volume_m3": float(dump_result.get("released_volume_m3", commit_result.get("accepted_volume_m3", 0.002 if _engaged else 0.0))),
		"build": build_summary,
		"terrain_commit": commit_result,
		"dump": dump_result,
	}
	return _last_result.duplicate(true)


func build_proposals(pose_snapshot: Dictionary, terrain_snapshot: Dictionary, was_engaged: bool) -> Dictionary:
	var previous := pose_snapshot.get("previous", {}) as Dictionary
	var current := pose_snapshot.get("current", {}) as Dictionary
	if not bool(pose_snapshot.get("valid", false)) or not previous.has("cutting_edge") or not current.has("cutting_edge"):
		return {"valid": false, "reason": "pose_unavailable", "engaged": false, "proposals": {}}
	var previous_edge := previous["cutting_edge"] as Transform3D
	var current_edge := current["cutting_edge"] as Transform3D
	if not previous_edge.is_finite() or not current_edge.is_finite():
		return {"valid": false, "reason": "pose_non_finite", "engaged": false, "proposals": {}}
	var pose_contract := pose_snapshot.get("contract", contract) as Dictionary
	var cutting := (pose_contract.get("proxies", {}) as Dictionary).get("cutting_edge", {}) as Dictionary
	var half_width := float(cutting.get("half_width_m", 0.0)) * WIDTH_MULTIPLIER
	if half_width <= 0.0:
		return {"valid": false, "reason": "width_invalid", "engaged": false, "proposals": {}}
	var previous_points := _edge_points(previous_edge, half_width)
	var current_points := _edge_points(current_edge, half_width)
	var maximum_travel := 0.0
	for index in previous_points.size():
		maximum_travel = maxf(maximum_travel, (current_points[index] - previous_points[index]).length())
	if maximum_travel > TELEPORT_DISTANCE_M:
		return {"valid": true, "reason": "teleport_reset", "engaged": false, "teleport_reset": true, "proposals": {}}
	if maximum_travel < MINIMUM_MOVEMENT_M:
		return {"valid": true, "reason": "stationary", "engaged": false, "proposals": {}}
	var proximity_band := EXIT_BAND_M if was_engaged else ENTER_BAND_M
	var in_work_band := false
	for point in previous_points + current_points:
		var surface := _sample_surface_bilinear(terrain_snapshot, Vector2(point.x, point.z))
		if not is_nan(surface) and point.y <= surface + proximity_band:
			in_work_band = true
			break
	if not in_work_band:
		return {"valid": true, "reason": "above_work_band", "engaged": false, "proposals": {}}
	var spacing := float(terrain_snapshot.get("spacing_m", 0.0))
	if spacing <= 0.0:
		return {"valid": false, "reason": "spacing_invalid", "engaged": false, "proposals": {}}
	var sample_steps := clampi(ceili(maximum_travel / maxf(spacing * 0.5, 0.05)), 1, MAX_INTERPOLATION_STEPS)
	var proposals := {}
	for sample_index in sample_steps:
		var t0 := float(sample_index) / float(sample_steps)
		var t1 := float(sample_index + 1) / float(sample_steps)
		var edge0 := previous_edge.interpolate_with(current_edge, t0)
		var edge1 := previous_edge.interpolate_with(current_edge, t1)
		_raster_segment(edge0, edge1, half_width, terrain_snapshot, proposals)
	return {
		"valid": true,
		"reason": "engaged" if not proposals.is_empty() else "no_covered_cells",
		"engaged": true,
		"teleport_reset": false,
		"sample_steps": sample_steps,
		"covered_cell_count": proposals.size(),
		"proposals": proposals,
	}


func get_status_snapshot() -> Dictionary:
	var load: Dictionary = load_state.get_status_snapshot()
	return {
		"schema_version": SCHEMA_VERSION,
		"configured": configured,
		"mode": "arcade_stamp_v3",
		"model_id": model_id,
		"generation": generation,
		"ledger_identity": String(load.get("ledger_identity", "arcade:unavailable")),
		"bucket_capacity_m3": float(load.get("bucket_capacity_m3", 0.0)),
		"bucket_volume_m3": float(load.get("bucket_volume_m3", 0.0)),
		"payload_mass_kg": float(load.get("payload_mass_kg", 0.0)),
		"fill_ratio": float(load.get("fill_ratio", 0.0)),
		"center_of_mass_local": load.get("center_of_mass_local", Vector3.ZERO),
		"fill_profile": load.get("fill_profile", PackedFloat32Array()),
		"cell_grid": load.get("cell_grid", [1, 1, 1]),
		"last_transaction": (load.get("last_transaction", {}) as Dictionary).duplicate(true),
		"accepted_dump_event_id": String(load.get("accepted_dump_event_id", "")),
		"dump_release_world": load.get("dump_release_world", Vector3.ZERO),
		"dump_released_fill_ratio": float(load.get("dump_released_fill_ratio", 0.0)),
		"pending_cells": _pending_targets.size(),
		"engaged": _engaged,
		"engaged_ticks": _engaged_ticks,
		"covered_cells": _covered_cells,
		"coalesced_cells": _coalesced_cells,
		"accepted_commits": _accepted_commits,
		"rejected_commits": _rejected_commits,
		"teleport_resets": _teleport_resets,
		"last_build_us": _last_build_us,
		"max_build_us": _max_build_us,
		"last_commit_us": _last_commit_us,
		"max_commit_us": _max_commit_us,
		"last_patch": _last_patch.duplicate(true),
		"last_result": _last_result.duplicate(true),
	}


func _flush_pending(tick: int, pose_identity: String) -> Dictionary:
	var commit_started_us := Time.get_ticks_usec()
	var snapshot := terrain_state.cell_patch_read_snapshot()
	var stable: PackedFloat32Array = snapshot.get("stable_heights", PackedFloat32Array())
	var loose: PackedFloat32Array = snapshot.get("loose_depth", PackedFloat32Array())
	var indices: Array = _pending_targets.keys()
	indices.sort()
	var rows: Array[Dictionary] = []
	for index_value in indices:
		var index := int(index_value)
		if index < 0 or index >= stable.size():
			continue
		var original_stable := float(stable[index])
		var original_loose := float(loose[index])
		var current_surface := original_stable + original_loose
		var desired_surface := minf(float(_pending_targets[index]), current_surface - MINIMUM_VISIBLE_CUT_M)
		desired_surface = maxf(desired_surface, current_surface - MAXIMUM_DEPTH_PER_COMMIT_M)
		desired_surface = maxf(desired_surface, terrain_state.minimum_stable_height_for_index(index))
		var removal := current_surface - desired_surface
		if removal <= 0.0005:
			continue
		var loose_removed := minf(original_loose, removal)
		var target_loose := original_loose - loose_removed
		var target_stable := original_stable - (removal - loose_removed)
		rows.append({
			"index": index,
			"original_stable_height": original_stable,
			"original_loose_depth": original_loose,
			"target_stable_height": target_stable,
			"target_loose_depth": target_loose,
			"action": "surface_cut",
			"contributing_region_ids": ["arcade_stamp_v3"],
		})
	if rows.is_empty():
		_pending_targets.clear()
		return _finish_commit_timing({"changed": false, "reason": "no_changed_cells"}, commit_started_us)
	_window_sequence += 1
	var patch := {
		"schema_version": SoilCellPatch.SCHEMA_VERSION,
		"generation": int(snapshot.get("world_generation", -1)),
		"base_revision": int(snapshot.get("terrain_revision", -1)),
		"tick": tick,
		"tool_identity": "%s|arcade-window:%d" % [pose_identity, _window_sequence],
		"rows": rows,
		"dirty_rect_cells": SoilCellPatch.dirty_rect(rows, int(snapshot.get("columns", 0))),
	}
	var metrics := SoilCellPatch.volume_metrics(patch, snapshot)
	patch["removed_stable_m3"] = float(metrics.get("stable_removed_m3", 0.0))
	patch["removed_loose_m3"] = float(metrics.get("loose_removed_m3", 0.0))
	patch["patch_hash"] = SoilCellPatch.compute_hash(patch)
	_last_patch = patch.duplicate(true)
	var transfer_id := "arcade:%d:%d:%s" % [generation, _window_sequence, String(patch["patch_hash"]).left(12)]
	if not terrain_scheduler.queue_cell_patch(_window_sequence, patch, generation, transfer_id):
		_rejected_commits += 1
		return _finish_commit_timing({"changed": false, "reason": "queue_rejected", "patch_hash": patch["patch_hash"]}, commit_started_us)
	var commit := terrain_scheduler.step_fixed(0.0, true)
	var committed: bool = bool(commit.get("changed", false)) and transfer_id in (commit.get("committed_transfer_ids", []) as Array)
	if not committed:
		_rejected_commits += 1
		commit["accepted_volume_m3"] = 0.0
		commit["patch_hash"] = patch["patch_hash"]
		return _finish_commit_timing(commit, commit_started_us)
	_pending_targets.clear()
	_accepted_commits += 1
	var accepted_volume := float(metrics.get("stable_removed_m3", 0.0)) + float(metrics.get("loose_removed_m3", 0.0))
	load_state.credit_accepted_cut(accepted_volume, tick, String(patch["patch_hash"]), VISUAL_FILL_GAIN)
	commit["accepted_volume_m3"] = accepted_volume
	commit["patch_hash"] = patch["patch_hash"]
	return _finish_commit_timing(commit, commit_started_us)


func _try_dump(pose_snapshot: Dictionary, tick: int) -> Dictionary:
	var payload: Dictionary = load_state.get_status_snapshot()
	if float(payload.get("bucket_volume_m3", 0.0)) <= LOAD_EPSILON_M3:
		return {"changed": false, "reason": "dump_empty"}
	var current := pose_snapshot.get("current", {}) as Dictionary
	if not bool(pose_snapshot.get("valid", false)) or not current.has("opening"):
		return {"changed": false, "reason": "dump_pose_unavailable"}
	var interaction := (pose_snapshot.get("contract", contract) as Dictionary).get("interaction", {}) as Dictionary
	var threshold := float(interaction.get("dump_opening_down_dot", 0.3))
	var opening_normal := pose_snapshot.get("opening_normal_world", Vector3.UP) as Vector3
	if not opening_normal.is_finite() or opening_normal.dot(Vector3.DOWN) <= threshold:
		return {"changed": false, "reason": "dump_not_oriented"}
	var opening := current["opening"] as Transform3D
	var surface := terrain_state.sample_surface_bilinear_at(Vector2(opening.origin.x, opening.origin.z))
	if is_nan(surface):
		return {"changed": false, "reason": "dump_outside_terrain"}
	return load_state.dump_visual_load(Vector3(opening.origin.x, surface + 0.02, opening.origin.z), tick)


func _raster_segment(edge0: Transform3D, edge1: Transform3D, half_width: float, snapshot: Dictionary, proposals: Dictionary) -> void:
	var points0 := _edge_points(edge0, half_width)
	var points1 := _edge_points(edge1, half_width)
	var quad := PackedVector2Array([
		Vector2(points0[0].x, points0[0].z),
		Vector2(points0[2].x, points0[2].z),
		Vector2(points1[2].x, points1[2].z),
		Vector2(points1[0].x, points1[0].z),
	])
	var spacing := float(snapshot.get("spacing_m", 0.0))
	var origin := snapshot.get("origin_xz", Vector2.ZERO) as Vector2
	var columns := int(snapshot.get("columns", 0))
	var rows := int(snapshot.get("rows", 0))
	var support_radius := spacing * SUPPORT_RADIUS_FACTOR
	var minimum := quad[0]
	var maximum := quad[0]
	for point in quad:
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	minimum -= Vector2.ONE * support_radius
	maximum += Vector2.ONE * support_radius
	var min_column := clampi(floori((minimum.x - origin.x) / spacing), 0, columns - 1)
	var max_column := clampi(ceili((maximum.x - origin.x) / spacing), 0, columns - 1)
	var min_row := clampi(floori((minimum.y - origin.y) / spacing), 0, rows - 1)
	var max_row := clampi(ceili((maximum.y - origin.y) / spacing), 0, rows - 1)
	var target_y := minf(minf(points0[0].y, points0[2].y), minf(points1[0].y, points1[2].y)) - RESPONSE_BIAS_M
	var stable: PackedFloat32Array = snapshot.get("stable_heights", PackedFloat32Array())
	var loose: PackedFloat32Array = snapshot.get("loose_depth", PackedFloat32Array())
	for row in range(min_row, max_row + 1):
		for column in range(min_column, max_column + 1):
			var point := Vector2(origin.x + float(column) * spacing, origin.y + float(row) * spacing)
			if not _inside_or_near_quad(point, quad, support_radius):
				continue
			var index := row * columns + column
			var surface := float(stable[index]) + float(loose[index])
			var desired := minf(target_y, surface - MINIMUM_VISIBLE_CUT_M)
			desired = maxf(desired, surface - MAXIMUM_DEPTH_PER_COMMIT_M)
			if proposals.has(index):
				proposals[index] = minf(float(proposals[index]), desired)
			else:
				proposals[index] = desired


func _edge_points(edge: Transform3D, half_width: float) -> Array[Vector3]:
	var axis := edge.basis.x.normalized()
	if axis.is_zero_approx():
		axis = Vector3.RIGHT
	return [edge.origin - axis * half_width, edge.origin, edge.origin + axis * half_width]


func _inside_or_near_quad(point: Vector2, quad: PackedVector2Array, radius: float) -> bool:
	if Geometry2D.is_point_in_polygon(point, quad):
		return true
	for index in quad.size():
		var nearest := Geometry2D.get_closest_point_to_segment(point, quad[index], quad[(index + 1) % quad.size()])
		if point.distance_to(nearest) <= radius:
			return true
	return false


func _sample_surface_bilinear(snapshot: Dictionary, world_xz: Vector2) -> float:
	var spacing := float(snapshot.get("spacing_m", 0.0))
	var origin := snapshot.get("origin_xz", Vector2.ZERO) as Vector2
	var columns := int(snapshot.get("columns", 0))
	var rows := int(snapshot.get("rows", 0))
	var stable: PackedFloat32Array = snapshot.get("stable_heights", PackedFloat32Array())
	var loose: PackedFloat32Array = snapshot.get("loose_depth", PackedFloat32Array())
	if spacing <= 0.0 or columns < 2 or rows < 2 or stable.size() != columns * rows or loose.size() != stable.size():
		return NAN
	var grid_x := (world_xz.x - origin.x) / spacing
	var grid_z := (world_xz.y - origin.y) / spacing
	if grid_x < 0.0 or grid_z < 0.0 or grid_x > float(columns - 1) or grid_z > float(rows - 1):
		return NAN
	var column0 := clampi(floori(grid_x), 0, columns - 1)
	var row0 := clampi(floori(grid_z), 0, rows - 1)
	var column1 := mini(column0 + 1, columns - 1)
	var row1 := mini(row0 + 1, rows - 1)
	var weight_x := clampf(grid_x - float(column0), 0.0, 1.0)
	var weight_z := clampf(grid_z - float(row0), 0.0, 1.0)
	var top_left := float(stable[row0 * columns + column0]) + float(loose[row0 * columns + column0])
	var top_right := float(stable[row0 * columns + column1]) + float(loose[row0 * columns + column1])
	var bottom_left := float(stable[row1 * columns + column0]) + float(loose[row1 * columns + column0])
	var bottom_right := float(stable[row1 * columns + column1]) + float(loose[row1 * columns + column1])
	return lerpf(lerpf(top_left, top_right, weight_x), lerpf(bottom_left, bottom_right, weight_x), weight_z)


func _finish_commit_timing(result: Dictionary, started_us: int) -> Dictionary:
	_last_commit_us = Time.get_ticks_usec() - started_us
	_max_commit_us = maxi(_max_commit_us, _last_commit_us)
	return result


func _result(changed: bool, reason: String) -> Dictionary:
	return {"changed": changed, "reason": reason, "interaction_state": "idle", "flow_volume_m3": 0.0}

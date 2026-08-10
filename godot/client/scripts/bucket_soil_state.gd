class_name BucketSoilState
extends RefCounted

## Deterministic local inventory and terrain-operation state.
## Python motion remains authoritative; this object is never serialized back.
const ALGORITHM_VERSION := "godot-bucket-soil-v1"
const BUCKET_CAPACITY_M3 := 0.35
const MAX_CUT_DEPTH_M := 0.08
const TOOTH_RADIUS_M := 0.20
const DEPOSIT_RADIUS_M := 0.75
const CONTACT_TOLERANCE_M := 0.12
const DUMP_CLEARANCE_M := 0.15
const EPSILON_M3 := 0.000001

var terrain_state: TerrainState
var bucket_volume_m3 := 0.0
var world_generation := 0
var _last_queued_sequence := -1
var _last_applied_sequence := -1
var _pending_commands: Array[Dictionary] = []
var _last_result: Dictionary = {}


func _init(terrain: TerrainState) -> void:
	terrain_state = terrain
	world_generation = terrain.world_generation if terrain != null else 0


func queue_cut(sequence: int, previous_tooth: Vector3, current_tooth: Vector3) -> bool:
	if not _can_queue(sequence) or not _is_finite_vector(previous_tooth) or not _is_finite_vector(current_tooth):
		return false
	_pending_commands.append({
		"sequence": sequence,
		"generation": world_generation,
		"kind": "cut",
		"previous_tooth": previous_tooth,
		"current_tooth": current_tooth,
	})
	_last_queued_sequence = sequence
	return true


func queue_deposit(sequence: int, center: Vector3) -> bool:
	if not _can_queue(sequence) or not _is_finite_vector(center):
		return false
	_pending_commands.append({
		"sequence": sequence,
		"generation": world_generation,
		"kind": "deposit",
		"center": center,
	})
	_last_queued_sequence = sequence
	return true


func step_fixed() -> Dictionary:
	if terrain_state == null:
		return _result(false, 0.0, 0.0, "terrain_unavailable")
	if terrain_state.world_generation != world_generation:
		reset_for_generation(terrain_state.world_generation)
		return _result(false, 0.0, 0.0, "generation_changed")
	if _pending_commands.is_empty():
		return _result(false, 0.0, 0.0, "idle")
	_pending_commands.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return int(left["sequence"]) < int(right["sequence"]))
	var changed := false
	var cut_volume := 0.0
	var deposit_volume := 0.0
	var accepted := 0
	var rejected := 0
	var reason := ""
	for command in _pending_commands:
		var sequence := int(command["sequence"])
		if sequence <= _last_applied_sequence or int(command["generation"]) != world_generation:
			rejected += 1
			reason = "stale_command"
			continue
		_last_applied_sequence = sequence
		var operation: Dictionary
		if String(command["kind"]) == "cut":
			operation = _apply_cut(command)
		else:
			operation = _apply_deposit(command)
		if bool(operation.get("accepted", false)):
			accepted += 1
			changed = true
			cut_volume += float(operation.get("cut_volume_m3", 0.0))
			deposit_volume += float(operation.get("deposit_volume_m3", 0.0))
		else:
			rejected += 1
			reason = String(operation.get("reason", "rejected"))
	_pending_commands.clear()
	_last_result = _result(changed, cut_volume, deposit_volume, reason)
	_last_result["accepted_commands"] = accepted
	_last_result["rejected_commands"] = rejected
	return _last_result.duplicate(true)


func reset_for_generation(generation: int = -1) -> void:
	bucket_volume_m3 = 0.0
	world_generation = terrain_state.world_generation if generation < 0 and terrain_state != null else maxi(generation, 0)
	_last_queued_sequence = -1
	_last_applied_sequence = -1
	_pending_commands.clear()
	_last_result = _result(false, 0.0, 0.0, "reset")


func get_status_snapshot() -> Dictionary:
	return {
		"algorithm_version": ALGORITHM_VERSION,
		"bucket_capacity_m3": BUCKET_CAPACITY_M3,
		"bucket_volume_m3": bucket_volume_m3,
		"world_generation": world_generation,
		"last_queued_sequence": _last_queued_sequence,
		"last_applied_sequence": _last_applied_sequence,
		"pending_commands": _pending_commands.size(),
		"last_result": _last_result.duplicate(true),
	}


func _apply_cut(command: Dictionary) -> Dictionary:
	var previous: Vector3 = command["previous_tooth"]
	var current: Vector3 = command["current_tooth"]
	var center := Vector2(current.x, current.z)
	if not terrain_state.is_inside_grid(center):
		return {"accepted": false, "reason": "outside_grid"}
	var surface := terrain_state.sample_surface_at(center)
	if not _is_finite(surface) or minf(previous.y, current.y) > surface + CONTACT_TOLERANCE_M:
		return {"accepted": false, "reason": "no_contact"}
	var penetration := surface + CONTACT_TOLERANCE_M - minf(previous.y, current.y)
	var depth := clampf(penetration, 0.01, MAX_CUT_DEPTH_M)
	var expected_volume := terrain_state.estimate_brush_volume(center, TOOTH_RADIUS_M, -depth)
	if expected_volume <= EPSILON_M3:
		return {"accepted": false, "reason": "empty_soil"}
	if bucket_volume_m3 + expected_volume > BUCKET_CAPACITY_M3 + EPSILON_M3:
		return {"accepted": false, "reason": "bucket_full"}
	if not terrain_state.enqueue_brush(int(command["sequence"]), center, TOOTH_RADIUS_M, -depth) or not terrain_state.step_fixed():
		return {"accepted": false, "reason": "terrain_rejected"}
	bucket_volume_m3 = clampf(bucket_volume_m3 + expected_volume, 0.0, BUCKET_CAPACITY_M3)
	return {"accepted": true, "cut_volume_m3": expected_volume, "deposit_volume_m3": 0.0}


func _apply_deposit(command: Dictionary) -> Dictionary:
	var center: Vector3 = command["center"]
	var center_xz := Vector2(center.x, center.z)
	if bucket_volume_m3 <= EPSILON_M3 or not terrain_state.is_inside_grid(center_xz):
		return {"accepted": false, "reason": "empty_bucket" if bucket_volume_m3 <= EPSILON_M3 else "outside_grid"}
	var surface := terrain_state.sample_surface_at(center_xz)
	if not _is_finite(surface) or center.y < surface + DUMP_CLEARANCE_M:
		return {"accepted": false, "reason": "insufficient_clearance"}
	var full_depth := MAX_CUT_DEPTH_M
	var requested_volume := terrain_state.estimate_brush_volume(center_xz, DEPOSIT_RADIUS_M, full_depth)
	if requested_volume <= EPSILON_M3:
		return {"accepted": false, "reason": "invalid_deposit"}
	var depth := full_depth * minf(1.0, bucket_volume_m3 / requested_volume)
	var actual_volume := terrain_state.estimate_brush_volume(center_xz, DEPOSIT_RADIUS_M, depth)
	if actual_volume <= EPSILON_M3:
		return {"accepted": false, "reason": "invalid_deposit"}
	if not terrain_state.enqueue_brush(int(command["sequence"]), center_xz, DEPOSIT_RADIUS_M, depth) or not terrain_state.step_fixed():
		return {"accepted": false, "reason": "terrain_rejected"}
	bucket_volume_m3 = clampf(bucket_volume_m3 - actual_volume, 0.0, BUCKET_CAPACITY_M3)
	return {"accepted": true, "cut_volume_m3": 0.0, "deposit_volume_m3": actual_volume}


func _can_queue(sequence: int) -> bool:
	return terrain_state != null and sequence > _last_queued_sequence and sequence >= 0


func _result(changed: bool, cut_volume: float, deposit_volume: float, reason: String) -> Dictionary:
	return {
		"changed": changed,
		"cut_volume_m3": cut_volume,
		"deposit_volume_m3": deposit_volume,
		"bucket_volume_m3": bucket_volume_m3,
		"world_generation": world_generation,
		"terrain_revision": terrain_state.terrain_revision if terrain_state != null else -1,
		"reason": reason,
	}


func _is_finite_vector(value: Vector3) -> bool:
	return _is_finite(value.x) and _is_finite(value.y) and _is_finite(value.z)


func _is_finite(value: float) -> bool:
	return not is_nan(value) and not is_inf(value)

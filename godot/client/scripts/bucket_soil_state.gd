class_name BucketSoilState
extends RefCounted

## Bucket-local cellular occupancy and terrain-transfer state. Python motion
## remains authoritative; granular motion is intentionally presentation-local.
const ALGORITHM_VERSION := "godot-bucket-soil-v2-cellular"
const BUCKET_CAPACITY_M3 := 0.35
const MAX_CUT_DEPTH_M := 0.08
const TOOTH_RADIUS_M := 0.20
const DEPOSIT_RADIUS_M := 0.75
const CONTACT_TOLERANCE_M := 0.12
const DUMP_CLEARANCE_M := 0.15
const EPSILON_M3 := 0.000001
const MAX_ACTIVE_TRANSFERS := 256

var terrain_state: TerrainState
var terrain_scheduler: TerrainCommitScheduler
var soil_contract: Dictionary = {}
var bucket_volume_m3 := 0.0
var bucket_capacity_m3 := BUCKET_CAPACITY_M3
var nominal_capacity_m3 := BUCKET_CAPACITY_M3
var material_density_kg_m3 := 1600.0
var world_generation := 0
var _last_queued_sequence := -1
var _last_applied_sequence := -1
var _pending_commands: Array[Dictionary] = []
var _last_result: Dictionary = {}
var _cell_fill := PackedFloat32Array()
var _cell_capacity_m3 := 0.0
var _grid_dimensions := Vector3i(1, 1, 1)
var _active_transfers: Dictionary = {}


func _init(terrain: TerrainState, contract: Dictionary = {}, scheduler: TerrainCommitScheduler = null) -> void:
	terrain_state = terrain
	terrain_scheduler = scheduler
	world_generation = terrain.world_generation if terrain != null else 0
	configure_contract(contract)


func configure_contract(contract: Dictionary) -> bool:
	if contract.is_empty():
		soil_contract = {}
		bucket_capacity_m3 = BUCKET_CAPACITY_M3
		nominal_capacity_m3 = BUCKET_CAPACITY_M3
		material_density_kg_m3 = 1600.0
		_initialize_cells([6, 4, 4])
		return true
	if contract.get("schema_version", "") != "excavator-soil-contract-v1":
		return false
	var heaped := float(contract.get("heaped_capacity_m3", 0.0))
	var nominal := float(contract.get("nominal_capacity_m3", 0.0))
	var density := float(contract.get("material_density_kg_m3", 0.0))
	var grid: Variant = contract.get("cell_grid", [])
	if heaped <= 0.0 or nominal <= 0.0 or nominal > heaped or density <= 0.0:
		return false
	if not grid is Array or (grid as Array).size() != 3:
		return false
	for dimension in grid:
		if int(dimension) < 2 or int(dimension) > 32:
			return false
	soil_contract = contract.duplicate(true)
	bucket_capacity_m3 = heaped
	nominal_capacity_m3 = nominal
	material_density_kg_m3 = density
	_initialize_cells(grid)
	return true


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
	return queue_deposit_volume(sequence, center, bucket_volume_m3)


func queue_deposit_volume(sequence: int, center: Vector3, requested_volume_m3: float) -> bool:
	if not _can_queue(sequence) or not _is_finite_vector(center):
		return false
	if not _is_finite(requested_volume_m3) or requested_volume_m3 <= EPSILON_M3:
		return false
	_pending_commands.append({
		"sequence": sequence,
		"generation": world_generation,
		"kind": "deposit",
		"center": center,
		"requested_volume_m3": requested_volume_m3,
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
	for index in _cell_fill.size():
		_cell_fill[index] = 0.0
	world_generation = terrain_state.world_generation if generation < 0 and terrain_state != null else maxi(generation, 0)
	_last_queued_sequence = -1
	_last_applied_sequence = -1
	_pending_commands.clear()
	_active_transfers.clear()
	_last_result = _result(false, 0.0, 0.0, "reset")


func get_status_snapshot() -> Dictionary:
	return {
		"algorithm_version": ALGORITHM_VERSION,
		"bucket_capacity_m3": bucket_capacity_m3,
		"nominal_capacity_m3": nominal_capacity_m3,
		"bucket_volume_m3": bucket_volume_m3,
		"payload_mass_kg": bucket_volume_m3 * material_density_kg_m3,
		"fill_ratio": bucket_volume_m3 / bucket_capacity_m3 if bucket_capacity_m3 > 0.0 else 0.0,
		"occupied_cells": _occupied_cell_count(),
		"cell_count": _cell_fill.size(),
		"cell_grid": [_grid_dimensions.x, _grid_dimensions.y, _grid_dimensions.z],
		"fill_profile": _build_fill_profile(),
		"center_of_mass_local": _center_of_mass_local(),
		"active_transfers": _active_transfers.size(),
		"transfer_states": _transfer_state_counts(),
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
	if not _is_finite(surface):
		return {"accepted": false, "reason": "no_contact"}
	var interaction: Dictionary = soil_contract.get("interaction", {})
	var tolerance := float(interaction.get("contact_tolerance_m", CONTACT_TOLERANCE_M))
	if minf(previous.y, current.y) > surface + tolerance:
		return {"accepted": false, "reason": "no_contact"}
	var maximum_depth := float(interaction.get("maximum_cut_depth_m", MAX_CUT_DEPTH_M))
	var radius := float(interaction.get("cut_radius_m", TOOTH_RADIUS_M))
	# Removal depth is pure penetration below the sampled surface. The contact
	# tolerance above only decides whether the stroke touches at all — adding
	# it here made terrain yield ~30x faster than the edge pressed, cratering
	# the hole until the bucket floated above grade and disengaged. The floor
	# stays sub-millimeter so removal tracks fine presses without over-cutting.
	var penetration := surface - minf(previous.y, current.y)
	var depth := clampf(penetration, 0.0005, maximum_depth)
	var expected_volume := terrain_state.estimate_brush_volume(center, radius, -depth)
	if expected_volume <= EPSILON_M3:
		return {"accepted": false, "reason": "empty_soil"}
	# Digging is decoupled from bucket capacity by design: removed soil leaves
	# the heightfield and spawns particles directly; it never gates the cut,
	# never fills the bucket, and never feeds payload load. The transfer below
	# only tracks scheduler commit bookkeeping.
	if terrain_scheduler == null:
		return {"accepted": false, "reason": "terrain_scheduler_unavailable"}
	var sequence := int(command["sequence"])
	var transfer_id := "%d:%d:cut" % [world_generation, sequence]
	if _active_transfers.size() >= MAX_ACTIVE_TRANSFERS or _active_transfers.has(transfer_id):
		return {"accepted": false, "reason": "transfer_capacity"}
	if not terrain_scheduler.queue_brush(sequence, center, radius, -depth, world_generation, transfer_id, true):
		return {"accepted": false, "reason": "terrain_rejected"}
	_active_transfers[transfer_id] = {"state": "bucket_pending_terrain", "volume_m3": expected_volume}
	return {"accepted": true, "cut_volume_m3": expected_volume, "deposit_volume_m3": 0.0, "transfer_id": transfer_id}


func _apply_deposit(command: Dictionary) -> Dictionary:
	var center: Vector3 = command["center"]
	var center_xz := Vector2(center.x, center.z)
	if bucket_volume_m3 <= EPSILON_M3 or not terrain_state.is_inside_grid(center_xz):
		return {"accepted": false, "reason": "empty_bucket" if bucket_volume_m3 <= EPSILON_M3 else "outside_grid"}
	var surface := terrain_state.sample_surface_at(center_xz)
	if not _is_finite(surface) or center.y < surface + DUMP_CLEARANCE_M:
		return {"accepted": false, "reason": "insufficient_clearance"}
	var interaction: Dictionary = soil_contract.get("interaction", {})
	var maximum_depth := float(interaction.get("maximum_cut_depth_m", MAX_CUT_DEPTH_M))
	var radius := float(interaction.get("deposit_radius_m", DEPOSIT_RADIUS_M))
	var requested_from_bucket := minf(bucket_volume_m3, float(command.get("requested_volume_m3", bucket_volume_m3)))
	var full_brush_volume := terrain_state.estimate_brush_volume(center_xz, radius, maximum_depth)
	if full_brush_volume <= EPSILON_M3 or requested_from_bucket <= EPSILON_M3:
		return {"accepted": false, "reason": "invalid_deposit"}
	var depth := maximum_depth * minf(1.0, requested_from_bucket / full_brush_volume)
	var actual_volume := minf(requested_from_bucket, terrain_state.estimate_brush_volume(center_xz, radius, depth))
	if actual_volume <= EPSILON_M3:
		return {"accepted": false, "reason": "invalid_deposit"}
	if terrain_scheduler == null:
		return {"accepted": false, "reason": "terrain_scheduler_unavailable"}
	var sequence := int(command["sequence"])
	var transfer_id := "%d:%d:deposit" % [world_generation, sequence]
	if _active_transfers.size() >= MAX_ACTIVE_TRANSFERS or _active_transfers.has(transfer_id):
		return {"accepted": false, "reason": "transfer_capacity"}
	if not terrain_scheduler.queue_brush(sequence, center_xz, radius, depth, world_generation, transfer_id):
		return {"accepted": false, "reason": "terrain_rejected"}
	var removed_volume := _remove_occupancy(actual_volume)
	var consumed_sources := _consume_bucket_transfers(removed_volume)
	_active_transfers[transfer_id] = {
		"state": "settled_pending_terrain",
		"volume_m3": removed_volume,
		"consumed_sources": consumed_sources,
	}
	return {"accepted": true, "cut_volume_m3": 0.0, "deposit_volume_m3": removed_volume, "transfer_id": transfer_id}


func _can_queue(sequence: int) -> bool:
	return terrain_state != null and sequence > _last_queued_sequence and sequence >= 0


func reconcile_transfers(committed_ids: Array, rejected_ids: Array = []) -> void:
	for transfer_id_value in committed_ids:
		var transfer_id := String(transfer_id_value)
		if not _active_transfers.has(transfer_id):
			continue
		var transfer: Dictionary = _active_transfers[transfer_id]
		if transfer.get("state", "") == "bucket_pending_terrain":
			# Cut soil becomes particles directly; it never occupies the
			# bucket. The transfer simply retires once terrain commits it.
			_active_transfers.erase(transfer_id)
		else:
			_active_transfers.erase(transfer_id)
	for transfer_id_value in rejected_ids:
		var transfer_id := String(transfer_id_value)
		if not _active_transfers.has(transfer_id):
			continue
		var transfer: Dictionary = _active_transfers[transfer_id]
		if transfer.get("state", "") == "settled_pending_terrain":
			_add_occupancy(float(transfer.get("volume_m3", 0.0)))
			_restore_bucket_transfers(transfer.get("consumed_sources", []))
		_active_transfers.erase(transfer_id)


func commit_transfers(transfer_ids: Array) -> void:
	reconcile_transfers(transfer_ids)


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


func _initialize_cells(grid: Array) -> void:
	var dimensions := Vector3i(int(grid[0]), int(grid[1]), int(grid[2]))
	var cell_count := dimensions.x * dimensions.y * dimensions.z
	var cells := PackedFloat32Array()
	cells.resize(cell_count)
	_cell_fill = cells
	_grid_dimensions = dimensions
	_cell_capacity_m3 = bucket_capacity_m3 / float(cell_count)
	bucket_volume_m3 = 0.0


func _add_occupancy(requested_volume_m3: float) -> float:
	var remaining := minf(requested_volume_m3, bucket_capacity_m3 - bucket_volume_m3)
	var accepted := remaining
	for index in _cell_fill.size():
		if remaining <= EPSILON_M3:
			break
		var free_volume := (1.0 - _cell_fill[index]) * _cell_capacity_m3
		var transfer := minf(free_volume, remaining)
		_cell_fill[index] += transfer / _cell_capacity_m3
		remaining -= transfer
	accepted -= remaining
	bucket_volume_m3 = clampf(bucket_volume_m3 + accepted, 0.0, bucket_capacity_m3)
	return accepted


func _remove_occupancy(requested_volume_m3: float) -> float:
	var remaining := minf(requested_volume_m3, bucket_volume_m3)
	var removed := remaining
	for reverse_index in _cell_fill.size():
		if remaining <= EPSILON_M3:
			break
		var index := _cell_fill.size() - reverse_index - 1
		var occupied_volume := _cell_fill[index] * _cell_capacity_m3
		var transfer := minf(occupied_volume, remaining)
		_cell_fill[index] -= transfer / _cell_capacity_m3
		remaining -= transfer
	removed -= remaining
	bucket_volume_m3 = clampf(bucket_volume_m3 - removed, 0.0, bucket_capacity_m3)
	return removed


func _occupied_cell_count() -> int:
	var count := 0
	for fill in _cell_fill:
		if fill > 0.0001:
			count += 1
	return count


func settle_cells(cavity_transform: Transform3D, delta: float) -> bool:
	if bucket_volume_m3 <= EPSILON_M3 or _cell_fill.is_empty():
		return false
	var gravity_local := cavity_transform.basis.inverse() * Vector3.DOWN
	if gravity_local.is_zero_approx():
		return false
	gravity_local = gravity_local.normalized()
	var ordered_indices: Array[int] = []
	for index in _cell_fill.size():
		ordered_indices.append(index)
	ordered_indices.sort_custom(
		func(left: int, right: int) -> bool:
			return _cell_center_local(left).dot(gravity_local) > _cell_center_local(right).dot(gravity_local)
	)
	var target := PackedFloat32Array()
	target.resize(_cell_fill.size())
	var remaining := bucket_volume_m3
	for index in ordered_indices:
		var cell_volume := minf(_cell_capacity_m3, remaining)
		target[index] = cell_volume / _cell_capacity_m3
		remaining -= cell_volume
	var blend := clampf(maxf(delta, 0.0) * 8.0, 0.0, 1.0)
	var changed := false
	for index in _cell_fill.size():
		var settled := lerpf(_cell_fill[index], target[index], blend)
		if absf(settled - _cell_fill[index]) > 0.0001:
			changed = true
		_cell_fill[index] = settled
	_normalize_cell_volume(bucket_volume_m3)
	return changed


func _transfer_state_counts() -> Dictionary:
	var counts := {}
	for transfer in _active_transfers.values():
		var state := String((transfer as Dictionary).get("state", "unknown"))
		counts[state] = int(counts.get(state, 0)) + 1
	return counts


func _consume_bucket_transfers(requested_volume_m3: float) -> Array[Dictionary]:
	var remaining := requested_volume_m3
	var consumed_sources: Array[Dictionary] = []
	for transfer_id_value in _active_transfers.keys():
		if remaining <= EPSILON_M3:
			break
		var transfer_id := String(transfer_id_value)
		var transfer: Dictionary = _active_transfers[transfer_id]
		if String(transfer.get("state", "")) != "bucket":
			continue
		var volume := float(transfer.get("volume_m3", 0.0))
		var consumed := minf(volume, remaining)
		if consumed > EPSILON_M3:
			consumed_sources.append({"transfer_id": transfer_id, "volume_m3": consumed})
		volume -= consumed
		remaining -= consumed
		if volume <= EPSILON_M3:
			_active_transfers.erase(transfer_id)
		else:
			transfer["volume_m3"] = volume
			_active_transfers[transfer_id] = transfer
	return consumed_sources


func _restore_bucket_transfers(consumed_sources: Variant) -> void:
	if not consumed_sources is Array:
		return
	for source_value in consumed_sources:
		if not source_value is Dictionary:
			continue
		var source := source_value as Dictionary
		var transfer_id := String(source.get("transfer_id", ""))
		var volume := float(source.get("volume_m3", 0.0))
		if transfer_id.is_empty() or volume <= EPSILON_M3:
			continue
		var transfer: Dictionary = _active_transfers.get(transfer_id, {"state": "bucket", "volume_m3": 0.0})
		transfer["state"] = "bucket"
		transfer["volume_m3"] = float(transfer.get("volume_m3", 0.0)) + volume
		_active_transfers[transfer_id] = transfer


func _pending_cut_volume() -> float:
	var volume := 0.0
	for transfer_value in _active_transfers.values():
		var transfer := transfer_value as Dictionary
		if String(transfer.get("state", "")) == "bucket_pending_terrain":
			volume += float(transfer.get("volume_m3", 0.0))
	return volume


func _build_fill_profile() -> PackedFloat32Array:
	var dimensions := _grid_dimensions
	var cells := _cell_fill
	var profile := PackedFloat32Array()
	if (
		dimensions.x <= 0 or dimensions.y <= 0 or dimensions.z <= 0
		or cells.size() != dimensions.x * dimensions.y * dimensions.z
	):
		return profile
	profile.resize(dimensions.x * dimensions.z)
	for z in dimensions.z:
		for x in dimensions.x:
			var column_fill := 0.0
			for y in dimensions.y:
				var index := (z * dimensions.y + y) * dimensions.x + x
				column_fill += cells[index]
			profile[z * dimensions.x + x] = column_fill / float(dimensions.y)
	return profile


func _center_of_mass_local() -> Vector3:
	if bucket_volume_m3 <= EPSILON_M3:
		return Vector3.ZERO
	var weighted := Vector3.ZERO
	var weight := 0.0
	for index in _cell_fill.size():
		var fill := float(_cell_fill[index])
		weighted += _cell_center_local(index) * fill
		weight += fill
	return weighted / weight if weight > 0.0 else Vector3.ZERO


func _cell_index(x: int, y: int, z: int) -> int:
	return (z * _grid_dimensions.y + y) * _grid_dimensions.x + x


func _cell_center_local(index: int) -> Vector3:
	var x := index % _grid_dimensions.x
	var yz := floori(float(index) / float(_grid_dimensions.x))
	var y := yz % _grid_dimensions.y
	var z := floori(float(yz) / float(_grid_dimensions.y))
	return Vector3(
		(float(x) + 0.5) / float(_grid_dimensions.x) - 0.5,
		(float(y) + 0.5) / float(_grid_dimensions.y) - 0.5,
		(float(z) + 0.5) / float(_grid_dimensions.z) - 0.5
	)


func _normalize_cell_volume(target_volume_m3: float) -> void:
	var current_volume := 0.0
	for fill in _cell_fill:
		current_volume += float(fill) * _cell_capacity_m3
	if current_volume <= EPSILON_M3:
		return
	var scale := target_volume_m3 / current_volume
	for index in _cell_fill.size():
		_cell_fill[index] = clampf(_cell_fill[index] * scale, 0.0, 1.0)

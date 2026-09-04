class_name VoxelSoilMaterialField
extends RefCounted

const MASS_Q_PER_KG := 1000000
const DEFAULT_COMPACTION_Q := 1000
const LOOSE_COMPACTION_Q := 0
const MAX_COMPACTION_Q := 1000
const LOOSE_DENSITY_RATIO := 0.78
const APPROXIMATE_CUT_OCCUPANCY_FRACTION := 0.55

var generation := -1
var material_density_kg_m3 := 0.0
var loose_density_kg_m3 := 0.0
var contract_bucket_capacity_m3 := 0.0
var bucket_capacity_override_m3 := 0.0
var bucket_capacity_m3 := 0.0
var bucket_capacity_mass_q := 0
var bucket_mass_q := 0
var terrain_mass_delta_q := 0
var conservation_error_q := 0
var _cells: Dictionary = {}
var _compactable_mobile_cells: Dictionary = {}
var _approximate_cut_coverage: Dictionary = {}
var _mobile_cell_count := 0
var _state_revision := 0
var _cached_state_digest_revision := -1
var _cached_state_digest := ""


func configure(contract: Dictionary, target_generation: int, capacity_override_m3: float = 0.0) -> bool:
	var density := float(contract.get("material_density_kg_m3", 0.0))
	var contract_capacity := float(contract.get("heaped_capacity_m3", 0.0))
	var override_valid := is_finite(capacity_override_m3) and capacity_override_m3 > 0.0
	var capacity := capacity_override_m3 if override_valid else contract_capacity
	if target_generation < 0 or not is_finite(density) or density <= 0.0 \
			or not is_finite(contract_capacity) or contract_capacity <= 0.0 \
			or not is_finite(capacity) or capacity <= 0.0:
		return false
	generation = target_generation
	material_density_kg_m3 = density
	loose_density_kg_m3 = density * LOOSE_DENSITY_RATIO
	contract_bucket_capacity_m3 = contract_capacity
	bucket_capacity_override_m3 = capacity_override_m3 if override_valid else 0.0
	bucket_capacity_m3 = capacity
	bucket_capacity_mass_q = _mass_q(capacity)
	bucket_mass_q = 0
	terrain_mass_delta_q = 0
	conservation_error_q = 0
	_cells.clear()
	_compactable_mobile_cells.clear()
	_approximate_cut_coverage.clear()
	_mobile_cell_count = 0
	_state_revision = 0
	_cached_state_digest_revision = -1
	_cached_state_digest = ""
	return true


func remaining_capacity_mass_q() -> int:
	return maxi(0, bucket_capacity_mass_q - bucket_mass_q)


func mass_q_for_volume(volume_m3: float) -> int:
	return _mass_q(volume_m3)


func mass_q_for_loose_volume(volume_m3: float) -> int:
	return roundi(maxf(0.0, volume_m3) * loose_density_kg_m3 * float(MASS_Q_PER_KG))


func volume_for_mass_q(mass_q: int) -> float:
	return float(mass_q) / (material_density_kg_m3 * float(MASS_Q_PER_KG)) if material_density_kg_m3 > 0.0 else 0.0


func loose_volume_for_mass_q(mass_q: int) -> float:
	return float(mass_q) / (loose_density_kg_m3 * float(MASS_Q_PER_KG)) if loose_density_kg_m3 > 0.0 else 0.0


func mobile_bulk_volume_for_mass_q(mass_q: int, compaction_q: int) -> float:
	var density := _mobile_bulk_density_kg_m3(compaction_q)
	return float(maxi(0, mass_q)) / (density * float(MASS_Q_PER_KG)) if density > 0.0 else 0.0


func stage_cut(cell_changes: Array[Dictionary], requested_mass_q: int) -> Dictionary:
	if generation < 0 or requested_mass_q <= 0 or requested_mass_q > remaining_capacity_mass_q():
		return {"valid": false, "reason": "invalid_or_full_capacity", "accepted_mass_q": 0, "mutations": []}
	var mutations: Array[Dictionary] = []
	var remaining := requested_mass_q
	for change in cell_changes:
		if remaining <= 0:
			break
		var coordinate := change.get("coordinate", Vector3i.ZERO) as Vector3i
		var key := _key(coordinate)
		var existing := (_cells.get(key, {}) as Dictionary).duplicate(true)
		if existing.is_empty():
			var pre_volume := maxf(0.0, float(change.get("pre_fraction", 0.0)) * float(change.get("cell_volume_m3", 0.0)))
			existing = {
				"coordinate": coordinate,
				"stable_mass_q": _mass_q(pre_volume),
				"mobile_mass_q": 0,
				"mobile_compaction_q": DEFAULT_COMPACTION_Q,
			}
		var desired := mini(remaining, maxi(0, int(change.get("removed_mass_q", 0))))
		var mobile_take := mini(desired, int(existing.get("mobile_mass_q", 0)))
		var stable_take := mini(desired - mobile_take, int(existing.get("stable_mass_q", 0)))
		var accepted := mobile_take + stable_take
		if accepted <= 0:
			continue
		existing["mobile_mass_q"] = int(existing["mobile_mass_q"]) - mobile_take
		existing["stable_mass_q"] = int(existing["stable_mass_q"]) - stable_take
		mutations.append({"key": key, "state": existing, "accepted_mass_q": accepted})
		remaining -= accepted
	var accepted_total := requested_mass_q - remaining
	if accepted_total <= 0:
		return {"valid": false, "reason": "no_accounted_material", "accepted_mass_q": 0, "mutations": []}
	return {
		"valid": true,
		"reason": "staged",
		"accepted_mass_q": accepted_total,
		"mutations": mutations,
	}


func commit_cut(staged: Dictionary) -> bool:
	if not can_commit_cut(staged):
		return false
	var accepted := int(staged.get("accepted_mass_q", 0))
	for value in staged.get("mutations", []):
		var mutation := value as Dictionary
		_store_state(String(mutation.get("key", "")), mutation.get("state", {}) as Dictionary)
	bucket_mass_q += accepted
	terrain_mass_delta_q -= accepted
	conservation_error_q = terrain_mass_delta_q + bucket_mass_q
	return conservation_error_q == 0


func can_commit_cut(staged: Dictionary) -> bool:
	if not bool(staged.get("valid", false)):
		return false
	var accepted := int(staged.get("accepted_mass_q", 0))
	if accepted <= 0 or accepted > remaining_capacity_mass_q():
		return false
	var staged_total := 0
	for value in staged.get("mutations", []):
		var mutation := value as Dictionary
		var key := String(mutation.get("key", ""))
		var state := mutation.get("state", {}) as Dictionary
		var accepted_cell := int(mutation.get("accepted_mass_q", 0))
		if key.is_empty() or state.is_empty() or accepted_cell < 0:
			return false
		staged_total += accepted_cell
	return staged_total == accepted and terrain_mass_delta_q + bucket_mass_q == 0


func stage_approximate_cut(coordinates: Array[Vector3i], voxel_volume_m3: float) -> Dictionary:
	if generation < 0 or coordinates.is_empty() or not is_finite(voxel_volume_m3) or voxel_volume_m3 <= 0.0:
		return {"valid": false, "reason": "invalid_approximate_cut", "accepted_mass_q": 0, "mutations": []}
	var unique: Dictionary = {}
	for coordinate in coordinates:
		unique[_key(coordinate)] = coordinate
	var keys := unique.keys()
	keys.sort()
	var requested_mass_q := 0
	var remaining := remaining_capacity_mass_q()
	var mutations: Array[Dictionary] = []
	var nominal_cell_mass_q := maxi(1, mass_q_for_volume(voxel_volume_m3 * APPROXIMATE_CUT_OCCUPANCY_FRACTION))
	for key_value in keys:
		var key := String(key_value)
		if _approximate_cut_coverage.has(key):
			continue
		var coordinate := unique[key] as Vector3i
		var existing := (_cells.get(key, {}) as Dictionary).duplicate(true)
		if existing.is_empty():
			existing = {
				"coordinate": coordinate,
				"stable_mass_q": mass_q_for_volume(voxel_volume_m3),
				"mobile_mass_q": 0,
				"mobile_compaction_q": DEFAULT_COMPACTION_Q,
			}
		var available := maxi(0, int(existing.get("mobile_mass_q", 0))) \
			+ maxi(0, int(existing.get("stable_mass_q", 0)))
		var desired := mini(nominal_cell_mass_q, available)
		if desired <= 0:
			continue
		requested_mass_q += desired
		if remaining <= 0:
			continue
		var accepted := mini(desired, remaining)
		var mobile_take := mini(accepted, maxi(0, int(existing.get("mobile_mass_q", 0))))
		var stable_take := mini(accepted - mobile_take, maxi(0, int(existing.get("stable_mass_q", 0))))
		existing["mobile_mass_q"] = maxi(0, int(existing.get("mobile_mass_q", 0)) - mobile_take)
		existing["stable_mass_q"] = maxi(0, int(existing.get("stable_mass_q", 0)) - stable_take)
		mutations.append({
			"key": key,
			"coverage_key": key,
			"state": existing,
			"accepted_mass_q": accepted,
		})
		remaining -= accepted
	var accepted_total := _staged_mutation_total({"mutations": mutations})
	if accepted_total <= 0:
		return {
			"valid": false,
			"reason": "bucket_full" if remaining_capacity_mass_q() <= 0 else "no_accounted_material",
			"requested_mass_q": requested_mass_q,
			"accepted_mass_q": 0,
			"mutations": [],
		}
	return {
		"valid": true,
		"reason": "staged_approximate",
		"accounting_mode": "sparse_coverage_approximate",
		"requested_mass_q": requested_mass_q,
		"accepted_mass_q": accepted_total,
		"capacity_clipped": accepted_total < requested_mass_q,
		"mutations": mutations,
	}


func can_commit_approximate_cut(staged: Dictionary) -> bool:
	if not bool(staged.get("valid", false)) or String(staged.get("accounting_mode", "")) != "sparse_coverage_approximate":
		return false
	var accepted := int(staged.get("accepted_mass_q", 0))
	if accepted <= 0 or accepted > remaining_capacity_mass_q() or _staged_mutation_total(staged) != accepted:
		return false
	for value in staged.get("mutations", []):
		var mutation := value as Dictionary
		var coverage_key := String(mutation.get("coverage_key", ""))
		if coverage_key.is_empty() or _approximate_cut_coverage.has(coverage_key):
			return false
	return terrain_mass_delta_q + bucket_mass_q == 0


func commit_approximate_cut(staged: Dictionary) -> bool:
	if not can_commit_approximate_cut(staged):
		return false
	var accepted := int(staged.get("accepted_mass_q", 0))
	for value in staged.get("mutations", []):
		var mutation := value as Dictionary
		_store_state(String(mutation.get("key", "")), mutation.get("state", {}) as Dictionary)
		_approximate_cut_coverage[String(mutation.get("coverage_key", ""))] = true
	bucket_mass_q += accepted
	terrain_mass_delta_q -= accepted
	conservation_error_q = terrain_mass_delta_q + bucket_mass_q
	return conservation_error_q == 0


func stage_deposit(cell_changes: Array[Dictionary], requested_mass_q: int, incoming_compaction_q: int = LOOSE_COMPACTION_Q) -> Dictionary:
	if generation < 0 or requested_mass_q <= 0 or requested_mass_q > bucket_mass_q:
		return {"valid": false, "reason": "invalid_or_empty_bucket", "accepted_mass_q": 0, "mutations": []}
	var mutations: Array[Dictionary] = []
	var remaining := requested_mass_q
	var pending_states: Dictionary = {}
	var bounded_compaction := clampi(incoming_compaction_q, LOOSE_COMPACTION_Q, MAX_COMPACTION_Q)
	for change in cell_changes:
		if remaining <= 0:
			break
		var coordinate := change.get("coordinate", Vector3i.ZERO) as Vector3i
		var key := _key(coordinate)
		var existing := _state_for_change(change, pending_states)
		var desired := mini(remaining, maxi(0, int(change.get("added_mass_q", 0))))
		if desired <= 0:
			continue
		var old_mobile := maxi(0, int(existing.get("mobile_mass_q", 0)))
		var old_compaction := clampi(int(existing.get("mobile_compaction_q", DEFAULT_COMPACTION_Q)), LOOSE_COMPACTION_Q, MAX_COMPACTION_Q)
		existing["mobile_mass_q"] = old_mobile + desired
		existing["mobile_compaction_q"] = bounded_compaction if old_mobile <= 0 else int(
			(old_mobile * old_compaction + desired * bounded_compaction) / (old_mobile + desired)
		)
		pending_states[key] = existing
		mutations.append({"key": key, "state": existing.duplicate(true), "accepted_mass_q": desired})
		remaining -= desired
	var accepted_total := requested_mass_q - remaining
	if accepted_total <= 0:
		return {"valid": false, "reason": "no_deposit_capacity", "accepted_mass_q": 0, "mutations": []}
	return {
		"valid": true,
		"reason": "staged",
		"accepted_mass_q": accepted_total,
		"mutations": mutations,
	}


func can_commit_deposit(staged: Dictionary) -> bool:
	if not bool(staged.get("valid", false)):
		return false
	var accepted := int(staged.get("accepted_mass_q", 0))
	if accepted <= 0 or accepted > bucket_mass_q:
		return false
	return _staged_mutation_total(staged) == accepted and terrain_mass_delta_q + bucket_mass_q == 0


func commit_deposit(staged: Dictionary) -> bool:
	if not can_commit_deposit(staged):
		return false
	var accepted := int(staged.get("accepted_mass_q", 0))
	_commit_states(staged)
	_invalidate_approximate_coverage(staged)
	bucket_mass_q -= accepted
	terrain_mass_delta_q += accepted
	conservation_error_q = terrain_mass_delta_q + bucket_mass_q
	return conservation_error_q == 0


func stage_mobile_transfer(removals: Array[Dictionary], additions: Array[Dictionary], requested_mass_q: int) -> Dictionary:
	if generation < 0 or requested_mass_q <= 0:
		return {"valid": false, "reason": "invalid_transfer", "accepted_mass_q": 0, "mutations": []}
	var pending_states: Dictionary = {}
	var mutations_by_key: Dictionary = {}
	var remaining_remove := requested_mass_q
	for change in removals:
		if remaining_remove <= 0:
			break
		var coordinate := change.get("coordinate", Vector3i.ZERO) as Vector3i
		var key := _key(coordinate)
		var existing := _state_for_change(change, pending_states)
		var desired := mini(remaining_remove, maxi(0, int(change.get("removed_mass_q", 0))))
		var take := mini(desired, maxi(0, int(existing.get("mobile_mass_q", 0))))
		if take <= 0:
			continue
		existing["mobile_mass_q"] = int(existing.get("mobile_mass_q", 0)) - take
		pending_states[key] = existing
		mutations_by_key[key] = {"key": key, "state": existing.duplicate(true), "accepted_mass_q": 0}
		remaining_remove -= take
	var removed := requested_mass_q - remaining_remove
	if removed != requested_mass_q:
		return {"valid": false, "reason": "insufficient_mobile_donor", "accepted_mass_q": 0, "mutations": []}
	var remaining_add := requested_mass_q
	for change in additions:
		if remaining_add <= 0:
			break
		var coordinate := change.get("coordinate", Vector3i.ZERO) as Vector3i
		var key := _key(coordinate)
		var existing := _state_for_change(change, pending_states)
		var desired := mini(remaining_add, maxi(0, int(change.get("added_mass_q", 0))))
		if desired <= 0:
			continue
		var old_mobile := maxi(0, int(existing.get("mobile_mass_q", 0)))
		var donor_compaction := clampi(int(change.get("incoming_compaction_q", LOOSE_COMPACTION_Q)), LOOSE_COMPACTION_Q, MAX_COMPACTION_Q)
		var old_compaction := clampi(int(existing.get("mobile_compaction_q", DEFAULT_COMPACTION_Q)), LOOSE_COMPACTION_Q, MAX_COMPACTION_Q)
		existing["mobile_mass_q"] = old_mobile + desired
		existing["mobile_compaction_q"] = donor_compaction if old_mobile <= 0 else int(
			(old_mobile * old_compaction + desired * donor_compaction) / (old_mobile + desired)
		)
		pending_states[key] = existing
		mutations_by_key[key] = {"key": key, "state": existing.duplicate(true), "accepted_mass_q": 0}
		remaining_add -= desired
	if remaining_add != 0:
		return {"valid": false, "reason": "insufficient_mobile_receiver", "accepted_mass_q": 0, "mutations": []}
	var keys := mutations_by_key.keys()
	keys.sort()
	var mutations: Array[Dictionary] = []
	for key_value in keys:
		mutations.append((mutations_by_key[key_value] as Dictionary).duplicate(true))
	return {"valid": true, "reason": "staged", "accepted_mass_q": requested_mass_q, "mutations": mutations}


func can_commit_mobile_transfer(staged: Dictionary) -> bool:
	return bool(staged.get("valid", false)) and int(staged.get("accepted_mass_q", 0)) > 0 \
		and terrain_mass_delta_q + bucket_mass_q == 0


func commit_mobile_transfer(staged: Dictionary) -> bool:
	if not can_commit_mobile_transfer(staged):
		return false
	_commit_states(staged)
	_invalidate_approximate_coverage(staged)
	conservation_error_q = terrain_mass_delta_q + bucket_mass_q
	return conservation_error_q == 0


func stage_compaction(coordinates: Array[Vector3i], compaction_delta_q: int) -> Dictionary:
	if generation < 0 or compaction_delta_q <= 0:
		return {"valid": false, "reason": "invalid_compaction", "accepted_mass_q": 0, "mutations": []}
	var unique: Dictionary = {}
	for coordinate in coordinates:
		unique[_key(coordinate)] = coordinate
	var keys := unique.keys()
	keys.sort()
	var mutations: Array[Dictionary] = []
	var affected_mass_q := 0
	var volume_loss_m3 := 0.0
	for key_value in keys:
		var key := String(key_value)
		var state := (_cells.get(key, {}) as Dictionary).duplicate(true)
		var mobile_mass_q := maxi(0, int(state.get("mobile_mass_q", 0)))
		if state.is_empty() or mobile_mass_q <= 0 or int(state.get("stable_mass_q", 0)) > 0:
			continue
		var previous := clampi(int(state.get("mobile_compaction_q", LOOSE_COMPACTION_Q)), LOOSE_COMPACTION_Q, MAX_COMPACTION_Q)
		var next := mini(MAX_COMPACTION_Q, previous + compaction_delta_q)
		if next == previous:
			continue
		state["mobile_compaction_q"] = next
		var cell_volume_loss := maxf(
			0.0,
			mobile_bulk_volume_for_mass_q(mobile_mass_q, previous)
				- mobile_bulk_volume_for_mass_q(mobile_mass_q, next),
		)
		mutations.append({
			"key": key,
			"state": state,
			"accepted_mass_q": 0,
			"affected_mass_q": mobile_mass_q,
			"previous_compaction_q": previous,
			"next_compaction_q": next,
			"volume_loss_m3": cell_volume_loss,
		})
		affected_mass_q += mobile_mass_q
		volume_loss_m3 += cell_volume_loss
	if mutations.is_empty():
		return {"valid": false, "reason": "no_loose_material", "accepted_mass_q": 0, "mutations": []}
	return {
		"valid": true,
		"reason": "staged",
		"accepted_mass_q": affected_mass_q,
		"volume_loss_m3": volume_loss_m3,
		"mutations": mutations,
	}


func can_commit_compaction(staged: Dictionary) -> bool:
	return bool(staged.get("valid", false)) and int(staged.get("accepted_mass_q", 0)) > 0 \
		and terrain_mass_delta_q + bucket_mass_q == 0


func commit_compaction(staged: Dictionary) -> bool:
	if not can_commit_compaction(staged):
		return false
	_commit_states(staged)
	conservation_error_q = terrain_mass_delta_q + bucket_mass_q
	return conservation_error_q == 0


func mobile_mass_q_at(coordinate: Vector3i) -> int:
	return maxi(0, int((_cells.get(_key(coordinate), {}) as Dictionary).get("mobile_mass_q", 0)))


func stable_mass_q_at(coordinate: Vector3i) -> int:
	return maxi(0, int((_cells.get(_key(coordinate), {}) as Dictionary).get("stable_mass_q", 0)))


func mobile_compaction_q_at(coordinate: Vector3i) -> int:
	return clampi(
		int((_cells.get(_key(coordinate), {}) as Dictionary).get("mobile_compaction_q", LOOSE_COMPACTION_Q)),
		LOOSE_COMPACTION_Q,
		MAX_COMPACTION_Q,
	)


func has_compactable_mobile() -> bool:
	return not _compactable_mobile_cells.is_empty()


func is_compactable_mobile_at(coordinate: Vector3i) -> bool:
	return _compactable_mobile_cells.has(_key(coordinate))


func total_mobile_mass_q() -> int:
	var total := 0
	for value in _cells.values():
		total += maxi(0, int((value as Dictionary).get("mobile_mass_q", 0)))
	return total


func total_stable_mass_q() -> int:
	var total := 0
	for value in _cells.values():
		total += maxi(0, int((value as Dictionary).get("stable_mass_q", 0)))
	return total


func mobile_cells_snapshot(limit: int = 512) -> Array[Dictionary]:
	var keys := _cells.keys()
	keys.sort()
	var result: Array[Dictionary] = []
	for key_value in keys:
		var state := _cells[key_value] as Dictionary
		if int(state.get("mobile_mass_q", 0)) <= 0:
			continue
		result.append(state.duplicate(true))
		if result.size() >= maxi(0, limit):
			break
	return result


func all_cells_snapshot(limit: int = 512) -> Array[Dictionary]:
	var keys := _cells.keys()
	keys.sort()
	var result: Array[Dictionary] = []
	for key_value in keys:
		result.append((_cells[key_value] as Dictionary).duplicate(true))
		if result.size() >= maxi(0, limit):
			break
	return result


func state_digest() -> String:
	if _cached_state_digest_revision != _state_revision:
		_cached_state_digest = JSON.stringify(all_cells_snapshot(_cells.size())).sha256_text()
		_cached_state_digest_revision = _state_revision
	return _cached_state_digest


func credit_bucket_mass_for_test(mass_q: int) -> bool:
	if mass_q <= 0 or mass_q > remaining_capacity_mass_q():
		return false
	bucket_mass_q += mass_q
	terrain_mass_delta_q -= mass_q
	conservation_error_q = terrain_mass_delta_q + bucket_mass_q
	return conservation_error_q == 0


func cell_snapshot(coordinate: Vector3i) -> Dictionary:
	return (_cells.get(_key(coordinate), {}) as Dictionary).duplicate(true)


func get_status_snapshot(cell_grid: Array = [1, 1, 1], center_of_mass_local: Vector3 = Vector3.ZERO) -> Dictionary:
	var fill_ratio := float(bucket_mass_q) / float(bucket_capacity_mass_q) if bucket_capacity_mass_q > 0 else 0.0
	var profile_size := 1
	for value in cell_grid:
		profile_size *= maxi(1, int(value))
	var fill_profile := PackedFloat32Array()
	fill_profile.resize(profile_size)
	fill_profile.fill(clampf(fill_ratio, 0.0, 1.0))
	return {
		"generation": generation,
		"material_density_kg_m3": material_density_kg_m3,
		"loose_density_kg_m3": loose_density_kg_m3,
		"contract_bucket_capacity_m3": contract_bucket_capacity_m3,
		"bucket_capacity_override_m3": bucket_capacity_override_m3,
		"bucket_capacity_overridden": bucket_capacity_override_m3 > 0.0,
		"bucket_capacity_m3": bucket_capacity_m3,
		"bucket_capacity_mass_q": bucket_capacity_mass_q,
		"bucket_mass_q": bucket_mass_q,
		"bucket_volume_m3": volume_for_mass_q(bucket_mass_q),
		"payload_mass_kg": float(bucket_mass_q) / float(MASS_Q_PER_KG),
		"fill_ratio": fill_ratio,
		"center_of_mass_local": center_of_mass_local,
		"fill_profile": fill_profile,
		"cell_grid": cell_grid.duplicate(),
		"terrain_mass_delta_q": terrain_mass_delta_q,
		"conservation_error_q": conservation_error_q,
		"conservation_error_kg": float(conservation_error_q) / float(MASS_Q_PER_KG),
		"sparse_cell_count": _cells.size(),
		"mobile_cell_count": _mobile_cell_count,
		"compactable_mobile_cell_count": _compactable_mobile_cells.size(),
		"mass_accounting_mode": "hybrid_exact_or_sparse_coverage",
		"approximate_cut_coverage_cells": _approximate_cut_coverage.size(),
		"material_state_revision": _state_revision,
		"material_state_digest": _cached_state_digest if _cached_state_digest_revision == _state_revision else "",
		"material_state_digest_deferred": _cached_state_digest_revision != _state_revision,
	}


func _mass_q(volume_m3: float) -> int:
	return roundi(maxf(0.0, volume_m3) * material_density_kg_m3 * float(MASS_Q_PER_KG))


func _mobile_bulk_density_kg_m3(compaction_q: int) -> float:
	var alpha := float(clampi(compaction_q, LOOSE_COMPACTION_Q, MAX_COMPACTION_Q)) / float(MAX_COMPACTION_Q)
	return lerpf(loose_density_kg_m3, material_density_kg_m3, alpha)


func _key(coordinate: Vector3i) -> String:
	return "%d,%d,%d" % [coordinate.x, coordinate.y, coordinate.z]


func _state_for_change(change: Dictionary, pending_states: Dictionary) -> Dictionary:
	var coordinate := change.get("coordinate", Vector3i.ZERO) as Vector3i
	var key := _key(coordinate)
	var existing := (pending_states.get(key, _cells.get(key, {})) as Dictionary).duplicate(true)
	if existing.is_empty():
		var pre_volume := maxf(0.0, float(change.get("pre_fraction", 0.0)) * float(change.get("cell_volume_m3", 0.0)))
		existing = {
			"coordinate": coordinate,
			"stable_mass_q": _mass_q(pre_volume),
			"mobile_mass_q": 0,
			"mobile_compaction_q": DEFAULT_COMPACTION_Q,
		}
	return existing


func _staged_mutation_total(staged: Dictionary) -> int:
	var total := 0
	for value in staged.get("mutations", []):
		var mutation := value as Dictionary
		var key := String(mutation.get("key", ""))
		var state := mutation.get("state", {}) as Dictionary
		var accepted_cell := int(mutation.get("accepted_mass_q", 0))
		if key.is_empty() or state.is_empty() or accepted_cell < 0:
			return -1
		total += accepted_cell
	return total


func _commit_states(staged: Dictionary) -> void:
	for value in staged.get("mutations", []):
		var mutation := value as Dictionary
		_store_state(String(mutation.get("key", "")), mutation.get("state", {}) as Dictionary)


func _invalidate_approximate_coverage(staged: Dictionary) -> void:
	for value in staged.get("mutations", []):
		var mutation := value as Dictionary
		_approximate_cut_coverage.erase(String(mutation.get("key", "")))


func _store_state(key: String, state: Dictionary) -> void:
	var previous := _cells.get(key, {}) as Dictionary
	var previous_mobile := int(previous.get("mobile_mass_q", 0)) > 0
	var stored := state.duplicate(true)
	var mobile := int(stored.get("mobile_mass_q", 0)) > 0
	if previous_mobile != mobile:
		_mobile_cell_count += 1 if mobile else -1
	_cells[key] = stored
	var compactable := mobile \
		and int(stored.get("stable_mass_q", 0)) <= 0 \
		and int(stored.get("mobile_compaction_q", LOOSE_COMPACTION_Q)) < MAX_COMPACTION_Q
	if compactable:
		_compactable_mobile_cells[key] = true
	else:
		_compactable_mobile_cells.erase(key)
	_state_revision += 1

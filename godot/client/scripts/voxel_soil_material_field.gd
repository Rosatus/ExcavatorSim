class_name VoxelSoilMaterialField
extends RefCounted

const MASS_Q_PER_KG := 1000000
const APPROXIMATE_CUT_OCCUPANCY_FRACTION := 0.55

var generation := -1
var material_density_kg_m3 := 0.0
var contract_bucket_capacity_m3 := 0.0
var bucket_capacity_override_m3 := 0.0
var bucket_capacity_m3 := 0.0
var bucket_capacity_mass_q := 0
var bucket_mass_q := 0
var terrain_mass_delta_q := 0
var discarded_cut_mass_q := 0
var conservation_error_q := 0
var _cells: Dictionary = {}
var _approximate_cut_coverage: Dictionary = {}
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
	contract_bucket_capacity_m3 = contract_capacity
	bucket_capacity_override_m3 = capacity_override_m3 if override_valid else 0.0
	bucket_capacity_m3 = capacity
	bucket_capacity_mass_q = _mass_q(capacity)
	bucket_mass_q = 0
	terrain_mass_delta_q = 0
	discarded_cut_mass_q = 0
	conservation_error_q = 0
	_cells.clear()
	_approximate_cut_coverage.clear()
	_state_revision = 0
	_cached_state_digest_revision = -1
	_cached_state_digest = ""
	return true


func remaining_capacity_mass_q() -> int:
	# Pending deposits remain in the bucket until terrain commit succeeds.
	return maxi(0, bucket_capacity_mass_q - bucket_mass_q)


func visual_fill_ratio() -> float:
	var visual_capacity_mass_q := _mass_q(contract_bucket_capacity_m3)
	return (
		float(bucket_mass_q) / float(visual_capacity_mass_q)
		if visual_capacity_mass_q > 0
		else 0.0
	)


func set_bucket_capacity_override_for_testing(capacity_override_m3: float) -> Dictionary:
	if generation < 0 or not is_finite(capacity_override_m3) or capacity_override_m3 < 0.0:
		return {"accepted": false, "reason": "invalid_capacity_override"}
	var override_valid := capacity_override_m3 > 0.0
	var next_capacity_m3 := capacity_override_m3 if override_valid else contract_bucket_capacity_m3
	var next_capacity_mass_q := _mass_q(next_capacity_m3)
	if next_capacity_mass_q <= 0:
		return {"accepted": false, "reason": "invalid_capacity_override"}
	if bucket_mass_q > next_capacity_mass_q:
		return {
			"accepted": false,
			"reason": "bucket_mass_exceeds_requested_capacity",
			"bucket_mass_q": bucket_mass_q,
			"requested_capacity_mass_q": next_capacity_mass_q,
		}
	bucket_capacity_override_m3 = capacity_override_m3 if override_valid else 0.0
	bucket_capacity_m3 = next_capacity_m3
	bucket_capacity_mass_q = next_capacity_mass_q
	return {
		"accepted": true,
		"reason": "capacity_override_updated",
		"bucket_capacity_overridden": override_valid,
		"bucket_capacity_m3": bucket_capacity_m3,
		"bucket_capacity_mass_q": bucket_capacity_mass_q,
	}


func mass_q_for_volume(volume_m3: float) -> int:
	return _mass_q(volume_m3)


func volume_for_mass_q(mass_q: int) -> float:
	return float(mass_q) / (material_density_kg_m3 * float(MASS_Q_PER_KG)) if material_density_kg_m3 > 0.0 else 0.0


func stage_cut(cell_changes: Array[Dictionary], requested_mass_q: int, allow_overflow: bool = false) -> Dictionary:
	if generation < 0 or requested_mass_q <= 0 or (not allow_overflow and requested_mass_q > remaining_capacity_mass_q()):
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
			}
		var desired := mini(remaining, maxi(0, int(change.get("removed_mass_q", 0))))
		var accepted := mini(desired, maxi(0, int(existing.get("stable_mass_q", 0))))
		if accepted <= 0:
			continue
		existing["stable_mass_q"] = int(existing["stable_mass_q"]) - accepted
		mutations.append({"key": key, "state": existing, "accepted_mass_q": accepted})
		remaining -= accepted
	var accepted_total := requested_mass_q - remaining
	if accepted_total <= 0:
		return {"valid": false, "reason": "no_accounted_material", "accepted_mass_q": 0, "mutations": []}
	return {
		"valid": true,
		"reason": "staged",
		"accepted_mass_q": accepted_total,
		"captured_mass_q": mini(accepted_total, remaining_capacity_mass_q()),
		"discarded_mass_q": maxi(0, accepted_total - remaining_capacity_mass_q()),
		"mutations": mutations,
	}


func commit_cut(staged: Dictionary) -> bool:
	if not can_commit_cut(staged):
		return false
	var accepted := int(staged.get("accepted_mass_q", 0))
	for value in staged.get("mutations", []):
		var mutation := value as Dictionary
		_store_state(String(mutation.get("key", "")), mutation.get("state", {}) as Dictionary)
	bucket_mass_q += int(staged.get("captured_mass_q", accepted))
	discarded_cut_mass_q += int(staged.get("discarded_mass_q", 0))
	terrain_mass_delta_q -= accepted
	conservation_error_q = _mass_balance_q()
	return conservation_error_q == 0


func can_commit_cut(staged: Dictionary) -> bool:
	if not bool(staged.get("valid", false)):
		return false
	var accepted := int(staged.get("accepted_mass_q", 0))
	if accepted <= 0 or not _cut_capture_valid(staged):
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
	return staged_total == accepted and _mass_balance_q() == 0


func has_credited_cut_coordinates(coordinates: Array[Vector3i]) -> bool:
	if coordinates.is_empty() or _mass_balance_q() != 0:
		return false
	for coordinate in coordinates:
		if not _approximate_cut_coverage.has(_key(coordinate)):
			return false
	return true


func stage_approximate_cut(coordinates: Array[Vector3i], voxel_volume_m3: float, allow_overflow: bool = false) -> Dictionary:
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
			}
		var available := maxi(0, int(existing.get("stable_mass_q", 0)))
		var desired := mini(nominal_cell_mass_q, available)
		if desired <= 0:
			continue
		requested_mass_q += desired
		if not allow_overflow and remaining <= 0:
			continue
		var accepted := desired if allow_overflow else mini(desired, remaining)
		existing["stable_mass_q"] = maxi(0, int(existing.get("stable_mass_q", 0)) - accepted)
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
		"captured_mass_q": mini(accepted_total, remaining_capacity_mass_q()),
		"discarded_mass_q": maxi(0, accepted_total - remaining_capacity_mass_q()),
		"capacity_clipped": accepted_total > remaining_capacity_mass_q() or accepted_total < requested_mass_q,
		"mutations": mutations,
	}


func can_commit_approximate_cut(staged: Dictionary) -> bool:
	if not bool(staged.get("valid", false)) or String(staged.get("accounting_mode", "")) != "sparse_coverage_approximate":
		return false
	var accepted := int(staged.get("accepted_mass_q", 0))
	if accepted <= 0 or not _cut_capture_valid(staged) or _staged_mutation_total(staged) != accepted:
		return false
	for value in staged.get("mutations", []):
		var mutation := value as Dictionary
		var coverage_key := String(mutation.get("coverage_key", ""))
		if coverage_key.is_empty() or _approximate_cut_coverage.has(coverage_key):
			return false
	return _mass_balance_q() == 0


func commit_approximate_cut(staged: Dictionary) -> bool:
	if not can_commit_approximate_cut(staged):
		return false
	var accepted := int(staged.get("accepted_mass_q", 0))
	for value in staged.get("mutations", []):
		var mutation := value as Dictionary
		_store_state(String(mutation.get("key", "")), mutation.get("state", {}) as Dictionary)
		_approximate_cut_coverage[String(mutation.get("coverage_key", ""))] = true
	bucket_mass_q += int(staged.get("captured_mass_q", accepted))
	discarded_cut_mass_q += int(staged.get("discarded_mass_q", 0))
	terrain_mass_delta_q -= accepted
	conservation_error_q = _mass_balance_q()
	return conservation_error_q == 0


func _cut_capture_valid(staged: Dictionary) -> bool:
	var removed := int(staged.get("accepted_mass_q", 0))
	var captured := int(staged.get("captured_mass_q", removed))
	var discarded := int(staged.get("discarded_mass_q", 0))
	return captured >= 0 and captured <= remaining_capacity_mass_q() \
		and discarded >= 0 and captured + discarded == removed


func _mass_balance_q() -> int:
	return terrain_mass_delta_q + bucket_mass_q + discarded_cut_mass_q


func stage_deposit(cell_changes: Array[Dictionary], requested_mass_q: int) -> Dictionary:
	if generation < 0 or requested_mass_q <= 0 or requested_mass_q > bucket_mass_q:
		return {"valid": false, "reason": "invalid_or_empty_bucket", "accepted_mass_q": 0, "mutations": []}
	var mutations: Array[Dictionary] = []
	var remaining := requested_mass_q
	var pending_states: Dictionary = {}
	for change in cell_changes:
		if remaining <= 0:
			break
		var coordinate := change.get("coordinate", Vector3i.ZERO) as Vector3i
		var key := _key(coordinate)
		var existing := _state_for_change(change, pending_states)
		var desired := mini(remaining, maxi(0, int(change.get("added_mass_q", 0))))
		if desired <= 0:
			continue
		existing["stable_mass_q"] = maxi(0, int(existing.get("stable_mass_q", 0))) + desired
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
	return _staged_mutation_total(staged) == accepted and _mass_balance_q() == 0


func commit_deposit(staged: Dictionary) -> bool:
	if not can_commit_deposit(staged):
		return false
	var accepted := int(staged.get("accepted_mass_q", 0))
	_commit_states(staged)
	_invalidate_approximate_coverage(staged)
	bucket_mass_q -= accepted
	terrain_mass_delta_q += accepted
	conservation_error_q = _mass_balance_q()
	return conservation_error_q == 0


func stable_mass_q_at(coordinate: Vector3i) -> int:
	return maxi(0, int((_cells.get(_key(coordinate), {}) as Dictionary).get("stable_mass_q", 0)))


func get_state_revision() -> int:
	return _state_revision


func total_stable_mass_q() -> int:
	var total := 0
	for value in _cells.values():
		total += maxi(0, int((value as Dictionary).get("stable_mass_q", 0)))
	return total


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
	conservation_error_q = _mass_balance_q()
	return conservation_error_q == 0


func cell_snapshot(coordinate: Vector3i) -> Dictionary:
	return (_cells.get(_key(coordinate), {}) as Dictionary).duplicate(true)


func get_status_snapshot(cell_grid: Array = [1, 1, 1], center_of_mass_local: Vector3 = Vector3.ZERO) -> Dictionary:
	var collection_fill_ratio := (
		float(bucket_mass_q) / float(bucket_capacity_mass_q)
		if bucket_capacity_mass_q > 0
		else 0.0
	)
	var fill_ratio := visual_fill_ratio()
	var profile_size := 1
	for value in cell_grid:
		profile_size *= maxi(1, int(value))
	var fill_profile := PackedFloat32Array()
	fill_profile.resize(profile_size)
	fill_profile.fill(clampf(fill_ratio, 0.0, 1.0))
	return {
		"generation": generation,
		"material_density_kg_m3": material_density_kg_m3,
		"contract_bucket_capacity_m3": contract_bucket_capacity_m3,
		"bucket_capacity_override_m3": bucket_capacity_override_m3,
		"bucket_capacity_overridden": bucket_capacity_override_m3 > 0.0,
		"bucket_capacity_m3": bucket_capacity_m3,
		"bucket_capacity_mass_q": bucket_capacity_mass_q,
		"visual_bucket_capacity_m3": contract_bucket_capacity_m3,
		"collection_fill_ratio": collection_fill_ratio,
		"bucket_mass_q": bucket_mass_q,
		"bucket_volume_m3": volume_for_mass_q(bucket_mass_q),
		"payload_mass_kg": float(bucket_mass_q) / float(MASS_Q_PER_KG),
		"fill_ratio": fill_ratio,
		"center_of_mass_local": center_of_mass_local,
		"fill_profile": fill_profile,
		"cell_grid": cell_grid.duplicate(),
		"terrain_mass_delta_q": terrain_mass_delta_q,
		"discarded_cut_mass_q": discarded_cut_mass_q,
		"discarded_cut_volume_m3": volume_for_mass_q(discarded_cut_mass_q),
		"conservation_error_q": conservation_error_q,
		"conservation_error_kg": float(conservation_error_q) / float(MASS_Q_PER_KG),
		"sparse_cell_count": _cells.size(),
		"mass_accounting_mode": "hybrid_exact_or_sparse_coverage",
		"approximate_cut_coverage_cells": _approximate_cut_coverage.size(),
		"material_state_revision": _state_revision,
		"material_state_digest": _cached_state_digest if _cached_state_digest_revision == _state_revision else "",
		"material_state_digest_deferred": _cached_state_digest_revision != _state_revision,
	}


func _mass_q(volume_m3: float) -> int:
	return roundi(maxf(0.0, volume_m3) * material_density_kg_m3 * float(MASS_Q_PER_KG))


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
	_cells[key] = state.duplicate(true)
	_state_revision += 1

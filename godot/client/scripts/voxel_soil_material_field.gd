class_name VoxelSoilMaterialField
extends RefCounted

const MASS_Q_PER_KG := 1000000
const DEFAULT_COMPACTION_Q := 1000

var generation := -1
var material_density_kg_m3 := 0.0
var contract_bucket_capacity_m3 := 0.0
var bucket_capacity_override_m3 := 0.0
var bucket_capacity_m3 := 0.0
var bucket_capacity_mass_q := 0
var bucket_mass_q := 0
var terrain_mass_delta_q := 0
var conservation_error_q := 0
var _cells: Dictionary = {}


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
	conservation_error_q = 0
	_cells.clear()
	return true


func remaining_capacity_mass_q() -> int:
	return maxi(0, bucket_capacity_mass_q - bucket_mass_q)


func mass_q_for_volume(volume_m3: float) -> int:
	return _mass_q(volume_m3)


func volume_for_mass_q(mass_q: int) -> float:
	return float(mass_q) / (material_density_kg_m3 * float(MASS_Q_PER_KG)) if material_density_kg_m3 > 0.0 else 0.0


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
		_cells[String(mutation.get("key", ""))] = (mutation.get("state", {}) as Dictionary).duplicate(true)
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
	}


func _mass_q(volume_m3: float) -> int:
	return roundi(maxf(0.0, volume_m3) * material_density_kg_m3 * float(MASS_Q_PER_KG))


func _key(coordinate: Vector3i) -> String:
	return "%d,%d,%d" % [coordinate.x, coordinate.y, coordinate.z]

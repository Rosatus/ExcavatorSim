class_name LooseSoilFluxSolver
extends RefCounted

## Bounded deterministic local plastic-flow approximation for the persistent
## loose heightfield. It moves existing loose depth simultaneously along
## canonical four-neighbor edges and never changes stable soil or total volume.

const SCHEMA_VERSION := "loose-soil-flux-v1"
const REPOSE_DEGREES := {
	"loose": 34.0,
	"compact": 40.0,
	"sand": 30.0,
	"damp": 43.0,
}
const DEFAULT_PASSES := 3
const MAX_PASSES := 8
const HYSTERESIS_M := 0.004
const MIN_CHANGE_M := 0.000001


func build_patch(
	snapshot: Dictionary,
	compaction: PackedFloat32Array,
	material_preset: String,
	frontier: Array[int],
	tick: int,
	pass_count: int = DEFAULT_PASSES,
	horizontal_impulse_xz: Vector2 = Vector2.ZERO
) -> Dictionary:
	var result := {
		"schema_version": SCHEMA_VERSION,
		"valid": false,
		"reason": "unavailable",
		"patch": {},
		"moved_volume_m3": 0.0,
		"changed_cell_count": 0,
		"passes": 0,
		"frontier_count": 0,
	}
	var stable: PackedFloat32Array = snapshot.get("stable_heights", PackedFloat32Array())
	var original_loose: PackedFloat32Array = snapshot.get("loose_depth", PackedFloat32Array())
	var rows := int(snapshot.get("rows", 0))
	var columns := int(snapshot.get("columns", 0))
	var spacing := float(snapshot.get("spacing_m", 0.0))
	if material_preset not in REPOSE_DEGREES or rows < 2 or columns < 2 or stable.size() != rows * columns or original_loose.size() != stable.size() or compaction.size() != stable.size() or spacing <= 0.0:
		result["reason"] = "field_invalid"
		return result
	var active_indices := _canonical_frontier(frontier, stable.size())
	if active_indices.is_empty():
		result["reason"] = "frontier_empty"
		return result
	result["frontier_count"] = active_indices.size()
	var active_lookup := {}
	for index in active_indices:
		active_lookup[index] = true
	var loose := original_loose.duplicate()
	var moved_height_total := 0.0
	var passes := clampi(pass_count, 1, MAX_PASSES)
	var impulse := horizontal_impulse_xz.normalized() if horizontal_impulse_xz.length_squared() > 0.000001 else Vector2.ZERO
	var impulse_strength := clampf(horizontal_impulse_xz.length(), 0.0, 1.0)
	for _pass_index in passes:
		var proposals: Array[Dictionary] = []
		var outgoing := PackedFloat32Array()
		outgoing.resize(loose.size())
		for index in active_indices:
			var row: int = index / columns
			var column: int = index % columns
			for offset_value in [Vector2i(1, 0), Vector2i(0, 1)]:
				var offset := offset_value as Vector2i
				var neighbor_column: int = column + offset.x
				var neighbor_row: int = row + offset.y
				if neighbor_column >= columns or neighbor_row >= rows:
					continue
				var neighbor: int = neighbor_row * columns + neighbor_column
				if not active_lookup.has(neighbor):
					continue
				var first_surface := stable[index] + loose[index]
				var second_surface := stable[neighbor] + loose[neighbor]
				var difference := first_surface - second_surface
				var pair_direction := Vector2(float(offset.x), float(offset.y))
				var impulse_alignment := pair_direction.dot(impulse)
				var donor := -1
				var receiver := -1
				if absf(difference) > HYSTERESIS_M:
					donor = index if difference > 0.0 else neighbor
					receiver = neighbor if difference > 0.0 else index
				elif absf(impulse_alignment) > 0.0001:
					donor = index if impulse_alignment > 0.0 else neighbor
					receiver = neighbor if impulse_alignment > 0.0 else index
				else:
					continue
				var compaction_average := clampf((compaction[donor] + compaction[receiver]) * 0.5, 0.0, 1.0)
				var repose := deg_to_rad(float(REPOSE_DEGREES[material_preset]) + compaction_average * 6.0)
				var allowed_height := tan(repose) * spacing + HYSTERESIS_M
				var excess := maxf(0.0, absf(difference) - allowed_height)
				if loose[donor] <= MIN_CHANGE_M:
					continue
				var mobility := lerpf(0.34, 0.12, compaction_average)
				var transfer := minf(loose[donor] * 0.28, excess * mobility * 0.5) if excess > MIN_CHANGE_M else 0.0
				var direction := Vector2(float((receiver % columns) - (donor % columns)), float((receiver / columns) - (donor / columns))).normalized()
				if not impulse.is_zero_approx():
					transfer += maxf(0.0, direction.dot(impulse)) * loose[donor] * 0.08 * impulse_strength
				transfer = minf(transfer, loose[donor])
				if transfer <= MIN_CHANGE_M:
					continue
				proposals.append({"donor": donor, "receiver": receiver, "height": transfer})
				outgoing[donor] += transfer
		if proposals.is_empty():
			break
		for proposal in proposals:
			var donor := int(proposal["donor"])
			var receiver := int(proposal["receiver"])
			var transfer := float(proposal["height"])
			if outgoing[donor] > loose[donor] and outgoing[donor] > MIN_CHANGE_M:
				transfer *= loose[donor] / outgoing[donor]
			loose[donor] -= transfer
			loose[receiver] += transfer
			moved_height_total += transfer
		result["passes"] = int(result["passes"]) + 1
	var patch_rows: Array[Dictionary] = []
	for index in active_indices:
		if absf(loose[index] - original_loose[index]) <= MIN_CHANGE_M:
			continue
		patch_rows.append({
			"index": index,
			"original_stable_height": float(stable[index]),
			"original_loose_depth": float(original_loose[index]),
			"target_stable_height": float(stable[index]),
			"target_loose_depth": maxf(0.0, float(loose[index])),
			"action": "repose_flux",
			"contributing_region_ids": ["loose_soil_flux"],
		})
	if patch_rows.is_empty():
		result["reason"] = "below_repose"
		return result
	var patch := {
		"schema_version": SoilCellPatch.SCHEMA_VERSION,
		"generation": int(snapshot.get("world_generation", -1)),
		"base_revision": int(snapshot.get("terrain_revision", -1)),
		"tick": tick,
		"tool_identity": "loose-flux|%d" % tick,
		"rows": patch_rows,
		"removed_stable_m3": 0.0,
		"removed_loose_m3": 0.0,
		"moved_volume_m3": moved_height_total * spacing * spacing,
		"dirty_rect_cells": SoilCellPatch.dirty_rect(patch_rows, columns),
	}
	patch["patch_hash"] = SoilCellPatch.compute_hash(patch)
	var validation := SoilCellPatch.validate_for_snapshot(patch, snapshot)
	if not bool(validation.get("valid", false)):
		result["reason"] = "patch_%s" % String(validation.get("reason", "invalid"))
		return result
	result["valid"] = true
	result["reason"] = "ok"
	result["patch"] = patch
	result["moved_volume_m3"] = patch["moved_volume_m3"]
	result["changed_cell_count"] = patch_rows.size()
	return result


func _canonical_frontier(frontier: Array[int], cell_count: int) -> Array[int]:
	var seen := {}
	for index in frontier:
		if index >= 0 and index < cell_count:
			seen[index] = true
	var result: Array[int] = []
	for index_value in seen.keys():
		result.append(int(index_value))
	result.sort()
	return result

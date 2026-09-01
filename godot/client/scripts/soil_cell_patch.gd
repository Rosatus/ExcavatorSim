class_name SoilCellPatch
extends RefCounted

## Canonical immutable terrain-layer patch shared by the continuous bucket
## sweep, TerrainState and the soil authority. Rows are always row-major,
## unique and expressed as absolute layer targets so validation can remain
## mutation-free.

const SCHEMA_VERSION := "soil-cell-patch-v2"
const MAX_ROWS := 50000


static func compute_hash(patch: Dictionary) -> String:
	var lines := PackedStringArray([
		SCHEMA_VERSION,
		str(int(patch.get("generation", -1))),
		str(int(patch.get("base_revision", -1))),
		str(int(patch.get("tick", -1))),
		String(patch.get("tool_identity", "")),
	])
	for value in patch.get("rows", []):
		if not value is Dictionary:
			return ""
		var row := value as Dictionary
		var contributors := PackedStringArray()
		for contributor in row.get("contributing_region_ids", []):
			contributors.append(String(contributor))
		lines.append("%d|%.9f|%.9f|%.9f|%.9f|%s|%s" % [
			int(row.get("index", -1)),
			float(row.get("original_stable_height", NAN)),
			float(row.get("original_loose_depth", NAN)),
			float(row.get("target_stable_height", NAN)),
			float(row.get("target_loose_depth", NAN)),
			String(row.get("action", "")),
			",".join(contributors),
		])
	return _sha256("\n".join(lines).to_utf8_buffer())


static func validate_for_snapshot(patch: Dictionary, snapshot: Dictionary) -> Dictionary:
	if String(patch.get("schema_version", "")) != SCHEMA_VERSION:
		return _result(false, "schema_mismatch")
	if int(patch.get("generation", -1)) != int(snapshot.get("world_generation", -2)):
		return _result(false, "generation_mismatch")
	if int(patch.get("base_revision", -1)) != int(snapshot.get("terrain_revision", -2)):
		return _result(false, "revision_mismatch")
	if int(patch.get("tick", -1)) < 0 or String(patch.get("tool_identity", "")).is_empty():
		return _result(false, "identity_invalid")
	var stable: PackedFloat32Array = snapshot.get("stable_heights", PackedFloat32Array())
	var loose: PackedFloat32Array = snapshot.get("loose_depth", PackedFloat32Array())
	if stable.is_empty() or stable.size() != loose.size():
		return _result(false, "snapshot_layers_invalid")
	var rows := patch.get("rows", []) as Array
	if rows.is_empty() or rows.size() > mini(MAX_ROWS, stable.size()):
		return _result(false, "row_count_invalid")
	var previous_index := -1
	var action_set := {}
	for value in rows:
		if not value is Dictionary:
			return _result(false, "row_invalid")
		var row := value as Dictionary
		var index := int(row.get("index", -1))
		if index <= previous_index or index < 0 or index >= stable.size():
			return _result(false, "row_order_invalid")
		previous_index = index
		var original_stable := float(row.get("original_stable_height", NAN))
		var original_loose := float(row.get("original_loose_depth", NAN))
		var target_stable := float(row.get("target_stable_height", NAN))
		var target_loose := float(row.get("target_loose_depth", NAN))
		if not _finite(original_stable) or not _finite(original_loose) or not _finite(target_stable) or not _finite(target_loose):
			return _result(false, "row_non_finite")
		if original_stable != stable[index] or original_loose != loose[index]:
			return _result(false, "original_mismatch")
		if target_loose < 0.0 or target_stable > original_stable:
			return _result(false, "layer_target_invalid")
		var contributors := row.get("contributing_region_ids", []) as Array
		var action := String(row.get("action", ""))
		if contributors.is_empty() or action.is_empty():
			return _result(false, "row_provenance_invalid")
		action_set[action] = true
		var previous_contributor := ""
		for contributor_value in contributors:
			var contributor := String(contributor_value)
			if contributor.is_empty() or (not previous_contributor.is_empty() and contributor <= previous_contributor):
				return _result(false, "row_provenance_order_invalid")
			previous_contributor = contributor
	var metrics := volume_metrics(patch, snapshot)
	if not bool(metrics.get("valid", false)):
		return _result(false, String(metrics.get("reason", "volume_invalid")))
	var tolerance := maxf(0.0000005, float(metrics.get("absolute_change_m3", 0.0)) * 0.0001)
	var actions := action_set.keys()
	var all_cut_actions := true
	for action_value in actions:
		if String(action_value) not in ["cut", "side_cut", "scrape", "grade", "surface_cut"]:
			all_cut_actions = false
	if all_cut_actions:
		if float(metrics["loose_added_m3"]) > tolerance:
			return _result(false, "cut_patch_added_loose")
		if absf(float(patch.get("removed_stable_m3", NAN)) - float(metrics["stable_removed_m3"])) > tolerance:
			return _result(false, "stable_volume_mismatch")
		if absf(float(patch.get("removed_loose_m3", NAN)) - float(metrics["loose_removed_m3"])) > tolerance:
			return _result(false, "loose_volume_mismatch")
	elif actions.size() == 1 and String(actions[0]) == "repose_flux":
		if float(metrics["stable_removed_m3"]) > tolerance or absf(float(metrics["loose_net_m3"])) > tolerance:
			return _result(false, "flux_not_conservative")
	elif actions.size() == 1 and String(actions[0]) == "settle_loose":
		if float(metrics["stable_removed_m3"]) > tolerance or float(metrics["loose_removed_m3"]) > tolerance:
			return _result(false, "settlement_removed_material")
		if absf(float(patch.get("added_loose_m3", NAN)) - float(metrics["loose_added_m3"])) > tolerance:
			return _result(false, "settlement_volume_mismatch")
	else:
		return _result(false, "action_invalid")
	var expected_dirty := dirty_rect(rows, int(snapshot.get("columns", 0)))
	var provided_dirty := patch.get("dirty_rect_cells", expected_dirty) as Rect2i
	if patch.has("dirty_rect_cells") and provided_dirty != expected_dirty:
		return _result(false, "dirty_rect_mismatch")
	var expected_hash := compute_hash(patch)
	if expected_hash.is_empty() or String(patch.get("patch_hash", "")) != expected_hash:
		return _result(false, "hash_mismatch")
	return _result(true, "ok")


static func volume_metrics(patch: Dictionary, snapshot: Dictionary) -> Dictionary:
	var spacing := float(snapshot.get("spacing_m", 0.0))
	if spacing <= 0.0:
		return {"valid": false, "reason": "spacing_invalid"}
	var stable_removed := 0.0
	var loose_removed := 0.0
	var loose_added := 0.0
	for value in patch.get("rows", []):
		if not value is Dictionary:
			return {"valid": false, "reason": "row_invalid"}
		var row := value as Dictionary
		var original_stable := float(row.get("original_stable_height", NAN))
		var original_loose := float(row.get("original_loose_depth", NAN))
		var target_stable := float(row.get("target_stable_height", NAN))
		var target_loose := float(row.get("target_loose_depth", NAN))
		if not _finite(original_stable) or not _finite(original_loose) or not _finite(target_stable) or not _finite(target_loose):
			return {"valid": false, "reason": "row_non_finite"}
		stable_removed += maxf(0.0, original_stable - target_stable)
		loose_removed += maxf(0.0, original_loose - target_loose)
		loose_added += maxf(0.0, target_loose - original_loose)
	var cell_area := spacing * spacing
	return {
		"valid": true,
		"reason": "ok",
		"stable_removed_m3": stable_removed * cell_area,
		"loose_removed_m3": loose_removed * cell_area,
		"loose_added_m3": loose_added * cell_area,
		"loose_net_m3": (loose_added - loose_removed) * cell_area,
		"absolute_change_m3": (stable_removed + loose_removed + loose_added) * cell_area,
	}


static func dirty_rect(rows_data: Array, column_count: int) -> Rect2i:
	if rows_data.is_empty() or column_count <= 0:
		return Rect2i()
	var minimum := Vector2i(2147483647, 2147483647)
	var maximum := Vector2i(-2147483648, -2147483648)
	for value in rows_data:
		if not value is Dictionary:
			return Rect2i()
		var index := int((value as Dictionary).get("index", -1))
		if index < 0:
			return Rect2i()
		var cell := Vector2i(index % column_count, index / column_count)
		minimum = minimum.min(cell)
		maximum = maximum.max(cell)
	return Rect2i(minimum, maximum - minimum + Vector2i.ONE)


static func _result(valid: bool, reason: String) -> Dictionary:
	return {"valid": valid, "reason": reason}


static func _sha256(bytes: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(bytes)
	return hashing.finish().hex_encode()


static func _finite(value: float) -> bool:
	return not is_nan(value) and not is_inf(value)

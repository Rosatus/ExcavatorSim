class_name ArcadeBucketLoadState
extends RefCounted

## Lightweight presentation/load estimate for arcade_stamp_v3. Removed terrain
## is not conserved here; this state only drives bucket fill, payload feedback
## and one generation-scoped visual dump event.

const SCHEMA_VERSION := "arcade-bucket-load-v1"
const EPSILON_M3 := 0.000001

var configured := false
var generation := -1
var model_id := ""
var capacity_m3 := 0.0
var material_density_kg_m3 := 0.0
var bucket_volume_m3 := 0.0
var cell_grid := [1, 1, 1]
var transaction_sequence := 0
var last_transaction: Dictionary = {}
var accepted_dump_event_id := ""
var dump_release_world := Vector3.ZERO
var dump_released_fill_ratio := 0.0


func configure(contract: Dictionary, world_generation: int) -> bool:
	var requested_model := String(contract.get("model_id", ""))
	var requested_capacity := float(contract.get("heaped_capacity_m3", contract.get("nominal_capacity_m3", 0.0)))
	var requested_density := float(contract.get("material_density_kg_m3", 0.0))
	var requested_grid := contract.get("cell_grid", [1, 1, 1]) as Array
	if requested_model.is_empty() or requested_capacity <= 0.0 or requested_density <= 0.0 or requested_grid.size() != 3:
		return false
	model_id = requested_model
	capacity_m3 = requested_capacity
	material_density_kg_m3 = requested_density
	cell_grid = requested_grid.duplicate()
	generation = world_generation
	bucket_volume_m3 = 0.0
	transaction_sequence = 0
	last_transaction.clear()
	accepted_dump_event_id = ""
	dump_release_world = Vector3.ZERO
	dump_released_fill_ratio = 0.0
	configured = true
	return true


func clear() -> void:
	configured = false
	generation = -1
	model_id = ""
	capacity_m3 = 0.0
	material_density_kg_m3 = 0.0
	bucket_volume_m3 = 0.0
	cell_grid = [1, 1, 1]
	transaction_sequence = 0
	last_transaction.clear()
	accepted_dump_event_id = ""
	dump_release_world = Vector3.ZERO
	dump_released_fill_ratio = 0.0


func credit_accepted_cut(removed_volume_m3: float, tick: int, patch_hash: String, fill_gain: float = 1.0) -> Dictionary:
	if not configured or removed_volume_m3 <= EPSILON_M3 or patch_hash.is_empty() or tick < 0:
		return {"changed": false, "reason": "cut_invalid"}
	var previous_volume := bucket_volume_m3
	var visual_credit := removed_volume_m3 * maxf(fill_gain, 0.0)
	bucket_volume_m3 = minf(capacity_m3, bucket_volume_m3 + visual_credit)
	transaction_sequence += 1
	last_transaction = {
		"sequence": transaction_sequence,
		"kind": "cut",
		"tick": tick,
		"patch_hash": patch_hash,
		"accepted_volume_m3": removed_volume_m3,
		"visual_credit_m3": bucket_volume_m3 - previous_volume,
	}
	return {
		"changed": bucket_volume_m3 > previous_volume + EPSILON_M3,
		"reason": "credited",
		"accepted_volume_m3": removed_volume_m3,
		"visual_credit_m3": bucket_volume_m3 - previous_volume,
	}


func dump_visual_load(release_world: Vector3, tick: int) -> Dictionary:
	if not configured or not release_world.is_finite() or tick < 0 or bucket_volume_m3 <= EPSILON_M3:
		return {"changed": false, "reason": "dump_empty"}
	var released_volume := bucket_volume_m3
	var released_ratio := clampf(released_volume / capacity_m3, 0.0, 1.0)
	bucket_volume_m3 = 0.0
	transaction_sequence += 1
	accepted_dump_event_id = "%d:%d:arcade-dump" % [generation, transaction_sequence]
	dump_release_world = release_world
	dump_released_fill_ratio = released_ratio
	last_transaction = {
		"sequence": transaction_sequence,
		"kind": "dump",
		"tick": tick,
		"event_id": accepted_dump_event_id,
		"accepted_volume_m3": released_volume,
		"release_world": release_world,
	}
	return {
		"changed": true,
		"reason": "dumped",
		"event_id": accepted_dump_event_id,
		"released_volume_m3": released_volume,
		"released_fill_ratio": released_ratio,
		"release_world": release_world,
	}


func get_status_snapshot() -> Dictionary:
	var fill_ratio := bucket_volume_m3 / capacity_m3 if configured and capacity_m3 > EPSILON_M3 else 0.0
	return {
		"schema_version": SCHEMA_VERSION,
		"configured": configured,
		"mode": "arcade_stamp_v3",
		"model_id": model_id,
		"generation": generation,
		"ledger_identity": "arcade:%d:%d" % [generation, transaction_sequence],
		"transaction_sequence": transaction_sequence,
		"bucket_capacity_m3": capacity_m3,
		"bucket_volume_m3": bucket_volume_m3,
		"payload_mass_kg": bucket_volume_m3 * material_density_kg_m3,
		"fill_ratio": fill_ratio,
		"center_of_mass_local": Vector3.ZERO,
		"fill_profile": PackedFloat32Array(),
		"cell_grid": cell_grid.duplicate(),
		"last_transaction": last_transaction.duplicate(true),
		"accepted_dump_event_id": accepted_dump_event_id,
		"dump_release_world": dump_release_world,
		"dump_released_fill_ratio": dump_released_fill_ratio,
	}

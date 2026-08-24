class_name ActiveSoilPersistentField
extends RefCounted

## Shadow-only persistent material field used by the bounded active-soil
## prototype. Every height mutation still crosses TerrainCommitScheduler; the
## scheduler owns an isolated TerrainState cloned from product truth.

const SCHEMA_VERSION := "active-soil-persistent-field-v1"
const MIN_VOLUME_M3 := 0.000001
const DEFAULT_BRUSH_RADIUS_M := 0.34
const MATERIAL_PRESETS := {
	"loose": {"id": 0, "compaction": 0.18},
	"compact": {"id": 1, "compaction": 0.78},
	"sand": {"id": 2, "compaction": 0.08},
	"damp": {"id": 3, "compaction": 0.42},
}

var terrain_state: TerrainState
var scheduler: TerrainCommitScheduler
var material_preset := "loose"
var source_epoch := ""
var source_revision := -1
var source_generation := -1

var _material_ids := PackedByteArray()
var _compaction := PackedFloat32Array()
var _transaction_sequence := 0
var _activated_volume_m3 := 0.0
var _settled_volume_m3 := 0.0
var _rejected_volume_m3 := 0.0


func configure(source_snapshot: Dictionary, preset: String = "loose") -> bool:
	clear()
	if not MATERIAL_PRESETS.has(preset):
		return false
	terrain_state = TerrainState.from_surface_snapshot(source_snapshot)
	if terrain_state == null:
		return false
	material_preset = preset
	source_epoch = String(source_snapshot.get("terrain_epoch", ""))
	source_revision = int(source_snapshot.get("terrain_revision", -1))
	source_generation = int(source_snapshot.get("world_generation", -1))
	scheduler = TerrainCommitScheduler.new(terrain_state)
	scheduler.commit_interval_s = 0.0
	scheduler.maximum_latency_s = 0.0
	scheduler.volume_threshold_m3 = 0.0
	var cell_count := terrain_state.rows * terrain_state.columns
	_material_ids.resize(cell_count)
	_compaction.resize(cell_count)
	var preset_data := MATERIAL_PRESETS[preset] as Dictionary
	_material_ids.fill(int(preset_data["id"]))
	_compaction.fill(float(preset_data["compaction"]))
	return true


func clear() -> void:
	terrain_state = null
	scheduler = null
	material_preset = "loose"
	source_epoch = ""
	source_revision = -1
	source_generation = -1
	_material_ids = PackedByteArray()
	_compaction = PackedFloat32Array()
	_transaction_sequence = 0
	_activated_volume_m3 = 0.0
	_settled_volume_m3 = 0.0
	_rejected_volume_m3 = 0.0


func activate_volume(center_xz: Vector2, requested_volume_m3: float, radius_m: float = DEFAULT_BRUSH_RADIUS_M, transfer_hint: String = "") -> Dictionary:
	return _commit_volume("activate", center_xz, requested_volume_m3, radius_m, transfer_hint)


func settle_volume(center_xz: Vector2, requested_volume_m3: float, radius_m: float = DEFAULT_BRUSH_RADIUS_M, transfer_hint: String = "") -> Dictionary:
	return _commit_volume("settle", center_xz, requested_volume_m3, radius_m, transfer_hint)


func sample_surface_at(world_xz: Vector2) -> float:
	return terrain_state.sample_surface_bilinear_at(world_xz) if terrain_state != null else NAN


func sample_material_id_at(world_xz: Vector2) -> int:
	var index := _cell_index(world_xz)
	return int(_material_ids[index]) if index >= 0 else -1


func sample_compaction_at(world_xz: Vector2) -> float:
	var index := _cell_index(world_xz)
	return float(_compaction[index]) if index >= 0 else NAN


func surface_snapshot() -> Dictionary:
	return terrain_state.surface_snapshot() if terrain_state != null else {}


func get_status_snapshot() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"configured": terrain_state != null and scheduler != null,
		"material_preset": material_preset,
		"source_epoch": source_epoch,
		"source_revision": source_revision,
		"source_generation": source_generation,
		"shadow_revision": terrain_state.terrain_revision if terrain_state != null else -1,
		"shadow_generation": terrain_state.world_generation if terrain_state != null else -1,
		"activated_volume_m3": _activated_volume_m3,
		"settled_volume_m3": _settled_volume_m3,
		"rejected_volume_m3": _rejected_volume_m3,
		"net_active_volume_m3": _activated_volume_m3 - _settled_volume_m3,
		"material_cell_count": _material_ids.size(),
		"estimated_memory_bytes": _material_ids.size() + _compaction.size() * 4,
	}


func _commit_volume(kind: String, center_xz: Vector2, requested_volume_m3: float, radius_m: float, transfer_hint: String) -> Dictionary:
	var rejected := {
		"accepted": false,
		"kind": kind,
		"requested_volume_m3": requested_volume_m3,
		"committed_volume_m3": 0.0,
		"reason": "invalid_request",
	}
	if terrain_state == null or scheduler == null:
		rejected["reason"] = "field_unavailable"
		return rejected
	if requested_volume_m3 <= MIN_VOLUME_M3 or radius_m <= 0.0 or not terrain_state.is_inside_grid(center_xz):
		_rejected_volume_m3 += maxf(requested_volume_m3, 0.0)
		return rejected
	var sign_value := -1.0 if kind == "activate" else 1.0
	var unit_volume := terrain_state.estimate_brush_volume(center_xz, radius_m, sign_value)
	if unit_volume <= MIN_VOLUME_M3:
		rejected["reason"] = "empty_support"
		_rejected_volume_m3 += requested_volume_m3
		return rejected
	var delta_m := sign_value * requested_volume_m3 / unit_volume
	var estimated_volume := terrain_state.estimate_brush_volume(center_xz, radius_m, delta_m)
	if estimated_volume <= MIN_VOLUME_M3:
		rejected["reason"] = "empty_transaction"
		_rejected_volume_m3 += requested_volume_m3
		return rejected
	# Negative brushes can hit their three-metre safety floor. One correction
	# keeps the committed amount conservative without exposing cell mutation.
	if kind == "activate" and estimated_volume < requested_volume_m3 * 0.999:
		delta_m *= requested_volume_m3 / estimated_volume
		estimated_volume = terrain_state.estimate_brush_volume(center_xz, radius_m, delta_m)
	var before_stable_volume := _layer_volume(terrain_state.stable_heights)
	var before_loose_volume := _layer_volume(terrain_state.loose_depth)
	var sequence := _transaction_sequence
	_transaction_sequence += 1
	var transfer_id := "active-patch:%d:%s:%s" % [sequence, kind, transfer_hint]
	if not scheduler.queue_brush(
		sequence,
		center_xz,
		radius_m,
		delta_m,
		terrain_state.world_generation,
		transfer_id,
	):
		rejected["reason"] = "scheduler_rejected"
		_rejected_volume_m3 += requested_volume_m3
		return rejected
	var commit := scheduler.step_fixed(0.0, true)
	if not bool(commit.get("changed", false)) or not (commit.get("committed_transfer_ids", []) as Array).has(transfer_id):
		rejected["reason"] = String(commit.get("reason", "commit_rejected"))
		_rejected_volume_m3 += requested_volume_m3
		return rejected
	if kind == "activate":
		_activated_volume_m3 += estimated_volume
	else:
		_settled_volume_m3 += estimated_volume
	var after_stable_volume := _layer_volume(terrain_state.stable_heights)
	var after_loose_volume := _layer_volume(terrain_state.loose_depth)
	var stable_volume := maxf(0.0, before_stable_volume - after_stable_volume) if kind == "activate" else 0.0
	var loose_volume := (
		maxf(0.0, before_loose_volume - after_loose_volume)
		if kind == "activate"
		else maxf(0.0, after_loose_volume - before_loose_volume)
	)
	_update_compaction(center_xz, radius_m, kind == "settle")
	return {
		"accepted": true,
		"kind": kind,
		"requested_volume_m3": requested_volume_m3,
		"committed_volume_m3": estimated_volume,
		"stable_volume_m3": stable_volume,
		"loose_volume_m3": loose_volume,
		"transfer_id": transfer_id,
		"reason": "committed",
	}


func _layer_volume(layer: PackedFloat32Array) -> float:
	if terrain_state == null:
		return 0.0
	var total := 0.0
	var cell_area := terrain_state.spacing_m * terrain_state.spacing_m
	for value in layer:
		total += float(value) * cell_area
	return total


func _update_compaction(center_xz: Vector2, radius_m: float, settling: bool) -> void:
	if terrain_state == null:
		return
	var preset_target := float((MATERIAL_PRESETS[material_preset] as Dictionary)["compaction"])
	var min_column := clampi(floori((center_xz.x - radius_m - terrain_state.origin_xz.x) / terrain_state.spacing_m), 0, terrain_state.columns - 1)
	var max_column := clampi(ceili((center_xz.x + radius_m - terrain_state.origin_xz.x) / terrain_state.spacing_m), 0, terrain_state.columns - 1)
	var min_row := clampi(floori((center_xz.y - radius_m - terrain_state.origin_xz.y) / terrain_state.spacing_m), 0, terrain_state.rows - 1)
	var max_row := clampi(ceili((center_xz.y + radius_m - terrain_state.origin_xz.y) / terrain_state.spacing_m), 0, terrain_state.rows - 1)
	for row in range(min_row, max_row + 1):
		for column in range(min_column, max_column + 1):
			var cell_world := terrain_state.origin_xz + Vector2(float(column), float(row)) * terrain_state.spacing_m
			var distance := cell_world.distance_to(center_xz)
			if distance > radius_m:
				continue
			var index := row * terrain_state.columns + column
			var influence := 1.0 - distance / radius_m
			var target := clampf(preset_target + (0.08 if settling else -0.08), 0.0, 1.0)
			_compaction[index] = lerpf(_compaction[index], target, influence * 0.3)


func _cell_index(world_xz: Vector2) -> int:
	if terrain_state == null or not terrain_state.is_inside_grid(world_xz):
		return -1
	var column := clampi(roundi((world_xz.x - terrain_state.origin_xz.x) / terrain_state.spacing_m), 0, terrain_state.columns - 1)
	var row := clampi(roundi((world_xz.y - terrain_state.origin_xz.y) / terrain_state.spacing_m), 0, terrain_state.rows - 1)
	return row * terrain_state.columns + column

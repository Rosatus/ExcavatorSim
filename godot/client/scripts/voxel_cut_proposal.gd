class_name VoxelCutProposal
extends RefCounted

const SCHEMA_VERSION := "voxel-cut-proposal-v1"

var generation := -1
var fixed_tick_begin := -1
var fixed_tick_end := -1
var sequence := -1
var model_id := ""
var authority_epoch := ""
var tool_hash := ""
var input_hash := ""
var area_voxels := AABB()
var capsules: Array[Dictionary] = []
var clearance_capsules: Array[Dictionary] = []
var probe_world := Vector3.ZERO
var quality_flags: Array[String] = []


static func create(fields: Dictionary) -> VoxelCutProposal:
	var proposal := VoxelCutProposal.new()
	proposal.generation = int(fields.get("generation", -1))
	proposal.fixed_tick_begin = int(fields.get("fixed_tick_begin", -1))
	proposal.fixed_tick_end = int(fields.get("fixed_tick_end", -1))
	proposal.sequence = int(fields.get("sequence", -1))
	proposal.model_id = String(fields.get("model_id", ""))
	proposal.authority_epoch = String(fields.get("authority_epoch", ""))
	proposal.tool_hash = String(fields.get("tool_hash", ""))
	proposal.area_voxels = fields.get("area_voxels", AABB()) as AABB
	proposal.probe_world = fields.get("probe_world", Vector3.ZERO) as Vector3
	for value in fields.get("capsules", []):
		if value is Dictionary:
			proposal.capsules.append((value as Dictionary).duplicate(true))
	for value in fields.get("clearance_capsules", []):
		if value is Dictionary:
			proposal.clearance_capsules.append((value as Dictionary).duplicate(true))
	for value in fields.get("quality_flags", []):
		proposal.quality_flags.append(String(value))
	proposal.input_hash = proposal._compute_hash()
	return proposal


func is_valid() -> bool:
	if generation < 0 or fixed_tick_begin < 0 or fixed_tick_end < fixed_tick_begin or sequence < 0:
		return false
	if model_id.is_empty() or authority_epoch.is_empty() or tool_hash.is_empty() or input_hash.is_empty():
		return false
	if not probe_world.is_finite() or area_voxels.size.x <= 0.0 or area_voxels.size.y <= 0.0 or area_voxels.size.z <= 0.0:
		return false
	if capsules.is_empty():
		return false
	for capsule in capsules + clearance_capsules:
		if not _capsule_valid(capsule):
			return false
	return input_hash == _compute_hash()


func duplicate_typed() -> VoxelCutProposal:
	return create(to_dictionary())


func to_dictionary() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"generation": generation,
		"fixed_tick_begin": fixed_tick_begin,
		"fixed_tick_end": fixed_tick_end,
		"sequence": sequence,
		"model_id": model_id,
		"authority_epoch": authority_epoch,
		"tool_hash": tool_hash,
		"input_hash": input_hash,
		"area_voxels": area_voxels,
		"capsules": capsules.duplicate(true),
		"clearance_capsules": clearance_capsules.duplicate(true),
		"probe_world": probe_world,
		"quality_flags": quality_flags.duplicate(),
	}


func _compute_hash() -> String:
	var rows: Array[String] = []
	for capsule in capsules + clearance_capsules:
		var a := capsule.get("a_voxels", Vector3.ZERO) as Vector3
		var b := capsule.get("b_voxels", Vector3.ZERO) as Vector3
		rows.append("%s|%.6f,%.6f,%.6f|%.6f,%.6f,%.6f|%.6f" % [
			String(capsule.get("source", "")),
			a.x, a.y, a.z, b.x, b.y, b.z,
			float(capsule.get("radius_voxels", 0.0)),
		])
	var canonical := "%d|%d|%d|%d|%s|%s|%s|%s" % [
		generation, fixed_tick_begin, fixed_tick_end, sequence,
		model_id, authority_epoch, tool_hash, ";".join(rows),
	]
	return canonical.sha256_text()


static func _capsule_valid(capsule: Dictionary) -> bool:
	var a := capsule.get("a_voxels", Vector3(INF, INF, INF)) as Vector3
	var b := capsule.get("b_voxels", Vector3(INF, INF, INF)) as Vector3
	var radius := float(capsule.get("radius_voxels", 0.0))
	return a.is_finite() and b.is_finite() and is_finite(radius) and radius > 0.0

class_name VoxelSoilOperationProposal
extends RefCounted

const SCHEMA_VERSION := "voxel-soil-operation-proposal-v1"
const OPERATIONS := ["deposit", "settle", "compact"]

var generation := -1
var fixed_tick_begin := -1
var fixed_tick_end := -1
var sequence := -1
var model_id := ""
var authority_epoch := ""
var tool_hash := ""
var input_hash := ""
var operation := ""
var area_voxels := AABB()
var shapes: Array[Dictionary] = []
var requested_mass_q := 0
var compaction_delta_q := 0
var release_world := Vector3.ZERO
var deposit_world := Vector3.ZERO
var release_fill_ratio := 0.0
var support_query_usec := 0
var batch_wait_usec := 0
var quality_flags: Array[String] = []


static func create(fields: Dictionary) -> VoxelSoilOperationProposal:
	var proposal := VoxelSoilOperationProposal.new()
	proposal.generation = int(fields.get("generation", -1))
	proposal.fixed_tick_begin = int(fields.get("fixed_tick_begin", -1))
	proposal.fixed_tick_end = int(fields.get("fixed_tick_end", -1))
	proposal.sequence = int(fields.get("sequence", -1))
	proposal.model_id = String(fields.get("model_id", ""))
	proposal.authority_epoch = String(fields.get("authority_epoch", ""))
	proposal.tool_hash = String(fields.get("tool_hash", ""))
	proposal.operation = String(fields.get("operation", ""))
	proposal.area_voxels = fields.get("area_voxels", AABB()) as AABB
	proposal.requested_mass_q = int(fields.get("requested_mass_q", 0))
	proposal.compaction_delta_q = int(fields.get("compaction_delta_q", 0))
	proposal.release_world = fields.get("release_world", Vector3.ZERO) as Vector3
	proposal.deposit_world = fields.get("deposit_world", proposal.release_world) as Vector3
	proposal.release_fill_ratio = float(fields.get("release_fill_ratio", 0.0))
	proposal.support_query_usec = maxi(0, int(fields.get("support_query_usec", 0)))
	proposal.batch_wait_usec = maxi(0, int(fields.get("batch_wait_usec", 0)))
	for value in fields.get("shapes", []):
		if value is Dictionary:
			proposal.shapes.append((value as Dictionary).duplicate(true))
	for value in fields.get("quality_flags", []):
		proposal.quality_flags.append(String(value))
	proposal.input_hash = proposal._compute_hash()
	return proposal


func is_valid() -> bool:
	if operation not in OPERATIONS or generation < 0 or fixed_tick_begin < 0 \
			or fixed_tick_end < fixed_tick_begin or sequence < 0:
		return false
	if model_id.is_empty() or authority_epoch.is_empty() or tool_hash.is_empty() or input_hash.is_empty():
		return false
	if not release_world.is_finite() or not deposit_world.is_finite() \
			or area_voxels.size.x <= 0.0 or area_voxels.size.y <= 0.0 or area_voxels.size.z <= 0.0:
		return false
	if shapes.is_empty() or requested_mass_q <= 0:
		return false
	if operation == "compact" and compaction_delta_q <= 0:
		return false
	for shape in shapes:
		if not _shape_valid(shape):
			return false
	return input_hash == _compute_hash()


func duplicate_typed() -> VoxelSoilOperationProposal:
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
		"operation": operation,
		"area_voxels": area_voxels,
		"shapes": shapes.duplicate(true),
		"requested_mass_q": requested_mass_q,
		"compaction_delta_q": compaction_delta_q,
		"release_world": release_world,
		"deposit_world": deposit_world,
		"release_fill_ratio": release_fill_ratio,
		"support_query_usec": support_query_usec,
		"batch_wait_usec": batch_wait_usec,
		"quality_flags": quality_flags.duplicate(),
	}


func _compute_hash() -> String:
	var rows: Array[String] = []
	for shape in shapes:
		var a := shape.get("a_voxels", Vector3.ZERO) as Vector3
		var b := shape.get("b_voxels", a) as Vector3
		rows.append("%s|%.6f,%.6f,%.6f|%.6f,%.6f,%.6f|%.6f" % [
			String(shape.get("mode", "")),
			a.x, a.y, a.z, b.x, b.y, b.z,
			float(shape.get("radius_voxels", 0.0)),
		])
	var canonical := "%d|%d|%d|%d|%s|%s|%s|%s|%d|%d|%.6f,%.6f,%.6f|%.6f,%.6f,%.6f|%.6f|%d|%d|%s|%s" % [
		generation, fixed_tick_begin, fixed_tick_end, sequence,
		model_id, authority_epoch, tool_hash, operation,
		requested_mass_q, compaction_delta_q,
		release_world.x, release_world.y, release_world.z,
		deposit_world.x, deposit_world.y, deposit_world.z,
		release_fill_ratio,
		support_query_usec,
		batch_wait_usec,
		";".join(quality_flags),
		";".join(rows),
	]
	return canonical.sha256_text()


static func _shape_valid(shape: Dictionary) -> bool:
	var mode := String(shape.get("mode", ""))
	var a := shape.get("a_voxels", Vector3(INF, INF, INF)) as Vector3
	var b := shape.get("b_voxels", a) as Vector3
	var radius := float(shape.get("radius_voxels", 0.0))
	return mode in ["add", "remove"] and a.is_finite() and b.is_finite() \
		and is_finite(radius) and radius > 0.0

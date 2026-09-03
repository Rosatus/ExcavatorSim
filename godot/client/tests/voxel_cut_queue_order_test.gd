extends SceneTree

const Authority = preload("res://scripts/voxel_excavation_authority.gd")
const Proposal = preload("res://scripts/voxel_cut_proposal.gd")


func _init() -> void:
	var authority := Authority.new()
	authority.generation = 3
	authority.model_id = "sy205"
	authority.tool_hash = "tool"
	var a := _proposal(10, 10, AABB(Vector3.ZERO, Vector3.ONE * 2.0))
	var b := _proposal(11, 11, AABB(Vector3(10.0, 0.0, 0.0), Vector3.ONE * 2.0))
	var c := _proposal(12, 12, AABB(Vector3(1.0, 0.0, 0.0), Vector3.ONE * 2.0))
	if not authority._coalesce_or_enqueue(a) or not authority._coalesce_or_enqueue(b) or not authority._coalesce_or_enqueue(c):
		_fail("valid proposals did not enqueue")
		return
	if authority._queue.size() != 3:
		_fail("non-adjacent overlap was illegally coalesced")
		return
	var sequences: Array[int] = []
	for queued in authority._queue:
		sequences.append((queued as VoxelCutProposal).sequence)
	if sequences != [10, 11, 12]:
		_fail("fixed transaction order changed: %s" % sequences)
		return
	print("Voxel cut queue ordering passed.")
	quit(0)


func _proposal(tick: int, sequence: int, area: AABB) -> VoxelCutProposal:
	return Proposal.create({
		"generation": 3,
		"fixed_tick_begin": tick,
		"fixed_tick_end": tick,
		"sequence": sequence,
		"model_id": "sy205",
		"authority_epoch": "queue-order",
		"tool_hash": "tool",
		"area_voxels": area,
		"capsules": [{"kind": "capsule", "a_voxels": area.position, "b_voxels": area.end, "radius_voxels": 1.0, "source": "test"}],
		"clearance_capsules": [],
		"probe_world": Vector3.ZERO,
	})


func _fail(message: String) -> void:
	push_error(message)
	quit(1)

class_name VoxelExcavationAuthority
extends RefCounted

const CutProposal = preload("res://scripts/voxel_cut_proposal.gd")
const CutTransaction = preload("res://scripts/voxel_cut_transaction.gd")
const BucketCutter = preload("res://scripts/voxel_bucket_cutter.gd")
const MaterialField = preload("res://scripts/voxel_soil_material_field.gd")
const WorkZoneConfig = preload("res://scripts/voxel_work_zone_config.gd")

const SCHEMA_VERSION := "voxel-excavation-authority-v1"
const COMMIT_PERIOD_S := 0.05
const MAX_QUEUE_DEPTH := 12
const MAX_JOURNAL_ROWS := 256
const MAX_STAGED_SAMPLES := 262144
const MAX_PROPOSAL_CAPSULES := 4096
const SDF_HALO_VOXELS := 2
const CAPACITY_SEARCH_STEPS := 14
const SDF_CHANNEL_MASK := 1 << VoxelBuffer.CHANNEL_SDF
const VOLUME_EPSILON_M3 := 0.000001

var configured := false
var generation := -1
var data_revision := 0
var mesh_revision := 0
var collision_revision := 0
var model_id := ""
var tool_hash := ""
var last_error := ""
var cutter := BucketCutter.new()
var material_field := MaterialField.new()

var _work_zone: VoxelWorkZone
var _tool: VoxelTool
var _contract: Dictionary = {}
var _queue: Array[VoxelCutProposal] = []
var _journal: Array[Dictionary] = []
var _seen_inputs: Dictionary = {}
var _seen_order: Array[String] = []
var _readiness_work: Array[Dictionary] = []
var _commit_accumulator_s := 0.0
var _engaged := false
var _last_submitted_tick := -1
var _last_submitted_motion_sequence := -1
var _next_sequence := 0
var _last_transaction: Dictionary = {}
var _last_cutter_result: Dictionary = {}
var _submitted_count := 0
var _accepted_proposal_count := 0
var _committed_count := 0
var _rejected_count := 0
var _coalesced_count := 0
var _capacity_clipped_count := 0
var _duplicate_count := 0
var _stale_count := 0
var _peak_queue_depth := 0
var _affected_samples_total := 0
var _affected_cells_total := 0
var _commit_usec_total := 0
var _commit_usec_max := 0
var _rejection_reasons: Dictionary = {}


func configure(work_zone: VoxelWorkZone, contract: Dictionary, target_generation: int, capacity_override_m3: float = 0.0) -> bool:
	clear()
	if work_zone == null or work_zone.terrain == null:
		return _fail("voxel_work_zone_unavailable")
	var candidate_model := String(contract.get("model_id", ""))
	var descriptor := SoilContractDescriptor.from_dictionary_for_test(contract)
	if candidate_model.is_empty() or not descriptor.is_valid_for(candidate_model):
		return _fail("invalid_soil_contract:%s" % descriptor.validation_error())
	if target_generation < 0:
		return _fail("invalid_generation")
	var voxel_tool := work_zone.get_voxel_tool()
	if voxel_tool == null:
		return _fail("voxel_tool_unavailable")
	voxel_tool.channel = VoxelBuffer.CHANNEL_SDF
	if not cutter.configure(contract, work_zone.voxel_scale_m):
		return _fail("cutter_configuration_failed:%s" % cutter.validation_error)
	if not material_field.configure(contract, target_generation, capacity_override_m3):
		return _fail("material_field_configuration_failed")
	_work_zone = work_zone
	_tool = voxel_tool
	_contract = contract.duplicate(true)
	model_id = candidate_model
	tool_hash = cutter.tool_hash
	generation = target_generation
	configured = true
	return true


func clear() -> void:
	configured = false
	generation = -1
	data_revision = 0
	mesh_revision = 0
	collision_revision = 0
	model_id = ""
	tool_hash = ""
	last_error = ""
	_work_zone = null
	_tool = null
	_contract.clear()
	_queue.clear()
	_journal.clear()
	_seen_inputs.clear()
	_seen_order.clear()
	_readiness_work.clear()
	_commit_accumulator_s = 0.0
	_engaged = false
	_last_submitted_tick = -1
	_last_submitted_motion_sequence = -1
	_next_sequence = 0
	_last_transaction.clear()
	_last_cutter_result.clear()
	_submitted_count = 0
	_accepted_proposal_count = 0
	_committed_count = 0
	_rejected_count = 0
	_coalesced_count = 0
	_capacity_clipped_count = 0
	_duplicate_count = 0
	_stale_count = 0
	_peak_queue_depth = 0
	_affected_samples_total = 0
	_affected_cells_total = 0
	_commit_usec_total = 0
	_commit_usec_max = 0
	_rejection_reasons.clear()


func submit_pose(pose_snapshot: Dictionary, identity: Dictionary) -> Dictionary:
	_submitted_count += 1
	if not configured:
		return _reject_submission("authority_unavailable")
	var identity_generation := int(identity.get("generation", -1))
	var tick := int(identity.get("physics_tick", -1))
	var motion_sequence := int(identity.get("motion_sequence", -1))
	var epoch := String(identity.get("authority_epoch", ""))
	if identity_generation != generation or tick < 0 or motion_sequence < 0 or epoch.is_empty():
		_stale_count += 1
		return _reject_submission("stale_identity")
	if tick <= _last_submitted_tick or motion_sequence <= _last_submitted_motion_sequence:
		_stale_count += 1
		return _reject_submission("stale_tick" if tick <= _last_submitted_tick else "stale_motion_sequence")
	_last_submitted_tick = tick
	_last_submitted_motion_sequence = motion_sequence
	var result := cutter.build_proposal(
		pose_snapshot,
		generation,
		tick,
		motion_sequence,
		epoch,
		_engaged,
		_sample_sdf_world,
	)
	_last_cutter_result = _sanitized_cutter_result(result)
	_engaged = bool(result.get("engaged", false))
	if not bool(result.get("accepted", false)):
		return _reject_submission(String(result.get("reason", "cutter_rejected")))
	var proposal := result.get("proposal") as VoxelCutProposal
	if proposal == null or not proposal.is_valid() or proposal.tool_hash != tool_hash:
		return _reject_submission("invalid_proposal")
	if _seen_inputs.has(proposal.input_hash):
		_duplicate_count += 1
		return _reject_submission("duplicate_proposal")
	_remember_input(proposal.input_hash)
	if not _coalesce_or_enqueue(proposal):
		return _reject_submission("queue_full")
	_accepted_proposal_count += 1
	return {
		"accepted": true,
		"reason": "queued",
		"input_hash": proposal.input_hash,
		"queue_depth": _queue.size(),
	}


func step_fixed(delta: float) -> Dictionary:
	_poll_readiness()
	if not configured or not is_finite(delta) or delta < 0.0:
		return {"changed": false, "reason": "authority_unavailable"}
	_commit_accumulator_s += delta
	if _queue.is_empty():
		return {"changed": false, "reason": "idle"}
	if _commit_accumulator_s + 0.000001 < COMMIT_PERIOD_S:
		return {"changed": false, "reason": "coalescing", "queue_depth": _queue.size()}
	_commit_accumulator_s = fmod(_commit_accumulator_s, COMMIT_PERIOD_S)
	var proposal := _queue.pop_front() as VoxelCutProposal
	var transaction := _commit_proposal(proposal)
	_last_transaction = transaction.to_dictionary()
	_append_journal(_last_transaction)
	if not transaction.accepted():
		_record_rejection(transaction.rejection_reason)
		return {"changed": false, "reason": transaction.rejection_reason, "transaction": _last_transaction.duplicate(true)}
	return {"changed": true, "reason": "committed", "transaction": _last_transaction.duplicate(true)}


func flush_for_test() -> Dictionary:
	return step_fixed(COMMIT_PERIOD_S)


func get_payload_snapshot() -> Dictionary:
	var grid := _contract.get("cell_grid", [1, 1, 1]) as Array
	var center := _bucket_center_local()
	var status := material_field.get_status_snapshot(grid, center)
	status["source"] = "voxel_bucket_v1"
	status["ledger_identity"] = "voxel:%d:%d" % [generation, data_revision]
	status["world_generation"] = generation
	return status


func get_status_snapshot() -> Dictionary:
	var payload := get_payload_snapshot() if configured else {}
	var oldest_age_ticks := 0
	if not _queue.is_empty():
		oldest_age_ticks = maxi(0, _last_submitted_tick - _queue[0].fixed_tick_begin)
	var status := {
		"schema_version": SCHEMA_VERSION,
		"configured": configured,
		"generation": generation,
		"data_revision": data_revision,
		"mesh_revision": mesh_revision,
		"collision_revision": collision_revision,
		"model_id": model_id,
		"tool_hash": tool_hash,
		"queue_depth": _queue.size(),
		"queue_capacity": MAX_QUEUE_DEPTH,
		"peak_queue_depth": _peak_queue_depth,
		"oldest_age_ticks": oldest_age_ticks,
		"pending_readiness_count": _readiness_work.size(),
		"submitted": _submitted_count,
		"accepted_proposals": _accepted_proposal_count,
		"committed": _committed_count,
		"rejected": _rejected_count,
		"coalesced": _coalesced_count,
		"capacity_clipped": _capacity_clipped_count,
		"duplicates": _duplicate_count,
		"stale": _stale_count,
		"affected_samples": _affected_samples_total,
		"affected_cells": _affected_cells_total,
		"commit_usec_total": _commit_usec_total,
		"commit_usec_max": _commit_usec_max,
		"commit_usec_average": float(_commit_usec_total) / float(_committed_count) if _committed_count > 0 else 0.0,
		"engaged": _engaged,
		"last_error": last_error,
		"last_cutter_result": _last_cutter_result.duplicate(true),
		"last_transaction": _last_transaction.duplicate(true),
		"rejection_reasons": _rejection_reasons.duplicate(true),
		"journal_size": _journal.size(),
		"payload": payload,
		"voxel_statistics": _work_zone.terrain.get_statistics() if _work_zone != null and _work_zone.terrain != null else {},
	}
	# Keep diagnostics and selected-world/UI payload reads on one typed status
	# surface without allowing payload fields to overwrite authority counters.
	status.merge(payload, false)
	return status


func get_journal_snapshot() -> Array[Dictionary]:
	return _journal.duplicate(true)


func _coalesce_or_enqueue(proposal: VoxelCutProposal) -> bool:
	if not _queue.is_empty():
		var index := _queue.size() - 1
		var pending := _queue[index]
		if pending.generation != proposal.generation or pending.model_id != proposal.model_id \
				or pending.authority_epoch != proposal.authority_epoch:
			pass
		elif pending.area_voxels.intersects(proposal.area_voxels) \
				and pending.fixed_tick_end < proposal.fixed_tick_begin \
				and pending.sequence < proposal.sequence \
				and pending.capsules.size() + pending.clearance_capsules.size() \
					+ proposal.capsules.size() + proposal.clearance_capsules.size() <= MAX_PROPOSAL_CAPSULES:
			_queue[index] = CutProposal.create({
			"generation": generation,
			"fixed_tick_begin": mini(pending.fixed_tick_begin, proposal.fixed_tick_begin),
			"fixed_tick_end": maxi(pending.fixed_tick_end, proposal.fixed_tick_end),
			"sequence": maxi(pending.sequence, proposal.sequence),
			"model_id": model_id,
			"authority_epoch": proposal.authority_epoch,
			"tool_hash": tool_hash,
			"area_voxels": pending.area_voxels.merge(proposal.area_voxels),
			"capsules": pending.capsules + proposal.capsules,
			"clearance_capsules": pending.clearance_capsules + proposal.clearance_capsules,
			"probe_world": proposal.probe_world,
			"quality_flags": ["coalesced", "continuous_half_voxel_subdivision", "constrained_clearance"],
			})
			_coalesced_count += 1
			return true
	if _queue.size() >= MAX_QUEUE_DEPTH:
		return false
	_queue.append(proposal.duplicate_typed())
	_peak_queue_depth = maxi(_peak_queue_depth, _queue.size())
	return true


func _commit_proposal(proposal: VoxelCutProposal) -> VoxelCutTransaction:
	var started := Time.get_ticks_usec()
	var transaction := CutTransaction.new()
	transaction.generation = proposal.generation
	transaction.sequence = proposal.sequence
	transaction.fixed_tick_begin = proposal.fixed_tick_begin
	transaction.fixed_tick_end = proposal.fixed_tick_end
	transaction.model_id = proposal.model_id
	transaction.area_voxels = proposal.area_voxels
	transaction.input_hash = proposal.input_hash
	if proposal.generation != generation or proposal.model_id != model_id or proposal.tool_hash != tool_hash:
		return _reject_transaction(transaction, "stale_or_wrong_tool", started)
	if material_field.remaining_capacity_mass_q() <= 0:
		return _reject_transaction(transaction, "bucket_full", started)
	var window := _integer_window(proposal.area_voxels)
	var origin := window["origin"] as Vector3i
	var size := window["size"] as Vector3i
	var sample_count := size.x * size.y * size.z
	if sample_count <= 0 or sample_count > MAX_STAGED_SAMPLES:
		return _reject_transaction(transaction, "staged_window_budget", started)
	var edit_area := AABB(Vector3(origin), Vector3(size))
	if not _tool.is_area_editable(edit_area):
		return _reject_transaction(transaction, "voxel_area_not_editable", started)
	var buffer := VoxelBuffer.new()
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	buffer.create(size.x, size.y, size.z)
	_tool.copy(origin, buffer, SDF_CHANNEL_MASK, false)
	var original := _buffer_values(buffer, size)
	transaction.pre_sdf_digest = _digest_values(original)
	var full_values := original.duplicate()
	var shapes := proposal.capsules + proposal.clearance_capsules
	if shapes.size() > MAX_PROPOSAL_CAPSULES:
		return _reject_transaction(transaction, "capsule_work_budget", started)
	var changed_samples := _apply_shapes(full_values, size, origin, shapes)
	if changed_samples <= 0:
		return _reject_transaction(transaction, "no_sdf_change", started)
	var full_cells := _cell_changes(original, full_values, size, origin)
	var requested_volume := _sum_removed_volume(full_cells)
	transaction.requested_volume_m3 = requested_volume
	transaction.requested_mass_q = material_field.mass_q_for_volume(requested_volume)
	if requested_volume <= VOLUME_EPSILON_M3 or transaction.requested_mass_q <= 0:
		return _reject_transaction(transaction, "sub_quantum_change", started)
	var final_values := full_values
	var final_cells := full_cells
	var remaining_mass_q := material_field.remaining_capacity_mass_q()
	if transaction.requested_mass_q > remaining_mass_q:
		transaction.capacity_clipped = true
		_capacity_clipped_count += 1
		var low := 0.0
		var high := 1.0
		for _iteration in CAPACITY_SEARCH_STEPS:
			var alpha := (low + high) * 0.5
			var candidate := _blend_values(original, full_values, alpha)
			var candidate_cells := _cell_changes(original, candidate, size, origin)
			if material_field.mass_q_for_volume(_sum_removed_volume(candidate_cells)) <= remaining_mass_q:
				low = alpha
			else:
				high = alpha
		if high <= 0.0:
			return _reject_transaction(transaction, "bucket_full", started)
		# Use the first representable slice at or above remaining capacity, then
		# credit exactly the bounded capacity. The geometric excess is bounded by
		# the binary-search resolution and the one-cell tolerance below.
		final_values = _blend_values(original, full_values, high)
		final_cells = _cell_changes(original, final_values, size, origin)
	var represented_mass_q := material_field.mass_q_for_volume(_sum_removed_volume(final_cells))
	var accepted_target_q := remaining_mass_q if transaction.capacity_clipped else represented_mass_q
	transaction.represented_mass_q = represented_mass_q
	transaction.mass_discretization_error_q = represented_mass_q - accepted_target_q
	transaction.mass_discretization_tolerance_q = material_field.mass_q_for_volume(pow(_work_zone.voxel_scale_m, 3.0))
	if absi(transaction.mass_discretization_error_q) > transaction.mass_discretization_tolerance_q:
		return _reject_transaction(transaction, "mass_discretization_tolerance", started)
	_assign_cell_mass(final_cells, accepted_target_q)
	var material_stage := material_field.stage_cut(final_cells, accepted_target_q)
	if not bool(material_stage.get("valid", false)):
		return _reject_transaction(transaction, String(material_stage.get("reason", "material_stage_failed")), started)
	transaction.accepted_mass_q = int(material_stage.get("accepted_mass_q", 0))
	if transaction.accepted_mass_q != accepted_target_q:
		return _reject_transaction(transaction, "material_geometry_mass_mismatch", started)
	if not material_field.can_commit_cut(material_stage):
		return _reject_transaction(transaction, "material_commit_invariant", started)
	transaction.accepted_volume_m3 = material_field.volume_for_mass_q(transaction.accepted_mass_q)
	transaction.affected_cells = final_cells.size()
	transaction.affected_samples = _changed_sample_count(original, final_values)
	_write_values(buffer, size, final_values)
	transaction.post_sdf_digest = _digest_values(final_values)
	if transaction.post_sdf_digest == transaction.pre_sdf_digest:
		return _reject_transaction(transaction, "unchanged_sdf_digest", started)
	var pre_hit_y := _ray_surface_y(proposal.probe_world)
	_tool.paste(origin, buffer, SDF_CHANNEL_MASK)
	# can_commit_cut() was validated immediately before paste with no intervening
	# material mutation; the following commit therefore has no reject branch.
	material_field.commit_cut(material_stage)
	data_revision += 1
	transaction.revision = data_revision
	transaction.commit_usec = Time.get_ticks_usec() - started
	_committed_count += 1
	_affected_samples_total += transaction.affected_samples
	_affected_cells_total += transaction.affected_cells
	_commit_usec_total += transaction.commit_usec
	_commit_usec_max = maxi(_commit_usec_max, transaction.commit_usec)
	var ticket := _work_zone.issue_edit_ticket(edit_area, &"voxel_bucket_cut")
	_readiness_work.append({
		"revision": data_revision,
		"ticket": ticket,
		"probe_world": proposal.probe_world,
		"pre_hit_y": pre_hit_y,
		"meshed_frame": -1,
	})
	return transaction


func _integer_window(area: AABB) -> Dictionary:
	var bounds := WorkZoneConfig.voxel_bounds(_work_zone.voxel_scale_m)
	var minimum := Vector3i(floor(area.position.x), floor(area.position.y), floor(area.position.z)) - Vector3i.ONE * SDF_HALO_VOXELS
	var maximum := Vector3i(ceil(area.end.x), ceil(area.end.y), ceil(area.end.z)) + Vector3i.ONE * SDF_HALO_VOXELS
	var bounds_min := Vector3i(ceil(bounds.position.x), ceil(bounds.position.y), ceil(bounds.position.z))
	var bounds_max := Vector3i(floor(bounds.end.x), floor(bounds.end.y), floor(bounds.end.z))
	minimum = minimum.max(bounds_min)
	maximum = maximum.min(bounds_max)
	return {"origin": minimum, "size": maximum - minimum}


func _buffer_values(buffer: VoxelBuffer, size: Vector3i) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	values.resize(size.x * size.y * size.z)
	for z in size.z:
		for y in size.y:
			for x in size.x:
				values[_index(x, y, z, size)] = buffer.get_voxel_f(x, y, z, VoxelBuffer.CHANNEL_SDF)
	return values


func _write_values(buffer: VoxelBuffer, size: Vector3i, values: PackedFloat32Array) -> void:
	for z in size.z:
		for y in size.y:
			for x in size.x:
				buffer.set_voxel_f(values[_index(x, y, z, size)], x, y, z, VoxelBuffer.CHANNEL_SDF)


func _apply_shapes(values: PackedFloat32Array, size: Vector3i, origin: Vector3i, shapes: Array[Dictionary]) -> int:
	var changed := 0
	var changed_flags := PackedByteArray()
	changed_flags.resize(values.size())
	for shape in shapes:
		var radius := float(shape.get("radius_voxels", 0.0))
		var influence := radius + 1.0
		var a := shape.get("a_voxels", Vector3.ZERO) as Vector3
		var b := shape.get("b_voxels", Vector3.ZERO) as Vector3
		var local_min := Vector3i(floor(a.min(b).x - influence), floor(a.min(b).y - influence), floor(a.min(b).z - influence)) - origin
		var local_max := Vector3i(ceil(a.max(b).x + influence), ceil(a.max(b).y + influence), ceil(a.max(b).z + influence)) - origin
		local_min = local_min.max(Vector3i.ZERO)
		local_max = local_max.min(size - Vector3i.ONE)
		for z in range(local_min.z, local_max.z + 1):
			for y in range(local_min.y, local_max.y + 1):
				for x in range(local_min.x, local_max.x + 1):
					var position := Vector3(origin + Vector3i(x, y, z))
					var distance := _distance_to_segment(position, a, b)
					if distance > influence:
						continue
					var index := _index(x, y, z, size)
					var removal_sdf := radius - distance
					if removal_sdf <= values[index] + 0.000001:
						continue
					values[index] = clampf(removal_sdf, -1.0, 1.0)
					if changed_flags[index] == 0:
						changed_flags[index] = 1
						changed += 1
	return changed


func _cell_changes(before: PackedFloat32Array, after: PackedFloat32Array, size: Vector3i, origin: Vector3i) -> Array[Dictionary]:
	var changes: Array[Dictionary] = []
	var cell_volume := pow(_work_zone.voxel_scale_m, 3.0)
	for z in range(size.z - 1):
		for y in range(size.y - 1):
			for x in range(size.x - 1):
				var pre := _cell_solid_fraction(before, size, x, y, z)
				var post := _cell_solid_fraction(after, size, x, y, z)
				if pre - post <= 0.000001:
					continue
				changes.append({
					"coordinate": origin + Vector3i(x, y, z),
					"pre_fraction": pre,
					"post_fraction": post,
					"cell_volume_m3": cell_volume,
					"removed_volume_m3": (pre - post) * cell_volume,
					"removed_mass_q": 0,
				})
	return changes


func _cell_solid_fraction(values: PackedFloat32Array, size: Vector3i, x: int, y: int, z: int) -> float:
	var c0 := values[_index(x, y, z, size)]
	var c1 := values[_index(x + 1, y, z, size)]
	var c2 := values[_index(x, y + 1, z, size)]
	var c3 := values[_index(x + 1, y + 1, z, size)]
	var c4 := values[_index(x, y, z + 1, size)]
	var c5 := values[_index(x + 1, y, z + 1, size)]
	var c6 := values[_index(x, y + 1, z + 1, size)]
	var c7 := values[_index(x + 1, y + 1, z + 1, size)]
	var total := (
		_tetra_solid_fraction(c0, c1, c3, c7)
		+ _tetra_solid_fraction(c0, c3, c2, c7)
		+ _tetra_solid_fraction(c0, c2, c6, c7)
		+ _tetra_solid_fraction(c0, c6, c4, c7)
		+ _tetra_solid_fraction(c0, c4, c5, c7)
		+ _tetra_solid_fraction(c0, c5, c1, c7)
	) / 6.0
	return clampf(total, 0.0, 1.0)


func _tetra_solid_fraction(a: float, b: float, c: float, d: float) -> float:
	var vertex_mean := (
		clampf(0.5 - a, 0.0, 1.0)
		+ clampf(0.5 - b, 0.0, 1.0)
		+ clampf(0.5 - c, 0.0, 1.0)
		+ clampf(0.5 - d, 0.0, 1.0)
	) * 0.25
	var centroid_sdf := (a + b + c + d) * 0.25
	return vertex_mean * 0.4 + clampf(0.5 - centroid_sdf, 0.0, 1.0) * 0.6


func _sum_removed_volume(changes: Array[Dictionary]) -> float:
	var total := 0.0
	for change in changes:
		total += float(change.get("removed_volume_m3", 0.0))
	return total


func _assign_cell_mass(changes: Array[Dictionary], target_mass_q: int) -> void:
	var assigned := 0
	for index in changes.size():
		var value := 0
		if index == changes.size() - 1:
			value = maxi(0, target_mass_q - assigned)
		else:
			value = material_field.mass_q_for_volume(float(changes[index].get("removed_volume_m3", 0.0)))
			value = mini(value, maxi(0, target_mass_q - assigned))
		changes[index]["removed_mass_q"] = value
		assigned += value


func _blend_values(before: PackedFloat32Array, full: PackedFloat32Array, alpha: float) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(before.size())
	for index in before.size():
		result[index] = lerpf(before[index], full[index], alpha)
	return result


func _changed_sample_count(before: PackedFloat32Array, after: PackedFloat32Array) -> int:
	var changed := 0
	for index in before.size():
		if absf(before[index] - after[index]) > 0.000001:
			changed += 1
	return changed


func _sample_sdf_world(world_position: Vector3) -> Dictionary:
	if not configured or _tool == null or not world_position.is_finite():
		return {"valid": false}
	var voxel_position := WorkZoneConfig.world_to_voxel(world_position, _work_zone.voxel_scale_m)
	var point := Vector3i(round(voxel_position.x), round(voxel_position.y), round(voxel_position.z))
	var point_area := AABB(Vector3(point - Vector3i.ONE), Vector3.ONE * 3.0)
	if not _tool.is_area_editable(point_area):
		return {"valid": false}
	var sdf := _tool.get_voxel_f(point)
	var gradient := Vector3(
		_tool.get_voxel_f(point + Vector3i.RIGHT) - _tool.get_voxel_f(point + Vector3i.LEFT),
		_tool.get_voxel_f(point + Vector3i.UP) - _tool.get_voxel_f(point + Vector3i.DOWN),
		_tool.get_voxel_f(point + Vector3i.BACK) - _tool.get_voxel_f(point + Vector3i.FORWARD),
	)
	if gradient.length_squared() < 0.000001:
		gradient = Vector3.UP
	return {"valid": true, "sdf": sdf, "gradient_world": gradient.normalized()}


func _poll_readiness() -> void:
	if _work_zone == null:
		return
	var completed: Array[int] = []
	for index in _readiness_work.size():
		var work := _readiness_work[index]
		var ticket := work.get("ticket", {}) as Dictionary
		if int(work.get("meshed_frame", -1)) < 0:
			if _work_zone.poll_ticket_meshed(ticket):
				work["meshed_frame"] = Engine.get_physics_frames()
				mesh_revision = maxi(mesh_revision, int(work.get("revision", 0)))
			continue
		if Engine.get_physics_frames() - int(work.get("meshed_frame", 0)) < 2:
			continue
		var pre_hit_y := float(work.get("pre_hit_y", INF))
		var post_hit_y := _ray_surface_y(work.get("probe_world", Vector3.ZERO) as Vector3)
		if (not is_finite(post_hit_y)) or (is_finite(pre_hit_y) and post_hit_y < pre_hit_y - _work_zone.voxel_scale_m * 0.25):
			if _work_zone.acknowledge_ticket_query(ticket):
				collision_revision = maxi(collision_revision, int(work.get("revision", 0)))
				completed.append(index)
	for reverse_index in range(completed.size() - 1, -1, -1):
		_readiness_work.remove_at(completed[reverse_index])


func _ray_surface_y(world_position: Vector3) -> float:
	if _work_zone == null or not _work_zone.is_inside_tree() or _work_zone.get_world_3d() == null:
		return INF
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(world_position.x, WorkZoneConfig.MAX_WORLD.y - 0.1, world_position.z),
		Vector3(world_position.x, WorkZoneConfig.MIN_WORLD.y + 0.1, world_position.z),
		WorkZoneConfig.TERRAIN_COLLISION_LAYER,
	)
	query.collide_with_areas = false
	var hit := _work_zone.get_world_3d().direct_space_state.intersect_ray(query)
	return (hit.get("position", Vector3(0.0, INF, 0.0)) as Vector3).y if not hit.is_empty() else INF


func _digest_values(values: PackedFloat32Array) -> String:
	return values.to_byte_array().hex_encode().sha256_text()


func _distance_to_segment(point: Vector3, a_value: Variant, b_value: Variant) -> float:
	var a := a_value as Vector3
	var b := b_value as Vector3
	var segment := b - a
	var length_squared := segment.length_squared()
	if length_squared <= 0.0000001:
		return point.distance_to(a)
	var alpha := clampf((point - a).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_to(a + segment * alpha)


func _index(x: int, y: int, z: int, size: Vector3i) -> int:
	return x + size.x * (y + size.y * z)


func _bucket_center_local() -> Vector3:
	var cavity := (_contract.get("proxies", {}) as Dictionary).get("cavity", {}) as Dictionary
	var raw := cavity.get("center_godot", [0.0, 0.0, 0.0]) as Array
	return Vector3(float(raw[0]), float(raw[1]), float(raw[2])) if raw.size() == 3 else Vector3.ZERO


func _sanitized_cutter_result(result: Dictionary) -> Dictionary:
	var copy := result.duplicate(true)
	copy.erase("proposal")
	return copy


func _remember_input(input_hash: String) -> void:
	_seen_inputs[input_hash] = true
	_seen_order.append(input_hash)
	while _seen_order.size() > MAX_JOURNAL_ROWS * 2:
		_seen_inputs.erase(_seen_order.pop_front())


func _append_journal(row: Dictionary) -> void:
	_journal.append(row.duplicate(true))
	while _journal.size() > MAX_JOURNAL_ROWS:
		_journal.pop_front()


func _reject_submission(reason: String) -> Dictionary:
	_record_rejection(reason)
	return {"accepted": false, "reason": reason, "queue_depth": _queue.size()}


func _record_rejection(reason: String) -> void:
	_rejected_count += 1
	_rejection_reasons[reason] = int(_rejection_reasons.get(reason, 0)) + 1


func _reject_transaction(transaction: VoxelCutTransaction, reason: String, started_usec: int) -> VoxelCutTransaction:
	transaction.rejection_reason = reason
	transaction.commit_usec = Time.get_ticks_usec() - started_usec
	return transaction


func _fail(reason: String) -> bool:
	last_error = reason
	return false

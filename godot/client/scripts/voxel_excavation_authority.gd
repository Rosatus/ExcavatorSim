class_name VoxelExcavationAuthority
extends RefCounted

const CutProposal = preload("res://scripts/voxel_cut_proposal.gd")
const CutTransaction = preload("res://scripts/voxel_cut_transaction.gd")
const SoilOperationProposal = preload("res://scripts/voxel_soil_operation_proposal.gd")
const BucketCutter = preload("res://scripts/voxel_bucket_cutter.gd")
const MaterialField = preload("res://scripts/voxel_soil_material_field.gd")
const WorkZoneConfig = preload("res://scripts/voxel_work_zone_config.gd")
const TimingWindow = preload("res://scripts/voxel_timing_window.gd")

const SCHEMA_VERSION := "voxel-excavation-authority-v2"
const COMMIT_PERIOD_S := 0.05
const MAX_QUEUE_DEPTH := 12
const MAX_JOURNAL_ROWS := 256
const MAX_STAGED_SAMPLES := 262144
const MAX_PROPOSAL_CAPSULES := 4096
const MAX_NATIVE_PATHS := 64
const MAX_NATIVE_PATH_INPUTS := 256
const MAX_NATIVE_COVERAGE_CELLS := 4096
const MAX_NATIVE_COVERAGE_PROBES := 16384
const MAX_NATIVE_DEPOSIT_PROBES := 4096
const MAX_NATIVE_DEPOSIT_PATHS := 2
const NATIVE_COVERAGE_STEP_VOXELS := 1.5
const NATIVE_DIGEST_SAMPLE_LIMIT := 128
const SDF_HALO_VOXELS := 2
const CAPACITY_SEARCH_STEPS := 14
const SDF_CHANNEL_MASK := 1 << VoxelBuffer.CHANNEL_SDF
const VOLUME_EPSILON_M3 := 0.000001
const MAX_SOIL_QUEUE_DEPTH := 12
const MAX_SETTLE_FRONTIER := 512
const MAX_SETTLE_CELLS_PER_COMMIT := 96
const REPOSE_ANGLE_DEG := 35.0
const SETTLE_TRANSFER_FRACTION := 0.18
const MIN_TRACK_SUPPORT_FORCE_N := 1000.0
const MAX_COMPACTION_DELTA_Q := 80
const DEPOSIT_MIN_RADIUS_VOXELS := 1.0
const DEPOSIT_MAX_RADIUS_VOXELS := 4.0
const DEPOSIT_MAX_HEIGHT_VOXELS := 8.0
const DUMP_BATCH_PERIOD_S := 0.1
const DUMP_LANDING_NEIGHBORHOOD_VOXELS := 4.0
const MAX_CONSECUTIVE_DEPOSIT_COMMITS := 2
const MAX_COMPACTION_SHAPES_PER_PROPOSAL := 32
const MAX_COMPACTION_STAGED_SAMPLES := 32768
const MAX_TRACK_COMPACTION_RECEIPTS := 32
const READINESS_WORK_TIMEOUT_FRAMES := 600
const SETTLE_OFFSETS: Array[Vector3i] = [Vector3i.LEFT, Vector3i.RIGHT, Vector3i.FORWARD, Vector3i.BACK]
const NATIVE_COVERAGE_OFFSETS: Array[Vector3i] = [
	Vector3i.ZERO,
	Vector3i.RIGHT,
	Vector3i.UP,
]

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
var _soil_queue: Array[VoxelSoilOperationProposal] = []
var _pending_dump: VoxelSoilOperationProposal
var _pending_dump_elapsed_s := 0.0
var _pending_dump_key := ""
var _journal: Array[Dictionary] = []
var _seen_inputs: Dictionary = {}
var _seen_order: Array[String] = []
var _seen_track_receipts: Dictionary = {}
var _seen_track_receipt_order: Array[String] = []
var _readiness_work: Array[Dictionary] = []
var _settle_frontier: Array[Vector3i] = []
var _settle_frontier_seen: Dictionary = {}
var _commit_accumulator_s := 0.0
var _prefer_background := false
var _consecutive_deposit_commits := 0
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
var _native_committed_count := 0
var _native_path_total := 0
var _native_overburden_path_total := 0
var _native_deposit_committed_count := 0
var _dump_batch_flush_count := 0
var _dump_batch_coalesced_count := 0
var _readiness_coalesced_count := 0
var _track_compaction_skipped_no_mobile := 0
var _readiness_retired_stale := 0
var _readiness_timed_out := 0
var _rejection_reasons: Dictionary = {}
var _operation_counts: Dictionary = {"cut": 0, "deposit": 0, "settle": 0, "compact": 0}
var _accepted_dump_event_id := ""
var _dump_release_world := Vector3.ZERO
var _dump_released_fill_ratio := 0.0
var _rejected_dump_event_id := ""
var _rejected_dump_world := Vector3.ZERO
var _proposal_timing_usec := TimingWindow.new()
var _commit_timing_usec := TimingWindow.new()
var _coverage_timing_usec := TimingWindow.new()
var _material_timing_usec := TimingWindow.new()
var _native_edit_timing_usec := TimingWindow.new()
var _digest_timing_usec := TimingWindow.new()
var _readiness_issue_timing_usec := TimingWindow.new()
var _status_digest_timing_usec := TimingWindow.new()
var _proposal_allocation_proxy := TimingWindow.new()
var _commit_allocation_proxy := TimingWindow.new()
var _operation_commit_timing: Dictionary = {}


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
	_soil_queue.clear()
	_pending_dump = null
	_pending_dump_elapsed_s = 0.0
	_pending_dump_key = ""
	_journal.clear()
	_seen_inputs.clear()
	_seen_order.clear()
	_seen_track_receipts.clear()
	_seen_track_receipt_order.clear()
	_readiness_work.clear()
	_settle_frontier.clear()
	_settle_frontier_seen.clear()
	_commit_accumulator_s = 0.0
	_prefer_background = false
	_consecutive_deposit_commits = 0
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
	_native_committed_count = 0
	_native_path_total = 0
	_native_overburden_path_total = 0
	_native_deposit_committed_count = 0
	_dump_batch_flush_count = 0
	_dump_batch_coalesced_count = 0
	_readiness_coalesced_count = 0
	_track_compaction_skipped_no_mobile = 0
	_readiness_retired_stale = 0
	_readiness_timed_out = 0
	_rejection_reasons.clear()
	_operation_counts = {"cut": 0, "deposit": 0, "settle": 0, "compact": 0}
	_accepted_dump_event_id = ""
	_dump_release_world = Vector3.ZERO
	_dump_released_fill_ratio = 0.0
	_rejected_dump_event_id = ""
	_rejected_dump_world = Vector3.ZERO
	_reset_timing_telemetry()


func submit_pose(pose_snapshot: Dictionary, identity: Dictionary, delta_s: float = 1.0 / 60.0) -> Dictionary:
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
	_next_sequence = maxi(_next_sequence, motion_sequence + 1)
	var proposal_started_usec := Time.get_ticks_usec()
	var dump_result := _build_dump_proposal(pose_snapshot, identity, delta_s)
	if bool(dump_result.get("attempted", false)):
		var dump_candidate := dump_result.get("proposal") as VoxelSoilOperationProposal
		_record_proposal_telemetry(
			proposal_started_usec,
			1 + dump_candidate.shapes.size() if dump_candidate != null else 1,
		)
		_engaged = false
		if not bool(dump_result.get("accepted", false)):
			# A previously accepted in-zone release remains valid even if the
			# opening subsequently leaves the dump gate. Queue it before reporting
			# the current rejected sample; neither path debits inventory here.
			_flush_pending_dump_to_queue()
			var dump_reason := String(dump_result.get("reason", "dump_rejected"))
			_record_rejected_dump(dump_reason, dump_result.get("release_world", Vector3.ZERO) as Vector3, identity)
			return _reject_submission(dump_reason)
		var dump_proposal := dump_result.get("proposal") as VoxelSoilOperationProposal
		if dump_proposal == null or not dump_proposal.is_valid() or dump_proposal.tool_hash != tool_hash:
			_record_rejected_dump("invalid_dump_proposal", dump_result.get("release_world", Vector3.ZERO) as Vector3, identity)
			return _reject_submission("invalid_dump_proposal")
		if _seen_inputs.has(dump_proposal.input_hash):
			_duplicate_count += 1
			return _reject_submission("duplicate_dump_proposal")
		var pending_result: Dictionary = _stage_pending_dump(dump_proposal)
		if not bool(pending_result.get("accepted", false)):
			_record_rejected_dump("soil_queue_full", dump_proposal.release_world, identity)
			return _reject_submission("soil_queue_full")
		_remember_input(dump_proposal.input_hash)
		if bool(pending_result.get("staged", true)):
			_accepted_proposal_count += 1
		return {
			"accepted": true,
			"reason": String(pending_result.get("reason", "dump_pending")),
			"operation": "dump",
			"input_hash": dump_proposal.input_hash,
			"queue_depth": _queue.size() + _soil_queue.size(),
			"pending_dump": _pending_dump != null,
		}
	if _pending_dump != null:
		_engaged = false
		if not _flush_pending_dump_to_queue():
			return _reject_submission("soil_queue_full")
		return {
			"accepted": true,
			"reason": "dump_end_flushed",
			"operation": "dump",
			"queue_depth": _queue.size() + _soil_queue.size(),
			"pending_dump": false,
		}
	proposal_started_usec = Time.get_ticks_usec()
	var result := cutter.build_proposal(
		pose_snapshot,
		generation,
		tick,
		motion_sequence,
		epoch,
		_engaged,
		_sample_sdf_world,
	)
	var cut_candidate := result.get("proposal") as VoxelCutProposal
	_record_proposal_telemetry(
		proposal_started_usec,
		1 + cut_candidate.capsules.size() + cut_candidate.clearance_capsules.size() \
			+ cut_candidate.native_paths.size() if cut_candidate != null else 1,
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
		"operation": "cut",
		"input_hash": proposal.input_hash,
		"queue_depth": _queue.size() + _soil_queue.size(),
	}


func step_fixed(delta: float) -> Dictionary:
	_poll_readiness()
	if not configured or not is_finite(delta) or delta < 0.0:
		return {"changed": false, "reason": "authority_unavailable"}
	_commit_accumulator_s += delta
	if _pending_dump != null:
		_pending_dump_elapsed_s += delta
		if _pending_dump_elapsed_s + 0.000001 >= DUMP_BATCH_PERIOD_S:
			_flush_pending_dump_to_queue()
	if _queue.is_empty() and _soil_queue.is_empty() and _settle_frontier.is_empty() and _pending_dump == null:
		return {"changed": false, "reason": "idle"}
	# Active dumping owns the foreground slot. Do not spend the batching window
	# committing stale compaction work while a deposit is waiting to flush.
	if _queue.is_empty() and _pending_dump != null and _soil_operation_queue_depth("deposit") == 0:
		return {
			"changed": false,
			"reason": "dump_batch_coalescing",
			"pending_dump_age_s": _pending_dump_elapsed_s,
		}
	if _commit_accumulator_s + 0.000001 < COMMIT_PERIOD_S:
		return {"changed": false, "reason": "coalescing", "queue_depth": _queue.size() + _soil_queue.size()}
	_commit_accumulator_s = fmod(_commit_accumulator_s, COMMIT_PERIOD_S)
	var transaction: VoxelCutTransaction
	var processed_background := false
	var dump_work_pending := _pending_dump != null or _soil_operation_queue_depth("deposit") > 0
	if not dump_work_pending and _queue.is_empty() and not _settle_frontier.is_empty() and (
			_prefer_background or (_queue.is_empty() and _soil_queue.is_empty())
	):
		var settle_proposal := _build_next_settle_proposal()
		if settle_proposal != null:
			transaction = _commit_soil_proposal(settle_proposal)
			processed_background = true
	if transaction == null:
		if _queue.is_empty() and _soil_queue.is_empty():
			return {"changed": false, "reason": "settle_idle"}
		if _queue.is_empty() and not _soil_queue.is_empty():
			transaction = _commit_soil_proposal(_dequeue_next_soil_proposal())
		else:
			transaction = _commit_proposal(_queue.pop_front())
	_prefer_background = not processed_background
	_record_transaction_telemetry(transaction)
	_last_transaction = transaction.to_dictionary()
	_append_journal(_last_transaction)
	if not transaction.accepted():
		_record_rejection(transaction.rejection_reason)
		return {"changed": false, "reason": transaction.rejection_reason, "transaction": _last_transaction.duplicate(true)}
	return {"changed": true, "reason": "committed", "transaction": _last_transaction.duplicate(true)}


func flush_for_test() -> Dictionary:
	if _pending_dump != null and not _flush_pending_dump_to_queue():
		return {"changed": false, "reason": "soil_queue_full"}
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
	var status_started_usec := Time.get_ticks_usec()
	var payload := get_payload_snapshot() if configured else {}
	var readiness_status := _work_zone.readiness.get_status_snapshot() \
		if _work_zone != null else {}
	var oldest_age_ticks := 0
	var oldest_tick := _last_submitted_tick
	if not _queue.is_empty():
		oldest_tick = mini(oldest_tick, _queue[0].fixed_tick_begin)
	if not _soil_queue.is_empty():
		oldest_tick = mini(oldest_tick, _soil_queue[0].fixed_tick_begin)
	if _pending_dump != null:
		oldest_tick = mini(oldest_tick, _pending_dump.fixed_tick_begin)
	oldest_age_ticks = maxi(0, _last_submitted_tick - oldest_tick)
	var status := {
		"schema_version": SCHEMA_VERSION,
		"configured": configured,
		"generation": generation,
		"data_revision": data_revision,
		"mesh_revision": mesh_revision,
		"collision_revision": collision_revision,
		"model_id": model_id,
		"tool_hash": tool_hash,
		"queue_depth": _queue.size() + _soil_queue.size(),
		"cut_queue_depth": _queue.size(),
		"soil_queue_depth": _soil_queue.size(),
		"queue_capacity": MAX_QUEUE_DEPTH + MAX_SOIL_QUEUE_DEPTH,
		"cut_queue_capacity": MAX_QUEUE_DEPTH,
		"soil_queue_capacity": MAX_SOIL_QUEUE_DEPTH,
		"deposit_queue_depth": _soil_operation_queue_depth("deposit"),
		"pending_dump_count": 1 if _pending_dump != null else 0,
		"pending_dump_mass_q": _pending_dump.requested_mass_q if _pending_dump != null else 0,
		"pending_dump_age_s": _pending_dump_elapsed_s if _pending_dump != null else 0.0,
		"dump_batch_period_s": DUMP_BATCH_PERIOD_S,
		"dump_batch_flush_count": _dump_batch_flush_count,
		"dump_batch_coalesced_count": _dump_batch_coalesced_count,
		"compaction_queue_depth": _soil_operation_queue_depth("compact"),
		"dump_admission_policy": "evict_pending_compaction_when_full",
		"peak_queue_depth": _peak_queue_depth,
		"settle_frontier_depth": _settle_frontier.size(),
		"settle_frontier_capacity": MAX_SETTLE_FRONTIER,
		"oldest_age_ticks": oldest_age_ticks,
		"pending_readiness_count": _readiness_work.size(),
		"track_compaction_skipped_no_mobile": _track_compaction_skipped_no_mobile,
		"readiness_retired_stale": _readiness_retired_stale,
		"readiness_timed_out": _readiness_timed_out,
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
		"native_committed": _native_committed_count,
		"native_path_total": _native_path_total,
		"native_overburden_path_total": _native_overburden_path_total,
		"native_deposit_committed": _native_deposit_committed_count,
		"readiness_coalesced": _readiness_coalesced_count,
		"readiness": readiness_status,
		"cut_accounting_mode": "sparse_coverage_approximate" if model_id == "sy135" else "exact_sdf_volume",
		"deposit_accounting_mode": "native_sparse_deposit_approximate",
		"engaged": _engaged,
		"last_error": last_error,
		"last_cutter_result": _last_cutter_result.duplicate(true),
		"last_transaction": _last_transaction.duplicate(true),
		"rejection_reasons": _rejection_reasons.duplicate(true),
		"operation_counts": _operation_counts.duplicate(true),
		"accepted_dump_event_id": _accepted_dump_event_id,
		"dump_release_world": _dump_release_world,
		"dump_released_fill_ratio": _dump_released_fill_ratio,
		"rejected_dump_event_id": _rejected_dump_event_id,
		"rejected_dump_world": _rejected_dump_world,
		"journal_size": _journal.size(),
		"payload": payload,
		"voxel_statistics": _work_zone.terrain.get_statistics() if _work_zone != null and _work_zone.terrain != null else {},
	}
	# Keep diagnostics and selected-world/UI payload reads on one typed status
	# surface without allowing payload fields to overwrite authority counters.
	status.merge(payload, false)
	status["phase_timings_usec"] = _phase_timing_snapshot()
	status["allocation_proxies"] = {
		"unit": "object_count_proxy_not_bytes",
		"proposal": _proposal_allocation_proxy.snapshot(),
		"commit": _commit_allocation_proxy.snapshot(),
	}
	_status_digest_timing_usec.record(Time.get_ticks_usec() - status_started_usec)
	(status["phase_timings_usec"] as Dictionary)["status_digest"] = _status_digest_timing_usec.snapshot()
	return status


func _reset_timing_telemetry() -> void:
	for window in [
		_proposal_timing_usec,
		_commit_timing_usec,
		_coverage_timing_usec,
		_material_timing_usec,
		_native_edit_timing_usec,
		_digest_timing_usec,
		_readiness_issue_timing_usec,
		_status_digest_timing_usec,
		_proposal_allocation_proxy,
		_commit_allocation_proxy,
	]:
		(window as VoxelTimingWindow).clear()
	_operation_commit_timing.clear()
	for operation in ["cut", "deposit", "settle", "compact"]:
		_operation_commit_timing[operation] = TimingWindow.new()


func _record_proposal_telemetry(started_usec: int, allocation_proxy: int) -> void:
	_proposal_timing_usec.record(Time.get_ticks_usec() - started_usec)
	_proposal_allocation_proxy.record(allocation_proxy)


func _record_transaction_telemetry(transaction: VoxelCutTransaction) -> void:
	if transaction == null or not transaction.accepted():
		return
	_commit_timing_usec.record(transaction.commit_usec)
	_record_nonzero_timing(_coverage_timing_usec, transaction.coverage_usec)
	_record_nonzero_timing(_material_timing_usec, transaction.material_usec)
	_record_nonzero_timing(_native_edit_timing_usec, transaction.native_edit_usec)
	_record_nonzero_timing(_digest_timing_usec, transaction.digest_usec)
	_record_nonzero_timing(_readiness_issue_timing_usec, transaction.readiness_issue_usec)
	# Godot does not expose per-transaction allocator bytes here. This explicit
	# object-count proxy tracks the variable-size collections that dominate the
	# proposal/commit path without pretending to be a byte measurement.
	_commit_allocation_proxy.record(
		transaction.coverage_candidate_count + transaction.coverage_new_count \
			+ transaction.native_path_count + transaction.affected_cells
	)
	var operation_window_value: Variant = _operation_commit_timing.get(transaction.operation)
	if operation_window_value is VoxelTimingWindow:
		(operation_window_value as VoxelTimingWindow).record(transaction.commit_usec)


func _record_nonzero_timing(window: VoxelTimingWindow, value_usec: int) -> void:
	if value_usec > 0:
		window.record(value_usec)


func _phase_timing_snapshot() -> Dictionary:
	var operation_commit: Dictionary = {}
	for operation_value in _operation_commit_timing.keys():
		var operation := String(operation_value)
		var window_value: Variant = _operation_commit_timing.get(operation_value)
		if window_value is VoxelTimingWindow:
			operation_commit[operation] = (window_value as VoxelTimingWindow).snapshot()
	return {
		"window_size": VoxelTimingWindow.DEFAULT_CAPACITY,
		"proposal_generation": _proposal_timing_usec.snapshot(),
		"commit": _commit_timing_usec.snapshot(),
		"commit_by_operation": operation_commit,
		"coverage": _coverage_timing_usec.snapshot(),
		"material_accounting": _material_timing_usec.snapshot(),
		"native_edit": _native_edit_timing_usec.snapshot(),
		"digest": _digest_timing_usec.snapshot(),
		"readiness_issue": _readiness_issue_timing_usec.snapshot(),
		"status_digest": _status_digest_timing_usec.snapshot(),
	}


func get_journal_snapshot() -> Array[Dictionary]:
	return _journal.duplicate(true)


func _coalesce_or_enqueue(proposal: VoxelCutProposal) -> bool:
	if not _queue.is_empty():
		var index := _queue.size() - 1
		var pending := _queue[index]
		var merged_native_paths := _merge_native_paths(pending.native_paths, proposal.native_paths)
		if pending.generation != proposal.generation or pending.model_id != proposal.model_id \
				or pending.authority_epoch != proposal.authority_epoch:
			pass
		elif pending.area_voxels.intersects(proposal.area_voxels) \
				and pending.fixed_tick_end < proposal.fixed_tick_begin \
				and pending.sequence < proposal.sequence \
				and pending.capsules.size() + pending.clearance_capsules.size() \
					+ proposal.capsules.size() + proposal.clearance_capsules.size() <= MAX_PROPOSAL_CAPSULES \
				and pending.native_paths.size() + proposal.native_paths.size() <= MAX_NATIVE_PATH_INPUTS \
				and merged_native_paths.size() <= MAX_NATIVE_PATHS:
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
			"native_paths": merged_native_paths,
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


func _merge_native_paths(first: Array[Dictionary], second: Array[Dictionary]) -> Array[Dictionary]:
	var merged: Array[Dictionary] = []
	var indexes: Dictionary = {}
	for path in first:
		var copy := path.duplicate(true)
		indexes[String(copy.get("path_id", ""))] = merged.size()
		merged.append(copy)
	for path in second:
		var path_id := String(path.get("path_id", ""))
		var role := String(path.get("role", ""))
		if not indexes.has(path_id):
			indexes[path_id] = merged.size()
			merged.append(path.duplicate(true))
			continue
		var index := int(indexes[path_id])
		var target := merged[index]
		if String(target.get("role", "")) != role:
			continue
		var target_points := target.get("points_voxels", PackedVector3Array()) as PackedVector3Array
		var target_radii := target.get("radii_voxels", PackedFloat32Array()) as PackedFloat32Array
		var incoming_points := path.get("points_voxels", PackedVector3Array()) as PackedVector3Array
		var incoming_radii := path.get("radii_voxels", PackedFloat32Array()) as PackedFloat32Array
		for point_index in incoming_points.size():
			if point_index == 0 and not target_points.is_empty() \
					and target_points[target_points.size() - 1].is_equal_approx(incoming_points[point_index]):
				continue
			target_points.append(incoming_points[point_index])
			target_radii.append(incoming_radii[point_index])
		target["points_voxels"] = target_points
		target["radii_voxels"] = target_radii
		merged[index] = target
	return merged


func _stage_pending_dump(proposal: VoxelSoilOperationProposal) -> Dictionary:
	var landing_key := _dump_landing_key(proposal.deposit_world)
	if _pending_dump != null and (
		_pending_dump_key != landing_key
		or _pending_dump.generation != proposal.generation
		or _pending_dump.authority_epoch != proposal.authority_epoch
	):
		if not _flush_pending_dump_to_queue():
			return {"accepted": false, "reason": "soil_queue_full", "staged": false}
	var available_mass_q := maxi(0, material_field.bucket_mass_q - _queued_deposit_mass_q())
	if available_mass_q <= 0:
		return {"accepted": true, "reason": "dump_mass_already_reserved", "staged": false}
	if _pending_dump == null:
		var initial_mass_q := mini(proposal.requested_mass_q, available_mass_q)
		_pending_dump = _resized_dump_proposal(proposal, initial_mass_q, proposal.fixed_tick_begin, 0)
		if _pending_dump == null:
			return {"accepted": false, "reason": "invalid_dump_batch", "staged": false}
		_pending_dump_elapsed_s = 0.0
		_pending_dump_key = landing_key
	else:
		var merged_mass_q := mini(
			available_mass_q,
			_pending_dump.requested_mass_q + proposal.requested_mass_q,
		)
		var merged := _resized_dump_proposal(
			proposal,
			merged_mass_q,
			_pending_dump.fixed_tick_begin,
			roundi(_pending_dump_elapsed_s * 1000000.0),
		)
		if merged == null:
			return {"accepted": false, "reason": "invalid_dump_batch", "staged": false}
		merged.support_query_usec += _pending_dump.support_query_usec
		_pending_dump = merged
		_dump_batch_coalesced_count += 1
	if _pending_dump.requested_mass_q >= available_mass_q:
		if not _flush_pending_dump_to_queue():
			return {"accepted": true, "reason": "dump_pending_backpressure", "staged": true}
		return {"accepted": true, "reason": "dump_batch_queued", "staged": true}
	return {"accepted": true, "reason": "dump_pending", "staged": true}


func _flush_pending_dump_to_queue() -> bool:
	if _pending_dump == null:
		return true
	var fields := _pending_dump.to_dictionary()
	fields["batch_wait_usec"] = maxi(
		int(fields.get("batch_wait_usec", 0)),
		roundi(_pending_dump_elapsed_s * 1000000.0),
	)
	var flags := fields.get("quality_flags", []) as Array
	flags.append("bounded_100ms_batch")
	fields["quality_flags"] = flags
	var queued := SoilOperationProposal.create(fields)
	if not queued.is_valid() or not _coalesce_or_enqueue_soil(queued):
		return false
	_pending_dump = null
	_pending_dump_elapsed_s = 0.0
	_pending_dump_key = ""
	_dump_batch_flush_count += 1
	return true


func _queued_deposit_mass_q() -> int:
	var total := 0
	for proposal in _soil_queue:
		if proposal.operation == "deposit":
			total += proposal.requested_mass_q
	return total


func _dump_landing_key(deposit_world: Vector3) -> String:
	var deposit_voxels := WorkZoneConfig.world_to_voxel(deposit_world, _work_zone.voxel_scale_m)
	return "%d,%d" % [
		floori(deposit_voxels.x / DUMP_LANDING_NEIGHBORHOOD_VOXELS),
		floori(deposit_voxels.z / DUMP_LANDING_NEIGHBORHOOD_VOXELS),
	]


func _resized_dump_proposal(
	base: VoxelSoilOperationProposal,
	requested_mass_q: int,
	fixed_tick_begin: int,
	batch_wait_usec: int
) -> VoxelSoilOperationProposal:
	if base == null or base.shapes.is_empty() or requested_mass_q <= 0:
		return null
	var base_shape := base.shapes[0]
	var old_radius_voxels := float(base_shape.get("radius_voxels", DEPOSIT_MIN_RADIUS_VOXELS))
	var support_voxels := (base_shape.get("a_voxels", Vector3.ZERO) as Vector3) \
		- Vector3.UP * old_radius_voxels * 0.2
	var support_world := WorkZoneConfig.voxel_to_world(support_voxels, _work_zone.voxel_scale_m)
	var shape_data := _deposit_shape_for_mass(requested_mass_q, support_world)
	if shape_data.is_empty():
		return null
	var flags: Array[String] = base.quality_flags.duplicate()
	flags.append("native_repose_profile")
	return SoilOperationProposal.create({
		"generation": base.generation,
		"fixed_tick_begin": fixed_tick_begin,
		"fixed_tick_end": base.fixed_tick_end,
		"sequence": base.sequence,
		"model_id": base.model_id,
		"authority_epoch": base.authority_epoch,
		"tool_hash": base.tool_hash,
		"operation": "deposit",
		"area_voxels": shape_data.get("area_voxels", AABB()) as AABB,
		"shapes": [shape_data.get("shape", {}) as Dictionary],
		"requested_mass_q": requested_mass_q,
		"release_world": base.release_world,
		"deposit_world": shape_data.get("deposit_world", support_world) as Vector3,
		"release_fill_ratio": base.release_fill_ratio,
		"support_query_usec": base.support_query_usec,
		"batch_wait_usec": batch_wait_usec,
		"quality_flags": flags,
	})


func _deposit_shape_for_mass(requested_mass_q: int, support_world: Vector3) -> Dictionary:
	if requested_mass_q <= 0 or not support_world.is_finite():
		return {}
	var loose_volume_m3 := material_field.loose_volume_for_mass_q(requested_mass_q)
	var repose_slope := maxf(0.2, tan(deg_to_rad(REPOSE_ANGLE_DEG)))
	var minimum_radius_m := _work_zone.voxel_scale_m * DEPOSIT_MIN_RADIUS_VOXELS
	var maximum_radius_m := _work_zone.voxel_scale_m * DEPOSIT_MAX_RADIUS_VOXELS
	var radius_world := clampf(
		pow(maxf(VOLUME_EPSILON_M3, 3.0 * loose_volume_m3 / (PI * repose_slope)), 1.0 / 3.0),
		minimum_radius_m,
		maximum_radius_m,
	)
	var height_world := clampf(
		3.0 * loose_volume_m3 / maxf(PI * radius_world * radius_world, VOLUME_EPSILON_M3),
		_work_zone.voxel_scale_m,
		_work_zone.voxel_scale_m * DEPOSIT_MAX_HEIGHT_VOXELS,
	)
	var radius_voxels := radius_world / _work_zone.voxel_scale_m
	var base_world := support_world + Vector3.UP * radius_world * 0.2
	var top_world := support_world + Vector3.UP * maxf(height_world, radius_world * 0.8)
	var shape := {
		"mode": "add",
		"a_voxels": WorkZoneConfig.world_to_voxel(base_world, _work_zone.voxel_scale_m),
		"b_voxels": WorkZoneConfig.world_to_voxel(top_world, _work_zone.voxel_scale_m),
		"radius_voxels": radius_voxels,
	}
	var area := _merge_shape_area(AABB(), shape)
	return {
		"shape": shape,
		"area_voxels": area,
		"deposit_world": base_world.lerp(top_world, 0.5),
	}


func _coalesce_or_enqueue_soil(proposal: VoxelSoilOperationProposal) -> bool:
	if not _soil_queue.is_empty():
		var index := _soil_queue.size() - 1
		var pending := _soil_queue[index]
		var merged_area := pending.area_voxels.merge(proposal.area_voxels)
		var compaction_merge_is_bounded := proposal.operation != "compact" or ( \
			pending.area_voxels.intersects(proposal.area_voxels) \
			and pending.shapes.size() + proposal.shapes.size() <= MAX_COMPACTION_SHAPES_PER_PROPOSAL \
			and _area_sample_count(merged_area) <= MAX_COMPACTION_STAGED_SAMPLES \
		)
		if proposal.operation != "deposit" \
				and pending.operation == proposal.operation and pending.generation == proposal.generation \
				and pending.model_id == proposal.model_id and pending.authority_epoch == proposal.authority_epoch \
				and pending.fixed_tick_end < proposal.fixed_tick_begin \
				and pending.shapes.size() + proposal.shapes.size() <= MAX_PROPOSAL_CAPSULES \
				and compaction_merge_is_bounded:
			_soil_queue[index] = SoilOperationProposal.create({
				"generation": generation,
				"fixed_tick_begin": pending.fixed_tick_begin,
				"fixed_tick_end": proposal.fixed_tick_end,
				"sequence": proposal.sequence,
				"model_id": model_id,
				"authority_epoch": proposal.authority_epoch,
				"tool_hash": tool_hash,
				"operation": proposal.operation,
				"area_voxels": merged_area,
				"shapes": pending.shapes + proposal.shapes,
				"requested_mass_q": pending.requested_mass_q + proposal.requested_mass_q,
				"compaction_delta_q": maxi(pending.compaction_delta_q, proposal.compaction_delta_q),
				"release_world": proposal.release_world,
				"deposit_world": proposal.deposit_world,
				"release_fill_ratio": proposal.release_fill_ratio,
				"quality_flags": pending.quality_flags + proposal.quality_flags + ["coalesced"],
			})
			_coalesced_count += 1
			return true
	if _soil_queue.size() >= MAX_SOIL_QUEUE_DEPTH:
		if proposal.operation != "deposit":
			return false
		var compact_index := -1
		for index in range(_soil_queue.size() - 1, -1, -1):
			if _soil_queue[index].operation == "compact":
				compact_index = index
				break
		if compact_index < 0:
			return false
		_soil_queue.remove_at(compact_index)
		_record_rejection("compaction_evicted_for_dump")
	_soil_queue.append(proposal.duplicate_typed())
	_peak_queue_depth = maxi(_peak_queue_depth, _queue.size() + _soil_queue.size())
	return true


func _dequeue_next_soil_proposal() -> VoxelSoilOperationProposal:
	var deposit_index := -1
	var background_index := -1
	for index in _soil_queue.size():
		if _soil_queue[index].operation == "deposit" and deposit_index < 0:
			deposit_index = index
		elif _soil_queue[index].operation != "deposit" and background_index < 0:
			background_index = index
	var selected_index := 0
	if deposit_index >= 0 and (
			background_index < 0 or _consecutive_deposit_commits < MAX_CONSECUTIVE_DEPOSIT_COMMITS
	):
		selected_index = deposit_index
		_consecutive_deposit_commits += 1
	elif background_index >= 0:
		selected_index = background_index
		_consecutive_deposit_commits = 0
	var selected := _soil_queue[selected_index]
	_soil_queue.remove_at(selected_index)
	return selected


func _soil_operation_queue_depth(operation: String) -> int:
	var count := 0
	for proposal in _soil_queue:
		if proposal.operation == operation:
			count += 1
	return count


func _commit_proposal(proposal: VoxelCutProposal) -> VoxelCutTransaction:
	var started := Time.get_ticks_usec()
	var transaction := CutTransaction.new()
	transaction.generation = proposal.generation
	transaction.sequence = proposal.sequence
	transaction.fixed_tick_begin = proposal.fixed_tick_begin
	transaction.fixed_tick_end = proposal.fixed_tick_end
	transaction.model_id = proposal.model_id
	transaction.operation = "cut"
	transaction.area_voxels = proposal.area_voxels
	transaction.input_hash = proposal.input_hash
	transaction.transaction_id = _transaction_id(transaction.operation, proposal.sequence, proposal.input_hash)
	if proposal.generation != generation or proposal.model_id != model_id or proposal.tool_hash != tool_hash:
		return _reject_transaction(transaction, "stale_or_wrong_tool", started)
	if material_field.remaining_capacity_mass_q() <= 0:
		return _reject_transaction(transaction, "bucket_full", started)
	if not proposal.native_paths.is_empty():
		return _commit_native_proposal(proposal, transaction, started)
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
	_operation_counts["cut"] = int(_operation_counts.get("cut", 0)) + 1
	_affected_samples_total += transaction.affected_samples
	_affected_cells_total += transaction.affected_cells
	_commit_usec_total += transaction.commit_usec
	_commit_usec_max = maxi(_commit_usec_max, transaction.commit_usec)
	var readiness_started := Time.get_ticks_usec()
	_issue_readiness_work(
		edit_area,
		data_revision,
		&"voxel_bucket_cut",
		proposal.probe_world,
		pre_hit_y,
		"lower",
	)
	transaction.readiness_issue_usec = Time.get_ticks_usec() - readiness_started
	var commit_before_readiness := transaction.commit_usec
	transaction.commit_usec = Time.get_ticks_usec() - started
	_commit_usec_total += transaction.commit_usec - commit_before_readiness
	_commit_usec_max = maxi(_commit_usec_max, transaction.commit_usec)
	return transaction


func _commit_native_proposal(
	proposal: VoxelCutProposal,
	transaction: VoxelCutTransaction,
	started_usec: int
) -> VoxelCutTransaction:
	if proposal.model_id != "sy135" or proposal.native_paths.size() > MAX_NATIVE_PATHS:
		return _reject_transaction(transaction, "native_path_work_budget", started_usec)
	var window := _integer_window_without_halo(proposal.area_voxels)
	var origin := window.get("origin", Vector3i.ZERO) as Vector3i
	var size := window.get("size", Vector3i.ZERO) as Vector3i
	if size.x <= 0 or size.y <= 0 or size.z <= 0:
		return _reject_transaction(transaction, "native_edit_area_empty", started_usec)
	var edit_area := AABB(Vector3(origin), Vector3(size))
	if not _tool.is_area_editable(edit_area):
		return _reject_transaction(transaction, "voxel_area_not_editable", started_usec)
	var phase_started := Time.get_ticks_usec()
	var coverage_coordinates := _native_coverage_coordinates(proposal.native_paths, origin, size)
	transaction.coverage_usec = Time.get_ticks_usec() - phase_started
	transaction.coverage_candidate_count = coverage_coordinates.size()
	if coverage_coordinates.is_empty():
		return _reject_transaction(transaction, "no_sdf_change", started_usec)
	phase_started = Time.get_ticks_usec()
	transaction.pre_sdf_digest = _native_sample_digest(coverage_coordinates)
	transaction.digest_usec += Time.get_ticks_usec() - phase_started
	var voxel_volume_m3 := pow(_work_zone.voxel_scale_m, 3.0)
	phase_started = Time.get_ticks_usec()
	var material_stage := material_field.stage_approximate_cut(coverage_coordinates, voxel_volume_m3)
	if not bool(material_stage.get("valid", false)):
		return _reject_transaction(transaction, String(material_stage.get("reason", "material_stage_failed")), started_usec)
	if not material_field.can_commit_approximate_cut(material_stage):
		return _reject_transaction(transaction, "material_commit_invariant", started_usec)
	transaction.material_usec += Time.get_ticks_usec() - phase_started
	transaction.accounting_mode = "sparse_coverage_approximate"
	transaction.requested_mass_q = int(material_stage.get("requested_mass_q", 0))
	transaction.accepted_mass_q = int(material_stage.get("accepted_mass_q", 0))
	transaction.represented_mass_q = transaction.requested_mass_q
	transaction.capacity_clipped = bool(material_stage.get("capacity_clipped", false))
	transaction.mass_discretization_error_q = transaction.requested_mass_q - transaction.accepted_mass_q
	transaction.accepted_volume_m3 = material_field.volume_for_mass_q(transaction.accepted_mass_q)
	transaction.requested_volume_m3 = material_field.volume_for_mass_q(transaction.requested_mass_q)
	transaction.coverage_new_count = (material_stage.get("mutations", []) as Array).size()
	transaction.affected_cells = transaction.coverage_new_count
	transaction.affected_samples = coverage_coordinates.size()
	transaction.native_path_count = proposal.native_paths.size()
	for path in proposal.native_paths:
		if String(path.get("role", "")) == "overburden_cleanup" \
				or (path.get("components", []) as Array).has("overburden_cleanup"):
			transaction.overburden_path_count += 1
	var pre_hit_y := _ray_surface_y(proposal.probe_world)
	_tool.channel = VoxelBuffer.CHANNEL_SDF
	_tool.mode = VoxelTool.MODE_REMOVE
	phase_started = Time.get_ticks_usec()
	for path in proposal.native_paths:
		var points := path.get("points_voxels", PackedVector3Array()) as PackedVector3Array
		var radii := path.get("radii_voxels", PackedFloat32Array()) as PackedFloat32Array
		_tool.do_path(points, radii)
	transaction.native_edit_usec = Time.get_ticks_usec() - phase_started
	phase_started = Time.get_ticks_usec()
	transaction.post_sdf_digest = _native_sample_digest(coverage_coordinates)
	transaction.digest_usec += Time.get_ticks_usec() - phase_started
	# The material stage is validated before the irreversible native edit. The
	# native API is synchronous and has no reject result, so this commit cannot
	# race another material mutation inside the single authority transaction.
	phase_started = Time.get_ticks_usec()
	material_field.commit_approximate_cut(material_stage)
	transaction.material_usec += Time.get_ticks_usec() - phase_started
	data_revision += 1
	transaction.revision = data_revision
	if transaction.capacity_clipped:
		_capacity_clipped_count += 1
	_committed_count += 1
	_native_committed_count += 1
	_native_path_total += transaction.native_path_count
	_native_overburden_path_total += transaction.overburden_path_count
	_operation_counts["cut"] = int(_operation_counts.get("cut", 0)) + 1
	_affected_samples_total += transaction.affected_samples
	_affected_cells_total += transaction.affected_cells
	phase_started = Time.get_ticks_usec()
	_issue_readiness_work(
		edit_area,
		data_revision,
		&"voxel_bucket_cut_native",
		proposal.probe_world,
		pre_hit_y,
		"lower",
	)
	transaction.readiness_issue_usec = Time.get_ticks_usec() - phase_started
	transaction.commit_usec = Time.get_ticks_usec() - started_usec
	_commit_usec_total += transaction.commit_usec
	_commit_usec_max = maxi(_commit_usec_max, transaction.commit_usec)
	return transaction


func submit_track_compaction(chassis_status: Dictionary) -> Dictionary:
	if not configured:
		return {"accepted": false, "reason": "authority_unavailable"}
	var epoch := String(chassis_status.get("authority_epoch", ""))
	var tick := int(chassis_status.get("physics_tick", -1))
	if epoch.is_empty() or tick < 0 or not bool(chassis_status.get("terrain_identity_valid", false)) \
			or int(chassis_status.get("terrain_generation", -1)) != generation:
		return {"accepted": false, "reason": "stale_track_identity"}
	var receipt_identity := "%d|%s|%d" % [generation, epoch, tick]
	if _seen_track_receipts.has(receipt_identity):
		_duplicate_count += 1
		return {"accepted": false, "reason": "duplicate_compaction"}
	if not material_field.has_compactable_mobile():
		_track_compaction_skipped_no_mobile += 1
		return {"accepted": false, "reason": "no_loose_track_contact"}
	var shapes: Array[Dictionary] = []
	var total_force := 0.0
	var area := AABB()
	var receipt_count := 0
	for value in chassis_status.get("track_contact_receipts", []):
		if receipt_count >= MAX_TRACK_COMPACTION_RECEIPTS:
			break
		receipt_count += 1
		var receipt := value as Dictionary
		if String(receipt.get("support_source", "")) != "voxel_terrain":
			continue
		var point := receipt.get("point", Vector3(INF, INF, INF)) as Vector3
		var force := float(receipt.get("support_force_n", 0.0))
		var width_m := float(receipt.get("footprint_width_m", 0.0))
		if not point.is_finite() or not is_finite(force) or not is_finite(width_m) \
				or force < MIN_TRACK_SUPPORT_FORCE_N or width_m <= 0.0 \
				or not WorkZoneConfig.is_world_position_editable(point, _work_zone.voxel_scale_m) \
				or not _work_zone.is_support_ready_at(point):
			continue
		var center := WorkZoneConfig.world_to_voxel(point - Vector3.UP * _work_zone.voxel_scale_m * 0.25, _work_zone.voxel_scale_m)
		var radius := clampf(width_m * 0.22 / _work_zone.voxel_scale_m, 0.75, 2.0)
		var shape := {"mode": "remove", "a_voxels": center, "b_voxels": center, "radius_voxels": radius}
		if not _shape_has_compactable_mobile(shape):
			continue
		shapes.append(shape)
		area = _merge_shape_area(area, shape)
		total_force += force
	if shapes.is_empty():
		return {"accepted": false, "reason": "no_loose_track_contact"}
	var proposal := SoilOperationProposal.create({
		"generation": generation,
		"fixed_tick_begin": tick,
		"fixed_tick_end": tick,
		"sequence": _next_sequence,
		"model_id": model_id,
		"authority_epoch": epoch,
		"tool_hash": tool_hash,
		"operation": "compact",
		"area_voxels": area,
		"shapes": shapes,
		"requested_mass_q": maxi(1, roundi(total_force)),
		"compaction_delta_q": clampi(roundi(total_force / 15000.0), 1, MAX_COMPACTION_DELTA_Q),
		"release_world": WorkZoneConfig.voxel_to_world(shapes[0].get("a_voxels", Vector3.ZERO), _work_zone.voxel_scale_m),
		"deposit_world": WorkZoneConfig.voxel_to_world(shapes[0].get("a_voxels", Vector3.ZERO), _work_zone.voxel_scale_m),
		"quality_flags": ["accepted_voxel_track_receipts", "loose_only"],
	})
	_next_sequence += 1
	if not proposal.is_valid():
		return {"accepted": false, "reason": "invalid_compaction_proposal"}
	if _seen_inputs.has(proposal.input_hash):
		return {"accepted": false, "reason": "duplicate_compaction"}
	if not _coalesce_or_enqueue_soil(proposal):
		return {"accepted": false, "reason": "soil_queue_full"}
	_remember_input(proposal.input_hash)
	_remember_track_receipt(receipt_identity)
	_accepted_proposal_count += 1
	return {"accepted": true, "reason": "compaction_queued", "queue_depth": _queue.size() + _soil_queue.size()}


func _build_dump_proposal(pose_snapshot: Dictionary, identity: Dictionary, delta_s: float) -> Dictionary:
	if material_field.bucket_mass_q <= 0 or not bool(pose_snapshot.get("valid", false)):
		return {"attempted": false}
	var contract := pose_snapshot.get("contract", {}) as Dictionary
	var interaction := contract.get("interaction", {}) as Dictionary
	var opening_down_dot := (pose_snapshot.get("opening_normal_world", Vector3.UP) as Vector3).dot(Vector3.DOWN)
	var dump_threshold := float(interaction.get("dump_opening_down_dot", 1.0))
	if opening_down_dot < dump_threshold:
		return {"attempted": false}
	var current := pose_snapshot.get("current", {}) as Dictionary
	var opening := current.get("opening", Transform3D.IDENTITY) as Transform3D
	var release_world := opening.origin
	if not WorkZoneConfig.is_world_position_editable(release_world, _work_zone.voxel_scale_m):
		return {"attempted": true, "accepted": false, "reason": "dump_out_of_zone", "release_world": release_world}
	var support_started_usec := Time.get_ticks_usec()
	var support := _find_sdf_support_world(release_world)
	var support_query_usec := Time.get_ticks_usec() - support_started_usec
	if not bool(support.get("valid", false)):
		return {"attempted": true, "accepted": false, "reason": "dump_support_unavailable", "release_world": release_world}
	var support_world := support.get("position", Vector3.ZERO) as Vector3
	if not WorkZoneConfig.is_world_position_editable(support_world, _work_zone.voxel_scale_m):
		return {"attempted": true, "accepted": false, "reason": "dump_out_of_zone", "release_world": release_world}
	var contract_capacity := float(contract.get("heaped_capacity_m3", 0.0))
	var exposure := clampf((opening_down_dot - dump_threshold) / maxf(0.01, 1.0 - dump_threshold), 0.0, 1.0)
	var release_volume := contract_capacity * lerpf(0.35, 1.4, exposure) * clampf(delta_s, 0.0, 0.1)
	var requested_mass_q := mini(material_field.bucket_mass_q, material_field.mass_q_for_volume(release_volume))
	if requested_mass_q <= 0:
		return {"attempted": true, "accepted": false, "reason": "dump_sub_quantum", "release_world": release_world}
	var shape_data := _deposit_shape_for_mass(requested_mass_q, support_world)
	var shape := shape_data.get("shape", {}) as Dictionary
	var area := shape_data.get("area_voxels", AABB()) as AABB
	var deposit_world := shape_data.get("deposit_world", support_world) as Vector3
	if shape.is_empty() or area.size == Vector3.ZERO:
		return {"attempted": true, "accepted": false, "reason": "dump_sub_quantum", "release_world": release_world}
	if not _area_is_editable_world_voxel(area):
		return {"attempted": true, "accepted": false, "reason": "dump_protected_boundary", "release_world": release_world}
	var sequence := int(identity.get("motion_sequence", _next_sequence))
	var proposal := SoilOperationProposal.create({
		"generation": generation,
		"fixed_tick_begin": int(identity.get("physics_tick", -1)),
		"fixed_tick_end": int(identity.get("physics_tick", -1)),
		"sequence": sequence,
		"model_id": model_id,
		"authority_epoch": String(identity.get("authority_epoch", "")),
		"tool_hash": tool_hash,
		"operation": "deposit",
		"area_voxels": area,
		"shapes": [shape],
		"requested_mass_q": requested_mass_q,
		"release_world": release_world,
		"deposit_world": deposit_world,
		"release_fill_ratio": float(material_field.bucket_mass_q) / float(material_field.bucket_capacity_mass_q),
		"support_query_usec": support_query_usec,
		"quality_flags": ["opening_validated", "sdf_support", "loose_density", "native_repose_profile"],
	})
	return {"attempted": true, "accepted": proposal.is_valid(), "reason": "accepted", "proposal": proposal, "release_world": release_world}


func _find_sdf_support_world(world_position: Vector3) -> Dictionary:
	var voxel_xz := WorkZoneConfig.world_to_voxel(world_position, _work_zone.voxel_scale_m)
	var bounds := WorkZoneConfig.voxel_bounds(_work_zone.voxel_scale_m)
	var x := roundi(voxel_xz.x)
	var z := roundi(voxel_xz.z)
	var top := mini(floori(voxel_xz.y), floori(bounds.end.y) - WorkZoneConfig.PROTECTED_SHELL_VOXELS - 1)
	var bottom := ceili(bounds.position.y) + WorkZoneConfig.PROTECTED_SHELL_VOXELS
	var prior_sdf := 1.0
	for y in range(top, bottom - 1, -1):
		var sdf := _tool.get_voxel_f(Vector3i(x, y, z))
		if sdf <= 0.0 and prior_sdf > 0.0:
			return {"valid": true, "position": WorkZoneConfig.voxel_to_world(Vector3(x, float(y) + clampf(sdf, -0.5, 0.5), z), _work_zone.voxel_scale_m)}
		prior_sdf = sdf
	return {"valid": false}


func _commit_soil_proposal(proposal: VoxelSoilOperationProposal) -> VoxelCutTransaction:
	var started := Time.get_ticks_usec()
	var transaction := CutTransaction.new()
	transaction.generation = proposal.generation
	transaction.sequence = proposal.sequence
	transaction.fixed_tick_begin = proposal.fixed_tick_begin
	transaction.fixed_tick_end = proposal.fixed_tick_end
	transaction.model_id = proposal.model_id
	transaction.operation = proposal.operation
	transaction.area_voxels = proposal.area_voxels
	transaction.input_hash = proposal.input_hash
	transaction.transaction_id = _transaction_id(proposal.operation, proposal.sequence, proposal.input_hash)
	transaction.release_world = proposal.release_world
	transaction.deposit_world = proposal.deposit_world
	transaction.release_fill_ratio = proposal.release_fill_ratio
	transaction.support_query_usec = proposal.support_query_usec
	transaction.batch_wait_usec = proposal.batch_wait_usec
	if proposal.generation != generation or proposal.model_id != model_id or proposal.tool_hash != tool_hash:
		return _reject_transaction(transaction, "stale_or_wrong_tool", started)
	if proposal.operation == "deposit" and material_field.bucket_mass_q <= 0:
		return _reject_transaction(transaction, "bucket_empty", started)
	if proposal.operation == "deposit" and not proposal.quality_flags.has("exact_sdf_diagnostic"):
		return _commit_native_deposit_proposal(proposal, transaction, started)
	var window := _integer_window(proposal.area_voxels)
	var origin := window.get("origin", Vector3i.ZERO) as Vector3i
	var size := window.get("size", Vector3i.ZERO) as Vector3i
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
	var final_values := original.duplicate()
	var material_stage: Dictionary = {}
	var affected_cells: Array[Dictionary] = []
	if proposal.operation == "deposit":
		var full_values := original.duplicate()
		if _apply_soil_shapes(full_values, size, origin, proposal.shapes) <= 0:
			return _reject_transaction(transaction, "no_sdf_change", started)
		var full_cells := _cell_additions(original, full_values, size, origin)
		var full_mass_q := _sum_added_mass_q(full_cells)
		var target_q := mini(proposal.requested_mass_q, material_field.bucket_mass_q)
		transaction.requested_mass_q = target_q
		transaction.requested_volume_m3 = material_field.loose_volume_for_mass_q(target_q)
		if full_mass_q > target_q:
			final_values = _fit_values_to_added_mass(original, full_values, size, origin, target_q)
		else:
			final_values = full_values
		affected_cells = _cell_additions(original, final_values, size, origin)
		var represented_q := _sum_added_mass_q(affected_cells)
		var accepted_target_q := mini(target_q, represented_q)
		if accepted_target_q <= 0:
			return _reject_transaction(transaction, "sub_quantum_change", started)
		_assign_added_cell_mass(affected_cells, accepted_target_q)
		material_stage = material_field.stage_deposit(affected_cells, accepted_target_q)
		transaction.represented_mass_q = represented_q
		transaction.mass_discretization_error_q = represented_q - accepted_target_q
		transaction.mass_discretization_tolerance_q = material_field.mass_q_for_loose_volume(pow(_work_zone.voxel_scale_m, 3.0))
	elif proposal.operation == "compact":
		var compact_full_values := original.duplicate()
		if _apply_soil_shapes(compact_full_values, size, origin, proposal.shapes) <= 0:
			return _reject_transaction(transaction, "no_sdf_change", started)
		compact_full_values = _mask_removal_to_pure_mobile(original, compact_full_values, size, origin)
		var compact_full_cells := _cell_changes(original, compact_full_values, size, origin)
		var compact_coordinates: Array[Vector3i] = []
		for change in compact_full_cells:
			var coordinate := change.get("coordinate", Vector3i.ZERO) as Vector3i
			if material_field.mobile_mass_q_at(coordinate) > 0 and material_field.stable_mass_q_at(coordinate) == 0:
				compact_coordinates.append(coordinate)
		material_stage = material_field.stage_compaction(compact_coordinates, proposal.compaction_delta_q)
		if not bool(material_stage.get("valid", false)):
			return _reject_transaction(transaction, String(material_stage.get("reason", "material_stage_failed")), started)
		var compaction_volume_loss_m3 := float(material_stage.get("volume_loss_m3", 0.0))
		var full_compaction_capacity_m3 := _sum_removed_volume(compact_full_cells)
		if compaction_volume_loss_m3 <= VOLUME_EPSILON_M3:
			return _reject_transaction(transaction, "sub_quantum_compaction", started)
		if full_compaction_capacity_m3 + VOLUME_EPSILON_M3 < compaction_volume_loss_m3:
			return _reject_transaction(transaction, "compaction_geometry_capacity", started)
		final_values = _fit_values_to_removed_volume(
			original,
			compact_full_values,
			size,
			origin,
			compaction_volume_loss_m3,
		)
		affected_cells = _cell_changes(original, final_values, size, origin)
		var represented_compaction_volume_m3 := _sum_removed_volume(affected_cells)
		transaction.requested_mass_q = proposal.requested_mass_q
		transaction.requested_volume_m3 = compaction_volume_loss_m3
		transaction.represented_mass_q = int(material_stage.get("accepted_mass_q", 0))
		transaction.mass_discretization_error_q = material_field.mass_q_for_loose_volume(
			absf(compaction_volume_loss_m3 - represented_compaction_volume_m3)
		)
		transaction.mass_discretization_tolerance_q = material_field.mass_q_for_loose_volume(
			pow(_work_zone.voxel_scale_m, 3.0)
		)
	elif proposal.operation == "settle":
		var remove_shapes := _shapes_for_mode(proposal.shapes, "remove")
		var add_shapes := _shapes_for_mode(proposal.shapes, "add")
		var remove_full_values := original.duplicate()
		if remove_shapes.is_empty() or add_shapes.is_empty() \
				or _apply_soil_shapes(remove_full_values, size, origin, remove_shapes) <= 0:
			return _reject_transaction(transaction, "no_sdf_change", started)
		remove_full_values = _mask_removal_to_pure_mobile(original, remove_full_values, size, origin)
		var full_removals := _cell_changes(original, remove_full_values, size, origin)
		var transfer_q := mini(proposal.requested_mass_q, _sum_removable_mobile_mass_q(full_removals))
		if transfer_q <= 0:
			return _reject_transaction(transaction, "settle_no_transfer", started)
		var removed_values := _fit_values_to_removed_mobile_mass(
			original,
			remove_full_values,
			size,
			origin,
			transfer_q,
		)
		var removals := _cell_changes(original, removed_values, size, origin)
		transfer_q = mini(transfer_q, _sum_removable_mobile_mass_q(removals))
		var add_full_values := removed_values.duplicate()
		if transfer_q <= 0 or _apply_soil_shapes(add_full_values, size, origin, add_shapes) <= 0:
			return _reject_transaction(transaction, "settle_no_receiver", started)
		var full_additions := _cell_additions(removed_values, add_full_values, size, origin)
		transfer_q = mini(transfer_q, _sum_added_mass_q(full_additions))
		if transfer_q <= 0:
			return _reject_transaction(transaction, "settle_no_receiver", started)
		# Refit both sides to the same accepted fixed-point mass so the SDF and
		# ledger cannot diverge by a fixed brush volume.
		removed_values = _fit_values_to_removed_mobile_mass(
			original,
			remove_full_values,
			size,
			origin,
			transfer_q,
		)
		removals = _cell_changes(original, removed_values, size, origin)
		add_full_values = removed_values.duplicate()
		_apply_soil_shapes(add_full_values, size, origin, add_shapes)
		final_values = _fit_values_to_added_mass(removed_values, add_full_values, size, origin, transfer_q)
		var additions := _cell_additions(removed_values, final_values, size, origin)
		transfer_q = mini(
			transfer_q,
			mini(_sum_removable_mobile_mass_q(removals), _sum_added_mass_q(additions)),
		)
		if transfer_q <= 0:
			return _reject_transaction(transaction, "settle_sub_quantum", started)
		_assign_removed_mobile_mass(removals, transfer_q)
		var donor_compaction_q := _weighted_removed_compaction_q(removals)
		_assign_added_cell_mass(additions, transfer_q)
		for addition in additions:
			addition["incoming_compaction_q"] = donor_compaction_q
		material_stage = material_field.stage_mobile_transfer(removals, additions, transfer_q)
		affected_cells = removals + additions
		transaction.requested_mass_q = proposal.requested_mass_q
		transaction.requested_volume_m3 = material_field.loose_volume_for_mass_q(proposal.requested_mass_q)
		transaction.represented_mass_q = transfer_q
		transaction.mass_discretization_tolerance_q = material_field.mass_q_for_loose_volume(pow(_work_zone.voxel_scale_m, 3.0))
		var removed_geometry_q := material_field.mass_q_for_loose_volume(_sum_removed_volume(removals))
		var added_geometry_q := _sum_added_mass_q(additions)
		transaction.mass_discretization_error_q = maxi(
			absi(removed_geometry_q - transfer_q),
			absi(added_geometry_q - transfer_q),
		)
	else:
		return _reject_transaction(transaction, "unsupported_operation", started)
	if not bool(material_stage.get("valid", false)):
		return _reject_transaction(transaction, String(material_stage.get("reason", "material_stage_failed")), started)
	if absi(transaction.mass_discretization_error_q) > transaction.mass_discretization_tolerance_q:
		return _reject_transaction(transaction, "mass_geometry_discretization", started)
	transaction.accepted_mass_q = int(material_stage.get("accepted_mass_q", 0))
	if transaction.accepted_mass_q <= 0:
		return _reject_transaction(transaction, "no_accounted_material", started)
	var can_commit := material_field.can_commit_deposit(material_stage) if proposal.operation == "deposit" \
		else (material_field.can_commit_compaction(material_stage) if proposal.operation == "compact" \
		else material_field.can_commit_mobile_transfer(material_stage))
	if not can_commit:
		return _reject_transaction(transaction, "material_commit_invariant", started)
	transaction.accepted_volume_m3 = transaction.requested_volume_m3 if proposal.operation == "compact" \
		else material_field.loose_volume_for_mass_q(transaction.accepted_mass_q)
	transaction.affected_cells = affected_cells.size()
	transaction.affected_samples = _changed_sample_count(original, final_values)
	_write_values(buffer, size, final_values)
	transaction.post_sdf_digest = _digest_values(final_values)
	if transaction.post_sdf_digest == transaction.pre_sdf_digest:
		return _reject_transaction(transaction, "unchanged_sdf_digest", started)
	var pre_hit_y := _ray_surface_y(proposal.deposit_world)
	_tool.paste(origin, buffer, SDF_CHANNEL_MASK)
	if proposal.operation == "deposit":
		material_field.commit_deposit(material_stage)
	elif proposal.operation == "compact":
		material_field.commit_compaction(material_stage)
	else:
		material_field.commit_mobile_transfer(material_stage)
	data_revision += 1
	transaction.revision = data_revision
	transaction.commit_usec = Time.get_ticks_usec() - started
	_committed_count += 1
	_operation_counts[proposal.operation] = int(_operation_counts.get(proposal.operation, 0)) + 1
	_affected_samples_total += transaction.affected_samples
	_affected_cells_total += transaction.affected_cells
	_commit_usec_total += transaction.commit_usec
	_commit_usec_max = maxi(_commit_usec_max, transaction.commit_usec)
	if proposal.operation in ["deposit", "settle"]:
		_enqueue_settle_cells(affected_cells)
	if proposal.operation == "deposit":
		_accepted_dump_event_id = transaction.transaction_id
		_dump_release_world = proposal.release_world
		_dump_released_fill_ratio = proposal.release_fill_ratio
	var readiness_started := Time.get_ticks_usec()
	var expected_support := _find_sdf_support_world(proposal.deposit_world)
	_issue_readiness_work(
		edit_area,
		data_revision,
		StringName("voxel_%s" % proposal.operation),
		proposal.deposit_world,
		pre_hit_y,
		"expected",
		(expected_support.get("position", Vector3(0.0, INF, 0.0)) as Vector3).y if bool(expected_support.get("valid", false)) else INF,
	)
	transaction.readiness_issue_usec = Time.get_ticks_usec() - readiness_started
	var commit_before_readiness := transaction.commit_usec
	transaction.commit_usec = Time.get_ticks_usec() - started
	_commit_usec_total += transaction.commit_usec - commit_before_readiness
	_commit_usec_max = maxi(_commit_usec_max, transaction.commit_usec)
	return transaction


func _commit_native_deposit_proposal(
	proposal: VoxelSoilOperationProposal,
	transaction: VoxelCutTransaction,
	started_usec: int
) -> VoxelCutTransaction:
	var paths := _native_deposit_paths(proposal.shapes)
	if paths.is_empty() or paths.size() > MAX_NATIVE_DEPOSIT_PATHS:
		return _reject_transaction(transaction, "native_deposit_path_budget", started_usec)
	var window := _integer_window_without_halo(proposal.area_voxels)
	var origin := window.get("origin", Vector3i.ZERO) as Vector3i
	var size := window.get("size", Vector3i.ZERO) as Vector3i
	if size.x <= 0 or size.y <= 0 or size.z <= 0:
		return _reject_transaction(transaction, "native_edit_area_empty", started_usec)
	var edit_area := AABB(Vector3(origin), Vector3(size))
	if not _tool.is_area_editable(edit_area):
		return _reject_transaction(transaction, "voxel_area_not_editable", started_usec)
	var phase_started_usec := Time.get_ticks_usec()
	var deposit_coordinates := _native_deposit_coordinates(paths, origin, size)
	transaction.coverage_usec = Time.get_ticks_usec() - phase_started_usec
	transaction.coverage_candidate_count = deposit_coordinates.size()
	if deposit_coordinates.is_empty():
		return _reject_transaction(transaction, "no_deposit_capacity", started_usec)
	var voxel_volume_m3 := pow(_work_zone.voxel_scale_m, 3.0)
	var cell_capacity_q := maxi(1, material_field.mass_q_for_loose_volume(voxel_volume_m3))
	var accepted_target_q := mini(
		mini(proposal.requested_mass_q, material_field.bucket_mass_q),
		deposit_coordinates.size() * cell_capacity_q,
	)
	if accepted_target_q <= 0:
		return _reject_transaction(transaction, "bucket_empty", started_usec)
	var deposit_changes: Array[Dictionary] = []
	var remaining_q := accepted_target_q
	for coordinate in deposit_coordinates:
		if remaining_q <= 0:
			break
		var cell_mass_q := mini(cell_capacity_q, remaining_q)
		deposit_changes.append({
			"coordinate": coordinate,
			"pre_fraction": 0.0,
			"post_fraction": float(cell_mass_q) / float(cell_capacity_q),
			"cell_volume_m3": voxel_volume_m3,
			"added_volume_m3": material_field.loose_volume_for_mass_q(cell_mass_q),
			"added_mass_q": cell_mass_q,
		})
		remaining_q -= cell_mass_q
	phase_started_usec = Time.get_ticks_usec()
	var material_stage := material_field.stage_deposit(deposit_changes, accepted_target_q)
	if not bool(material_stage.get("valid", false)):
		return _reject_transaction(transaction, String(material_stage.get("reason", "material_stage_failed")), started_usec)
	if not material_field.can_commit_deposit(material_stage):
		return _reject_transaction(transaction, "material_commit_invariant", started_usec)
	transaction.material_usec += Time.get_ticks_usec() - phase_started_usec
	transaction.accounting_mode = "native_sparse_deposit_approximate"
	transaction.requested_mass_q = proposal.requested_mass_q
	transaction.accepted_mass_q = int(material_stage.get("accepted_mass_q", 0))
	transaction.represented_mass_q = transaction.accepted_mass_q
	transaction.capacity_clipped = transaction.accepted_mass_q < proposal.requested_mass_q
	transaction.mass_discretization_error_q = 0
	transaction.mass_discretization_tolerance_q = cell_capacity_q
	transaction.requested_volume_m3 = material_field.loose_volume_for_mass_q(proposal.requested_mass_q)
	transaction.accepted_volume_m3 = material_field.loose_volume_for_mass_q(transaction.accepted_mass_q)
	transaction.coverage_new_count = (material_stage.get("mutations", []) as Array).size()
	transaction.affected_cells = transaction.coverage_new_count
	transaction.affected_samples = deposit_coordinates.size()
	transaction.native_path_count = paths.size()
	phase_started_usec = Time.get_ticks_usec()
	transaction.pre_sdf_digest = _native_sample_digest(deposit_coordinates)
	transaction.digest_usec += Time.get_ticks_usec() - phase_started_usec
	var pre_hit_y := _ray_surface_y(proposal.deposit_world)
	_tool.channel = VoxelBuffer.CHANNEL_SDF
	_tool.mode = VoxelTool.MODE_ADD
	phase_started_usec = Time.get_ticks_usec()
	for path in paths:
		var points := path.get("points_voxels", PackedVector3Array()) as PackedVector3Array
		var radii := path.get("radii_voxels", PackedFloat32Array()) as PackedFloat32Array
		_tool.do_path(points, radii)
	transaction.native_edit_usec = Time.get_ticks_usec() - phase_started_usec
	phase_started_usec = Time.get_ticks_usec()
	transaction.post_sdf_digest = _native_sample_digest(deposit_coordinates)
	transaction.digest_usec += Time.get_ticks_usec() - phase_started_usec
	# Admission and the complete material mutation are frozen before native edit.
	# VoxelTool has no reject/rollback result, so publication has no conditional
	# branch after this point.
	phase_started_usec = Time.get_ticks_usec()
	material_field.commit_deposit(material_stage)
	transaction.material_usec += Time.get_ticks_usec() - phase_started_usec
	data_revision += 1
	transaction.revision = data_revision
	if transaction.capacity_clipped:
		_capacity_clipped_count += 1
	_committed_count += 1
	_native_committed_count += 1
	_native_deposit_committed_count += 1
	_native_path_total += transaction.native_path_count
	_operation_counts["deposit"] = int(_operation_counts.get("deposit", 0)) + 1
	_affected_samples_total += transaction.affected_samples
	_affected_cells_total += transaction.affected_cells
	_accepted_dump_event_id = transaction.transaction_id
	_dump_release_world = proposal.release_world
	_dump_released_fill_ratio = proposal.release_fill_ratio
	phase_started_usec = Time.get_ticks_usec()
	_issue_readiness_work(
		edit_area,
		data_revision,
		&"voxel_deposit_native",
		proposal.deposit_world,
		pre_hit_y,
		"raise",
	)
	transaction.readiness_issue_usec = Time.get_ticks_usec() - phase_started_usec
	transaction.commit_usec = Time.get_ticks_usec() - started_usec
	_commit_usec_total += transaction.commit_usec
	_commit_usec_max = maxi(_commit_usec_max, transaction.commit_usec)
	return transaction


func _native_deposit_paths(shapes: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for shape in shapes:
		if String(shape.get("mode", "")) != "add" or result.size() >= MAX_NATIVE_DEPOSIT_PATHS:
			continue
		var a := shape.get("a_voxels", Vector3.ZERO) as Vector3
		var b := shape.get("b_voxels", a) as Vector3
		var base_radius := float(shape.get("radius_voxels", 0.0))
		if not a.is_finite() or not b.is_finite() or base_radius <= 0.0:
			continue
		if a.is_equal_approx(b):
			b = a + Vector3.UP * maxf(base_radius, DEPOSIT_MIN_RADIUS_VOXELS)
		var points := PackedVector3Array([a, b])
		var radii := PackedFloat32Array([
			base_radius,
			maxf(0.55, base_radius * 0.28),
		])
		result.append({
			"path_id": "native_deposit_%d" % result.size(),
			"role": "repose_mound",
			"points_voxels": points,
			"radii_voxels": radii,
		})
	return result


func _native_deposit_coordinates(
	paths: Array[Dictionary],
	origin: Vector3i,
	size: Vector3i
) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	var probes := 0
	for z in size.z:
		for y in size.y:
			for x in size.x:
				if probes >= MAX_NATIVE_DEPOSIT_PROBES:
					return result
				probes += 1
				var coordinate := origin + Vector3i(x, y, z)
				var point := Vector3(coordinate) + Vector3.ONE * 0.5
				if not _point_inside_native_deposit_paths(point, paths):
					continue
				if _tool.get_voxel_f(coordinate) <= 0.0:
					continue
				result.append(coordinate)
	return result


func _point_inside_native_deposit_paths(point: Vector3, paths: Array[Dictionary]) -> bool:
	for path in paths:
		var points := path.get("points_voxels", PackedVector3Array()) as PackedVector3Array
		var radii := path.get("radii_voxels", PackedFloat32Array()) as PackedFloat32Array
		for segment_index in range(points.size() - 1):
			var a := points[segment_index]
			var b := points[segment_index + 1]
			var segment := b - a
			var length_squared := segment.length_squared()
			var alpha := clampf((point - a).dot(segment) / length_squared, 0.0, 1.0) \
				if length_squared > 0.000001 else 0.0
			var radius := lerpf(radii[segment_index], radii[segment_index + 1], alpha)
			if point.distance_to(a.lerp(b, alpha)) <= radius + 0.5:
				return true
	return false


func _issue_readiness_work(
	edit_area: AABB,
	target_revision: int,
	purpose: StringName,
	probe_world: Vector3,
	pre_hit_y: float,
	query_mode: String,
	expected_hit_y: float = INF
) -> void:
	var merged_area := edit_area
	var merged_existing := true
	while merged_existing:
		merged_existing = false
		for index in range(_readiness_work.size() - 1, -1, -1):
			var existing := _readiness_work[index]
			var existing_area := existing.get("edit_area", AABB()) as AABB
			if existing_area.size == Vector3.ZERO \
					or not _readiness_work_is_compatible(existing, purpose, query_mode, probe_world) \
					or not _areas_share_mesh_block(existing_area, merged_area):
				continue
			merged_area = merged_area.merge(existing_area)
			_readiness_work.remove_at(index)
			_readiness_coalesced_count += 1
			merged_existing = true
	var ticket := _work_zone.issue_edit_ticket(merged_area, purpose)
	_readiness_work.append({
		"kind": String(purpose),
		"edit_area": merged_area,
		"revision": target_revision,
		"ticket": ticket,
		"probe_world": probe_world,
		"pre_hit_y": pre_hit_y,
		"query_mode": query_mode,
		"expected_hit_y": expected_hit_y,
		"meshed_frame": -1,
		"issued_frame": Engine.get_physics_frames(),
	})


func _areas_share_mesh_block(first: AABB, second: AABB) -> bool:
	var first_keys := WorkZoneConfig.mesh_block_keys_for_area(first)
	var second_lookup: Dictionary = {}
	for block_key in WorkZoneConfig.mesh_block_keys_for_area(second):
		second_lookup[block_key] = true
	for block_key in first_keys:
		if second_lookup.has(block_key):
			return true
	return false


func _readiness_work_is_compatible(
	existing: Dictionary,
	purpose: StringName,
	query_mode: String,
	probe_world: Vector3
) -> bool:
	if String(existing.get("kind", "")) != String(purpose) \
			or String(existing.get("query_mode", "")) != query_mode:
		return false
	var existing_probe := existing.get("probe_world", Vector3(INF, INF, INF)) as Vector3
	if not existing_probe.is_finite() or not probe_world.is_finite() or _work_zone == null:
		return false
	return WorkZoneConfig.mesh_block_key(WorkZoneConfig.world_to_voxel(existing_probe, _work_zone.voxel_scale_m)) \
		== WorkZoneConfig.mesh_block_key(WorkZoneConfig.world_to_voxel(probe_world, _work_zone.voxel_scale_m))


func _apply_soil_shapes(values: PackedFloat32Array, size: Vector3i, origin: Vector3i, shapes: Array[Dictionary]) -> int:
	var changed := 0
	var flags := PackedByteArray()
	flags.resize(values.size())
	for shape in shapes:
		var mode := String(shape.get("mode", ""))
		var radius := float(shape.get("radius_voxels", 0.0))
		var influence := radius + 1.0
		var a := shape.get("a_voxels", Vector3.ZERO) as Vector3
		var b := shape.get("b_voxels", a) as Vector3
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
					var shape_sdf := distance - radius
					var next := minf(values[index], shape_sdf) if mode == "add" else maxf(values[index], -shape_sdf)
					next = clampf(next, -1.0, 1.0)
					if absf(next - values[index]) <= 0.000001:
						continue
					values[index] = next
					if flags[index] == 0:
						flags[index] = 1
						changed += 1
	return changed


func _cell_additions(before: PackedFloat32Array, after: PackedFloat32Array, size: Vector3i, origin: Vector3i) -> Array[Dictionary]:
	var changes: Array[Dictionary] = []
	var cell_volume := pow(_work_zone.voxel_scale_m, 3.0)
	for z in range(size.z - 1):
		for y in range(size.y - 1):
			for x in range(size.x - 1):
				var pre := _cell_solid_fraction(before, size, x, y, z)
				var post := _cell_solid_fraction(after, size, x, y, z)
				if post - pre <= 0.000001:
					continue
				changes.append({
					"coordinate": origin + Vector3i(x, y, z),
					"pre_fraction": pre,
					"post_fraction": post,
					"cell_volume_m3": cell_volume,
					"added_volume_m3": (post - pre) * cell_volume,
					"added_mass_q": 0,
				})
	return changes


func _fit_values_to_added_mass(before: PackedFloat32Array, full: PackedFloat32Array, size: Vector3i, origin: Vector3i, target_mass_q: int) -> PackedFloat32Array:
	var low := 0.0
	var high := 1.0
	for _iteration in CAPACITY_SEARCH_STEPS:
		var alpha := (low + high) * 0.5
		var candidate := _blend_values(before, full, alpha)
		var mass_q := _sum_added_mass_q(_cell_additions(before, candidate, size, origin))
		if mass_q <= target_mass_q:
			low = alpha
		else:
			high = alpha
	var low_values := _blend_values(before, full, low)
	var high_values := _blend_values(before, full, high)
	var low_mass_q := _sum_added_mass_q(_cell_additions(before, low_values, size, origin))
	var high_mass_q := _sum_added_mass_q(_cell_additions(before, high_values, size, origin))
	return high_values if absi(high_mass_q - target_mass_q) < absi(low_mass_q - target_mass_q) else low_values


func _fit_values_to_removed_volume(before: PackedFloat32Array, full: PackedFloat32Array, size: Vector3i, origin: Vector3i, target_volume_m3: float) -> PackedFloat32Array:
	var low := 0.0
	var high := 1.0
	for _iteration in CAPACITY_SEARCH_STEPS:
		var alpha := (low + high) * 0.5
		var candidate := _blend_values(before, full, alpha)
		var volume_m3 := _sum_removed_volume(_cell_changes(before, candidate, size, origin))
		if volume_m3 <= target_volume_m3:
			low = alpha
		else:
			high = alpha
	return _blend_values(before, full, low)


func _fit_values_to_removed_mobile_mass(before: PackedFloat32Array, full: PackedFloat32Array, size: Vector3i, origin: Vector3i, target_mass_q: int) -> PackedFloat32Array:
	var low := 0.0
	var high := 1.0
	for _iteration in CAPACITY_SEARCH_STEPS:
		var alpha := (low + high) * 0.5
		var candidate := _blend_values(before, full, alpha)
		var mass_q := _sum_removable_mobile_mass_q(_cell_changes(before, candidate, size, origin))
		if mass_q <= target_mass_q:
			low = alpha
		else:
			high = alpha
	return _blend_values(before, full, low)


func _shapes_for_mode(shapes: Array[Dictionary], mode: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for shape in shapes:
		if String(shape.get("mode", "")) == mode:
			result.append(shape.duplicate(true))
	return result


func _sum_added_mass_q(changes: Array[Dictionary]) -> int:
	var total := 0
	for change in changes:
		total += material_field.mass_q_for_loose_volume(float(change.get("added_volume_m3", 0.0)))
	return total


func _assign_added_cell_mass(changes: Array[Dictionary], target_mass_q: int) -> void:
	var assigned := 0
	for index in changes.size():
		var value := maxi(0, target_mass_q - assigned) if index == changes.size() - 1 else mini(
			material_field.mass_q_for_loose_volume(float(changes[index].get("added_volume_m3", 0.0))),
			maxi(0, target_mass_q - assigned),
		)
		changes[index]["added_mass_q"] = value
		assigned += value


func _sum_removable_mobile_mass_q(changes: Array[Dictionary]) -> int:
	var total := 0
	for change in changes:
		var coordinate := change.get("coordinate", Vector3i.ZERO) as Vector3i
		if material_field.stable_mass_q_at(coordinate) > 0:
			continue
		var represented := material_field.mass_q_for_loose_volume(float(change.get("removed_volume_m3", 0.0)))
		total += mini(material_field.mobile_mass_q_at(coordinate), represented)
	return total


func _assign_removed_mobile_mass(changes: Array[Dictionary], target_mass_q: int) -> void:
	var assigned := 0
	for change in changes:
		var coordinate := change.get("coordinate", Vector3i.ZERO) as Vector3i
		var represented := material_field.mass_q_for_loose_volume(float(change.get("removed_volume_m3", 0.0)))
		var value := mini(
			mini(material_field.mobile_mass_q_at(coordinate), represented),
			maxi(0, target_mass_q - assigned),
		)
		change["removed_mass_q"] = value
		assigned += value
		if assigned >= target_mass_q:
			break


func _weighted_removed_compaction_q(changes: Array[Dictionary]) -> int:
	var weighted := 0
	var total := 0
	for change in changes:
		var removed := maxi(0, int(change.get("removed_mass_q", 0)))
		if removed <= 0:
			continue
		var coordinate := change.get("coordinate", Vector3i.ZERO) as Vector3i
		weighted += removed * material_field.mobile_compaction_q_at(coordinate)
		total += removed
	return int(weighted / total) if total > 0 else MaterialField.LOOSE_COMPACTION_Q


func _mask_removal_to_pure_mobile(before: PackedFloat32Array, after: PackedFloat32Array, size: Vector3i, origin: Vector3i) -> PackedFloat32Array:
	var result := after.duplicate()
	for z in size.z:
		for y in size.y:
			for x in size.x:
				var index := _index(x, y, z, size)
				if absf(before[index] - after[index]) <= 0.000001:
					continue
				var sample := origin + Vector3i(x, y, z)
				var mobile_neighbor := false
				var protected_neighbor := false
				for dz in [-1, 0]:
					for dy in [-1, 0]:
						for dx in [-1, 0]:
							var cell := sample + Vector3i(dx, dy, dz)
							var local_cell := cell - origin
							if local_cell.x < 0 or local_cell.y < 0 or local_cell.z < 0 \
									or local_cell.x >= size.x - 1 or local_cell.y >= size.y - 1 or local_cell.z >= size.z - 1:
								continue
							var cell_solid_fraction := _cell_solid_fraction(
								before, size, local_cell.x, local_cell.y, local_cell.z
							)
							if cell_solid_fraction <= 0.000001:
								continue
							var mobile_mass_q := material_field.mobile_mass_q_at(cell)
							var stable_mass_q := material_field.stable_mass_q_at(cell)
							if mobile_mass_q > 0 and stable_mass_q == 0:
								mobile_neighbor = true
							else:
								protected_neighbor = true
				if not mobile_neighbor or protected_neighbor:
					result[index] = before[index]
	return result


func _enqueue_settle_cells(changes: Array[Dictionary]) -> void:
	for change in changes:
		var coordinate := change.get("coordinate", Vector3i.ZERO) as Vector3i
		if material_field.mobile_mass_q_at(coordinate) <= 0 or material_field.stable_mass_q_at(coordinate) > 0:
			continue
		var key := "%d,%d,%d" % [coordinate.x, coordinate.y, coordinate.z]
		if _settle_frontier_seen.has(key):
			continue
		if _settle_frontier.size() >= MAX_SETTLE_FRONTIER:
			break
		_settle_frontier.append(coordinate)
		_settle_frontier_seen[key] = true


func _build_next_settle_proposal() -> VoxelSoilOperationProposal:
	var examined := 0
	while not _settle_frontier.is_empty() and examined < MAX_SETTLE_CELLS_PER_COMMIT:
		examined += 1
		var donor: Vector3i = _settle_frontier.pop_front()
		_settle_frontier_seen.erase("%d,%d,%d" % [donor.x, donor.y, donor.z])
		var donor_mass_q := material_field.mobile_mass_q_at(donor)
		if donor_mass_q <= 0 or material_field.stable_mass_q_at(donor) > 0:
			continue
		var receiver := _settle_receiver(donor)
		if receiver == donor:
			continue
		var height_delta_m := float(donor.y - receiver.y) * _work_zone.voxel_scale_m
		var horizontal_m := Vector2(float(donor.x - receiver.x), float(donor.z - receiver.z)).length() * _work_zone.voxel_scale_m
		if height_delta_m <= tan(deg_to_rad(REPOSE_ANGLE_DEG)) * horizontal_m:
			continue
		var transfer_q := maxi(1, roundi(float(donor_mass_q) * SETTLE_TRANSFER_FRACTION))
		var donor_center := _solid_point_for_mobile_cell(donor)
		var receiver_center := Vector3(receiver) + Vector3.ONE * 0.5
		var shapes: Array[Dictionary] = [
			{"mode": "remove", "a_voxels": donor_center, "b_voxels": donor_center, "radius_voxels": 0.7},
			{"mode": "add", "a_voxels": receiver_center, "b_voxels": receiver_center, "radius_voxels": 0.7},
		]
		var area := AABB()
		for shape in shapes:
			area = _merge_shape_area(area, shape)
		if not _area_is_editable_world_voxel(area):
			continue
		var proposal := SoilOperationProposal.create({
			"generation": generation,
			"fixed_tick_begin": maxi(0, _last_submitted_tick),
			"fixed_tick_end": maxi(0, _last_submitted_tick),
			"sequence": _next_sequence,
			"model_id": model_id,
			"authority_epoch": "settle:%d" % generation,
			"tool_hash": tool_hash,
			"operation": "settle",
			"area_voxels": area,
			"shapes": shapes,
			"requested_mass_q": transfer_q,
			"release_world": WorkZoneConfig.voxel_to_world(donor_center, _work_zone.voxel_scale_m),
			"deposit_world": WorkZoneConfig.voxel_to_world(receiver_center, _work_zone.voxel_scale_m),
			"quality_flags": ["paired_transfer", "bounded_frontier", "repose_angle"],
		})
		_next_sequence += 1
		return proposal if proposal.is_valid() else null
	return null


func _settle_receiver(donor: Vector3i) -> Vector3i:
	var best := donor
	var best_y := donor.y
	for offset: Vector3i in SETTLE_OFFSETS:
		var neighbor: Vector3i = donor + offset
		var world := WorkZoneConfig.voxel_to_world(Vector3(neighbor) + Vector3(0.5, 4.0, 0.5), _work_zone.voxel_scale_m)
		var support := _find_sdf_support_world(world)
		if not bool(support.get("valid", false)):
			continue
		var support_voxel := WorkZoneConfig.world_to_voxel(support.get("position", Vector3.ZERO) as Vector3, _work_zone.voxel_scale_m)
		var receiver_y := floori(support_voxel.y)
		if receiver_y < best_y:
			best_y = receiver_y
			best = Vector3i(neighbor.x, receiver_y, neighbor.z)
	return best


func _solid_point_for_mobile_cell(coordinate: Vector3i) -> Vector3:
	var best := Vector3(coordinate) + Vector3.ONE * 0.5
	var best_sdf := _tool.get_voxel_f(Vector3i(round(best.x), round(best.y), round(best.z)))
	for z in 2:
		for y in 2:
			for x in 2:
				var point := coordinate + Vector3i(x, y, z)
				var sdf := _tool.get_voxel_f(point)
				if sdf < best_sdf:
					best_sdf = sdf
					best = Vector3(point)
	return best


func _merge_shape_area(current: AABB, shape: Dictionary) -> AABB:
	var a := shape.get("a_voxels", Vector3.ZERO) as Vector3
	var b := shape.get("b_voxels", a) as Vector3
	var radius := float(shape.get("radius_voxels", 0.0)) + 1.0
	var area := AABB(a.min(b) - Vector3.ONE * radius, a.max(b) - a.min(b) + Vector3.ONE * radius * 2.0)
	return area if current.size == Vector3.ZERO else current.merge(area)


func _shape_has_compactable_mobile(shape: Dictionary) -> bool:
	var shape_area := _merge_shape_area(AABB(), shape)
	var minimum := Vector3i(floor(shape_area.position.x), floor(shape_area.position.y), floor(shape_area.position.z))
	var maximum := Vector3i(ceil(shape_area.end.x), ceil(shape_area.end.y), ceil(shape_area.end.z))
	for z in range(minimum.z, maximum.z + 1):
		for y in range(minimum.y, maximum.y + 1):
			for x in range(minimum.x, maximum.x + 1):
				if material_field.is_compactable_mobile_at(Vector3i(x, y, z)):
					return true
	return false


func _area_sample_count(area: AABB) -> int:
	var window := _integer_window(area)
	var size := window.get("size", Vector3i.ZERO) as Vector3i
	if size.x <= 0 or size.y <= 0 or size.z <= 0:
		return 0
	return size.x * size.y * size.z


func _area_is_editable_world_voxel(area: AABB) -> bool:
	var editable := WorkZoneConfig.editable_world_bounds(_work_zone.voxel_scale_m)
	var world_min := WorkZoneConfig.voxel_to_world(area.position, _work_zone.voxel_scale_m)
	var world_max := WorkZoneConfig.voxel_to_world(area.end, _work_zone.voxel_scale_m)
	return editable.has_point(world_min) and editable.has_point(world_max - Vector3.ONE * 0.000001)


func _transaction_id(operation: String, sequence: int, input_hash: String) -> String:
	return "%d:%d:%s:%s" % [generation, sequence, operation, input_hash.left(12)]


func _record_rejected_dump(reason: String, release_world: Vector3, identity: Dictionary) -> void:
	_rejected_dump_event_id = "%d:%d:dump-rejected:%s" % [
		generation,
		int(identity.get("motion_sequence", -1)),
		reason,
	]
	_rejected_dump_world = release_world


func _integer_window(area: AABB) -> Dictionary:
	var bounds := WorkZoneConfig.voxel_bounds(_work_zone.voxel_scale_m)
	var minimum := Vector3i(floor(area.position.x), floor(area.position.y), floor(area.position.z)) - Vector3i.ONE * SDF_HALO_VOXELS
	var maximum := Vector3i(ceil(area.end.x), ceil(area.end.y), ceil(area.end.z)) + Vector3i.ONE * SDF_HALO_VOXELS
	var bounds_min := Vector3i(ceil(bounds.position.x), ceil(bounds.position.y), ceil(bounds.position.z))
	var bounds_max := Vector3i(floor(bounds.end.x), floor(bounds.end.y), floor(bounds.end.z))
	minimum = minimum.max(bounds_min)
	maximum = maximum.min(bounds_max)
	return {"origin": minimum, "size": maximum - minimum}


func _integer_window_without_halo(area: AABB) -> Dictionary:
	var bounds := WorkZoneConfig.voxel_bounds(_work_zone.voxel_scale_m)
	var minimum := Vector3i(floor(area.position.x), floor(area.position.y), floor(area.position.z))
	var maximum := Vector3i(ceil(area.end.x), ceil(area.end.y), ceil(area.end.z))
	var bounds_min := Vector3i(ceil(bounds.position.x), ceil(bounds.position.y), ceil(bounds.position.z))
	var bounds_max := Vector3i(floor(bounds.end.x), floor(bounds.end.y), floor(bounds.end.z))
	minimum = minimum.max(bounds_min)
	maximum = maximum.min(bounds_max)
	return {"origin": minimum, "size": maximum - minimum}


func _native_coverage_coordinates(
	paths: Array[Dictionary],
	origin: Vector3i,
	size: Vector3i
) -> Array[Vector3i]:
	var unique: Dictionary = {}
	var bounds := WorkZoneConfig.voxel_bounds(_work_zone.voxel_scale_m)
	var bounds_min := Vector3i(ceil(bounds.position.x), ceil(bounds.position.y), ceil(bounds.position.z))
	var bounds_max := Vector3i(floor(bounds.end.x), floor(bounds.end.y), floor(bounds.end.z)) - Vector3i.ONE
	for path in paths:
		var points := path.get("points_voxels", PackedVector3Array()) as PackedVector3Array
		var radii := path.get("radii_voxels", PackedFloat32Array()) as PackedFloat32Array
		for segment_index in range(points.size() - 1):
			var a := points[segment_index]
			var b := points[segment_index + 1]
			var distance := a.distance_to(b)
			var steps := maxi(1, ceili(distance / NATIVE_COVERAGE_STEP_VOXELS))
			for step_index in range(steps + 1):
				var alpha := float(step_index) / float(steps)
				var sample := a.lerp(b, alpha)
				var radius := lerpf(radii[segment_index], radii[segment_index + 1], alpha)
				var center := Vector3i(roundi(sample.x), roundi(sample.y), roundi(sample.z))
				for offset in NATIVE_COVERAGE_OFFSETS:
					var coordinate := center + offset
					if coordinate.x < bounds_min.x or coordinate.y < bounds_min.y or coordinate.z < bounds_min.z \
							or coordinate.x > bounds_max.x or coordinate.y > bounds_max.y or coordinate.z > bounds_max.z:
						continue
					if Vector3(coordinate).distance_to(sample) > radius + 0.55:
						continue
					var key := "%d,%d,%d" % [coordinate.x, coordinate.y, coordinate.z]
					if unique.has(key):
						continue
					unique[key] = coordinate
					if unique.size() >= MAX_NATIVE_COVERAGE_PROBES:
						return _solid_coordinates_from_buffer(unique, origin, size)
	return _solid_coordinates_from_buffer(unique, origin, size)


func _solid_coordinates_from_buffer(unique: Dictionary, origin: Vector3i, size: Vector3i) -> Array[Vector3i]:
	var buffer := VoxelBuffer.new()
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	buffer.create(size.x, size.y, size.z)
	_tool.copy(origin, buffer, SDF_CHANNEL_MASK, false)
	var keys := unique.keys()
	keys.sort()
	var result: Array[Vector3i] = []
	for key_value in keys:
		var coordinate := unique[key_value] as Vector3i
		var local := coordinate - origin
		if local.x < 0 or local.y < 0 or local.z < 0 \
				or local.x >= size.x or local.y >= size.y or local.z >= size.z:
			continue
		if buffer.get_voxel_f(local.x, local.y, local.z, VoxelBuffer.CHANNEL_SDF) > 0.0:
			continue
		result.append(coordinate)
		if result.size() >= MAX_NATIVE_COVERAGE_CELLS:
			break
	return result


func _native_sample_digest(coordinates: Array[Vector3i]) -> String:
	var rows: Array[String] = []
	var count := mini(coordinates.size(), NATIVE_DIGEST_SAMPLE_LIMIT)
	for index in count:
		var coordinate := coordinates[index]
		rows.append("%d,%d,%d:%.6f" % [
			coordinate.x,
			coordinate.y,
			coordinate.z,
			_tool.get_voxel_f(coordinate),
		])
	return "|".join(rows).sha256_text()


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
	var current_frame := Engine.get_physics_frames()
	for index in _readiness_work.size():
		var work := _readiness_work[index]
		var ticket := work.get("ticket", {}) as Dictionary
		var ticket_status := _work_zone.get_ticket_status(ticket)
		if bool(ticket_status.get("stale", false)):
			_readiness_retired_stale += 1
			completed.append(index)
			continue
		if current_frame - int(work.get("issued_frame", current_frame)) > READINESS_WORK_TIMEOUT_FRAMES:
			_readiness_timed_out += 1
			_work_zone.retire_ticket(ticket, &"authority_timeout")
			completed.append(index)
			continue
		if int(work.get("meshed_frame", -1)) < 0:
			if _work_zone.poll_ticket_meshed(ticket):
				work["meshed_frame"] = current_frame
				mesh_revision = maxi(mesh_revision, int(work.get("revision", 0)))
			continue
		if current_frame - int(work.get("meshed_frame", 0)) < 2:
			continue
		var pre_hit_y := float(work.get("pre_hit_y", INF))
		var post_hit_y := _ray_surface_y(work.get("probe_world", Vector3.ZERO) as Vector3)
		var query_mode := String(work.get("query_mode", "changed"))
		var query_changed := false
		if query_mode == "lower":
			query_changed = (not is_finite(post_hit_y)) or (is_finite(pre_hit_y) and post_hit_y < pre_hit_y - _work_zone.voxel_scale_m * 0.25)
		elif query_mode == "raise":
			query_changed = is_finite(post_hit_y) and ((not is_finite(pre_hit_y)) or post_hit_y > pre_hit_y + _work_zone.voxel_scale_m * 0.25)
		elif query_mode == "expected":
			var expected_hit_y := float(work.get("expected_hit_y", INF))
			query_changed = (not is_finite(expected_hit_y) and not is_finite(post_hit_y)) \
				or (is_finite(expected_hit_y) and is_finite(post_hit_y) and absf(post_hit_y - expected_hit_y) <= _work_zone.voxel_scale_m * 2.5)
		else:
			query_changed = is_finite(post_hit_y) != is_finite(pre_hit_y) \
				or (is_finite(post_hit_y) and is_finite(pre_hit_y) and absf(post_hit_y - pre_hit_y) > _work_zone.voxel_scale_m * 0.1)
		if query_changed:
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


func _remember_track_receipt(identity: String) -> void:
	_seen_track_receipts[identity] = true
	_seen_track_receipt_order.append(identity)
	while _seen_track_receipt_order.size() > MAX_JOURNAL_ROWS * 2:
		_seen_track_receipts.erase(_seen_track_receipt_order.pop_front())


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

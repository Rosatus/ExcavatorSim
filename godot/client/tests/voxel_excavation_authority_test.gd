extends SceneTree

const Authority = preload("res://scripts/voxel_excavation_authority.gd")
const CutProposal = preload("res://scripts/voxel_cut_proposal.gd")
const MaterialField = preload("res://scripts/voxel_soil_material_field.gd")
const SoilOperationProposal = preload("res://scripts/voxel_soil_operation_proposal.gd")
const WorkZone = preload("res://scripts/voxel_work_zone.gd")
const WorkZoneConfig = preload("res://scripts/voxel_work_zone_config.gd")

const MAX_READY_FRAMES := 1200
const REPRESENTATIVE_COMMIT_BUDGET_USEC := 75000
const EMPTY_TRACK_ADMISSION_ITERATIONS := 180
const EMPTY_TRACK_ADMISSION_BUDGET_USEC := 100000


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures: Array[String] = []
	_check_soil_queue_fairness(failures)
	var zone := WorkZone.new()
	zone.name = "VoxelAuthorityTestZone"
	root.add_child(zone)
	_expect(zone.terrain != null, "work zone runtime is available", failures)
	if zone.terrain != null:
		_expect(await _wait_initial_ready(zone), "initial collision is ready", failures)
		await _check_commit_contract(zone, failures)
		_check_sy135_deep_native_cut(zone, failures)
	zone.queue_free()
	await process_frame
	var cadence_a := await _run_cadence(PackedFloat32Array([0.05]))
	var cadence_b := await _run_cadence(PackedFloat32Array([0.01, 0.01, 0.03]))
	var deterministic_a := cadence_a.duplicate()
	var deterministic_b := cadence_b.duplicate()
	for timing_key in ["commit_usec_max", "coverage_usec", "material_usec", "native_edit_usec", "digest_usec", "readiness_issue_usec"]:
		deterministic_a.erase(timing_key)
		deterministic_b.erase(timing_key)
	_expect(not cadence_a.is_empty() and deterministic_a == deterministic_b, "render cadence preserves transaction/SDF/ledger identity", failures)
	_expect(int(cadence_a.get("peak_queue_depth", 99)) == 1 and int(cadence_a.get("coalesced", 0)) == 2, "overlapping fixed inputs coalesce into one bounded commit", failures)
	_expect(int(cadence_a.get("native_committed", 0)) == 1 and int(cadence_a.get("native_path_count", 0)) > 0, "SY135 commit uses the native path", failures)
	_expect(String(cadence_a.get("accounting_mode", "")) == "sparse_coverage_approximate", "SY135 commit reports approximate sparse coverage accounting", failures)
	_expect(int(cadence_a.get("commit_usec_max", REPRESENTATIVE_COMMIT_BUDGET_USEC + 1)) <= REPRESENTATIVE_COMMIT_BUDGET_USEC, "representative coalesced commit stays inside the focused-test sanity budget", failures)
	if not cadence_a.is_empty():
		print("VOXEL_CUT_PERF %s" % JSON.stringify(cadence_a))
	if failures.is_empty():
		print("Voxel excavation authority contracts passed.")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _check_soil_queue_fairness(failures: Array[String]) -> void:
	var authority := Authority.new()
	for sequence in 3:
		authority._soil_queue.append(_soil_proposal_for_queue_test("deposit", sequence))
	authority._soil_queue.append(_soil_proposal_for_queue_test("compact", 3))
	var first := authority._dequeue_next_soil_proposal()
	var second := authority._dequeue_next_soil_proposal()
	var third := authority._dequeue_next_soil_proposal()
	_expect(first.operation == "deposit" and second.operation == "deposit", "interactive dumps receive bounded queue priority", failures)
	_expect(third.operation == "compact", "continuous dumps cannot starve queued compaction", failures)


func _soil_proposal_for_queue_test(operation: String, sequence: int) -> VoxelSoilOperationProposal:
	return SoilOperationProposal.create({
		"generation": 1,
		"fixed_tick_begin": sequence,
		"fixed_tick_end": sequence,
		"sequence": sequence,
		"model_id": "queue-test",
		"authority_epoch": "queue-test",
		"tool_hash": "queue-test",
		"operation": operation,
		"area_voxels": AABB(Vector3.ZERO, Vector3.ONE),
		"shapes": [{"mode": "remove" if operation == "compact" else "add", "a_voxels": Vector3.ZERO, "b_voxels": Vector3.ZERO, "radius_voxels": 1.0}],
		"requested_mass_q": 1,
		"compaction_delta_q": 1 if operation == "compact" else 0,
		"release_world": Vector3.ZERO,
		"deposit_world": Vector3.ZERO,
	})


func _check_commit_contract(zone: VoxelWorkZone, failures: Array[String]) -> void:
	var descriptor := SoilContractDescriptor.load_for_model("sy205")
	_expect(descriptor != null and descriptor.is_valid_for("sy205"), "sy205 hash-bound contract loads", failures)
	if descriptor == null or not descriptor.is_valid_for("sy205"):
		return
	var contract := descriptor.to_dictionary()
	var authority := Authority.new()
	var generation := zone.readiness.generation
	_expect(authority.configure(zone, contract, generation), "authority configures", failures)
	if not authority.configured:
		return
	var pre_digest := _surface_digest(zone)
	var first_pose := _pose(contract, Vector3(0.0, _bucket_origin_y(contract, -0.03), 18.0), Vector3(0.0, -0.04, 0.06), "commit")
	var cutter_result := authority.cutter.build_proposal(first_pose, generation, 10, 1, "voxel-authority-test", false, authority._sample_sdf_world)
	var committed_proposal := cutter_result.get("proposal") as VoxelCutProposal
	var submission := authority.submit_pose(first_pose, _identity(generation, 10, 1))
	_expect(bool(submission.get("accepted", false)), "valid fixed-tick sweep is queued", failures)
	var result := authority.flush_for_test()
	_expect(bool(result.get("changed", false)), "queued sweep commits", failures)
	var status := authority.get_status_snapshot()
	var transaction := status.get("last_transaction", {}) as Dictionary
	var payload := authority.get_payload_snapshot()
	_expect(int(status.get("data_revision", 0)) == 1, "data revision advances once", failures)
	_expect(int(transaction.get("accepted_mass_q", 0)) > 0, "commit transfers positive mass", failures)
	_expect(String(transaction.get("pre_sdf_digest", "")) != String(transaction.get("post_sdf_digest", "")), "transaction records changed SDF", failures)
	_expect(_surface_digest(zone) != pre_digest, "authoritative SDF changes", failures)
	_expect(int(payload.get("bucket_mass_q", 0)) == int(transaction.get("accepted_mass_q", -1)), "bucket owns accepted mass", failures)
	_expect(int(payload.get("terrain_mass_delta_q", 0)) == -int(payload.get("bucket_mass_q", 0)), "terrain and bucket ledgers balance", failures)
	_expect(int(payload.get("conservation_error_q", 1)) == 0, "fixed-point conservation is exact", failures)
	_expect(String(payload.get("source", "")) == "voxel_bucket_v1", "payload identifies voxel authority", failures)
	_expect(_clearance_is_air(zone, committed_proposal), "accepted constrained clearance contains no authoritative solid", failures)

	var digest_after_commit := _surface_digest(zone)
	var mass_after_commit := int(payload.get("bucket_mass_q", 0))
	var stale := authority.submit_pose(first_pose, _identity(generation, 10, 2))
	_expect(not bool(stale.get("accepted", false)) and String(stale.get("reason", "")) == "stale_tick", "same fixed tick is rejected", failures)
	var stale_generation := authority.submit_pose(first_pose, _identity(generation - 1, 11, 3))
	_expect(not bool(stale_generation.get("accepted", false)) and String(stale_generation.get("reason", "")) == "stale_identity", "stale generation is rejected", failures)
	var repeated_motion := authority.submit_pose(first_pose, _identity(generation, 11, 1))
	_expect(not bool(repeated_motion.get("accepted", false)) and String(repeated_motion.get("reason", "")) == "stale_motion_sequence", "new tick cannot replay an old motion sequence", failures)
	var stationary_origin := Vector3(2.0, _bucket_origin_y(contract, -0.03), 20.0)
	var stationary := authority.submit_pose(
		_pose(contract, stationary_origin, Vector3.ZERO, "stationary"),
		_identity(generation, 12, 4),
	)
	_expect(not bool(stationary.get("accepted", false)) and String(stationary.get("reason", "")) == "stationary", "stationary bucket cannot erase terrain", failures)
	authority.flush_for_test()
	_expect(_surface_digest(zone) == digest_after_commit, "rejected input leaves SDF unchanged", failures)
	_expect(int(authority.get_payload_snapshot().get("bucket_mass_q", -1)) == mass_after_commit, "rejected input leaves mass unchanged", failures)
	var empty_track_revision := authority.data_revision
	var empty_track_accepted := int(authority.get_status_snapshot().get("accepted_proposals", 0))
	var empty_track_started := Time.get_ticks_usec()
	for empty_track_tick in EMPTY_TRACK_ADMISSION_ITERATIONS:
		var empty_track_result := authority.submit_track_compaction({
			"authority_epoch": "stable-ground-admission-test",
			"physics_tick": 1000 + empty_track_tick,
			"terrain_identity_valid": true,
			"terrain_generation": generation,
			"track_contact_receipts": [{
				"point": Vector3(0.0, 0.0, 18.0),
				"support_force_n": 30000.0,
				"support_source": "voxel_terrain",
				"footprint_width_m": 0.7,
			}],
		})
		_expect(
			not bool(empty_track_result.get("accepted", false)) \
				and String(empty_track_result.get("reason", "")) == "no_loose_track_contact",
			"stable-ground track receipt is rejected before staging (%d)" % empty_track_tick,
			failures,
		)
	var empty_track_elapsed := Time.get_ticks_usec() - empty_track_started
	var empty_track_status := authority.get_status_snapshot()
	_expect(authority.data_revision == empty_track_revision, "stable-ground contacts do not mutate voxel data", failures)
	_expect(int(empty_track_status.get("soil_queue_depth", -1)) == 0, "stable-ground contacts never enter the soil queue", failures)
	_expect(int(empty_track_status.get("accepted_proposals", -1)) == empty_track_accepted, "stable-ground contacts do not count as accepted proposals", failures)
	_expect(int(empty_track_status.get("track_compaction_skipped_no_mobile", 0)) == EMPTY_TRACK_ADMISSION_ITERATIONS, "empty loose-soil admission is observable", failures)
	_expect(empty_track_elapsed <= EMPTY_TRACK_ADMISSION_BUDGET_USEC, "empty track admission remains constant-time and inside focused-test budget", failures)
	var dump_pose := _dump_pose(contract, Vector3(6.0, 1.5, 24.0), "dump")
	var dump_submit := authority.submit_pose(dump_pose, _identity(generation, 13, 5), 1.0 / 60.0)
	_expect(bool(dump_submit.get("accepted", false)) and String(dump_submit.get("operation", "")) == "dump", "valid opening stages an in-zone dump batch", failures)
	var mass_before_batch := int(authority.get_payload_snapshot().get("bucket_mass_q", 0))
	var first_batch_step := authority.step_fixed(0.05)
	_expect(not bool(first_batch_step.get("changed", false)) and int(authority.get_status_snapshot().get("pending_dump_count", 0)) == 1, "deposit remains pending before the 100 ms deadline", failures)
	_expect(int(authority.get_payload_snapshot().get("bucket_mass_q", -1)) == mass_before_batch, "pending deposit does not debit bucket inventory", failures)
	var second_dump_submit := authority.submit_pose(dump_pose, _identity(generation, 14, 6), 1.0 / 60.0)
	_expect(bool(second_dump_submit.get("accepted", false)) and int(authority.get_status_snapshot().get("dump_batch_coalesced_count", 0)) == 1, "same-neighborhood releases coalesce into one pending batch", failures)
	var dump_result := authority.step_fixed(0.05)
	var dump_transaction := dump_result.get("transaction", {}) as Dictionary
	var dump_status := authority.get_status_snapshot()
	_expect(bool(dump_result.get("changed", false)) and String(dump_transaction.get("operation", "")) == "deposit", "deposit commits through the soil authority", failures)
	_expect(String(dump_transaction.get("accounting_mode", "")) == "native_sparse_deposit_approximate" and int(dump_transaction.get("native_path_count", 0)) > 0, "runtime deposit uses the bounded native approximate path", failures)
	_expect(int(dump_transaction.get("batch_wait_usec", 0)) >= 100000, "native deposit records the bounded batch wait", failures)
	_expect(int(authority.get_payload_snapshot().get("bucket_mass_q", mass_after_commit)) < mass_after_commit, "accepted deposit debits bucket inventory", failures)
	_expect(int(authority.get_payload_snapshot().get("conservation_error_q", 1)) == 0, "deposit preserves exact fixed-point conservation", failures)
	_expect(not String(dump_status.get("accepted_dump_event_id", "")).is_empty(), "deposit publishes one stable presentation event", failures)
	_expect(int((dump_status.get("operation_counts", {}) as Dictionary).get("deposit", 0)) == 1, "deposit diagnostic counter advances once", failures)
	print("VOXEL_DUMP_PERF %s" % JSON.stringify({
		"commit_usec": int(dump_transaction.get("commit_usec", -1)),
		"support_query_usec": int(dump_transaction.get("support_query_usec", -1)),
		"batch_wait_usec": int(dump_transaction.get("batch_wait_usec", -1)),
		"coverage_usec": int(dump_transaction.get("coverage_usec", -1)),
		"material_usec": int(dump_transaction.get("material_usec", -1)),
		"native_edit_usec": int(dump_transaction.get("native_edit_usec", -1)),
		"digest_usec": int(dump_transaction.get("digest_usec", -1)),
		"readiness_issue_usec": int(dump_transaction.get("readiness_issue_usec", -1)),
		"accepted_mass_q": int(dump_transaction.get("accepted_mass_q", -1)),
		"conservation_error_q": int(authority.get_payload_snapshot().get("conservation_error_q", -1)),
	}))
	var before_dump_end_mass := int(authority.get_payload_snapshot().get("bucket_mass_q", 0))
	# Keep this release below the small remainder left by the first batch so the
	# dump-end transition, rather than mass exhaustion, owns the flush.
	var dump_end_stage := authority.submit_pose(dump_pose, _identity(generation, 15, 7), 0.001)
	_expect(
		bool(dump_end_stage.get("accepted", false)) and int(authority.get_status_snapshot().get("pending_dump_count", 0)) == 1,
		"a partial release opens a new pending batch (result=%s)" % JSON.stringify(dump_end_stage),
		failures,
	)
	var dump_end_flush := authority.submit_pose(
		_pose(contract, Vector3(2.0, _bucket_origin_y(contract, -0.03), 20.0), Vector3.ZERO, "dump-end"),
		_identity(generation, 16, 8),
	)
	_expect(
		bool(dump_end_flush.get("accepted", false)) and String(dump_end_flush.get("reason", "")) == "dump_end_flushed",
		"leaving the dump gate flushes the pending batch (result=%s)" % JSON.stringify(dump_end_flush),
		failures,
	)
	_expect(int(authority.get_payload_snapshot().get("bucket_mass_q", -1)) == before_dump_end_mass, "dump-end queueing still does not debit before commit", failures)
	var dump_end_commit := authority.flush_for_test()
	_expect(bool(dump_end_commit.get("changed", false)) and int(authority.get_status_snapshot().get("pending_dump_count", -1)) == 0, "dump-end batch commits on the next authority commit", failures)
	_expect(int(authority.get_status_snapshot().get("readiness_coalesced", 0)) > 0, "overlapping native deposits coalesce readiness work", failures)
	var before_outside_mass := int(authority.get_payload_snapshot().get("bucket_mass_q", 0))
	var before_outside_revision := authority.data_revision
	var outside_submit := authority.submit_pose(_dump_pose(contract, Vector3(30.0, 1.5, 24.0), "outside-dump"), _identity(generation, 17, 9), 1.0 / 60.0)
	_expect(
		not bool(outside_submit.get("accepted", false)) and String(outside_submit.get("reason", "")) == "dump_out_of_zone",
		"out-of-zone dump rejects before queueing (result=%s)" % JSON.stringify(outside_submit),
		failures,
	)
	_expect(int(authority.get_payload_snapshot().get("bucket_mass_q", -1)) == before_outside_mass and authority.data_revision == before_outside_revision, "out-of-zone dump changes neither inventory nor SDF revision", failures)
	_expect(not String(authority.get_status_snapshot().get("rejected_dump_event_id", "")).is_empty(), "out-of-zone dump publishes deduplicated feedback identity", failures)
	var mobile_before_settle := authority.material_field.total_mobile_mass_q()
	var stable_before_settle := _stable_mass_snapshot(authority.material_field)
	var settle_before := int((authority.get_status_snapshot().get("operation_counts", {}) as Dictionary).get("settle", 0))
	for _iteration in 16:
		authority.flush_for_test()
	var settled_status := authority.get_status_snapshot()
	_expect(int((settled_status.get("operation_counts", {}) as Dictionary).get("settle", 0)) == settle_before, "native repose mound does not start continuous settle work", failures)
	_expect(int(settled_status.get("settle_frontier_depth", -1)) == 0, "native deposit leaves no active settle frontier", failures)
	_expect(int(authority.get_payload_snapshot().get("conservation_error_q", 1)) == 0, "native repose mound preserves exact ledger conservation", failures)
	_expect(authority.material_field.total_mobile_mass_q() == mobile_before_settle, "idle frames preserve aggregate native-deposit mass", failures)
	_expect(not _stable_mass_regressed(authority.material_field, stable_before_settle), "native deposition never consumes previously accounted stable ground", failures)
	var mobile_cells: Array[Dictionary] = []
	for mobile_value in authority.material_field.mobile_cells_snapshot(128):
		var candidate_mobile := mobile_value as Dictionary
		if int(candidate_mobile.get("stable_mass_q", 0)) == 0:
			if mobile_cells.is_empty() or (candidate_mobile.get("coordinate", Vector3i.ZERO) as Vector3i).y \
					> ((mobile_cells[0] as Dictionary).get("coordinate", Vector3i.ZERO) as Vector3i).y:
				mobile_cells = [candidate_mobile]
	_expect(not mobile_cells.is_empty(), "native repose pile retains mobile material", failures)
	if not mobile_cells.is_empty():
		var mobile_coordinate := (mobile_cells[0] as Dictionary).get("coordinate", Vector3i.ZERO) as Vector3i
		var contact_voxel := authority._solid_point_for_mobile_cell(mobile_coordinate)
		var contact_world := WorkZoneConfig.voxel_to_world(contact_voxel, zone.voxel_scale_m)
		_expect(await _wait_authority_ready(authority, zone, contact_world), "deposit/settle collision becomes query-ready", failures)
		var stale_compaction := authority.submit_track_compaction({
			"authority_epoch": "track-compaction-test",
			"physics_tick": 28,
			"terrain_identity_valid": true,
			"terrain_generation": generation - 1,
			"track_contact_receipts": [],
		})
		_expect(not bool(stale_compaction.get("accepted", false)) and String(stale_compaction.get("reason", "")) == "stale_track_identity", "stale terrain identity cannot compact soil", failures)
		var weak_compaction := authority.submit_track_compaction({
			"authority_epoch": "track-compaction-test",
			"physics_tick": 29,
			"terrain_identity_valid": true,
			"terrain_generation": generation,
			"track_contact_receipts": [{
				"point": contact_world,
				"support_force_n": 999.0,
				"support_source": "voxel_terrain",
				"footprint_width_m": 0.7,
			}],
		})
		_expect(not bool(weak_compaction.get("accepted", false)) and String(weak_compaction.get("reason", "")) == "no_loose_track_contact", "sub-threshold contact force cannot compact soil", failures)
		var compaction_submit := authority.submit_track_compaction({
			"authority_epoch": "track-compaction-test",
			"physics_tick": 30,
			"terrain_identity_valid": true,
			"terrain_generation": generation,
			"track_contact_receipts": [{
				"point": contact_world,
				"normal": Vector3.UP,
				"track_side": "left",
				"probe_index": 0,
				"support_force_n": 30000.0,
				"support_source": "voxel_terrain",
				"footprint_width_m": 0.7,
			}],
		})
		_expect(bool(compaction_submit.get("accepted", false)), "accepted voxel track receipt queues compaction", failures)
		var duplicate_compaction := authority.submit_track_compaction({
			"authority_epoch": "track-compaction-test",
			"physics_tick": 30,
			"terrain_identity_valid": true,
			"terrain_generation": generation,
			"track_contact_receipts": [{
				"point": contact_world,
				"support_force_n": 30000.0,
				"support_source": "voxel_terrain",
				"footprint_width_m": 0.7,
			}],
		})
		_expect(not bool(duplicate_compaction.get("accepted", false)) and String(duplicate_compaction.get("reason", "")) == "duplicate_compaction", "one chassis tick cannot replay track compaction", failures)
		var mobile_before_compaction := authority.material_field.total_mobile_mass_q()
		var stable_before_compaction := _stable_mass_snapshot(authority.material_field)
		var compact_before := int((authority.get_status_snapshot().get("operation_counts", {}) as Dictionary).get("compact", 0))
		for _iteration in 8:
			authority.flush_for_test()
			if int((authority.get_status_snapshot().get("operation_counts", {}) as Dictionary).get("compact", 0)) > compact_before:
				break
		_expect(int((authority.get_status_snapshot().get("operation_counts", {}) as Dictionary).get("compact", 0)) > compact_before, "loose-only track compaction commits through the authority", failures)
		_expect(int(authority.get_payload_snapshot().get("conservation_error_q", 1)) == 0, "compaction preserves exact ledger conservation", failures)
		_expect(authority.material_field.total_mobile_mass_q() == mobile_before_compaction, "compaction changes density without deleting mobile mass", failures)
		_expect(not _stable_mass_regressed(authority.material_field, stable_before_compaction), "track compaction never consumes previously accounted stable ground", failures)
		var before_recut_mass := int(authority.get_payload_snapshot().get("bucket_mass_q", 0))
		var mobile_before_recut := authority.material_field.total_mobile_mass_q()
		var stable_before_recut := _stable_mass_snapshot(authority.material_field)
		var cut_before := int((authority.get_status_snapshot().get("operation_counts", {}) as Dictionary).get("cut", 0))
		var recut_radius := 0.45
		var recut_influence := recut_radius + 1.0
		var recut_capsule := {
			"source": "deposited_mobile_recut",
			"a_voxels": contact_voxel,
			"b_voxels": contact_voxel + Vector3(0.0, 0.0, 0.2),
			"radius_voxels": recut_radius,
		}
		var recut_proposal := CutProposal.create({
			"generation": generation,
			"fixed_tick_begin": 40,
			"fixed_tick_end": 40,
			"sequence": 40,
			"model_id": authority.model_id,
			"authority_epoch": "voxel-authority-test",
			"tool_hash": authority.tool_hash,
			"area_voxels": AABB(
				contact_voxel - Vector3.ONE * recut_influence,
				Vector3.ONE * recut_influence * 2.0 + Vector3(0.0, 0.0, 0.2),
			),
			"capsules": [recut_capsule],
			"clearance_capsules": [],
			"probe_world": contact_world,
			"quality_flags": ["deposited_mobile_recut"],
		})
		_expect(recut_proposal.is_valid() and authority._coalesce_or_enqueue(recut_proposal), "settled/compacted pile accepts the authoritative cutter path", failures)
		for _iteration in 8:
			authority.flush_for_test()
			if int((authority.get_status_snapshot().get("operation_counts", {}) as Dictionary).get("cut", 0)) > cut_before:
				break
		_expect(int((authority.get_status_snapshot().get("operation_counts", {}) as Dictionary).get("cut", 0)) > cut_before and int(authority.get_payload_snapshot().get("bucket_mass_q", 0)) > before_recut_mass, "re-cut pile returns mobile mass to the bucket", failures)
		_expect(authority.material_field.total_mobile_mass_q() < mobile_before_recut, "re-cut consumes deposited mobile soil instead of only native ground", failures)
		_expect(not _stable_mass_regressed(authority.material_field, stable_before_recut), "re-cut of the pile leaves previously accounted stable ground unchanged", failures)
		_expect(int(authority.get_payload_snapshot().get("conservation_error_q", 1)) == 0, "full cut/dump/settle/compact/re-cut cycle conserves mass", failures)
		var full_dump_submissions := 0
		while int(authority.get_payload_snapshot().get("bucket_mass_q", 0)) > 0 and full_dump_submissions < 12:
			var deposit_before := int((authority.get_status_snapshot().get("operation_counts", {}) as Dictionary).get("deposit", 0))
			var full_dump_identity := 50 + full_dump_submissions
			var full_dump_world := Vector3(-10.0 + float(full_dump_submissions) * 1.5, 2.0, 25.0)
			var full_dump_submit := authority.submit_pose(
				_dump_pose(contract, full_dump_world, "full-dump:%d" % full_dump_submissions),
				_identity(generation, full_dump_identity, full_dump_identity),
				0.1,
			)
			if not bool(full_dump_submit.get("accepted", false)):
				break
			for _drain in 4:
				authority.flush_for_test()
				if int((authority.get_status_snapshot().get("operation_counts", {}) as Dictionary).get("deposit", 0)) > deposit_before:
					break
			full_dump_submissions += 1
		var full_dump_remaining_q := int(authority.get_payload_snapshot().get("bucket_mass_q", -1))
		_expect(full_dump_submissions > 0 and full_dump_remaining_q == 0, "bounded full-dump sequence debits the complete bucket inventory (submissions=%d remaining_q=%d last=%s)" % [
			full_dump_submissions,
			full_dump_remaining_q,
			JSON.stringify(authority.get_status_snapshot().get("last_transaction", {})),
		], failures)
		_expect(int(authority.get_payload_snapshot().get("conservation_error_q", 1)) == 0, "full dump preserves exact fixed-point conservation", failures)

	authority.clear()
	var limited := Authority.new()
	var limited_capacity_mass_q := 100000
	var limited_capacity_m3 := float(limited_capacity_mass_q) \
		/ (float(contract.get("material_density_kg_m3", 0.0)) * float(MaterialField.MASS_Q_PER_KG))
	_expect(limited.configure(zone, contract, generation, limited_capacity_m3), "capacity-bound authority configures", failures)
	var limited_status := limited.get_status_snapshot()
	_expect(bool(limited_status.get("bucket_capacity_overridden", false)), "authority exposes the capacity override", failures)
	_expect(int(limited_status.get("bucket_capacity_mass_q", -1)) == limited_capacity_mass_q, "authority quantizes the requested capacity exactly", failures)
	var limited_center := Vector3(3.0, _bucket_origin_y(contract, -0.04), 22.0)
	var limited_submit := limited.submit_pose(
		_pose(contract, limited_center, Vector3(0.0, -0.12, 0.18), "capacity"),
		_identity(generation, 20, 20),
	)
	_expect(bool(limited_submit.get("accepted", false)), "capacity test sweep queues", failures)
	var limited_result := limited.flush_for_test()
	var limited_transaction := limited_result.get("transaction", {}) as Dictionary
	_expect(bool(limited_result.get("changed", false)), "capacity-clipped sweep commits", failures)
	_expect(bool(limited_transaction.get("capacity_clipped", false)), "oversized cut is marked capacity-clipped", failures)
	_expect(int(limited.get_payload_snapshot().get("bucket_mass_q", -1)) == limited_capacity_mass_q, "capacity clipping fills exactly to the fixed-point limit", failures)
	var limited_digest := _surface_digest(zone, Vector3(3.0, 0.0, 22.0))
	var full_submit := limited.submit_pose(
		_pose(contract, Vector3(5.0, _bucket_origin_y(contract, -0.04), 22.0), Vector3(0.0, -0.12, 0.18), "full"),
		_identity(generation, 21, 21),
	)
	_expect(bool(full_submit.get("accepted", false)), "full-boundary proposal reaches ordered queue", failures)
	var full_result := limited.flush_for_test()
	_expect(not bool(full_result.get("changed", false)) and String(full_result.get("reason", "")) == "bucket_full", "full bucket rejects deletion", failures)
	_expect(_surface_digest(zone, Vector3(3.0, 0.0, 22.0)) == limited_digest, "full-bucket rejection leaves SDF unchanged", failures)

	var sy135 := SoilContractDescriptor.load_for_model("sy135")
	var switched := sy135 != null
	if switched:
		switched = limited.configure(zone, sy135.to_dictionary(), generation)
	_expect(switched, "model switch reconfigures the sole authority", failures)
	_expect(limited.model_id == "sy135" and int(limited.get_payload_snapshot().get("bucket_mass_q", -1)) == 0, "model switch clears prior bucket inventory", failures)


func _run_cadence(deltas: PackedFloat32Array) -> Dictionary:
	var zone := WorkZone.new()
	zone.name = "CadenceZone"
	root.add_child(zone)
	if zone.terrain == null or not await _wait_initial_ready(zone):
		zone.queue_free()
		await process_frame
		return {}
	var descriptor := SoilContractDescriptor.load_for_model("sy135")
	if descriptor == null or not descriptor.is_valid_for("sy135"):
		zone.queue_free()
		await process_frame
		return {}
	var contract := descriptor.to_dictionary()
	var authority := Authority.new()
	if not authority.configure(zone, contract, zone.readiness.generation):
		zone.queue_free()
		await process_frame
		return {}
	var start := Vector3(-2.0, _bucket_origin_y(contract, -0.04), 20.0)
	var stroke_motion := Vector3(0.1, -0.08, 0.12)
	for index in 3:
		var stroke_start := start + stroke_motion * float(index)
		if not bool(authority.submit_pose(
			_pose(contract, stroke_start, stroke_motion, "cadence:%d" % index),
			_identity(authority.generation, 30 + index, 30 + index),
		).get("accepted", false)):
			zone.queue_free()
			await process_frame
			return {}
	for delta in deltas:
		authority.step_fixed(float(delta))
	var status := authority.get_status_snapshot()
	var transaction := status.get("last_transaction", {}) as Dictionary
	var payload := authority.get_payload_snapshot()
	var result := {
		"post_sdf_digest": String(transaction.get("post_sdf_digest", "")),
		"accepted_mass_q": int(transaction.get("accepted_mass_q", 0)),
		"bucket_mass_q": int(payload.get("bucket_mass_q", 0)),
		"conservation_error_q": int(payload.get("conservation_error_q", 1)),
		"revision": int(status.get("data_revision", 0)),
		"queue_depth": int(status.get("queue_depth", -1)),
		"peak_queue_depth": int(status.get("peak_queue_depth", -1)),
		"coalesced": int(status.get("coalesced", -1)),
		"affected_samples": int(status.get("affected_samples", -1)),
		"affected_cells": int(status.get("affected_cells", -1)),
		"native_committed": int(status.get("native_committed", 0)),
		"native_path_count": int(transaction.get("native_path_count", 0)),
		"accounting_mode": String(transaction.get("accounting_mode", "")),
		"coverage_usec": int(transaction.get("coverage_usec", 0)),
		"material_usec": int(transaction.get("material_usec", 0)),
		"native_edit_usec": int(transaction.get("native_edit_usec", 0)),
		"digest_usec": int(transaction.get("digest_usec", 0)),
		"readiness_issue_usec": int(transaction.get("readiness_issue_usec", 0)),
		"commit_usec_max": int(status.get("commit_usec_max", -1)),
	}
	zone.queue_free()
	await process_frame
	return result


func _check_sy135_deep_native_cut(zone: VoxelWorkZone, failures: Array[String]) -> void:
	var descriptor := SoilContractDescriptor.load_for_model("sy135")
	_expect(descriptor != null and descriptor.is_valid_for("sy135"), "deep native contract is available", failures)
	if descriptor == null or not descriptor.is_valid_for("sy135"):
		return
	var contract := descriptor.to_dictionary()
	var authority := Authority.new()
	_expect(authority.configure(zone, contract, zone.readiness.generation, 1000.0), "deep native authority configures", failures)
	var start := Vector3(6.0, _bucket_origin_y(contract, -1.1), 32.0)
	var submission := authority.submit_pose(
		_pose(contract, start, Vector3(0.08, -0.12, 0.18), "deep-native"),
		_identity(authority.generation, 90, 90),
	)
	_expect(bool(submission.get("accepted", false)), "deep native pose is accepted", failures)
	if not bool(submission.get("accepted", false)):
		return
	var commit := authority.flush_for_test()
	var transaction := commit.get("transaction", {}) as Dictionary
	_expect(bool(commit.get("changed", false)), "deep native cut commits", failures)
	var native_path_count := int(transaction.get("native_path_count", 0))
	_expect(native_path_count > 0 and native_path_count <= 4, "deep native cut uses a bounded path set", failures)
	_expect(int(transaction.get("overburden_path_count", 0)) == 1, "deep native cut executes overburden cleanup", failures)
	_expect(String(transaction.get("accounting_mode", "")) == "sparse_coverage_approximate", "deep native cut uses approximate accounting", failures)
	_expect(String(transaction.get("pre_sdf_digest", "")) != String(transaction.get("post_sdf_digest", "")), "deep native cut changes sampled SDF", failures)


func _wait_initial_ready(zone: VoxelWorkZone) -> bool:
	for _frame in MAX_READY_FRAMES:
		if zone.readiness.is_ready(zone.initial_ticket):
			return true
		await physics_frame
	return false


func _wait_authority_ready(authority: VoxelExcavationAuthority, zone: VoxelWorkZone, point: Vector3) -> bool:
	for _frame in MAX_READY_FRAMES:
		authority._poll_readiness()
		if zone.is_support_ready_at(point):
			return true
		await physics_frame
	return false


func _pose(contract: Dictionary, start: Vector3, motion: Vector3, identity: String) -> Dictionary:
	var tool := BucketSoilTool.new()
	if not tool.configure(contract):
		return {}
	var previous := Transform3D(Basis.IDENTITY, start)
	var current := Transform3D(Basis.IDENTITY, start + motion)
	return {
		"valid": true,
		"reason": "ok",
		"model_id": String(contract.get("model_id", "")),
		"soil_tool": tool.compose_snapshot(previous, current, true, identity),
		"contract": contract,
	}


func _identity(generation: int, tick: int, sequence: int) -> Dictionary:
	return {
		"generation": generation,
		"physics_tick": tick,
		"motion_sequence": sequence,
		"authority_epoch": "voxel-authority-test",
	}


func _dump_pose(contract: Dictionary, opening_world: Vector3, identity: String) -> Dictionary:
	return {
		"valid": true,
		"reason": "ok",
		"model_id": String(contract.get("model_id", "")),
		"identity": identity,
		"opening_normal_world": Vector3.DOWN,
		"current": {"opening": Transform3D(Basis.IDENTITY, opening_world)},
		"previous": {"opening": Transform3D(Basis.IDENTITY, opening_world)},
		"contract": contract,
	}


func _bucket_origin_y(contract: Dictionary, desired_edge_y: float) -> float:
	var cutting := (contract.get("proxies", {}) as Dictionary).get("cutting_edge", {}) as Dictionary
	var center := cutting.get("center_godot", [0.0, 0.0, 0.0]) as Array
	return desired_edge_y - float(center[1])


func _surface_digest(zone: VoxelWorkZone, center_world: Vector3 = Vector3(0.0, 0.0, 18.0)) -> String:
	var tool := zone.get_voxel_tool()
	var center_value := WorkZoneConfig.world_to_voxel(center_world, zone.voxel_scale_m)
	var center := Vector3i(roundi(center_value.x), roundi(center_value.y), roundi(center_value.z))
	var rows := PackedFloat32Array()
	for z in range(center.z - 12, center.z + 13, 2):
		for x in range(center.x - 24, center.x + 25, 4):
			for y in range(center.y - 8, center.y + 5):
				rows.append(tool.get_voxel_f(Vector3i(x, y, z)))
	return rows.to_byte_array().hex_encode().sha256_text()


func _stable_mass_snapshot(field: VoxelSoilMaterialField) -> Dictionary:
	var result: Dictionary = {}
	for value in field.all_cells_snapshot(4096):
		var state := value as Dictionary
		var coordinate := state.get("coordinate", Vector3i.ZERO) as Vector3i
		result["%d,%d,%d" % [coordinate.x, coordinate.y, coordinate.z]] = int(state.get("stable_mass_q", 0))
	return result


func _stable_mass_regressed(field: VoxelSoilMaterialField, baseline: Dictionary) -> bool:
	for value in field.all_cells_snapshot(4096):
		var state := value as Dictionary
		var coordinate := state.get("coordinate", Vector3i.ZERO) as Vector3i
		var key := "%d,%d,%d" % [coordinate.x, coordinate.y, coordinate.z]
		if baseline.has(key) and int(state.get("stable_mass_q", 0)) < int(baseline[key]):
			return true
	return false


func _clearance_is_air(zone: VoxelWorkZone, proposal: VoxelCutProposal) -> bool:
	if proposal == null or proposal.clearance_capsules.is_empty():
		return false
	var tool := zone.get_voxel_tool()
	for capsule in proposal.clearance_capsules:
		var a := capsule.get("a_voxels", Vector3.ZERO) as Vector3
		var b := capsule.get("b_voxels", Vector3.ZERO) as Vector3
		for alpha in [0.0, 0.5, 1.0]:
			var point := a.lerp(b, float(alpha))
			var coordinate := Vector3i(roundi(point.x), roundi(point.y), roundi(point.z))
			if tool.get_voxel_f(coordinate) < -0.001:
				return false
	return true


func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append("voxel authority: %s" % message)

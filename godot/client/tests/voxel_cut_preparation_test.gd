extends "res://tests/voxel_excavation_authority_test.gd"

class BudgetAuthority extends VoxelExcavationAuthority:
	var frame_token := 0
	var drain_in_step := false
	var slices := 0

	func _preparation_frame_id() -> int:
		return frame_token

	func step_fixed(delta: float) -> Dictionary:
		frame_token += 1
		var result := super.step_fixed(delta)
		if drain_in_step:
			for slice_index in 1000:
				if _preparing_cut == null:
					break
				frame_token += 1
				result = super.step_fixed(0.0)
				slices += 1
		return result


func _run() -> void:
	var failures: Array[String] = []
	var reference := await _run_cadence(PackedFloat32Array([0.05]))
	var budgeted := BudgetAuthority.new()
	budgeted.cut_preparation_budget_usec = 250
	budgeted.drain_in_step = true
	var prepared := await _run_cadence(PackedFloat32Array([0.05]), true, budgeted)
	for key in ["commit_usec_max", "coverage_usec", "material_usec", "native_edit_usec", "digest_usec", "readiness_issue_usec"]:
		reference.erase(key)
		prepared.erase(key)
	_expect(not reference.is_empty() and prepared == reference, "sliced publication preserves full SDF digest, mass, revision, queue and proposal identity", failures)
	_expect(budgeted.slices > 1, "representative cut spans multiple budgeted frames", failures)
	_check_bounded_queue(failures)
	await _check_lifecycle(failures)
	await _check_recorded_equivalence(failures)
	await _check_threaded_cancellation(failures)
	await _check_threaded_publication(failures)
	for failure in failures:
		push_error(failure)
	print("CUT_PREPARATION failures=%d slices=%d" % [failures.size(),budgeted.slices])
	quit(0 if failures.is_empty() else 1)


func _check_lifecycle(failures: Array[String]) -> void:
	var zone := WorkZone.new()
	root.add_child(zone)
	_expect(await _wait_initial_ready(zone), "lifecycle zone ready", failures)
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	var authority := BudgetAuthority.new()
	authority.cut_preparation_budget_usec = 100
	authority.configure(zone, contract, zone.readiness.generation)
	var start := Vector3(6, _bucket_origin_y(contract,-1.1),32)
	authority.submit_pose(_pose(contract,start,Vector3(0.08,-0.12,0.18),"life"),_identity(authority.generation,30,30))
	authority.step_fixed(0.05)
	_expect(authority._preparing_cut != null and authority.data_revision == 0 and authority.material_field.bucket_mass_q == 0, "preparation does not publish SDF revision or bucket mass",failures)
	var spent := authority._preparation_spent_usec
	var coverage := authority._cut_preparation.coverage_usec
	for tick in 8:
		authority._advance_preparing_cut()
	_expect(authority._preparation_spent_usec == spent and authority._cut_preparation.coverage_usec == coverage, "eight catchup calls cannot replenish a frame's preparation budget",failures)
	for frame in 1000:
		if authority._cut_preparation.buffer != null:
			break
		authority.step_fixed(0)
	_expect(authority._cut_preparation != null and authority._cut_preparation.buffer != null, "snapshot prepared before publication",failures)
	# Simulate another authoritative mutation. The old snapshot must be discarded.
	authority.data_revision += 1
	authority.step_fixed(0)
	_expect(authority._preparation_restarts == 1 and authority._preparation_revision == authority.data_revision, "changed terrain revision restarts old snapshot",failures)
	authority.clear()
	_expect(authority._preparing_cut == null and authority._cut_preparation == null, "generation teardown drops uncommitted private work",failures)
	_expect(not bool(authority.step_fixed(0.05).get("changed",false)), "cancelled work cannot publish after reset",failures)
	zone.queue_free()
	await process_frame


func _check_recorded_equivalence(failures: Array[String]) -> void:
	# Replay both executors against fresh terrain. Drain at the same physical
	# boundary so the geometry oracle compares identical inputs and coalescing.
	var results: Array[Dictionary] = []
	for choice in 3:
		var zone := WorkZone.new()
		root.add_child(zone)
		_expect(await _wait_initial_ready(zone), "recorded comparison zone ready",failures)
		var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
		var authority: VoxelExcavationAuthority = Authority.new() if choice == 0 else BudgetAuthority.new()
		if choice > 0:
			authority.cut_preparation_budget_usec = 500
			authority.drain_in_step = choice == 1
			authority.threaded_cut_preparation = choice == 2
		authority.configure(zone,contract,zone.readiness.generation)
		var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/sy135_live_residual_trajectory.json"))
		var previous := Transform3D.IDENTITY
		var journal: Array = []
		for row in fixture.frames:
			var tr := Transform3D(Basis(Vector3(row[4],row[5],row[6]),Vector3(row[7],row[8],row[9]),Vector3(row[10],row[11],row[12])),Vector3(row[1],row[2],row[3]))
			if previous == Transform3D.IDENTITY: previous = tr
			var tick := int(row[0])
			authority.submit_pose(_pose_from_transforms(contract,previous,tr,"live-%d"%tick),_identity(authority.generation,tick,tick))
			var result := authority.step_fixed(1.0/60.0)
			if choice == 2:
				var deadline := Time.get_ticks_msec() + 3000
				while authority.has_pending_cut_preparation() and Time.get_ticks_msec() < deadline:
					await process_frame
					result = authority.step_fixed(0.0)
				_expect(not authority.has_pending_cut_preparation(), "worker finishes without blocking a frame", failures)
			if result.has("transaction"):
				var tx: Dictionary = result.transaction
				journal.append([tx.input_hash,tx.accepted_mass_q,tx.rejection_reason])
			previous = tr
		for drain in 12: authority.flush_for_test()
		var buffer := VoxelBuffer.new()
		buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF,VoxelBuffer.DEPTH_16_BIT)
		buffer.create(70,50,80)
		zone.get_voxel_tool().copy(Vector3i(-70,-40,-120),buffer,Authority.SDF_CHANNEL_MASK,false)
		results.append({"sdf":buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF),"journal":journal,"mass":authority.material_field.bucket_mass_q,"revision":authority.data_revision})
		_expect(authority.material_field.conservation_error_q == 0, "recorded mass balance",failures)
		authority.clear()
		zone.queue_free()
		await process_frame
	_expect(results[0] == results[1] and results[0] == results[2], "421-frame recorded trajectory preserves complete SDF bytes, journal, stock and revision",failures)


func _check_bounded_queue(failures: Array[String]) -> void:
	var authority := BudgetAuthority.new()
	authority.cut_preparation_budget_usec = 100
	var accepted := 0
	for tick in 40:
		var proposal := CutProposal.create({
			"generation": 1, "fixed_tick_begin": tick, "fixed_tick_end": tick,
			"sequence": tick, "model_id": "sy135", "authority_epoch": "test", "tool_hash": "test",
			"area_voxels": AABB(Vector3.ZERO,Vector3.ONE*4),
			"native_paths": [{"path_id":"edge", "role":"cut", "points_voxels":PackedVector3Array([Vector3.ZERO,Vector3.ONE]),"radii_voxels":PackedFloat32Array([1,1])}],
		})
		# Match queue identity without needing a scene; the active job uses one slot.
		authority.generation = 1
		authority.model_id = "sy135"
		authority.tool_hash = "test"
		if tick == 0:
			authority._preparing_cut = proposal
		elif authority._coalesce_or_enqueue(proposal):
			accepted += 1
	_expect(authority._queue.size() == 11 and accepted == 33, "active plus pending jobs have bounded capacity without losing in-capacity sweeps", failures)
	var expected_tick := 1
	for proposal in authority._queue:
		_expect(proposal.fixed_tick_begin == expected_tick and proposal.fixed_tick_end == expected_tick + 2, "backlog preserves ordered three-tick batches", failures)
		expected_tick += 3


func _check_threaded_cancellation(failures: Array[String]) -> void:
	var zone := WorkZone.new()
	root.add_child(zone)
	_expect(await _wait_initial_ready(zone), "worker cancellation zone ready", failures)
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	var authority := BudgetAuthority.new()
	authority.cut_preparation_budget_usec = 3000
	authority.threaded_cut_preparation = true
	authority.configure(zone, contract, zone.readiness.generation)
	var start := Vector3(6, _bucket_origin_y(contract,-1.1),32)
	authority.submit_pose(_pose(contract,start,Vector3(0.08,-0.12,0.18),"cancel"),_identity(authority.generation,30,30))
	authority.step_fixed(0.05)
	var worker: Node = authority._cut_worker
	_expect(is_instance_valid(worker), "background worker launched", failures)
	authority.clear()
	zone.queue_free()
	var deadline := Time.get_ticks_msec() + 3000
	while is_instance_valid(worker) and Time.get_ticks_msec() < deadline:
		await process_frame
	_expect(not is_instance_valid(worker), "cancelled job is reaped after its world is freed", failures)
	_expect(authority.data_revision == 0 and not authority.has_pending_cut_preparation(), "cancelled worker cannot publish into reset authority", failures)


func _check_threaded_publication(failures: Array[String]) -> void:
	var zone := WorkZone.new()
	root.add_child(zone)
	_expect(await _wait_initial_ready(zone), "publication zone ready", failures)
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	var authority := BudgetAuthority.new()
	authority.cut_preparation_budget_usec = 3000
	authority.threaded_cut_preparation = true
	authority.configure(zone, contract, zone.readiness.generation)
	var start := Vector3(6, _bucket_origin_y(contract,-1.1),32)
	authority.submit_pose(_pose(contract,start,Vector3(0.08,-0.12,0.18),"publish"),_identity(authority.generation,30,30))
	var window := authority._integer_window(authority._queue[0].area_voxels)
	var size := window["size"] as Vector3i
	var before := VoxelBuffer.new()
	before.set_channel_depth(VoxelBuffer.CHANNEL_SDF,VoxelBuffer.DEPTH_16_BIT)
	before.create(size.x,size.y,size.z)
	zone.get_voxel_tool().copy(window.origin,before,Authority.SDF_CHANNEL_MASK,false)
	authority.step_fixed(0.05)
	var worker: Node = authority._cut_worker
	var deadline := Time.get_ticks_msec() + 3000
	while not worker.completed() and Time.get_ticks_msec() < deadline:
		await process_frame
	_expect(worker.completed(), "private worker completes", failures)
	var after := VoxelBuffer.new()
	after.set_channel_depth(VoxelBuffer.CHANNEL_SDF,VoxelBuffer.DEPTH_16_BIT)
	after.create(size.x,size.y,size.z)
	zone.get_voxel_tool().copy(window.origin,after,Authority.SDF_CHANNEL_MASK,false)
	_expect(before.get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF) == after.get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF), "finished private job cannot change visible SDF before publication", failures)
	# The bucket can change while the worker runs. Its result carries geometry,
	# never a stale material stage or capacity reservation.
	var capacity := authority.material_field.mass_q_for_volume(float(contract.heaped_capacity_m3))
	_expect(authority.material_field.credit_bucket_mass_for_test(capacity), "fill bucket while work is pending", failures)
	var result := authority.step_fixed(0.0)
	_expect(bool(result.get("changed",false)), "completed job publishes", failures)
	var tx: Dictionary = result.get("transaction",{})
	_expect(int(tx.get("captured_mass_q",-1)) == 0 and int(tx.get("discarded_mass_q",0)) > 0, "publication uses current full-bucket capacity and overflow sink", failures)
	_expect(authority.material_field.conservation_error_q == 0, "late capacity change preserves mass", failures)
	_expect(not bool(authority.step_fixed(0).get("changed",false)), "completed result is published exactly once", failures)
	authority.clear()
	zone.queue_free()
	await process_frame

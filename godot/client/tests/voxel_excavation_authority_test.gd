extends SceneTree

const Authority = preload("res://scripts/voxel_excavation_authority.gd")
const MaterialField = preload("res://scripts/voxel_soil_material_field.gd")
const WorkZone = preload("res://scripts/voxel_work_zone.gd")
const WorkZoneConfig = preload("res://scripts/voxel_work_zone_config.gd")

const MAX_READY_FRAMES := 1200
const REPRESENTATIVE_COMMIT_BUDGET_USEC := 50000


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures: Array[String] = []
	var zone := WorkZone.new()
	zone.name = "VoxelAuthorityTestZone"
	root.add_child(zone)
	_expect(zone.terrain != null, "work zone runtime is available", failures)
	if zone.terrain != null:
		_expect(await _wait_initial_ready(zone), "initial collision is ready", failures)
		await _check_commit_contract(zone, failures)
	zone.queue_free()
	await process_frame
	var cadence_a := await _run_cadence(PackedFloat32Array([0.05]))
	var cadence_b := await _run_cadence(PackedFloat32Array([0.01, 0.01, 0.03]))
	var deterministic_a := cadence_a.duplicate()
	var deterministic_b := cadence_b.duplicate()
	deterministic_a.erase("commit_usec_max")
	deterministic_b.erase("commit_usec_max")
	_expect(not cadence_a.is_empty() and deterministic_a == deterministic_b, "render cadence preserves transaction/SDF/ledger identity", failures)
	_expect(int(cadence_a.get("peak_queue_depth", 99)) == 1 and int(cadence_a.get("coalesced", 0)) == 2, "overlapping fixed inputs coalesce into one bounded commit", failures)
	_expect(int(cadence_a.get("commit_usec_max", REPRESENTATIVE_COMMIT_BUDGET_USEC + 1)) <= REPRESENTATIVE_COMMIT_BUDGET_USEC, "representative coalesced commit stays inside the 20 Hz window", failures)
	if not cadence_a.is_empty():
		print("VOXEL_CUT_PERF %s" % JSON.stringify(cadence_a))
	if failures.is_empty():
		print("Voxel excavation authority contracts passed.")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


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
		"commit_usec_max": int(status.get("commit_usec_max", -1)),
	}
	zone.queue_free()
	await process_frame
	return result


func _wait_initial_ready(zone: VoxelWorkZone) -> bool:
	for _frame in MAX_READY_FRAMES:
		if zone.readiness.is_ready(zone.initial_ticket):
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

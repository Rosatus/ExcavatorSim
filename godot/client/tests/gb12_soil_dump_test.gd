extends "res://tests/voxel_excavation_authority_test.gd"


func _run() -> void:
	var failures: Array[String] = []
	var zone := WorkZone.new()
	root.add_child(zone)
	_expect(await _wait_initial_ready(zone), "GB12 dump terrain ready", failures)
	var contract: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://resources/attachments/gb12_s50_soil_contract.json"))
	contract.model_id = "sy135"
	var authority := Authority.new()
	var generation := zone.readiness.generation
	_expect(authority.configure(zone, contract, generation), "GB12 authority configures", failures)
	authority.material_field.credit_bucket_mass_for_test(authority.material_field.mass_q_for_volume(0.02))
	var stock := authority.material_field.bucket_mass_q
	var source := Vector3(0, 4, 18)
	var pose := _dump_pose_with_normal(contract, source, Vector3(sqrt(0.96), -0.2, 0), "gb12-shallow-dump")
	for tick in range(1, 9):
		authority.submit_pose(pose, _identity(generation, tick, tick), 0.02)
	_expect(authority.material_field.bucket_mass_q == stock, "pending GB12 dump retains stock", failures)
	var committed := authority.step_fixed(0.1)
	var event: Dictionary = authority.get_visual_snapshot()["accepted_dump_event"]
	_expect(bool(committed.get("release_changed", false)), "GB12 shallow mouth-down commits release", failures)
	_expect(bool(event.get("terrain_stable", false)), "GB12 dump publishes stable terrain event", failures)
	_expect(authority.material_field.bucket_mass_q < stock, "committed GB12 release debits stock", failures)
	_expect(authority.material_field.conservation_error_q == 0, "GB12 release conserves material", failures)
	_expect((event.get("release_world", Vector3.ZERO) as Vector3).is_equal_approx(source), "GB12 release uses its opening source", failures)
	# Closing the mouth cancels uncommitted release; no residual VFX or stock loss.
	pose = _dump_pose_with_normal(contract, source, Vector3.UP, "gb12-retain")
	var held := authority.material_field.bucket_mass_q
	authority.submit_pose(pose, _identity(generation, 9, 9), 0.02)
	authority.step_fixed(0.1)
	_expect(authority.material_field.bucket_mass_q == held, "upward GB12 mouth retains remaining stock", failures)
	authority.clear()
	zone.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("gb12_soil_dump_test: PASS")
	quit(0 if failures.is_empty() else 1)

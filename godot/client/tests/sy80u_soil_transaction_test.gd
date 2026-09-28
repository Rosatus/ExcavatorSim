extends "res://tests/voxel_excavation_authority_test.gd"
## Real native cut -> bucket stock -> retained/committed mouth-based release.


func _run() -> void:
	var failures: Array[String] = []
	var zone := WorkZone.new()
	root.add_child(zone)
	_expect(await _wait_initial_ready(zone), "SY80U terrain ready", failures)
	var descriptor := SoilContractDescriptor.load_for_model("sy80u")
	_expect(descriptor != null and descriptor.is_valid_for("sy80u"), "SY80U contract valid", failures)
	var contract := descriptor.to_dictionary()
	var authority := Authority.new()
	authority.set_diagnostics_enabled(true)
	var generation := zone.readiness.generation
	_expect(authority.configure(zone, contract, generation), "SY80U authority configures", failures)
	var previous := Transform3D(Basis.IDENTITY, Vector3(0, -0.4, 24))
	var current := Transform3D(Basis.IDENTITY, previous.origin + Vector3(0, -0.08, 0.06))
	var pose := _pose_from_transforms(contract, previous, current, "sy80u-native-cut")
	_expect(bool(authority.submit_pose(pose, _identity(generation, 1, 1)).accepted), "native stroke accepted", failures)
	var cut := authority.flush_for_test()
	_expect(bool(cut.get("changed", false)), "native cut commits", failures)
	_expect(int(cut.get("transaction", {}).get("native_path_count", 0)) > 0, "native swept volume used", failures)
	_expect(authority.material_field.bucket_mass_q > 0, "cut captures stock", failures)
	_expect(authority.material_field.conservation_error_q == 0, "cut conserves mass", failures)
	# The rebuilt +Y mouth frame must preserve the ordinary bucket's .5 gate.
	var stock := authority.material_field.bucket_mass_q
	var source := Vector3(0, 3, 24)
	pose = _dump_pose_with_normal(contract, source, Vector3(sqrt(0.84), -0.4, 0), "sy80u-carry")
	for tick in range(2, 10):
		authority.submit_pose(pose, _identity(generation, tick, tick), 0.02)
		authority.step_fixed(0.02)
	_expect(authority.material_field.bucket_mass_q == stock, "shallow ordinary mouth retains soil", failures)
	pose = _dump_pose_with_normal(contract, source, Vector3.DOWN, "sy80u-dump")
	for tick in range(10, 18):
		authority.submit_pose(pose, _identity(generation, tick, tick), 0.02)
	_expect(authority.material_field.bucket_mass_q == stock, "pending dump retains stock", failures)
	var dumped := authority.step_fixed(0.1)
	var event: Dictionary = authority.get_visual_snapshot().accepted_dump_event
	_expect(bool(dumped.get("release_changed", false)), "open mouth commits release", failures)
	_expect(bool(event.get("terrain_stable", false)), "dump deposits stable terrain", failures)
	_expect(authority.material_field.bucket_mass_q < stock, "committed release debits stock", failures)
	_expect(authority.material_field.conservation_error_q == 0, "cut/dump ledger conserves mass", failures)
	_expect((event.get("release_world", Vector3.ZERO) as Vector3).is_equal_approx(source), "release originates at measured opening", failures)
	pose = _dump_pose_with_normal(contract, source, Vector3.UP, "sy80u-closed")
	stock = authority.material_field.bucket_mass_q
	authority.submit_pose(pose, _identity(generation, 18, 18), 0.02)
	authority.step_fixed(0.1)
	_expect(authority.material_field.bucket_mass_q == stock, "closed mouth cancels remaining dump", failures)
	authority.clear()
	zone.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	print("sy80u_soil_transaction_test: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

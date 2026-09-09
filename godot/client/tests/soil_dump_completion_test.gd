extends "res://tests/voxel_excavation_authority_test.gd"


func _run() -> void:
	var failures: Array[String] = []
	var zone := WorkZone.new()
	root.add_child(zone)
	_expect(await _wait_initial_ready(zone), "dump-completion fixture ready", failures)
	var authority := Authority.new()
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	authority.configure(zone, contract, zone.readiness.generation)
	authority.material_field.credit_bucket_mass_for_test(authority.material_field.mass_q_for_volume(0.2))
	var pose := _dump_pose(contract, Vector3(0, 4, 18), "completion")
	var effects := SoilEffects.new()
	effects.excavation_world_path = NodePath()
	root.add_child(effects)
	effects.set_physics_process(false)
	var tail_releases := 0
	var last_release_mass := 0
	for tick in range(1, 401):
		authority.submit_pose(pose, _identity(authority.generation, tick, tick), 0.05)
		var step := authority.step_fixed(0.05)
		var visual := authority.get_visual_snapshot()
		visual["soil_material_lifecycle_mode"] = "voxel"
		visual["material_generation"] = authority.generation
		visual["fill_ratio"] = authority.material_field.visual_fill_ratio()
		effects.apply_visual_snapshot_for_test(visual)
		effects._physics_process(0.05)
		if bool(step.get("release_changed", false)):
			last_release_mass = int((authority.get_visual_snapshot()["accepted_dump_event"] as Dictionary).get("accepted_mass_q", 0))
			if tick > 360:
				tail_releases += 1
	print("DUMP_COMPLETION %s" % JSON.stringify({"tail_releases": tail_releases,
		"last_release_mass_q": last_release_mass, "bucket_mass_q": authority.material_field.bucket_mass_q,
		"conservation_error_q": authority.material_field.conservation_error_q}))
	_expect(tail_releases == 0, "empty-looking bucket must not endlessly relaunch unrepresentable residue", failures)
	_expect(authority.material_field.conservation_error_q == 0, "dump completion preserves all material", failures)
	_expect(authority.material_field.bucket_mass_q < authority._minimum_dump_mass_q(), "only sub-visual residual is retained", failures)
	_expect(effects._active_clods.is_empty() and not effects._flow_particles.emitting,
		"last landing retires airborne clods and flow", failures)
	var stale := authority.get_visual_snapshot()
	stale["soil_material_lifecycle_mode"] = "voxel"
	stale["material_generation"] = authority.generation
	stale["interaction_state"] = "dump"
	stale["flow_volume_m3"] = 0.5
	stale["bucket_pose"] = pose
	var births_before := effects._spawn_sequence
	effects.apply_visual_snapshot_for_test(stale)
	effects._physics_process(0.2)
	_expect(not effects._flow_particles.emitting and effects._spawn_sequence == births_before,
		"stale continuous-flow fields cannot resurrect voxel release", failures)
	var expired_event := (stale["accepted_dump_event"] as Dictionary).duplicate(true)
	expired_event["published_usec"] = Time.get_ticks_usec() - 10000000
	stale["accepted_dump_event"] = expired_event
	var late_effects := SoilEffects.new()
	late_effects.excavation_world_path = NodePath()
	root.add_child(late_effects)
	late_effects.apply_visual_snapshot_for_test(stale)
	_expect(not late_effects._flow_particles.emitting, "late subscriber cannot emit already landed event", failures)
	var small_event := (stale.get("accepted_dump_event", {}) as Dictionary).duplicate(true)
	small_event["event_id"] = "small-visible-release"
	small_event["published_usec"] = Time.get_ticks_usec()
	small_event["accepted_volume_m3"] = authority.material_field.volume_for_mass_q(authority._minimum_dump_mass_q())
	stale["accepted_dump_event"] = small_event
	late_effects.apply_visual_snapshot_for_test(stale)
	_expect(late_effects._flow_particles.amount_ratio < 0.001, "tiny release is not amplified to five-percent flow", failures)
	late_effects._physics_process(0.1)
	_expect(late_effects._active_clods.is_empty(), "tiny released volume cannot spawn large clods", failures)
	late_effects.apply_visual_snapshot_for_test(stale)
	late_effects.advance_release_visual_for_test(0.3)
	_expect(not late_effects._flow_particles.emitting, "small release expires independently of terrain", failures)
	late_effects.queue_free()
	effects.queue_free()
	authority.clear()
	zone.queue_free()
	await process_frame
	if failures.is_empty():
		print("PASS dump completion")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)

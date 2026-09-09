extends "res://tests/voxel_excavation_authority_test.gd"

const Visuals = preload("res://scripts/soil_visual_resources.gd")
const Flight = preload("res://scripts/soil_flight.gd")


func _run() -> void:
	var failures: Array[String] = []
	var zone := WorkZone.new()
	root.add_child(zone)
	_expect(await _wait_initial_ready(zone), "voxel fixture ready", failures)
	var authority := Authority.new()
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	var generation := zone.readiness.generation
	_expect(authority.configure(zone, contract, generation), "authority configures", failures)
	authority.material_field.credit_bucket_mass_for_test(authority.material_field.mass_q_for_volume(0.2))
	var stock := authority.material_field.bucket_mass_q
	var pose := _dump_pose(contract, Vector3(0, 4, 18), "stable-deposit")
	for tick in range(1, 9):
		authority.submit_pose(pose, _identity(generation, tick, tick), 0.02)
	_expect(authority.material_field.bucket_mass_q == stock, "pending dump does not debit inventory", failures)
	var before := _surface_digest(zone)
	var committed := authority.step_fixed(0.1)
	var event := authority.get_visual_snapshot()["accepted_dump_event"] as Dictionary
	_expect(bool(committed.get("changed", false)) and bool(event.get("terrain_stable", false)), "dump commits stable ground directly", failures)
	_expect(_surface_digest(zone) != before and authority.data_revision == 1, "same commit changes authoritative geometry", failures)
	_expect(authority.material_field.total_stable_mass_q() > 0 and authority.material_field.conservation_error_q == 0, "stable deposit conserves mass", failures)
	_expect(not authority.get_visual_snapshot().has("in_flight_mass_q"), "no airborne ledger", failures)
	# VFX is independent of the committed terrain and expires without a landing callback.
	event["published_usec"] = Time.get_ticks_usec()
	_check_visuals(event, failures)
	var deposited := _surface_digest(zone)
	for _tick in 10:
		authority.step_fixed(0.1)
	_expect(_surface_digest(zone) == deposited, "idle does not settle the pile", failures)
	authority.clear()
	zone.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _check_visuals(event: Dictionary, failures: Array[String]) -> void:
	var effects := SoilEffects.new()
	effects.excavation_world_path = NodePath()
	root.add_child(effects)
	var status := {"material_generation": 1, "soil_material_lifecycle_mode": "voxel",
		"accepted_dump_event": event, "dump_gate_active": false, "bucket_pose": {}}
	effects.apply_visual_snapshot_for_test(status)
	_expect(effects._flow_particles.emitting, "committed release survives closed gate in VFX", failures)
	_expect(effects._flow_particles.draw_pass_1 is ArrayMesh, "airborne grains use irregular mesh", failures)
	_expect(effects._flow_particles.draw_pass_1 == Visuals.clod_mesh(Vector3(0.042, 0.036, 0.05)), "grain resources are reused", failures)
	_expect(effects._fill_material.normal_enabled and effects._fill_material.uv1_triplanar, "fill has UV-independent surface detail", failures)
	_expect(not effects._fill_material.uv1_world_triplanar, "moving fill keeps texture in object space", failures)
	var ground := Visuals.surface_material(true)
	_expect(ground.uv1_world_triplanar and ground.albedo_texture == effects._fill_material.albedo_texture, "ground shares soil textures", failures)
	var dust := Visuals.dust_texture().get_image()
	_expect(dust.get_pixel(0, 0).a == 0.0 and dust.get_pixel(32, 32).a > 0.9, "dust has soft transparent edges", failures)
	effects.advance_release_visual_for_test(0.2)
	_expect(not effects._flow_particles.emitting, "released segment stops births within bounded TTL", failures)
	effects.apply_visual_snapshot_for_test(status)
	_expect(not effects._flow_particles.emitting, "same event cannot restart expired flow", failures)
	var next_event := event.duplicate(true)
	next_event["event_id"] = "toggle-test"
	next_event["published_usec"] = Time.get_ticks_usec()
	status["accepted_dump_event"] = next_event
	effects.apply_visual_snapshot_for_test(status)
	effects.set_emission_enabled(false)
	effects.set_emission_enabled(true)
	effects.apply_visual_snapshot_for_test(status)
	_expect(not effects._flow_particles.emitting and effects._active_release_event.is_empty(), "VFX toggling cannot resume an old release", failures)
	var gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	_expect(is_equal_approx(effects._clods[0].gravity_scale * gravity, Flight.GRAVITY), "hero clods share fall gravity", failures)
	effects.clear_for_generation(2)
	_expect(effects._active_release_event.is_empty(), "generation reset clears release presentation", failures)
	effects.queue_free()

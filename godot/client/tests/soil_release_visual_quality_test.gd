extends "res://tests/voxel_excavation_authority_test.gd"

const Visuals = preload("res://scripts/soil_visual_resources.gd")
const Flight = preload("res://scripts/soil_flight.gd")


func _run() -> void:
	var failures: Array[String] = []
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	var field := MaterialField.new()
	field.configure(contract, 1)
	field.credit_bucket_mass_for_test(field.bucket_capacity_mass_q)
	var initial := field.bucket_mass_q
	_expect(field.release_to_flight(initial / 2), "flight admission transfers existing stock", failures)
	_expect(field.remaining_capacity_mass_q() == 0, "flight reserves return capacity", failures)
	_expect(not field.release_to_flight(initial), "flight cannot double spend bucket", failures)
	_expect(field.conservation_error_q == 0, "airborne mass is included in conservation", failures)
	_expect(field.return_from_flight(initial / 2) and field.bucket_mass_q == initial, "rejection restores exact stock", failures)
	_expect(not field.return_from_flight(1), "resolved flight cannot return twice", failures)
	var zone := WorkZone.new()
	root.add_child(zone)
	_expect(await _wait_initial_ready(zone), "voxel fixture ready", failures)
	var authority := Authority.new()
	var generation := zone.readiness.generation
	_expect(authority.configure(zone, contract, generation), "authority configured", failures)
	authority.material_field.credit_bucket_mass_for_test(authority.material_field.mass_q_for_volume(0.2))
	var pose := _dump_pose(contract, Vector3(0.0, 4.0, 18.0), "flight")
	for tick in range(1, 9):
		authority.submit_pose(pose, _identity(generation, tick, tick), 0.02)
	var before := _surface_digest(zone)
	var released := authority.step_fixed(0.1)
	var event := authority.get_visual_snapshot()["accepted_dump_event"] as Dictionary
	_expect(bool(released.get("release_changed", false)) and not event.is_empty(), "release is published before terrain edit", failures)
	_expect(authority.data_revision == 0 and _surface_digest(zone) == before, "release does not grow ground", failures)
	_expect(authority.material_field.in_flight_mass_q > 0, "authority tracks airborne mass", failures)
	var event_id := String(event.get("event_id", ""))
	# Closing the gate cancels pending intake, never soil already in flight.
	authority.submit_pose(_dump_pose_with_normal(contract, Vector3(2, 4, 18), Vector3.UP, "closed"), _identity(generation, 9, 9), 0.02)
	authority.step_fixed(0.1)
	_expect(authority.data_revision == 0, "high dump cannot land immediately after gate closure", failures)
	authority._settle_frontier.append(Vector3i.ZERO)
	authority._prefer_background = true
	var landed := authority.step_fixed(float(event.get("flight_duration_s", 1.0)) + 0.1)
	_expect(bool(landed.get("changed", false)), "airborne release lands after gate closure: %s" % landed.get("reason", ""), failures)
	_expect(String((landed.get("transaction", {}) as Dictionary).get("operation", "")) == "deposit" and authority.data_revision == 1,
		"background work cannot overwrite landing or commit twice in one tick", failures)
	authority._settle_frontier.clear()
	_expect(authority.material_field.in_flight_mass_q == 0 and authority.material_field.conservation_error_q == 0, "landing resolves escrow with conservation", failures)
	_expect(_surface_digest(zone) != before, "landing changes real ground SDF", failures)
	_expect(String(authority.get_visual_snapshot()["accepted_dump_event_id"]) == event_id, "landing does not replay release", failures)
	_check_visuals(event, failures)
	# A changed/invalid receiving surface rejects without losing released mass.
	for tick in range(10, 18):
		authority.submit_pose(pose, _identity(generation, tick, tick), 0.02)
	authority.step_fixed(0.1)
	var stock_before_failure := authority.material_field.bucket_mass_q + authority.material_field.in_flight_mass_q
	var invalid := (authority._flights[0]["proposal"] as VoxelSoilOperationProposal).to_dictionary()
	invalid["release_world"] = Vector3(-100, 4, 18)
	authority._flights[0]["proposal"] = SoilOperationProposal.create(invalid)
	var revision_before_failure := authority.data_revision
	var rejected := authority.step_fixed(Flight.MAX_FLIGHT_S + 0.2)
	_expect(not bool(rejected.get("changed", true)) and authority.data_revision == revision_before_failure,
		"invalid landing cannot edit ground", failures)
	_expect(authority.material_field.bucket_mass_q == stock_before_failure and authority.material_field.in_flight_mass_q == 0,
		"failed landing restores all escrow stock", failures)
	_expect(authority.material_field.conservation_error_q == 0, "failed landing preserves mass", failures)
	# A further released flight is cleared before it can edit a new generation.
	for tick in range(18, 26):
		authority.submit_pose(pose, _identity(generation, tick, tick), 0.02)
	authority.step_fixed(0.1)
	_expect(authority.material_field.in_flight_mass_q > 0, "reset fixture has flight", failures)
	authority.clear()
	_expect(authority.material_field.in_flight_mass_q == 0 and authority._flights.is_empty(), "clear retires flights and escrow", failures)
	_expect(not bool(authority.step_fixed(5.0).get("changed", false)), "cleared flight cannot publish", failures)
	# Low release uses the same path, with a shorter positive arrival interval.
	authority.configure(zone, contract, generation)
	authority.material_field.credit_bucket_mass_for_test(authority.material_field.mass_q_for_volume(0.1))
	var low_pose := _dump_pose(contract, Vector3(0.0, 0.8, 18.0), "low-flight")
	for tick in range(1, 9):
		authority.submit_pose(low_pose, _identity(generation, tick, tick), 0.02)
	var low_release := authority.step_fixed(0.1)
	var low_event := authority.get_visual_snapshot()["accepted_dump_event"] as Dictionary
	_expect(bool(low_release.get("release_changed", false)) and authority.data_revision == 0, "low dump also releases before terrain growth", failures)
	_expect(float(low_event.get("flight_duration_s", 9.0)) < float(event.get("flight_duration_s", 0.0)), "lower dump uses shorter flight time", failures)
	_expect(bool(authority.flush_for_test().get("changed", false)), "low flight lands through same surface path", failures)
	authority.clear()
	zone.queue_free()
	await process_frame
	if failures.is_empty():
		print("PASS soil release timing, mass lifecycle, and visual resources")
	else:
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

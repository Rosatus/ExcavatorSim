extends "res://tests/voxel_excavation_authority_test.gd"

const LegacyCoverage = preload("res://tests/fixtures/legacy_voxel_coverage.gd")
const TIMING_KEYS := ["commit_usec_max", "coverage_usec", "material_usec", "native_edit_usec", "digest_usec", "readiness_issue_usec"]


class StatusSpy extends VoxelExcavationAuthority:
	var status_reads := 0
	var native_digest_reads := 0


	func get_status_snapshot(refresh_diagnostics: bool = false) -> Dictionary:
		status_reads += 1
		return super.get_status_snapshot(refresh_diagnostics)


	func _native_sample_digest(coordinates: Array[Vector3i]) -> String:
		native_digest_reads += 1
		return super._native_sample_digest(coordinates)


func _run() -> void:
	var failures: Array[String] = []
	_check_optional_diagnostics(failures)
	_check_readiness_diagnostic_session(failures)
	for scale_m in WorkZoneConfig.candidate_scales_m():
		await _check_coverage_equivalence(float(scale_m), failures)
	var enabled_spy := StatusSpy.new()
	var disabled_spy := StatusSpy.new()
	var enabled := await _run_cadence(PackedFloat32Array([0.05]), true, enabled_spy)
	var disabled := await _run_cadence(PackedFloat32Array([0.01, 0.01, 0.03]), false, disabled_spy)
	var enabled_result := enabled.duplicate()
	var disabled_result := disabled.duplicate()
	for key in TIMING_KEYS:
		enabled_result.erase(key)
		disabled_result.erase(key)
		_expect(int(disabled.get(key, -1)) == 0, "disabled diagnostic timing is zero: %s" % key, failures)
	for key in ["pre_sdf_digest", "post_sdf_digest"]:
		_expect(String(disabled.get(key, "missing")).is_empty() and not String(enabled.get(key, "")).is_empty(), "native digest is explicitly optional: %s" % key, failures)
		enabled_result.erase(key)
		disabled_result.erase(key)
	_expect(enabled_spy.native_digest_reads == 2 and disabled_spy.native_digest_reads == 0, "off mode skips native diagnostic SDF sampling itself", failures)
	_expect(not enabled.is_empty() and enabled_result == disabled_result, "diagnostic switch preserves real SDF, ledger, queue and cadence outcome", failures)
	_expect(int(enabled.get("commit_usec_max", 0)) > 0, "enabled diagnostics measure a real native commit", failures)
	print("CUTTING_OPTIMIZED %s" % JSON.stringify(enabled))
	if failures.is_empty():
		print("Voxel cutting performance and optional diagnostics passed.")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _check_optional_diagnostics(failures: Array[String]) -> void:
	var authority := StatusSpy.new()
	var transaction := VoxelCutTransaction.new()
	transaction.revision = 1
	transaction.accepted_mass_q = 42
	transaction.commit_usec = 123
	transaction.coverage_usec = 23
	authority._last_transaction = transaction.to_dictionary()
	authority._accepted_dump_event = {"event_id": "release-1", "nested": {"mass_q": 42}}
	var before_visual := authority.get_visual_snapshot()
	_expect(not authority.diagnostics_enabled, "authority diagnostics default off", failures)
	authority._record_proposal_telemetry(0, 99)
	authority._record_transaction_telemetry(transaction)
	var disabled := authority.get_status_snapshot(true)
	for key in ["phase_timings_usec", "allocation_proxies", "voxel_statistics", "readiness"]:
		_expect((disabled.get(key, {}) as Dictionary).is_empty(), "disabled status omits optional aggregation: %s" % key, failures)
	_expect(authority._proposal_timing_usec.snapshot()["recorded_count"] == 0, "disabled proposal sampling performs no records", failures)
	_expect(authority._commit_timing_usec.snapshot()["recorded_count"] == 0, "disabled commit sampling performs no records", failures)

	authority.set_diagnostics_enabled(true)
	authority._record_proposal_telemetry(Time.get_ticks_usec(), 99)
	authority._record_transaction_telemetry(transaction)
	var enabled := authority.get_status_snapshot(true)
	var phases := enabled["phase_timings_usec"] as Dictionary
	_expect((phases["commit"] as Dictionary)["sample_count"] == 1, "enabled commit enters fresh timing window", failures)
	_expect(authority.get_visual_snapshot() == before_visual, "enabling diagnostics preserves visual fields", failures)
	# A cached diagnostic response remains detached and does not sort again.
	(phases["commit"] as Dictionary)["sample_count"] = 999
	var cached := authority.get_status_snapshot()
	_expect(((cached["phase_timings_usec"] as Dictionary)["commit"] as Dictionary)["sample_count"] == 1, "callers cannot mutate cached diagnostics", failures)
	_expect(authority._status_digest_timing_usec.snapshot()["recorded_count"] == 1, "repeated status read reuses the four-Hz diagnostic aggregate", failures)

	var world := ExcavationWorld.new()
	world._voxel_authority = authority
	world._soil_authority_modes.set_requested_mode("voxel")
	world._soil_authority_modes.begin_generation("diagnostic-spy")
	var status_reads := authority.status_reads
	var visual := world.get_soil_visual_snapshot()
	_expect(authority.status_reads == status_reads, "world effects/audio projection never calls full authority status", failures)
	_expect(visual["last_transaction"] == before_visual["last_transaction"], "world visual transaction retains evidence", failures)
	((visual["accepted_dump_event"] as Dictionary)["nested"] as Dictionary)["mass_q"] = 0
	(visual["last_transaction"] as Dictionary)["accepted_mass_q"] = 0
	_expect(authority.get_visual_snapshot() == before_visual, "visual consumers cannot mutate authority state", failures)
	world.free()

	authority.set_diagnostics_enabled(false)
	authority._record_transaction_telemetry(transaction)
	authority.set_diagnostics_enabled(true)
	var fresh := authority.get_status_snapshot(true)
	_expect(((fresh["phase_timings_usec"] as Dictionary)["commit"] as Dictionary)["sample_count"] == 0, "re-enabling excludes old and disabled-period samples", failures)
	_expect(authority.get_visual_snapshot() == before_visual, "switching does not clear last transaction or release event", failures)


func _check_readiness_diagnostic_session(failures: Array[String]) -> void:
	var readiness := VoxelCollisionReadiness.new()
	var area := AABB(Vector3.ZERO, Vector3.ONE * 4.0)
	var ticket := readiness.issue(area, &"disabled")
	readiness.mark_meshed(ticket)
	readiness.acknowledge_query(ticket)
	_expect(readiness.is_point_ready(Vector3.ONE), "disabled diagnostics still publish collision readiness", failures)
	_expect(readiness._mesh_latency_usec.snapshot()["recorded_count"] == 0, "disabled readiness does not sample latency", failures)
	readiness.set_diagnostics_enabled(true)
	var pending := readiness.issue(area, &"pending")
	var revision := readiness.revision
	readiness.set_diagnostics_enabled(false)
	readiness.set_diagnostics_enabled(true)
	_expect(readiness.revision == revision and readiness.is_point_ready(Vector3.ONE), "diagnostic toggle preserves pending block fallback and revision", failures)
	readiness.mark_meshed(pending)
	readiness.acknowledge_query(pending)
	_expect(readiness.is_ready(pending), "pending ticket completes across diagnostic session boundary", failures)
	_expect(readiness._end_to_end_latency_usec.snapshot()["recorded_count"] == 0, "prior-session ticket cannot contaminate fresh latency window", failures)
	var current := readiness.issue(area, &"current")
	readiness.mark_meshed(current)
	readiness.acknowledge_query(current)
	_expect(readiness._end_to_end_latency_usec.snapshot()["recorded_count"] == 1, "current-session ticket contributes latency", failures)


func _check_coverage_equivalence(scale_m: float, failures: Array[String]) -> void:
	var zone := WorkZone.new()
	zone.voxel_scale_m = scale_m
	root.add_child(zone)
	if zone.terrain == null or not await _wait_initial_ready(zone):
		_expect(false, "coverage fixture becomes ready", failures)
		zone.queue_free()
		await process_frame
		return
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	var authority := Authority.new()
	var legacy := LegacyCoverage.new()
	_expect(authority.configure(zone, contract, 1) and legacy.configure(zone, contract, 1), "coverage authorities configure", failures)
	var bounds := WorkZoneConfig.voxel_bounds(scale_m)
	var origin := Vector3i(bounds.position)
	var size := Vector3i(bounds.size)
	var simple: Array[Dictionary] = [_path(Vector3(-12, -2, -12), Vector3(12, -2, 12))]
	simple.append(simple[0].duplicate(true))
	for path_values in [simple, [_path(Vector3(-12, 8, -12), Vector3(12, 8, 12))], []]:
		var paths: Array[Dictionary] = []
		paths.assign(path_values)
		var expected := legacy._native_coverage_coordinates(paths, origin, size)
		_expect(authority._native_coverage_coordinates(paths, origin, size) == expected, "coverage matches legacy for duplicate/air/empty paths", failures)
	_expect(authority._native_coverage_coordinates(simple, Vector3i(-5, -5, -5), Vector3i(10, 10, 10)) \
		== legacy._native_coverage_coordinates(simple, Vector3i(-5, -5, -5), Vector3i(10, 10, 10)), "coverage clips read window identically", failures)
	var boundary: Array[Dictionary] = [_path(bounds.position - Vector3(2, -2, -2), bounds.position + Vector3(5, 2, 2))]
	_expect(authority._native_coverage_coordinates(boundary, origin, size) == legacy._native_coverage_coordinates(boundary, origin, size), "coverage respects negative zone boundary", failures)

	var wide: Array[Dictionary] = []
	var xmin := bounds.position.x + 4
	var xmax := bounds.end.x - 4
	for z in range(int(bounds.position.z) + 4, int(bounds.end.z) - 4, 2):
		wide.append(_path(Vector3(xmin, -10, z), Vector3(xmax, -10, z)))
	var capped := authority._native_coverage_coordinates(wide, origin, size)
	_expect(capped.size() == Authority.MAX_NATIVE_COVERAGE_CELLS, "large fixture reaches solid coverage cap", failures)
	_expect(capped == legacy._native_coverage_coordinates(wide, origin, size), "probe and solid caps retain exact legacy lexical subset", failures)

	var before := authority._native_coverage_coordinates(simple, origin, size)
	var buffer_id := authority._coverage_buffer.get_instance_id()
	var buffer_size := authority._coverage_buffer_size
	_expect(buffer_size.x * buffer_size.y * buffer_size.z < size.x * size.y * size.z, "scratch buffer copies only the candidate bounding box", failures)
	authority._native_coverage_coordinates(simple, origin, size)
	_expect(authority._coverage_buffer.get_instance_id() == buffer_id, "same read shape reuses scratch buffer", failures)
	var tool := zone.get_voxel_tool()
	tool.mode = VoxelTool.MODE_REMOVE
	tool.do_sphere(Vector3(0, -2, 0), 5.0)
	var after := authority._native_coverage_coordinates(simple, origin, size)
	_expect(after != before and after == legacy._native_coverage_coordinates(simple, origin, size), "reused buffer reads fresh SDF after an edit", failures)

	# Same-process paired microbenchmark, with no terrain edits between readers.
	var legacy_times: Array[int] = []
	var optimized_times: Array[int] = []
	for _iteration in 5:
		var started := Time.get_ticks_usec()
		legacy._native_coverage_coordinates(wide, origin, size)
		legacy_times.append(Time.get_ticks_usec() - started)
		started = Time.get_ticks_usec()
		authority._native_coverage_coordinates(wide, origin, size)
		optimized_times.append(Time.get_ticks_usec() - started)
	legacy_times.sort()
	optimized_times.sort()
	print("COVERAGE_COMPARISON %s" % JSON.stringify({"voxel_scale_m": scale_m, "legacy_median_usec": legacy_times[2], "optimized_median_usec": optimized_times[2], "solid_cap": capped.size()}))
	authority.clear()
	_expect(authority._coverage_buffer == null, "generation teardown drops scratch storage", failures)
	zone.queue_free()
	await process_frame


func _path(a: Vector3, b: Vector3) -> Dictionary:
	return {"points_voxels": PackedVector3Array([a, b]), "radii_voxels": PackedFloat32Array([2.0, 2.0])}

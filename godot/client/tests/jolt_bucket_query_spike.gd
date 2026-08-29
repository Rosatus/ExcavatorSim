extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if ProjectSettings.get_setting("physics/3d/physics_engine") != "Jolt Physics":
		return _fail("Jolt Physics is not selected")
	var host := Node3D.new()
	host.name = "BucketQuerySpike"
	root.add_child(host)
	var terrain_world := TerrainWorld.new()
	terrain_world.name = "TerrainWorld"
	host.add_child(terrain_world)
	var terrain_collider := TerrainCollider.new()
	terrain_collider.name = "TerrainCollider"
	terrain_collider.enabled = true
	host.add_child(terrain_collider)
	await process_frame
	var terrain_snapshot := terrain_world.terrain_state.surface_snapshot()
	var collider_started_usec := Time.get_ticks_usec()
	if not terrain_collider.queue_snapshot(terrain_snapshot) or not terrain_collider.apply_pending():
		return _fail("terrain collider fixture failed")
	var collider_apply_usec := Time.get_ticks_usec() - collider_started_usec
	print("jolt_bucket_query_spike: collider apply=%d usec" % collider_apply_usec)
	await physics_frame

	var sweeper := BucketProxySweeper.new()
	if not sweeper.configure("probe", _query_contract(), terrain_collider, 1):
		return _fail("bucket proxy sweeper rejected a valid query contract")
	var child_count_before := host.get_child_count()
	var identity := terrain_collider.get_applied_identity()
	var previous := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.2, 0.0))
	var candidate := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(18.0)), Vector3(0.0, -0.5, 0.0))
	var result := sweeper.sweep(host.get_world_3d(), previous, candidate, identity, 10, "probe-epoch", 1)
	if not bool(result.get("valid", false)):
		failures.append("valid previous-to-candidate query was rejected: %s" % result)
	if float(result.get("accepted_fraction", 1.0)) >= 1.0:
		failures.append("bucket query did not report a blocking travel fraction")
	var contacts := result.get("contacts", []) as Array
	if contacts.is_empty():
		failures.append("bucket query omitted contact evidence")
	else:
		var contact := contacts[0] as Dictionary
		if not contact.has_all(["contact_id", "proxy_role", "travel_fraction", "point_world", "normal_world", "collider_id", "query_source"]):
			failures.append("bucket query contact omitted required identity or geometry")
		elif String(contact["query_source"]) != "terrain_collider":
			failures.append("bucket query accepted a non-authoritative source: %s" % contact["query_source"])
	if host.get_child_count() != child_count_before:
		failures.append("query-only sweep created a scene body")
	var query_durations_usec: Array[int] = []
	for sample_index in 100:
		var started_usec := Time.get_ticks_usec()
		var sampled := sweeper.sweep(
			host.get_world_3d(), previous, candidate, identity, 20 + sample_index,
			"probe-epoch", 20 + sample_index
		)
		query_durations_usec.append(Time.get_ticks_usec() - started_usec)
		if not bool(sampled.get("valid", false)):
			failures.append("performance sample rejected a valid query")
			break
	query_durations_usec.sort()
	var median_usec := query_durations_usec[query_durations_usec.size() / 2]
	var p95_usec := query_durations_usec[min(94, query_durations_usec.size() - 1)]
	print("jolt_bucket_query_spike: query median=%d usec p95=%d usec" % [median_usec, p95_usec])
	if p95_usec > 10000:
		failures.append("bucket query p95 exceeded 10 ms: %d usec" % p95_usec)

	var overlap := sweeper.sweep(
		host.get_world_3d(),
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0)),
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.1, 0.0)),
		identity,
		11,
		"probe-epoch",
		2,
	)
	if bool(overlap.get("valid", true)) or not (overlap.get("quality_flags", []) as Array).has("bucket_query_initial_overlap"):
		failures.append("initial overlap was not surfaced as ineligible evidence")
	if not is_equal_approx(float(overlap.get("accepted_fraction", -1.0)), 1.0):
		failures.append("initial-overlap recovery motion was blocked")
	var deeper_overlap := sweeper.sweep(
		host.get_world_3d(),
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.0)),
		Transform3D(Basis.IDENTITY, Vector3(0.0, -0.1, 0.0)),
		identity,
		12,
		"probe-epoch",
		3,
	)
	if not is_equal_approx(float(deeper_overlap.get("accepted_fraction", -1.0)), 1.0):
		failures.append("deeper initial-overlap recovery motion was blocked")

	var stale := sweeper.sweep(host.get_world_3d(), previous, candidate, Vector2i(identity.x, identity.y + 1), 13, "probe-epoch", 4)
	if bool(stale.get("valid", true)) or not (stale.get("quality_flags", []) as Array).has("bucket_query_terrain_identity_mismatch"):
		failures.append("stale terrain identity did not fail closed")

	host.queue_free()
	await physics_frame
	await physics_frame
	if failures.is_empty():
		print("jolt_bucket_query_spike: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _query_contract() -> Dictionary:
	var box := {"frame": "bucket_link", "center_godot": [0.0, 0.0, 0.0], "size_m": [0.4, 0.4, 0.4]}
	return {
		"schema_version": "excavator-soil-contract-v1",
		"proxies": {
			"cutting_edge": {"frame": "bucket_link", "center_godot": [0.0, 0.0, 0.0], "half_width_m": 0.2},
			"opening": {"frame": "bucket_link", "center_godot": [0.0, 0.0, 0.0], "up_godot": [0.0, 1.0, 0.0], "size_m": [0.4, 0.4]},
			"cavity": box.duplicate(true),
			"shell": box.duplicate(true),
			"rear_support": {"frame": "bucket_link", "center_godot": [0.0, 0.0, 0.0], "radius_m": 0.2},
		},
	}


func _fail(message: String) -> void:
	failures.append(message)
	push_error(message)
	quit(1)

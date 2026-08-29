extends SceneTree

const OUTPUT_ARG := "--output-dir"
const BACKENDS := [TerrainWorld.BACKEND_FALLBACK, TerrainWorld.BACKEND_TERRAIN3D]
const CHECKPOINTS := ["initial", "after_cut", "after_carry", "after_dump"]

var _failures: Array[String] = []
var _evidence := {
	"schema_version": "terrain3d-authority-equivalence-v1",
	"models": {},
}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	for model_id in ["sy205", "sy135"]:
		var runs := {}
		for backend in BACKENDS:
			var result := await _run_backend_journey(model_id, backend)
			runs[backend] = result
			if not bool(result.get("passed", false)):
				_failures.append("%s/%s journey failed: %s" % [model_id, backend, result.get("reason", "unknown")])
		if bool((runs[TerrainWorld.BACKEND_FALLBACK] as Dictionary).get("passed", false)) \
				and bool((runs[TerrainWorld.BACKEND_TERRAIN3D] as Dictionary).get("passed", false)):
			_compare_backend_runs(model_id, runs[TerrainWorld.BACKEND_FALLBACK], runs[TerrainWorld.BACKEND_TERRAIN3D])
		_evidence["models"][model_id] = {
			TerrainWorld.BACKEND_FALLBACK: _evidence_view(runs[TerrainWorld.BACKEND_FALLBACK]),
			TerrainWorld.BACKEND_TERRAIN3D: _evidence_view(runs[TerrainWorld.BACKEND_TERRAIN3D]),
		}
	var product_lifecycle := await _run_product_lifecycle_ab()
	_evidence["product_lifecycle"] = product_lifecycle.get("evidence", {})
	if not bool(product_lifecycle.get("passed", false)):
		_failures.append("product lifecycle A/B failed: %s" % product_lifecycle.get("reason", "unknown"))
	_evidence["passed"] = _failures.is_empty()
	_evidence["failures"] = _failures.duplicate()
	_write_evidence_if_requested()
	if not _failures.is_empty():
		for failure in _failures:
			push_error(failure)
		quit(1)
		return
	print("terrain3d_authority_equivalence_test: PASS")
	quit(0)


func _run_backend_journey(model_id: String, backend: String) -> Dictionary:
	var descriptor := SoilContractDescriptor.load_for_model(model_id)
	if descriptor == null or not descriptor.is_valid_for(model_id):
		return {"passed": false, "reason": "contract_unavailable"}
	var rig := _build_rig(model_id, backend)
	root.add_child(rig["host"])
	await process_frame
	await process_frame
	var world := rig["world"] as TerrainWorld
	var adapter := rig["adapter"] as Terrain3DAdapter
	var collider := rig["collider"] as TerrainCollider
	var source := world.terrain_state
	if source == null:
		await _dispose_rig(rig)
		return {"passed": false, "reason": "terrain_state_unavailable"}
	var scheduler := TerrainCommitScheduler.new(source, world, collider)
	if not scheduler.refresh_derivatives():
		await _dispose_rig(rig)
		return {"passed": false, "reason": "initial_derivative_sync_failed"}
	var patch := ActiveSoilPatch.new()
	if not patch.configure_product(source, scheduler, "balanced", "loose"):
		await _dispose_rig(rig)
		return {"passed": false, "reason": "patch_configure_failed"}
	var authority := SoilInteractionAuthority.new()
	var contract := descriptor.to_dictionary()
	if not authority.configure(contract, source.world_generation, "loose", "active_patch"):
		await _dispose_rig(rig)
		return {"passed": false, "reason": "authority_configure_failed"}
	var tool := BucketSoilTool.new()
	if not tool.configure(contract):
		await _dispose_rig(rig)
		return {"passed": false, "reason": "tool_configure_failed"}

	var checkpoints := {}
	checkpoints["initial"] = _capture_checkpoint(source, authority, world, adapter, collider)
	var identity := tool.compose_snapshot(Transform3D.IDENTITY, Transform3D.IDENTITY, true, "%s:identity" % model_id)
	var teeth_local := _region_sample_point(identity, "teeth_main_edge")
	var cut_snapshot := tool.compose_snapshot(
		Transform3D(Basis.IDENTITY, Vector3(0.0, 0.18 - teeth_local.y, 0.0)),
		Transform3D(Basis.IDENTITY, Vector3(0.0, -0.04 - teeth_local.y, 0.0)),
		true,
		"%s:%s:cut" % [model_id, backend],
	)
	var cut_classification := tool.classify(cut_snapshot, source, 0.0, contract["interaction"] as Dictionary)
	var cut_point := _candidate_point(cut_classification, "cut")
	if not cut_point.is_finite():
		await _dispose_rig(rig)
		return {"passed": false, "reason": "cut_candidate_missing"}
	authority.step_fixed(1.0 / 60.0, 1, cut_snapshot, cut_classification, patch, cut_point)
	checkpoints["after_cut"] = _capture_checkpoint(source, authority, world, adapter, collider)

	var inner_local := _region_center(identity, "inner_shell")
	var carry_transform := Transform3D(Basis.IDENTITY, cut_point - inner_local)
	var carry_snapshot := tool.compose_snapshot(carry_transform, carry_transform, true, "%s:%s:carry" % [model_id, backend])
	var carry_classification := tool.classify(carry_snapshot, source, 0.0, contract["interaction"] as Dictionary)
	authority.step_fixed(1.0 / 60.0, 2, carry_snapshot, carry_classification, patch, cut_point)
	checkpoints["after_carry"] = _capture_checkpoint(source, authority, world, adapter, collider)

	var opening_normal := _region_normal(identity, "opening")
	var dump_basis := Basis(Quaternion(opening_normal, Vector3.DOWN))
	var dump_transform := Transform3D(dump_basis, Vector3(0.0, 1.5, 0.0))
	var dump_snapshot := tool.compose_snapshot(dump_transform, dump_transform, true, "%s:%s:dump" % [model_id, backend])
	for tick in range(3, 243):
		var fill_ratio := float(authority.get_status_snapshot()["fill_ratio"])
		var dump_classification := tool.classify(dump_snapshot, source, fill_ratio, contract["interaction"] as Dictionary)
		authority.step_fixed(1.0 / 60.0, tick, dump_snapshot, dump_classification, patch, dump_transform.origin)
	checkpoints["after_dump"] = _capture_checkpoint(source, authority, world, adapter, collider)

	var final_status := authority.get_status_snapshot()
	if absf(float(final_status["conservation_drift_m3"])) > 0.00001:
		await _dispose_rig(rig)
		return {"passed": false, "reason": "ledger_drift"}
	if int(final_status["invariant_failure_count"]) != 0:
		await _dispose_rig(rig)
		return {"passed": false, "reason": "ledger_invariant_failure"}
	if float(final_status["bucket_volume_m3"]) > 0.00001:
		await _dispose_rig(rig)
		return {"passed": false, "reason": "bucket_not_empty"}
	for checkpoint_name in CHECKPOINTS:
		var checkpoint := checkpoints[checkpoint_name] as Dictionary
		if not bool(checkpoint.get("derivatives_match", false)):
			await _dispose_rig(rig)
			return {"passed": false, "reason": "%s_derivative_identity_mismatch" % checkpoint_name}
		if int(checkpoint.get("visible_surface_count", 0)) != 1:
			await _dispose_rig(rig)
			return {"passed": false, "reason": "%s_visible_surface_count" % checkpoint_name}
		if String(checkpoint.get("configured_backend", "")) != backend \
				or String(checkpoint.get("active_backend", "")) != backend:
			await _dispose_rig(rig)
			return {"passed": false, "reason": "%s_backend_not_active" % checkpoint_name}

	var motion := await _run_jolt_sequence(model_id, rig, world, collider)
	if not bool(motion.get("passed", false)):
		await _dispose_rig(rig)
		return {"passed": false, "reason": motion.get("reason", "motion_failed")}
	var lifecycle := await _exercise_lifecycle(world, adapter, collider, scheduler, backend)
	if not bool(lifecycle.get("passed", false)):
		await _dispose_rig(rig)
		return {"passed": false, "reason": lifecycle.get("reason", "lifecycle_failed")}
	var result := {
		"passed": true,
		"backend": backend,
		"model_id": model_id,
		"checkpoints": checkpoints,
		"journal": authority.get_journal_snapshot(),
		"motion": motion,
		"lifecycle": lifecycle,
	}
	await _dispose_rig(rig)
	return result


func _run_product_lifecycle_ab() -> Dictionary:
	var runs := {}
	for backend in BACKENDS:
		var result := await _run_product_lifecycle_backend(backend)
		runs[backend] = result
		if not bool(result.get("passed", false)):
			return {"passed": false, "reason": "%s_%s" % [backend, result.get("reason", "failed")], "evidence": runs}
	var fallback := runs[TerrainWorld.BACKEND_FALLBACK] as Dictionary
	var native := runs[TerrainWorld.BACKEND_TERRAIN3D] as Dictionary
	for checkpoint_name in ["startup_sy205", "switched_sy135", "reset_sy135"]:
		var fallback_checkpoint := (fallback["checkpoints"] as Dictionary)[checkpoint_name] as Dictionary
		var native_checkpoint := (native["checkpoints"] as Dictionary)[checkpoint_name] as Dictionary
		for field in ["model_id", "world_generation", "terrain_revision", "terrain_epoch", "surface_sha256", "collider_generation", "collider_revision"]:
			if fallback_checkpoint[field] != native_checkpoint[field]:
				return {"passed": false, "reason": "%s_%s_mismatch" % [checkpoint_name, field], "evidence": runs}
	return {"passed": true, "evidence": runs}


func _run_product_lifecycle_backend(backend: String) -> Dictionary:
	var packed := load("res://scenes/main.tscn") as PackedScene
	if packed == null:
		return {"passed": false, "reason": "main_scene_unavailable"}
	var scene := packed.instantiate() as Node3D
	var world := scene.get_node_or_null("TerrainRoot/TerrainWorld") as TerrainWorld
	var client := scene.get_node_or_null("MotionClient") as MotionClient
	if world == null or client == null:
		scene.free()
		return {"passed": false, "reason": "main_scene_contract_missing"}
	world.terrain_backend = backend
	client.auto_connect = false
	client.desired_model_id = "sy205"
	root.add_child(scene)
	await process_frame
	await process_frame
	await physics_frame
	var session := scene.get_node_or_null("ProductSession") as ProductSession
	var presentation := scene.get_node_or_null("MotionPresentation") as MotionPresentation
	var collider := scene.get_node_or_null("TerrainRoot/TerrainCollider") as TerrainCollider
	if session == null or presentation == null or collider == null:
		await _dispose_product_scene(scene, collider)
		return {"passed": false, "reason": "product_nodes_missing"}
	var checkpoints := {
		"startup_sy205": _product_lifecycle_checkpoint(presentation, world, collider),
	}
	if not session.request_start():
		await _dispose_product_scene(scene, collider)
		return {"passed": false, "reason": "start_failed"}
	await physics_frame
	if not session.request_pause():
		await _dispose_product_scene(scene, collider)
		return {"passed": false, "reason": "pause_failed"}
	if not session.request_model_switch("sy135"):
		await _dispose_product_scene(scene, collider)
		return {"passed": false, "reason": "model_switch_failed"}
	await process_frame
	await physics_frame
	checkpoints["switched_sy135"] = _product_lifecycle_checkpoint(presentation, world, collider)
	if not session.request_reset():
		await _dispose_product_scene(scene, collider)
		return {"passed": false, "reason": "reset_failed"}
	await process_frame
	await physics_frame
	checkpoints["reset_sy135"] = _product_lifecycle_checkpoint(presentation, world, collider)
	var expected_models := {
		"startup_sy205": "sy205",
		"switched_sy135": "sy135",
		"reset_sy135": "sy135",
	}
	for checkpoint_name in checkpoints:
		var checkpoint := checkpoints[checkpoint_name] as Dictionary
		if String(checkpoint["model_id"]) != String(expected_models[checkpoint_name]) \
				or String(checkpoint["configured_backend"]) != backend \
				or String(checkpoint["active_backend"]) != backend \
				or int(checkpoint["visible_surface_count"]) != 1 \
				or int(checkpoint["world_generation"]) != int(checkpoint["collider_generation"]) \
				or int(checkpoint["terrain_revision"]) != int(checkpoint["collider_revision"]):
			await _dispose_product_scene(scene, collider)
			return {"passed": false, "reason": "%s_identity_or_backend" % checkpoint_name}
	var result := {"passed": true, "checkpoints": checkpoints}
	await _dispose_product_scene(scene, collider)
	return result


func _product_lifecycle_checkpoint(
	presentation: MotionPresentation,
	world: TerrainWorld,
	collider: TerrainCollider
) -> Dictionary:
	var surface := world.terrain_state.surface_snapshot()
	var world_status := world.get_status_snapshot()
	return {
		"model_id": presentation.get_active_model_id(),
		"world_generation": int(surface["world_generation"]),
		"terrain_revision": int(surface["terrain_revision"]),
		"terrain_epoch": String(surface["terrain_epoch"]),
		"surface_sha256": String(surface["snapshot_sha256"]),
		"configured_backend": String(world_status["configured_backend"]),
		"active_backend": String(world_status["active_backend"]),
		"visible_surface_count": int(world_status["visible_surface_count"]),
		"collider_generation": collider.get_applied_identity().x,
		"collider_revision": collider.get_applied_identity().y,
	}


func _dispose_product_scene(scene: Node3D, collider: TerrainCollider) -> void:
	if collider != null:
		collider.disable_for_test()
	scene.queue_free()
	await process_frame
	await physics_frame


func _run_jolt_sequence(
	model_id: String,
	rig: Dictionary,
	world: TerrainWorld,
	collider: TerrainCollider
) -> Dictionary:
	var descriptor := PhysicsRigDescriptor.load_for_model(model_id)
	if descriptor == null or not descriptor.is_valid_for(model_id, descriptor.model_version()):
		return {"passed": false, "reason": "physics_descriptor_unavailable"}
	var runtime := JoltChassisTrackRuntime.new()
	runtime.name = "AuthorityJoltRuntime"
	(rig["host"] as Node3D).add_child(runtime)
	if not runtime.configure(descriptor, world, collider, _spawn_transform(descriptor, world)):
		runtime.queue_free()
		await process_frame
		return {"passed": false, "reason": "jolt_runtime_configure_failed"}
	runtime.set_commands(0.0, 0.0)
	runtime.set_equipment_commands(Vector4.ZERO, 0)
	var observed_support_sources := {}
	var observed_bucket_sources := {}
	for _frame in 90:
		await physics_frame
		_collect_motion_provenance(runtime.get_status_snapshot(), observed_support_sources, observed_bucket_sources)
	var settled := _motion_checkpoint(runtime.get_status_snapshot())
	if not bool(settled.get("terrain_identity_valid", false)) \
			or int(settled.get("left_contact_count", 0)) <= 0 \
			or int(settled.get("right_contact_count", 0)) <= 0:
		runtime.teardown()
		runtime.queue_free()
		await process_frame
		return {"passed": false, "reason": "jolt_settle_support_failed"}

	runtime.set_commands(0.65, 0.65)
	runtime.set_equipment_commands(Vector4(0.20, -0.12, 0.16, -0.10), 1)
	for _frame in 90:
		await physics_frame
		_collect_motion_provenance(runtime.get_status_snapshot(), observed_support_sources, observed_bucket_sources)
	var driven := _motion_checkpoint(runtime.get_status_snapshot())
	runtime.set_commands(0.0, 0.0)
	runtime.set_equipment_commands(Vector4.ZERO, 2)
	for _frame in 45:
		await physics_frame
		_collect_motion_provenance(runtime.get_status_snapshot(), observed_support_sources, observed_bucket_sources)
	var stopped := _motion_checkpoint(runtime.get_status_snapshot())
	var bucket_probe := _run_bucket_contact_probe(model_id, world, collider)
	if not bool(bucket_probe.get("passed", false)):
		runtime.teardown()
		runtime.queue_free()
		await process_frame
		return {"passed": false, "reason": bucket_probe.get("reason", "bucket_contact_probe_failed")}
	for contact_value in bucket_probe.get("contacts", []):
		var contact := contact_value as Dictionary
		var source := String(contact.get("query_source", "unknown"))
		observed_bucket_sources[source] = int(observed_bucket_sources.get(source, 0)) + 1
	if int(observed_support_sources.get("terrain_collider", 0)) <= 0:
		runtime.teardown()
		runtime.queue_free()
		await process_frame
		return {"passed": false, "reason": "terrain_collider_support_not_observed"}
	for source in observed_support_sources:
		if String(source) not in ["terrain_collider", "terrain_state_fallback"]:
			runtime.teardown()
			runtime.queue_free()
			await process_frame
			return {"passed": false, "reason": "unauthorized_track_support_%s" % source}
	for source in observed_bucket_sources:
		if String(source) != "terrain_collider":
			runtime.teardown()
			runtime.queue_free()
			await process_frame
			return {"passed": false, "reason": "unauthorized_bucket_query_%s" % source}
	runtime.teardown()
	runtime.queue_free()
	await process_frame
	await physics_frame
	return {
		"passed": true,
		"settled": settled,
		"driven": driven,
		"stopped": stopped,
		"bucket_contact_probe": bucket_probe,
		"observed_support_sources": observed_support_sources,
		"observed_bucket_sources": observed_bucket_sources,
	}


func _run_bucket_contact_probe(model_id: String, world: TerrainWorld, collider: TerrainCollider) -> Dictionary:
	var descriptor := SoilContractDescriptor.load_for_model(model_id)
	if descriptor == null or not descriptor.is_valid_for(model_id):
		return {"passed": false, "reason": "bucket_probe_contract_unavailable"}
	var contract := descriptor.to_dictionary()
	var sweeper := BucketProxySweeper.new()
	if not sweeper.configure(model_id, contract, collider, 1):
		return {"passed": false, "reason": "bucket_probe_configure_failed"}
	var cutting_edge := (contract["proxies"] as Dictionary).get("cutting_edge", {}) as Dictionary
	var local_center := _vector3(cutting_edge.get("center_godot", [0.0, 0.0, 0.0]) as Array)
	var surface_y := world.terrain_state.sample_surface_bilinear_at(Vector2.ZERO)
	var previous := Transform3D(Basis.IDENTITY, Vector3(-local_center.x, surface_y + 0.35 - local_center.y, -local_center.z))
	var candidate := Transform3D(Basis.IDENTITY, Vector3(-local_center.x, surface_y - 0.12 - local_center.y, -local_center.z))
	var identity := collider.get_applied_identity()
	var result := sweeper.sweep(
		world.get_world_3d(), previous, candidate, identity,
		Engine.get_physics_frames(), "authority-equivalence:%s" % model_id, 1,
	)
	var contacts := result.get("contacts", []) as Array
	if not bool(result.get("valid", false)):
		return {"passed": false, "reason": "bucket_probe_invalid"}
	if contacts.is_empty():
		return {"passed": false, "reason": "bucket_probe_no_contact"}
	for contact_value in contacts:
		var contact := contact_value as Dictionary
		if String(contact.get("query_source", "")) != "terrain_collider":
			return {"passed": false, "reason": "bucket_probe_unauthorized_source"}
	return {
		"passed": true,
		"valid": bool(result.get("valid", false)),
		"accepted_fraction": float(result.get("accepted_fraction", 1.0)),
		"terrain_generation": identity.x,
		"terrain_revision": identity.y,
		"contacts": _canonical_bucket_query(result)["contacts"],
	}


func _collect_motion_provenance(snapshot: Dictionary, support_sources: Dictionary, bucket_sources: Dictionary) -> void:
	var current_support := snapshot.get("track_support_source_counts", {}) as Dictionary
	for source in current_support:
		support_sources[source] = int(support_sources.get(source, 0)) + int(current_support[source])
	var bucket_query := snapshot.get("bucket_query", {}) as Dictionary
	for contact_value in bucket_query.get("contacts", []):
		var contact := contact_value as Dictionary
		var source := String(contact.get("query_source", "unknown"))
		bucket_sources[source] = int(bucket_sources.get(source, 0)) + 1


func _motion_checkpoint(snapshot: Dictionary) -> Dictionary:
	return {
		"body_transform": snapshot.get("body_transform", Transform3D.IDENTITY),
		"linear_velocity": snapshot.get("linear_velocity", Vector3.ZERO),
		"angular_velocity": snapshot.get("angular_velocity", Vector3.ZERO),
		"kinematic_frames": (snapshot.get("kinematic_frames", []) as Array).duplicate(true),
		"joints": (snapshot.get("joints", []) as Array).duplicate(true),
		"payload": (snapshot.get("payload", {}) as Dictionary).duplicate(true),
		"command_identity": int(snapshot.get("command_identity", -1)),
		"terrain_generation": int(snapshot.get("terrain_generation", -1)),
		"terrain_revision": int(snapshot.get("terrain_revision", -1)),
		"terrain_identity_valid": bool(snapshot.get("terrain_identity_valid", false)),
		"left_contact_count": int(snapshot.get("left_contact_count", 0)),
		"right_contact_count": int(snapshot.get("right_contact_count", 0)),
		"grounded": bool(snapshot.get("grounded", false)),
		"track_support_source_counts": (snapshot.get("track_support_source_counts", {}) as Dictionary).duplicate(true),
		"bucket_query": _canonical_bucket_query(snapshot.get("bucket_query", {}) as Dictionary),
	}


func _canonical_bucket_query(query: Dictionary) -> Dictionary:
	var contacts: Array[Dictionary] = []
	for contact_value in query.get("contacts", []):
		var contact := contact_value as Dictionary
		contacts.append({
			"proxy_role": String(contact.get("proxy_role", "")),
			"query_source": String(contact.get("query_source", "unknown")),
			"travel_fraction": float(contact.get("travel_fraction", 1.0)),
			"point_world": contact.get("point_world", Vector3.ZERO),
			"normal_world": contact.get("normal_world", Vector3.UP),
			"initial_overlap": bool(contact.get("initial_overlap", false)),
		})
	return {
		"valid": bool(query.get("valid", false)),
		"accepted_fraction": float(query.get("accepted_fraction", 1.0)),
		"terrain_generation": int(query.get("terrain_generation", -1)),
		"terrain_revision": int(query.get("terrain_revision", -1)),
		"accepted_bucket_transform": query.get("accepted_bucket_transform", Transform3D.IDENTITY),
		"contacts": contacts,
		"quality_flags": (query.get("quality_flags", []) as Array).duplicate(),
	}


func _exercise_lifecycle(
	world: TerrainWorld,
	adapter: Terrain3DAdapter,
	collider: TerrainCollider,
	scheduler: TerrainCommitScheduler,
	backend: String
) -> Dictionary:
	var before := world.terrain_state.surface_snapshot()
	var before_identity := Vector2i(int(before["world_generation"]), int(before["terrain_revision"]))
	if not world.set_test_mode(true):
		return {"passed": false, "reason": "test_grid_entry_failed"}
	var grid_status := world.get_status_snapshot()
	if String(grid_status["presentation_override"]) != TerrainWorld.OVERRIDE_TEST_GRID \
			or int(grid_status["visible_surface_count"]) != 1 \
			or collider.get_applied_identity() != before_identity:
		return {"passed": false, "reason": "test_grid_authority_mismatch"}
	if not world.set_test_mode(false):
		return {"passed": false, "reason": "test_grid_exit_failed"}
	var restored_status := world.get_status_snapshot()
	if String(restored_status["active_backend"]) != backend or int(restored_status["visible_surface_count"]) != 1:
		return {"passed": false, "reason": "test_grid_restore_mismatch"}
	var after_grid := world.terrain_state.surface_snapshot()
	if before["surface_bytes"] != after_grid["surface_bytes"] or before_identity != Vector2i(int(after_grid["world_generation"]), int(after_grid["terrain_revision"])):
		return {"passed": false, "reason": "test_grid_mutated_authority"}

	if backend == TerrainWorld.BACKEND_TERRAIN3D:
		adapter.material_path = "res://tests/__missing_terrain3d_material__.tres"
	if not scheduler.reset_world():
		return {"passed": false, "reason": "scheduler_reset_failed"}
	var reset_snapshot := world.terrain_state.surface_snapshot()
	var reset_identity := Vector2i(int(reset_snapshot["world_generation"]), int(reset_snapshot["terrain_revision"]))
	var reset_status := world.get_status_snapshot()
	if collider.get_applied_identity() != reset_identity or int(reset_status["visible_surface_count"]) != 1:
		return {"passed": false, "reason": "reset_derivative_identity_mismatch"}
	if backend == TerrainWorld.BACKEND_TERRAIN3D:
		if String(reset_status["active_backend"]) != TerrainWorld.BACKEND_FALLBACK \
				or String(reset_status["fallback_reason"]) != TerrainWorld.FALLBACK_MATERIAL:
			return {"passed": false, "reason": "native_failure_did_not_fail_open"}
		adapter.material_path = Terrain3DAdapter.WORKSITE_MATERIAL
		if not world.rebuild_mesh():
			return {"passed": false, "reason": "native_recovery_failed"}
		var recovered := world.get_status_snapshot()
		if String(recovered["active_backend"]) != TerrainWorld.BACKEND_TERRAIN3D \
				or int(recovered["visible_surface_count"]) != 1:
			return {"passed": false, "reason": "native_recovery_identity_mismatch"}
	return {
		"passed": true,
		"pre_reset_surface_sha256": String(before["snapshot_sha256"]),
		"reset_surface_sha256": String(reset_snapshot["snapshot_sha256"]),
		"reset_generation": int(reset_snapshot["world_generation"]),
		"reset_revision": int(reset_snapshot["terrain_revision"]),
		"collider_generation": collider.get_applied_identity().x,
		"collider_revision": collider.get_applied_identity().y,
	}


func _capture_checkpoint(
	source: TerrainState,
	authority: SoilInteractionAuthority,
	world: TerrainWorld,
	adapter: Terrain3DAdapter,
	collider: TerrainCollider
) -> Dictionary:
	var surface := source.surface_snapshot()
	var authority_status := authority.get_status_snapshot()
	var world_status := world.get_status_snapshot()
	var identity := Vector2i(int(surface["world_generation"]), int(surface["terrain_revision"]))
	var adapter_status := adapter.get_status_snapshot()
	return {
		"world_generation": identity.x,
		"terrain_revision": identity.y,
		"terrain_epoch": String(surface["terrain_epoch"]),
		"surface_sha256": String(surface["snapshot_sha256"]),
		"surface_bytes": (surface["surface_bytes"] as PackedByteArray).duplicate(),
		"stable_heights": (surface["stable_heights"] as PackedFloat32Array).duplicate(),
		"loose_depth": (surface["loose_depth"] as PackedFloat32Array).duplicate(),
		"stable_sha256": _sha256(source.surface_to_bytes(surface["stable_heights"] as PackedFloat32Array)),
		"loose_sha256": _sha256(source.surface_to_bytes(surface["loose_depth"] as PackedFloat32Array)),
		"ledger_identity": String(authority_status["ledger_identity"]),
		"ledger_sha256": String(authority_status["snapshot_sha256"]),
		"compartments_m3": (authority_status["compartments_m3"] as Dictionary).duplicate(true),
		"conservation_drift_m3": float(authority_status["conservation_drift_m3"]),
		"invariant_failure_count": int(authority_status["invariant_failure_count"]),
		"bucket_volume_m3": float(authority_status["bucket_volume_m3"]),
		"payload_mass_kg": float(authority_status["payload_mass_kg"]),
		"fill_ratio": float(authority_status["fill_ratio"]),
		"fill_profile": (authority_status["fill_profile"] as Array).duplicate(true),
		"center_of_mass_local": authority_status["center_of_mass_local"] as Vector3,
		"journal_size": int(authority_status["journal_size"]),
		"configured_backend": String(world_status["configured_backend"]),
		"active_backend": String(world_status["active_backend"]),
		"visible_surface_count": int(world_status["visible_surface_count"]),
		"accepted_generation": int(world_status["accepted_generation"]),
		"accepted_revision": int(world_status["accepted_revision"]),
		"collider_generation": collider.get_applied_identity().x,
		"collider_revision": collider.get_applied_identity().y,
		"derivatives_match": int(world_status["accepted_generation"]) == identity.x \
			and int(world_status["accepted_revision"]) == identity.y \
			and collider.get_applied_identity() == identity,
		"native_collision_mode_configured": int(adapter_status["native_collision_mode_configured"]),
		"native_collision_mode_actual": int(adapter_status["native_collision_mode_actual"]),
		"native_collision_layer_actual": int(adapter_status["native_collision_layer_actual"]),
	}


func _compare_backend_runs(model_id: String, fallback_run: Dictionary, native_run: Dictionary) -> void:
	var fallback_checkpoints := fallback_run["checkpoints"] as Dictionary
	var native_checkpoints := native_run["checkpoints"] as Dictionary
	for checkpoint_name in CHECKPOINTS:
		var fallback := fallback_checkpoints[checkpoint_name] as Dictionary
		var native := native_checkpoints[checkpoint_name] as Dictionary
		for field in ["world_generation", "terrain_revision", "terrain_epoch", "surface_sha256", "stable_sha256", "loose_sha256", "ledger_identity", "ledger_sha256", "journal_size"]:
			if fallback[field] != native[field]:
				_failures.append("%s/%s differs at %s" % [model_id, checkpoint_name, field])
		for field in ["surface_bytes", "stable_heights", "loose_depth", "compartments_m3", "fill_profile", "center_of_mass_local"]:
			if fallback[field] != native[field]:
				_failures.append("%s/%s backend changed %s" % [model_id, checkpoint_name, field])
		for field in ["conservation_drift_m3", "bucket_volume_m3", "payload_mass_kg", "fill_ratio"]:
			if not is_equal_approx(float(fallback[field]), float(native[field])):
				_failures.append("%s/%s backend changed %s" % [model_id, checkpoint_name, field])
		if int(native["native_collision_mode_configured"]) != 0 \
				or int(native["native_collision_mode_actual"]) != 0 \
				or int(native["native_collision_layer_actual"]) != 0:
			_failures.append("%s/%s native Terrain3D collision authority is not disabled" % [model_id, checkpoint_name])
	if fallback_run["journal"] != native_run["journal"]:
		_failures.append("%s backend changed the soil transaction journal" % model_id)
	var fallback_motion := fallback_run["motion"] as Dictionary
	var native_motion := native_run["motion"] as Dictionary
	for motion_checkpoint in ["settled", "driven", "stopped"]:
		if not _variants_close(fallback_motion[motion_checkpoint], native_motion[motion_checkpoint], 0.002):
			_failures.append("%s/%s backend changed accepted Jolt outcome" % [model_id, motion_checkpoint])
	for source_field in ["observed_support_sources", "observed_bucket_sources"]:
		if fallback_motion[source_field] != native_motion[source_field]:
			_failures.append("%s backend changed %s" % [model_id, source_field])
	if not _variants_close(fallback_motion["bucket_contact_probe"], native_motion["bucket_contact_probe"], 0.002):
		_failures.append("%s backend changed accepted bucket contact evidence" % model_id)
	var fallback_lifecycle := fallback_run["lifecycle"] as Dictionary
	var native_lifecycle := native_run["lifecycle"] as Dictionary
	for field in ["pre_reset_surface_sha256", "reset_surface_sha256", "reset_generation", "reset_revision", "collider_generation", "collider_revision"]:
		if fallback_lifecycle[field] != native_lifecycle[field]:
			_failures.append("%s lifecycle differs at %s" % [model_id, field])


func _build_rig(model_id: String, backend: String) -> Dictionary:
	var host := Node3D.new()
	host.name = "TerrainAuthority_%s_%s" % [model_id, backend]
	var camera := Camera3D.new()
	camera.name = "AuthorityCamera"
	camera.current = true
	camera.position = Vector3(0.0, 12.0, 12.0)
	host.add_child(camera)
	var foundation := MeshInstance3D.new()
	foundation.name = "FoundationGround"
	host.add_child(foundation)
	var adapter := Terrain3DAdapter.new()
	adapter.name = "Terrain3DAdapter"
	adapter.native_collision_mode = 0
	host.add_child(adapter)
	var world := TerrainWorld.new()
	world.name = "TerrainWorld"
	world.terrain_backend = backend
	world.terrain_seed = 1937
	world.terrain_rows = 41
	world.terrain_columns = 41
	world.terrain_spacing_m = 0.25
	world.terrain3d_adapter_path = NodePath("../Terrain3DAdapter")
	world.foundation_ground_path = NodePath("../FoundationGround")
	var renderer := TerrainRenderer.new()
	renderer.name = "TerrainMesh"
	world.add_child(renderer)
	host.add_child(world)
	var collider := TerrainCollider.new()
	collider.name = "TerrainCollider"
	collider.enabled = true
	host.add_child(collider)
	return {
		"host": host,
		"world": world,
		"adapter": adapter,
		"collider": collider,
	}


func _dispose_rig(rig: Dictionary) -> void:
	var collider := rig.get("collider") as TerrainCollider
	if collider != null:
		collider.disable_for_test()
	var host := rig.get("host") as Node3D
	if host != null and is_instance_valid(host):
		host.queue_free()
	await process_frame
	await physics_frame


func _evidence_view(run: Dictionary) -> Dictionary:
	if not bool(run.get("passed", false)):
		return {"passed": false, "reason": run.get("reason", "unknown")}
	var checkpoint_evidence := {}
	for checkpoint_name in CHECKPOINTS:
		var checkpoint := (run["checkpoints"] as Dictionary)[checkpoint_name] as Dictionary
		checkpoint_evidence[checkpoint_name] = {
			"world_generation": checkpoint["world_generation"],
			"terrain_revision": checkpoint["terrain_revision"],
			"terrain_epoch": checkpoint["terrain_epoch"],
			"surface_sha256": checkpoint["surface_sha256"],
			"stable_sha256": checkpoint["stable_sha256"],
			"loose_sha256": checkpoint["loose_sha256"],
			"ledger_identity": checkpoint["ledger_identity"],
			"ledger_sha256": checkpoint["ledger_sha256"],
			"journal_size": checkpoint["journal_size"],
			"active_backend": checkpoint["active_backend"],
			"visible_surface_count": checkpoint["visible_surface_count"],
			"collider_generation": checkpoint["collider_generation"],
			"collider_revision": checkpoint["collider_revision"],
			"native_collision_mode_actual": checkpoint["native_collision_mode_actual"],
			"native_collision_layer_actual": checkpoint["native_collision_layer_actual"],
		}
	return {
		"passed": true,
		"checkpoints": checkpoint_evidence,
		"journal_size": (run["journal"] as Array).size(),
		"motion": _motion_evidence(run["motion"] as Dictionary),
		"lifecycle": run["lifecycle"],
	}


func _motion_evidence(motion: Dictionary) -> Dictionary:
	var checkpoints := {}
	for checkpoint_name in ["settled", "driven", "stopped"]:
		var checkpoint := motion[checkpoint_name] as Dictionary
		var body := checkpoint["body_transform"] as Transform3D
		var bucket := (checkpoint["bucket_query"] as Dictionary).get("accepted_bucket_transform", Transform3D.IDENTITY) as Transform3D
		checkpoints[checkpoint_name] = {
			"body_origin": [body.origin.x, body.origin.y, body.origin.z],
			"accepted_bucket_origin": [bucket.origin.x, bucket.origin.y, bucket.origin.z],
			"terrain_generation": checkpoint["terrain_generation"],
			"terrain_revision": checkpoint["terrain_revision"],
			"left_contact_count": checkpoint["left_contact_count"],
			"right_contact_count": checkpoint["right_contact_count"],
			"grounded": checkpoint["grounded"],
			"track_support_source_counts": checkpoint["track_support_source_counts"],
			"bucket_query_valid": (checkpoint["bucket_query"] as Dictionary)["valid"],
		}
	return {
		"checkpoints": checkpoints,
		"observed_support_sources": motion["observed_support_sources"],
		"observed_bucket_sources": motion["observed_bucket_sources"],
		"bucket_contact_probe": {
			"valid": (motion["bucket_contact_probe"] as Dictionary)["valid"],
			"accepted_fraction": (motion["bucket_contact_probe"] as Dictionary)["accepted_fraction"],
			"terrain_generation": (motion["bucket_contact_probe"] as Dictionary)["terrain_generation"],
			"terrain_revision": (motion["bucket_contact_probe"] as Dictionary)["terrain_revision"],
			"contact_count": ((motion["bucket_contact_probe"] as Dictionary)["contacts"] as Array).size(),
		},
	}


func _variants_close(left: Variant, right: Variant, tolerance: float) -> bool:
	if typeof(left) != typeof(right):
		return false
	match typeof(left):
		TYPE_FLOAT:
			return absf(float(left) - float(right)) <= tolerance
		TYPE_VECTOR2:
			return (left as Vector2).distance_to(right as Vector2) <= tolerance
		TYPE_VECTOR3:
			return (left as Vector3).distance_to(right as Vector3) <= tolerance
		TYPE_VECTOR4:
			return (left as Vector4).distance_to(right as Vector4) <= tolerance
		TYPE_BASIS:
			return _basis_close(left as Basis, right as Basis, tolerance)
		TYPE_TRANSFORM3D:
			var left_transform := left as Transform3D
			var right_transform := right as Transform3D
			return left_transform.origin.distance_to(right_transform.origin) <= tolerance \
				and _basis_close(left_transform.basis, right_transform.basis, tolerance)
		TYPE_ARRAY:
			var left_array := left as Array
			var right_array := right as Array
			if left_array.size() != right_array.size():
				return false
			for index in left_array.size():
				if not _variants_close(left_array[index], right_array[index], tolerance):
					return false
			return true
		TYPE_DICTIONARY:
			var left_dictionary := left as Dictionary
			var right_dictionary := right as Dictionary
			if left_dictionary.size() != right_dictionary.size():
				return false
			for key in left_dictionary:
				if not right_dictionary.has(key) or not _variants_close(left_dictionary[key], right_dictionary[key], tolerance):
					return false
			return true
		_:
			return left == right


func _basis_close(left: Basis, right: Basis, tolerance: float) -> bool:
	return left.x.distance_to(right.x) <= tolerance \
		and left.y.distance_to(right.y) <= tolerance \
		and left.z.distance_to(right.z) <= tolerance


func _spawn_transform(descriptor: PhysicsRigDescriptor, terrain_world: TerrainWorld) -> Transform3D:
	var data := descriptor.to_dictionary()
	var dynamics := data["chassis_dynamics"] as Dictionary
	var state := terrain_world.terrain_state
	var spacing := state.spacing_m
	var left_height := state.sample_surface_bilinear_at(Vector2(-spacing, 0.0))
	var right_height := state.sample_surface_bilinear_at(Vector2(spacing, 0.0))
	var rear_height := state.sample_surface_bilinear_at(Vector2(0.0, -spacing))
	var front_height := state.sample_surface_bilinear_at(Vector2(0.0, spacing))
	var terrain_normal := Vector3((left_height - right_height) / (2.0 * spacing), 1.0, (rear_height - front_height) / (2.0 * spacing)).normalized()
	var forward := Vector3.FORWARD.slide(terrain_normal).normalized()
	var basis := Basis(forward.cross(terrain_normal).normalized(), terrain_normal, -forward).orthonormalized()
	basis = (basis * Basis(Vector3.UP, float(dynamics.get("spawn_yaw_rad", 0.0)))).orthonormalized()
	var clearance := float(dynamics["ground_clearance_m"])
	var surface_y := state.sample_surface_bilinear_at(Vector2.ZERO)
	var tracks := data["tracks"] as Dictionary
	var stiffness := float(tracks.get("support_stiffness_n_per_m", 0.0))
	var probe_count := maxi(1, int(tracks.get("traction_points_per_side", 1)) * 2)
	var support_sag := clampf(float(dynamics["mass_kg"]) * 9.80665 / (stiffness * float(probe_count)), 0.0, 0.12) if stiffness > 0.0 else 0.0
	var minimum_bottom := INF
	var required_origin_y := -INF
	for shape in dynamics["compound_shapes"]:
		var center := _vector3(shape["center_m"])
		var half := 0.5 * _vector3(shape["size_m"])
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					var offset := basis * (center + Vector3(sx * half.x, sy * half.y, sz * half.z))
					minimum_bottom = minf(minimum_bottom, offset.y)
					var corner_ground := state.sample_surface_bilinear_at(Vector2(offset.x, offset.z))
					if is_finite(corner_ground):
						required_origin_y = maxf(required_origin_y, corner_ground + clearance + support_sag - offset.y)
	return Transform3D(basis, Vector3(0.0, required_origin_y if not is_inf(required_origin_y) else surface_y - minimum_bottom + clearance + support_sag, 0.0))


func _vector3(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


func _candidate_point(classification: Dictionary, action: String) -> Vector3:
	for value in classification.get("candidates", []):
		var candidate := value as Dictionary
		if String(candidate.get("classification", "none")) == action:
			return candidate.get("point_world", Vector3(INF, INF, INF)) as Vector3
	return Vector3(INF, INF, INF)


func _region_center(snapshot: Dictionary, region_id: String) -> Vector3:
	for value in snapshot.get("regions", []):
		var region := value as Dictionary
		if String(region.get("region_id", "")) == region_id:
			return region.get("current_center_world", Vector3.ZERO) as Vector3
	return Vector3.ZERO


func _region_sample_point(snapshot: Dictionary, region_id: String) -> Vector3:
	for value in snapshot.get("regions", []):
		var region := value as Dictionary
		if String(region.get("region_id", "")) != region_id:
			continue
		var points := region.get("current_points", []) as Array
		return points[0] as Vector3 if not points.is_empty() else region.get("current_center_world", Vector3.ZERO) as Vector3
	return Vector3.ZERO


func _region_normal(snapshot: Dictionary, region_id: String) -> Vector3:
	for value in snapshot.get("regions", []):
		var region := value as Dictionary
		if String(region.get("region_id", "")) == region_id:
			return region.get("outward_normal_world", Vector3.UP) as Vector3
	return Vector3.UP


func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	context.update(bytes)
	return context.finish().hex_encode()


func _write_evidence_if_requested() -> void:
	var args := OS.get_cmdline_user_args()
	var index := args.find(OUTPUT_ARG)
	if index < 0 or index + 1 >= args.size():
		return
	var output_dir := String(args[index + 1]).replace("\\", "/")
	DirAccess.make_dir_recursive_absolute(output_dir)
	var file := FileAccess.open(output_dir.path_join("authority-equivalence.json"), FileAccess.WRITE)
	if file == null:
		_failures.append("could not write authority equivalence evidence")
		return
	file.store_string(JSON.stringify(_evidence, "  "))

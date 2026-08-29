extends Node

const MAIN_SCENE := "res://scenes/main.tscn"
const WORKSITE_MATERIAL := "res://assets/terrain/terrain3d_worksite_material.tres"
const MISSING_MATERIAL := "res://tests/__missing_terrain3d_material__.tres"

var _failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		_finish({"reason": "main_scene_unavailable"})
		return
	var scene := packed.instantiate() as Node3D
	var motion_client := scene.get_node_or_null("MotionClient") as MotionClient
	if motion_client != null:
		motion_client.auto_connect = false
	add_child(scene)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().physics_frame

	var world := scene.get_node_or_null("TerrainRoot/TerrainWorld") as TerrainWorld
	var adapter := scene.get_node_or_null("TerrainRoot/Terrain3DAdapter") as Terrain3DAdapter
	var session := scene.get_node_or_null("ProductSession") as ProductSession
	var presentation := scene.get_node_or_null("MotionPresentation") as MotionPresentation
	var chassis := scene.get_node_or_null("ChassisMotionRoot") as TrackedChassisController
	var excavation := scene.get_node_or_null("TerrainRoot/ExcavationWorld") as ExcavationWorld
	var effects := scene.get_node_or_null("SoilEffects") as SoilEffects
	if world == null or adapter == null or session == null or presentation == null or chassis == null or excavation == null or effects == null:
		_failures.append("product_contract_missing")
		_finish({})
		return

	var startup := _terrain_checkpoint(world)
	_expect(String(startup.get("configured_backend", "")) == TerrainWorld.BACKEND_TERRAIN3D, "default_not_terrain3d")
	_expect(String(startup.get("active_backend", "")) == TerrainWorld.BACKEND_TERRAIN3D, "native_startup_failed")
	_expect(String(startup.get("material_identity", "")) == "project_procedural_worksite_soil", "project_soil_material_missing")
	_expect(bool(startup.get("native_material_ready", false)), "native_material_not_ready")
	_expect(not bool(startup.get("native_demo_dressing_active", true)), "demo_dressing_active")
	_expect(int(startup.get("visible_surface_count", 0)) == 1, "startup_surface_count_invalid")

	var mode_terrain_before := world.terrain_state.surface_snapshot()
	_expect(session.request_bucket_ground_mode(BucketGroundInteractionMode.PASSTHROUGH), "bucket_passthrough_request_failed")
	await get_tree().physics_frame
	await get_tree().physics_frame
	var mode_terrain_active := world.terrain_state.surface_snapshot()
	var mode_chassis := chassis.get_status_snapshot().get("bucket_ground_interaction", {}) as Dictionary
	var mode_soil := excavation.get_status_snapshot().get("bucket_ground_interaction", {}) as Dictionary
	var mode_effects := effects.get_effect_snapshot()
	_expect(String(session.get_status_snapshot().get("bucket_ground_mode", "")) == BucketGroundInteractionMode.PASSTHROUGH, "bucket_passthrough_not_active")
	_expect(String(mode_chassis.get("mode", "")) == BucketGroundInteractionMode.PASSTHROUGH, "bucket_passthrough_jolt_missing")
	_expect(String(mode_soil.get("mode", "")) == BucketGroundInteractionMode.PASSTHROUGH, "bucket_passthrough_soil_missing")
	_expect(String(mode_effects.get("bucket_ground_mode", "")) == BucketGroundInteractionMode.PASSTHROUGH, "bucket_passthrough_effects_missing")
	_expect(_same_terrain(mode_terrain_before, mode_terrain_active), "bucket_passthrough_entry_mutated_terrain")
	var query_bypass_before := int(mode_chassis.get("query_bypassed", 0))
	var soil_bypass_before := int(mode_soil.get("soil_steps_bypassed", 0))
	var effects_bypass_before := int(mode_effects.get("update_bypassed", 0))
	for _frame in 5:
		await get_tree().physics_frame
	mode_chassis = chassis.get_status_snapshot().get("bucket_ground_interaction", {}) as Dictionary
	mode_soil = excavation.get_status_snapshot().get("bucket_ground_interaction", {}) as Dictionary
	mode_effects = effects.get_effect_snapshot()
	_expect(int(mode_chassis.get("query_bypassed", 0)) > query_bypass_before, "bucket_passthrough_query_not_bypassed")
	_expect(int(mode_soil.get("soil_steps_bypassed", 0)) > soil_bypass_before, "bucket_passthrough_soil_not_bypassed")
	_expect(int(mode_effects.get("update_bypassed", 0)) > effects_bypass_before, "bucket_passthrough_effects_not_bypassed")
	_expect(session.request_bucket_ground_mode(BucketGroundInteractionMode.NORMAL), "bucket_normal_restore_request_failed")
	await get_tree().physics_frame
	await get_tree().physics_frame
	var mode_terrain_restored := world.terrain_state.surface_snapshot()
	_expect(String(session.get_status_snapshot().get("bucket_ground_mode", "")) == BucketGroundInteractionMode.NORMAL, "bucket_normal_not_restored")
	_expect(_same_terrain(mode_terrain_active, mode_terrain_restored), "bucket_passthrough_exit_mutated_terrain")
	var bucket_ground_checkpoint := {
		"entry_terrain_unchanged": _same_terrain(mode_terrain_before, mode_terrain_active),
		"exit_terrain_unchanged": _same_terrain(mode_terrain_active, mode_terrain_restored),
		"query_bypassed": int(mode_chassis.get("query_bypassed", 0)) - query_bypass_before,
		"soil_bypassed": int(mode_soil.get("soil_steps_bypassed", 0)) - soil_bypass_before,
		"effects_bypassed": int(mode_effects.get("update_bypassed", 0)) - effects_bypass_before,
		"restored_mode": String(session.get_status_snapshot().get("bucket_ground_mode", "")),
	}

	var initial := world.terrain_state.surface_snapshot()
	_expect(world.enqueue_brush_for_test(1, Vector2(0.0, 0.0), 1.4, -0.16), "cut_brush_rejected")
	_expect(world.step_fixed_for_test(), "cut_brush_not_applied")
	var cut := world.terrain_state.surface_snapshot()
	_expect(int(cut.get("terrain_revision", -1)) > int(initial.get("terrain_revision", -1)), "cut_revision_not_advanced")
	_expect(String(cut.get("snapshot_sha256", "")) != String(initial.get("snapshot_sha256", "")), "cut_surface_unchanged")
	_expect(world.enqueue_brush_for_test(2, Vector2(2.0, 1.5), 1.2, 0.12), "deposit_brush_rejected")
	_expect(world.step_fixed_for_test(), "deposit_brush_not_applied")
	var deposit := world.terrain_state.surface_snapshot()
	_expect(int(deposit.get("terrain_revision", -1)) > int(cut.get("terrain_revision", -1)), "deposit_revision_not_advanced")
	_expect(String(deposit.get("snapshot_sha256", "")) != String(cut.get("snapshot_sha256", "")), "deposit_surface_unchanged")
	var deformed := _terrain_checkpoint(world)
	_expect(String(deformed.get("active_backend", "")) == TerrainWorld.BACKEND_TERRAIN3D, "native_deformation_presentation_failed")
	_expect(int(deformed.get("applied_revision", -1)) == int(deposit.get("terrain_revision", -2)), "native_revision_stale")
	_expect_single_surface(deformed, "deformed")

	_expect(world.set_test_mode(true), "test_grid_entry_failed")
	var grid := _terrain_checkpoint(world)
	_expect(String(grid.get("presentation_override", "")) == TerrainWorld.OVERRIDE_TEST_GRID, "test_grid_override_missing")
	_expect(String(grid.get("active_backend", "")) == TerrainWorld.BACKEND_FALLBACK, "test_grid_not_visible")
	_expect_single_surface(grid, "test_grid")
	_expect(world.set_test_mode(false), "test_grid_exit_failed")
	var restored := _terrain_checkpoint(world)
	_expect(String(restored.get("active_backend", "")) == TerrainWorld.BACKEND_TERRAIN3D, "test_grid_native_restore_failed")
	_expect_single_surface(restored, "test_grid_restored")

	adapter.material_path = MISSING_MATERIAL
	world.reset_for_test()
	var failed_open := _terrain_checkpoint(world)
	_expect(String(failed_open.get("active_backend", "")) == TerrainWorld.BACKEND_FALLBACK, "native_failure_did_not_fail_open")
	_expect(not String(failed_open.get("fallback_reason", "")).is_empty(), "fallback_reason_missing")
	_expect_single_surface(failed_open, "failed_open")
	adapter.material_path = WORKSITE_MATERIAL
	_expect(world.rebuild_mesh(), "native_recovery_rebuild_failed")
	var recovered := _terrain_checkpoint(world)
	_expect(String(recovered.get("active_backend", "")) == TerrainWorld.BACKEND_TERRAIN3D, "native_recovery_failed")
	_expect_single_surface(recovered, "recovered")

	var before_rollback := world.terrain_state.surface_snapshot()
	world.terrain_backend = TerrainWorld.BACKEND_FALLBACK
	_expect(world.rebuild_mesh(), "explicit_rollback_rebuild_failed")
	var rollback := _terrain_checkpoint(world)
	var after_rollback := world.terrain_state.surface_snapshot()
	_expect(String(rollback.get("configured_backend", "")) == TerrainWorld.BACKEND_FALLBACK, "explicit_rollback_not_configured")
	_expect(String(rollback.get("active_backend", "")) == TerrainWorld.BACKEND_FALLBACK, "explicit_rollback_not_active")
	_expect(String(before_rollback.get("snapshot_sha256", "")) == String(after_rollback.get("snapshot_sha256", "")), "explicit_rollback_mutated_authority")
	_expect_single_surface(rollback, "explicit_rollback")
	world.terrain_backend = TerrainWorld.BACKEND_TERRAIN3D
	_expect(world.rebuild_mesh(), "rollback_native_restore_failed")
	var rollback_restored := _terrain_checkpoint(world)
	_expect(String(rollback_restored.get("active_backend", "")) == TerrainWorld.BACKEND_TERRAIN3D, "rollback_native_not_restored")
	_expect_single_surface(rollback_restored, "rollback_restored")

	_expect(session.request_start(), "session_start_failed")
	_expect(session.request_pause(), "session_pause_failed")
	_expect(session.request_model_switch("sy135"), "sy135_switch_failed")
	await get_tree().process_frame
	await get_tree().physics_frame
	_expect(presentation.get_active_model_id() == "sy135", "sy135_not_active")
	var generation_before_reset := session.generation
	_expect(session.request_reset(), "session_reset_failed")
	await get_tree().process_frame
	await get_tree().physics_frame
	_expect(session.generation == generation_before_reset + 1, "session_generation_not_advanced")
	var final_status := _terrain_checkpoint(world)
	_expect(String(final_status.get("active_backend", "")) == TerrainWorld.BACKEND_TERRAIN3D, "post_reset_native_missing")
	_expect_single_surface(final_status, "post_reset")

	_finish({
		"startup": startup,
		"cut_revision": int(cut.get("terrain_revision", -1)),
		"deposit_revision": int(deposit.get("terrain_revision", -1)),
		"test_grid": grid,
		"failed_open": failed_open,
		"recovered": recovered,
		"explicit_rollback": rollback,
		"rollback_restored": rollback_restored,
		"final": final_status,
		"active_model_id": presentation.get_active_model_id(),
		"session_generation": session.generation,
		"bucket_ground": bucket_ground_checkpoint,
	})


func _terrain_checkpoint(world: TerrainWorld) -> Dictionary:
	var status := world.get_status_snapshot()
	return {
		"configured_backend": String(status.get("configured_backend", "")),
		"active_backend": String(status.get("active_backend", "")),
		"presentation_override": String(status.get("presentation_override", "")),
		"fallback_reason": String(status.get("fallback_reason", "")),
		"material_identity": String(status.get("material_identity", "")),
		"native_material_ready": bool(status.get("native_material_ready", false)),
		"native_demo_dressing_active": bool(status.get("native_demo_dressing_active", false)),
		"visible_surface_count": int(status.get("visible_surface_count", 0)),
		"applied_generation": int(status.get("applied_generation", -1)),
		"applied_revision": int(status.get("applied_revision", -1)),
	}


func _expect(condition: bool, reason: String) -> void:
	if not condition:
		_failures.append(reason)


func _expect_single_surface(checkpoint: Dictionary, name: String) -> void:
	_expect(int(checkpoint.get("visible_surface_count", 0)) == 1, "%s_surface_count_invalid" % name)


func _same_terrain(before: Dictionary, after: Dictionary) -> bool:
	return (
		int(before.get("world_generation", -1)) == int(after.get("world_generation", -2))
		and int(before.get("terrain_revision", -1)) == int(after.get("terrain_revision", -2))
		and String(before.get("snapshot_sha256", "")) == String(after.get("snapshot_sha256", "missing"))
	)


func _finish(details: Dictionary) -> void:
	var result := {
		"schema_version": "terrain3d-release-smoke-v1",
		"passed": _failures.is_empty(),
		"failures": _failures,
		"engine_version": String(Engine.get_version_info().get("string", "unknown")),
		"features": ProjectSettings.get_setting("application/config/features", PackedStringArray()),
		"details": details,
	}
	var output_file := _argument_value("--output-file")
	if not output_file.is_empty():
		var file := FileAccess.open(output_file, FileAccess.WRITE)
		if file == null:
			push_error("Unable to write Terrain3D release smoke evidence: %s" % output_file)
			get_tree().quit(2)
			return
		file.store_string(JSON.stringify(result, "  "))
	print(JSON.stringify(result))
	get_tree().quit(0 if bool(result["passed"]) else 1)


func _argument_value(name: String) -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find(name)
	return String(args[index + 1]) if index >= 0 and index + 1 < args.size() else ""

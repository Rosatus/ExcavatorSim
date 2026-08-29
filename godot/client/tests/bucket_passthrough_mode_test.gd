extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"
const TRACE_FRAMES := 24

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := load(MAIN_SCENE).instantiate() as Node3D
	if scene == null:
		_fail("main scene did not instantiate")
		quit(1)
		return
	root.add_child(scene)
	await process_frame
	await physics_frame
	await physics_frame

	var session := scene.get_node_or_null("ProductSession") as ProductSession
	var chassis := scene.get_node_or_null("ChassisMotionRoot") as TrackedChassisController
	var excavation := scene.get_node_or_null("TerrainRoot/ExcavationWorld") as ExcavationWorld
	var terrain_world := scene.get_node_or_null("TerrainRoot/TerrainWorld") as TerrainWorld
	var terrain_collider := scene.get_node_or_null("TerrainRoot/TerrainCollider") as TerrainCollider
	var effects := scene.get_node_or_null("SoilEffects") as SoilEffects
	var operator_ui := scene.get_node_or_null("OperatorUI") as MotionOperatorUI
	var mode_button := scene.get_node_or_null("OperatorUI/StatusPanel/Margin/VBox/Tools/BucketPassthrough") as CheckButton
	if (
		session == null
		or chassis == null
		or excavation == null
		or terrain_world == null
		or terrain_collider == null
		or effects == null
		or operator_ui == null
		or mode_button == null
	):
		_fail("main scene is missing a bucket pass-through dependency")
	else:
		await _exercise_mode(session, chassis, excavation, terrain_world, terrain_collider, effects, mode_button)

	scene.queue_free()
	await process_frame
	if failures.is_empty():
		print("bucket_passthrough_mode_test: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _exercise_mode(
	session: ProductSession,
	chassis: TrackedChassisController,
	excavation: ExcavationWorld,
	terrain_world: TerrainWorld,
	terrain_collider: TerrainCollider,
	effects: SoilEffects,
	mode_button: CheckButton,
) -> void:
	var initial_session := session.get_status_snapshot()
	if String(initial_session.get("bucket_ground_mode", "")) != BucketGroundInteractionMode.NORMAL:
		_fail("application did not start in normal bucket-ground mode")
	if session.request_bucket_ground_mode("invalid"):
		_fail("invalid bucket-ground mode was accepted")
	var terrain_before := terrain_world.terrain_state.surface_snapshot()
	var material_before := int(excavation.get_status_snapshot().get("material_generation", -1))
	if not mode_button.tooltip_text.contains("clears bucket soil"):
		_fail("game UI did not disclose destructive material clearing")
	mode_button.emit_signal("toggled", true)
	var requested := session.get_status_snapshot()
	if (
		String(requested.get("bucket_ground_mode", "")) != BucketGroundInteractionMode.NORMAL
		or not bool(requested.get("bucket_ground_mode_pending", false))
	):
		_fail("pass-through changed active state before a fixed tick")
	await physics_frame
	await physics_frame
	var active := session.get_status_snapshot()
	var soil_active := excavation.get_status_snapshot()
	var chassis_active := chassis.get_status_snapshot()
	if String(active.get("bucket_ground_mode", "")) != BucketGroundInteractionMode.PASSTHROUGH:
		_fail("pass-through did not become active at a fixed tick")
	if String((soil_active.get("bucket_ground_interaction", {}) as Dictionary).get("mode", "")) != BucketGroundInteractionMode.PASSTHROUGH:
		_fail("excavation did not receive pass-through policy")
	if String((chassis_active.get("bucket_ground_interaction", {}) as Dictionary).get("mode", "")) != BucketGroundInteractionMode.PASSTHROUGH:
		_fail("Jolt runtime did not receive pass-through policy")
	var payload := excavation.get_selected_soil_payload_snapshot()
	if float(payload.get("payload_mass_kg", -1.0)) != 0.0 or float(payload.get("bucket_volume_m3", -1.0)) != 0.0:
		_fail("mode entry did not clear selected bucket payload")
	if int(soil_active.get("material_generation", -1)) <= material_before:
		_fail("mode entry did not advance the clean material generation")
	_assert_same_terrain(terrain_before, terrain_world.terrain_state.surface_snapshot(), "mode entry")
	if not terrain_collider.enabled:
		_fail("pass-through disabled the terrain collider used by chassis support")

	if excavation.queue_cut_world(9001, Vector3.ZERO, Vector3.DOWN):
		_fail("manual cut seam bypassed pass-through policy")
	if excavation.queue_deposit_world(9002, Vector3.ZERO):
		_fail("manual deposit seam bypassed pass-through policy")
	excavation.debug_manual_controls = true
	if excavation.request_dig() or excavation.request_deposit():
		_fail("debug soil controls bypassed pass-through policy")
	excavation.debug_manual_controls = false
	if String(excavation.step_fixed_for_test().get("reason", "")) != "bucket_ground_interaction_bypassed":
		_fail("test soil step bypassed pass-through policy")

	var jolt_before := (chassis.get_status_snapshot().get("bucket_ground_interaction", {}) as Dictionary).duplicate(true)
	var soil_before := (excavation.get_status_snapshot().get("bucket_ground_interaction", {}) as Dictionary).duplicate(true)
	var effects_before := effects.get_effect_snapshot()
	session.request_start()
	chassis.set_test_input_focus_bypass_for_test(true)
	chassis.set_equipment_commands_for_test(Vector4(0.0, -1.0, -1.0, -1.0))
	for _frame in TRACE_FRAMES:
		await physics_frame
	var jolt_after := chassis.get_status_snapshot().get("bucket_ground_interaction", {}) as Dictionary
	var soil_after := excavation.get_status_snapshot().get("bucket_ground_interaction", {}) as Dictionary
	var effects_after := effects.get_effect_snapshot()
	if int(jolt_after.get("query_executed", -1)) != int(jolt_before.get("query_executed", -2)):
		_fail("bucket sweep executed during pass-through trace")
	if int(jolt_after.get("query_bypassed", 0)) <= int(jolt_before.get("query_bypassed", 0)):
		_fail("bucket sweep bypass counter did not advance")
	if int(jolt_after.get("cut_probe_executed", -1)) != int(jolt_before.get("cut_probe_executed", -2)):
		_fail("cut penetration probe executed during pass-through trace")
	if int(jolt_after.get("support_applied", -1)) != int(jolt_before.get("support_applied", -2)):
		_fail("bucket support wrench applied during pass-through trace")
	if int(soil_after.get("soil_steps_executed", -1)) != int(soil_before.get("soil_steps_executed", -2)):
		_fail("soil authority executed during pass-through trace")
	if int(soil_after.get("soil_steps_bypassed", 0)) <= int(soil_before.get("soil_steps_bypassed", 0)):
		_fail("soil bypass counter did not advance")
	if int(effects_after.get("update_executed", -1)) != int(effects_before.get("update_executed", -2)):
		_fail("soil effects executed during pass-through trace")
	if int(effects_after.get("update_bypassed", 0)) <= int(effects_before.get("update_bypassed", 0)):
		_fail("soil effects bypass counter did not advance")
	var query := chassis.get_status_snapshot().get("bucket_query", {}) as Dictionary
	if (
		float(query.get("accepted_fraction", 0.0)) != 1.0
		or not (query.get("contacts", []) as Array).is_empty()
		or not (query.get("quality_flags", []) as Array).has("bucket_ground_interaction_bypassed")
	):
		_fail("pass-through query diagnostic was not full-motion and contact-free")
	_assert_same_terrain(terrain_before, terrain_world.terrain_state.surface_snapshot(), "pass-through trace")

	if not session.request_model_switch("sy135"):
		_fail("model switch failed while pass-through was active")
	await physics_frame
	await physics_frame
	if String(session.get_status_snapshot().get("bucket_ground_mode", "")) != BucketGroundInteractionMode.PASSTHROUGH:
		_fail("model switch did not preserve pass-through selection")
	if String((chassis.get_status_snapshot().get("bucket_ground_interaction", {}) as Dictionary).get("mode", "")) != BucketGroundInteractionMode.PASSTHROUGH:
		_fail("SY135 rebuilt runtime lost pass-through policy")
	if not session.request_reset():
		_fail("reset failed while pass-through was active")
	await physics_frame
	if String(session.get_status_snapshot().get("bucket_ground_mode", "")) != BucketGroundInteractionMode.PASSTHROUGH:
		_fail("reset did not preserve pass-through selection")

	var terrain_exit_before := terrain_world.terrain_state.surface_snapshot()
	mode_button.emit_signal("toggled", false)
	if not bool(session.get_status_snapshot().get("bucket_ground_mode_pending", false)):
		_fail("normal-mode restore was not deferred to a fixed tick")
	await physics_frame
	await physics_frame
	if String(session.get_status_snapshot().get("bucket_ground_mode", "")) != BucketGroundInteractionMode.NORMAL:
		_fail("normal mode was not restored")
	_assert_same_terrain(terrain_exit_before, terrain_world.terrain_state.surface_snapshot(), "mode exit")
	var restored_jolt_before := chassis.get_status_snapshot().get("bucket_ground_interaction", {}) as Dictionary
	var restored_soil_before := excavation.get_status_snapshot().get("bucket_ground_interaction", {}) as Dictionary
	session.request_start()
	chassis.set_equipment_commands_for_test(Vector4(0.0, 0.0, -0.5, -0.5))
	for _frame in TRACE_FRAMES:
		await physics_frame
	var restored_jolt_after := chassis.get_status_snapshot().get("bucket_ground_interaction", {}) as Dictionary
	var restored_soil_after := excavation.get_status_snapshot().get("bucket_ground_interaction", {}) as Dictionary
	if int(restored_jolt_after.get("query_executed", 0)) <= int(restored_jolt_before.get("query_executed", 0)):
		_fail("normal restore did not resume bucket query execution")
	if int(restored_soil_after.get("soil_steps_executed", 0)) <= int(restored_soil_before.get("soil_steps_executed", 0)):
		_fail("normal restore did not resume soil authority execution")
	if int(restored_jolt_after.get("query_bypassed", -1)) != int(restored_jolt_before.get("query_bypassed", -2)):
		_fail("normal restore continued counting bypassed bucket queries")
	chassis.clear_equipment_commands_for_test()
	chassis.set_test_input_focus_bypass_for_test(false)


func _assert_same_terrain(before: Dictionary, after: Dictionary, label: String) -> void:
	if (
		int(before.get("world_generation", -1)) != int(after.get("world_generation", -2))
		or int(before.get("terrain_revision", -1)) != int(after.get("terrain_revision", -2))
		or String(before.get("snapshot_sha256", "")) != String(after.get("snapshot_sha256", "missing"))
	):
		_fail("%s mutated persistent terrain identity or bytes" % label)


func _fail(message: String) -> void:
	failures.append(message)

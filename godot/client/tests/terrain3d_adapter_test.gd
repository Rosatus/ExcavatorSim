extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var result := await _test_snapshot_guards_without_native_backend()
	if result == 0:
		result = await _test_scene_adapter_seam()
	if result == 0:
		result = await _test_jolt_collision_and_disable()
	if result == 0:
		print("Terrain3D adapter contracts passed.")
	quit(result)


func _test_snapshot_guards_without_native_backend() -> int:
	var state := TerrainState.new(77)
	var adapter := Terrain3DAdapter.new()
	adapter.enabled = false
	root.add_child(adapter)
	await process_frame
	var baseline := state.surface_snapshot()
	if not adapter.queue_snapshot(baseline):
		return _fail("adapter accepts a complete TerrainState snapshot")
	if adapter.apply_pending() or adapter.available:
		return _fail("disabled native backend fails open")
	var status: Dictionary = adapter.get_status_snapshot()
	if int(status["queued_generation"]) != int(baseline["world_generation"]) or int(status["queued_revision"]) != int(baseline["terrain_revision"]):
		return _fail("adapter exposes queued generation and revision")
	if int(status["rock_count"]) != 0 or int(status["tree_count"]) != 0:
		return _fail("disabled native backend creates no site dressing")
	if not state.enqueue_brush(1, Vector2.ZERO, 1.0, 0.2) or not state.step_fixed():
		return _fail("test edit changes the logical source")
	var newer := state.surface_snapshot()
	if not adapter.queue_snapshot(newer):
		return _fail("newer revision replaces pending native work")
	if adapter.queue_snapshot(baseline):
		return _fail("stale revision cannot replace newer native work")
	if state.surface_snapshot()["surface_bytes"] != newer["surface_bytes"]:
		return _fail("adapter queueing never mutates logical snapshot bytes")
	adapter.queue_free()
	return 0


func _test_scene_adapter_seam() -> int:
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		return _fail("main scene loads")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	var adapter := scene.get_node_or_null("TerrainRoot/Terrain3DAdapter") as Terrain3DAdapter
	var terrain_world := scene.get_node_or_null("TerrainRoot/TerrainWorld") as TerrainWorld
	var fallback := scene.get_node_or_null("TerrainRoot/TerrainWorld/TerrainMesh") as TerrainRenderer
	var foundation := scene.get_node_or_null("TerrainRoot/FoundationGround") as MeshInstance3D
	if adapter == null or terrain_world == null or fallback == null or foundation == null:
		scene.queue_free()
		return _fail("scene keeps adapter and custom renderer seams")
	if terrain_world.terrain_state == null:
		scene.queue_free()
		return _fail("adapter is downstream of an initialized TerrainState")
	if not adapter.get_status_snapshot().has_all(["queued_generation", "queued_revision", "applied_generation", "applied_revision"]):
		scene.queue_free()
		return _fail("adapter reports generation-gated status")
	var status := adapter.get_status_snapshot()
	if String(status["assets_source"]) != "demo:terrain3d-official":
		scene.queue_free()
		return _fail("adapter uses the official Terrain3D demo assets")
	if int(status["presentation_rows"]) != 129 or int(status["presentation_columns"]) != 129:
		scene.queue_free()
		return _fail("adapter materializes the medium construction-site grid")
	if int(status["rock_count"]) != 18 or int(status["tree_count"]) != 0 or not bool(status["grass_enabled"]):
		scene.queue_free()
		return _fail("adapter reports official demo rocks and grass")
	var native_terrain := scene.get_node_or_null("TerrainRoot/Terrain3DAdapter/Terrain3DNative") as Terrain3D
	if native_terrain == null or native_terrain.assets == null or native_terrain.material == null:
		scene.queue_free()
		return _fail("Terrain3D enters the scene with assets and material configured")
	if native_terrain.region_size != adapter.region_size or native_terrain.collision_mask != 1:
		scene.queue_free()
		return _fail("Terrain3D enters the scene with stable region and collision settings")
	if native_terrain.material.world_background != Terrain3DMaterial.NONE:
		scene.queue_free()
		return _fail("Terrain3D keeps its infinite background disabled so Sky3D owns the horizon")
	if fallback.visible or foundation.visible:
		scene.queue_free()
		return _fail("native Terrain3D hides both legacy ground presentation layers")
	# Incremental revision contract: ordinary edits patch the live native
	# surface in place. The active native terrain never becomes invisible while
	# work is queued or applying, dressing nodes stay stable, and only the patch
	# counter advances.
	var status_before := adapter.get_status_snapshot()
	var dressing_node := scene.get_node_or_null("TerrainRoot/Terrain3DAdapter/ConstructionSiteDressing") as Node3D
	if dressing_node == null:
		scene.queue_free()
		return _fail("adapter owns a disposable construction-site dressing layer")
	var dressing_ids_before := _dressing_instance_ids(dressing_node)
	var logical_state := terrain_world.terrain_state
	for _patch_index in 2:
		if not logical_state.enqueue_brush(logical_state.next_brush_sequence(), Vector2.ZERO, 1.0, 0.05):
			scene.queue_free()
			return _fail("incremental brush queues")
		if not logical_state.step_fixed():
			scene.queue_free()
			return _fail("incremental brush changes terrain")
		if not terrain_world.rebuild_mesh():
			scene.queue_free()
			return _fail("terrain world refreshes derivatives")
		if not adapter.available or not adapter.is_native_mesh_active():
			scene.queue_free()
			return _fail("native terrain stays visible during incremental revisions")
		if fallback.visible or foundation.visible:
			scene.queue_free()
			return _fail("no native/fallback flash during incremental revisions")
	var status_after := adapter.get_status_snapshot()
	if int(status_after["patch_count"]) != int(status_before["patch_count"]) + 2:
		scene.queue_free()
		return _fail("ordinary revisions increment the patch counter")
	if int(status_after["full_import_count"]) != int(status_before["full_import_count"]):
		scene.queue_free()
		return _fail("ordinary revisions must not increment the full-import counter")
	if adapter.get_applied_identity() != Vector2i(logical_state.world_generation, logical_state.terrain_revision):
		scene.queue_free()
		return _fail("applied identity converges to the accepted revision")
	if _dressing_instance_ids(dressing_node) != dressing_ids_before:
		scene.queue_free()
		return _fail("site dressing nodes stay stable across patches")
	# The patched native height map matches the logical authority at the brush
	# center; Terrain3D internal maps never replace the byte digest oracle.
	var native_data: Variant = (scene.get_node("TerrainRoot/Terrain3DAdapter/Terrain3DNative") as Node3D).get("data")
	var patched_height: float = native_data.call("get_height", Vector3(0.0, 0.0, 0.0)) if native_data != null and (native_data as Object).has_method("get_height") else NAN
	if is_nan(patched_height) or not is_equal_approx(patched_height, logical_state.sample_surface_at(Vector2.ZERO)):
		scene.queue_free()
		return _fail("patched native height matches the logical surface at the edit")
	# Reset performs a clean full rebuild and clears stale pending patch work.
	var full_before_reset := int(status_after["full_import_count"])
	terrain_world.reset_for_test()
	var status_reset := adapter.get_status_snapshot()
	if int(status_reset["full_import_count"]) != full_before_reset + 1:
		scene.queue_free()
		return _fail("reset performs a clean full materialization")
	if int(status_reset["patch_count"]) != int(status_after["patch_count"]):
		scene.queue_free()
		return _fail("reset does not count as a patch")
	if bool(status_reset["resync_requested"]) or not adapter.available:
		scene.queue_free()
		return _fail("reset clears stale pending patch work and keeps native active")
	if adapter.get_applied_identity() != Vector2i(logical_state.world_generation, logical_state.terrain_revision):
		scene.queue_free()
		return _fail("reset converges applied identity to the new generation")
	var dressing := scene.get_node_or_null("TerrainRoot/Terrain3DAdapter/ConstructionSiteDressing")
	if dressing == null:
		scene.queue_free()
		return _fail("adapter owns a disposable construction-site dressing layer")
	for layer_name in ["Rocks1", "Rocks2", "Rocks3"]:
		var layer := dressing.get_node_or_null(layer_name) as MultiMeshInstance3D
		if layer == null or layer.multimesh == null:
			scene.queue_free()
			return _fail("site dressing uses three bounded scanned-rock MultiMesh layers")
	var particles := dressing.get_node_or_null("Terrain3DParticles")
	var process_material := particles.get("process_material") as ShaderMaterial if particles != null else null
	if process_material == null or float(process_material.get_shader_parameter("exclusion_radius")) != 12.0:
		scene.queue_free()
		return _fail("official demo grass excludes the central flat work pad")
	if dressing.find_children("*", "CollisionObject3D", true, false).size() != 0:
		scene.queue_free()
		return _fail("site dressing does not add physics authority")
	var scene_collider := scene.get_node_or_null("TerrainRoot/TerrainCollider") as TerrainCollider
	if scene_collider != null:
		scene_collider.disable_for_test()
	scene.queue_free()
	await process_frame
	await physics_frame
	return 0


func _test_jolt_collision_and_disable() -> int:
	if String(ProjectSettings.get_setting("physics/3d/physics_engine", "")) != "Jolt Physics":
		return _fail("project keeps Jolt as the 3D physics backend")
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		return _fail("collision smoke scene loads")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	var adapter := scene.get_node_or_null("TerrainRoot/Terrain3DAdapter") as Terrain3DAdapter
	var terrain_world := scene.get_node_or_null("TerrainRoot/TerrainWorld") as TerrainWorld
	var logical_collider := scene.get_node_or_null("TerrainRoot/TerrainCollider") as TerrainCollider
	if adapter == null or terrain_world == null or logical_collider == null or not adapter.available:
		scene.queue_free()
		return _fail("native Terrain3D backend is available for collision smoke")
	# The product-default Jolt chassis may enable the separate logical heightfield
	# collider. Disable it here so this test isolates Terrain3D's native shape.
	logical_collider.disable_for_test()
	var chassis_body := scene.get_node_or_null("ChassisMotionRoot/AuthoritativeChassisBody") as CollisionObject3D
	if chassis_body != null:
		chassis_body.collision_layer = 0
		chassis_body.collision_mask = 0
	await physics_frame
	var before := terrain_world.terrain_state.surface_snapshot()
	if not adapter.set_collision_mode(1):
		scene.queue_free()
		return _fail("Terrain3D Dynamic/Game collision enables")
	for _frame in 30:
		if adapter.collision_available:
			break
		await physics_frame
	var query := PhysicsRayQueryParameters3D.create(Vector3(0.0, 5.0, 0.0), Vector3(0.0, -5.0, 0.0))
	query.collision_mask = 1
	var hit: Dictionary = scene.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or not (hit.get("collider") is Terrain3D):
		scene.queue_free()
		return _fail("Jolt raycast hits the Terrain3D static collider")
	if adapter.set_collision_mode(0) or adapter.collision_available:
		scene.queue_free()
		return _fail("Terrain3D collision disables fail-open")
	for _frame in 30:
		if not adapter.collision_available:
			break
		await physics_frame
	var stale_hit: Dictionary = scene.get_world_3d().direct_space_state.intersect_ray(query)
	if not stale_hit.is_empty():
		scene.queue_free()
		var stale_collider: Variant = stale_hit.get("collider")
		return _fail("disabled Terrain3D collision leaves no stale shape (%s)" % (stale_collider.get_class() if stale_collider is Object else "unknown"))
	var after := terrain_world.terrain_state.surface_snapshot()
	if before["surface_bytes"] != after["surface_bytes"] or before["terrain_revision"] != after["terrain_revision"]:
		scene.queue_free()
		return _fail("Jolt collision toggles never mutate logical terrain")
	scene.queue_free()
	await process_frame
	return 0


func _dressing_instance_ids(dressing: Node3D) -> Array:
	var ids := []
	for child in dressing.get_children():
		ids.append(child.get_instance_id())
	return ids


func _fail(message: String) -> int:
	push_error("Terrain3D adapter check failed: %s" % message)
	return 1

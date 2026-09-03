extends SceneTree

const VoxelZone = preload("res://scripts/voxel_work_zone_config.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var failure := await _check_scene_and_derived_seam()
	if failure.is_empty():
		print("Voxel work-zone hard/soil seam contracts passed.")
		quit(0)
		return
	push_error(failure)
	quit(1)


func _check_scene_and_derived_seam() -> String:
	var packed := load("res://scenes/main.tscn") as PackedScene
	if packed == null:
		return "main scene loads"
	var scene := packed.instantiate()
	if scene.get_node_or_null("TerrainRoot/VoxelWorkZone") == null:
		scene.free()
		return "main scene contains VoxelWorkZone"
	if scene.get_node_or_null("TerrainRoot/VoxelWorkZoneBoundary") == null:
		scene.free()
		return "main scene contains VoxelWorkZoneBoundary"
	scene.free()

	var state := TerrainState.new(24681357)
	var snapshot := state.surface_snapshot()
	var renderer := TerrainRenderer.new()
	if not renderer.queue_snapshot(snapshot) or not renderer.apply_pending():
		renderer.free()
		return "fallback renderer accepts baseline"
	var arrays := (renderer.mesh as ArrayMesh).surface_get_arrays(0)
	var vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var indices := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
	for offset in range(0, indices.size(), 3):
		var center := (vertices[indices[offset]] + vertices[indices[offset + 1]] + vertices[indices[offset + 2]]) / 3.0
		if VoxelZone.owns_world_xz(Vector2(center.x, center.z)):
			renderer.free()
			return "fallback mesh omits voxel-owned cells"
	renderer.free()

	var collider := TerrainCollider.new()
	collider.enabled = true
	root.add_child(collider)
	if not collider.queue_snapshot(snapshot) or not collider.apply_pending():
		collider.free()
		return "hard collider accepts masked baseline"
	await physics_frame
	await physics_frame
	if _ray(Vector2.ZERO).is_empty():
		collider.free()
		return "hard collider supports the spawn outside voxel ownership"
	if not _ray(Vector2(0.0, 16.0)).is_empty():
		collider.free()
		return "hard collider omits voxel-owned cells"
	collider.queue_free()
	await process_frame
	return ""


func _ray(world_xz: Vector2) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(world_xz.x, 3.0, world_xz.y),
		Vector3(world_xz.x, -3.0, world_xz.y),
		VoxelZone.TERRAIN_COLLISION_LAYER,
	)
	query.collide_with_areas = false
	return root.get_world_3d().direct_space_state.intersect_ray(query)

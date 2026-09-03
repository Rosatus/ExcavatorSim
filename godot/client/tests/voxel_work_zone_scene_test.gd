extends SceneTree

const MAX_READY_FRAMES := 1200


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://scenes/main.tscn") as PackedScene
	if packed == null:
		quit(_fail("main scene loads"))
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	var zone := scene.get_node_or_null("TerrainRoot/VoxelWorkZone")
	var boundary := scene.get_node_or_null("TerrainRoot/VoxelWorkZoneBoundary")
	if zone == null or boundary == null:
		quit(_fail("foundation nodes exist"))
		return
	if not await _wait_zone_ready(zone):
		quit(_fail("initial voxel collision becomes ready"))
		return
	if boundary.get_child_count() != 5:
		quit(_fail("retaining boundary has five entrance-aware segments"))
		return
	var voxel_hit := _ray(Vector2(0.0, 16.0))
	if voxel_hit.is_empty() or not _has_voxel_ancestor(voxel_hit.get("collider") as Node):
		quit(_fail("voxel collision exclusively supports the work zone"))
		return
	var spawn_hit := _ray(Vector2.ZERO)
	if spawn_hit.is_empty() or _has_voxel_ancestor(spawn_hit.get("collider") as Node):
		quit(_fail("hard collision exclusively supports the spawn"))
		return
	var old_ticket := zone.initial_ticket.duplicate(true) as Dictionary
	var old_generation: int = int(zone.readiness.generation)
	if not zone.reset_zone():
		quit(_fail("zone reset rebuilds runtime"))
		return
	if zone.readiness.generation != old_generation + 1 or zone.readiness.mark_meshed(old_ticket):
		quit(_fail("reset advances generation and rejects old tickets"))
		return
	if not await _wait_zone_ready(zone):
		quit(_fail("reset collision becomes ready"))
		return
	print("Voxel work-zone scene/reset contracts passed.")
	scene.queue_free()
	await process_frame
	quit(0)


func _wait_zone_ready(zone: Node) -> bool:
	for _frame in MAX_READY_FRAMES:
		if zone.is_support_ready_at(Vector3(0.0, 0.0, 16.0)):
			return true
		await physics_frame
	return false


func _ray(world_xz: Vector2) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(world_xz.x, 3.0, world_xz.y),
		Vector3(world_xz.x, -3.0, world_xz.y),
		1,
	)
	query.collide_with_areas = false
	return root.get_world_3d().direct_space_state.intersect_ray(query)


func _has_voxel_ancestor(node: Node) -> bool:
	var current := node
	while current != null:
		if current.is_class("VoxelTerrain"):
			return true
		current = current.get_parent()
	return false


func _fail(message: String) -> int:
	push_error("Voxel work-zone scene check failed: %s" % message)
	return 1

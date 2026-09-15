extends SceneTree

const Profile = preload("res://scripts/site_profile.gd")
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)


func ray(world: Node3D, x: float, z: float, mask: int) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(Vector3(x, 6, z), Vector3(x, -14, z), mask)
	return world.get_world_3d().direct_space_state.intersect_ray(query)


func run() -> void:
	var started := Time.get_ticks_msec()
	var scene := load("res://scenes/earthworks_site_workbench.tscn") as PackedScene
	check(scene != null, "scene parses")
	if scene == null:
		quit(1)
		return
	var world := scene.instantiate() as Node3D
	root.add_child(world)
	current_scene = world
	var hard := world.get_node("HardTerrain") as Terrain3D
	var voxel := world.get_node("VoxelTerrain") as VoxelTerrain
	check(hard.material.world_background == 0, "missing region must not render background")
	check(hard.assets.get_texture_count() == 4, "four surface texture roles")
	check(hard.region_size == 64, "region size retained on reload")
	check(is_nan(hard.data.get_height(Vector3(32, 0, 32))), "central region has no hard height")
	check(absf(hard.data.get_height(Vector3(32, 0, 65))) < 0.05, "hard approach matches voxel perimeter")
	check(voxel.bounds == Profile.VOXEL_BOUNDS, "finite voxel bounds persisted")
	check(not world.get_node("InitialSoilPreview").visible, "no runtime initial-mesh double surface")
	check(voxel.visible, "native voxel visible at runtime")
	check(not Profile.EDITABLE_BOUNDS.has_point(world.get_node("EntranceCamera").position), "spawn outside editable soil")
	var tool := voxel.get_voxel_tool()
	tool.channel = VoxelBuffer.CHANNEL_SDF
	var cut_center := Vector3(32, -1, 48)
	var cut_area := AABB(cut_center / Profile.VOXEL_SCALE - Vector3.ONE * 12, Vector3.ONE * 24)
	var hit: Dictionary = {}
	while Time.get_ticks_msec() - started < 30000:
		await physics_frame
		hit = ray(world, 32, 48, 2)
		if not hit.is_empty() and tool.is_area_editable(cut_area) and tool.is_area_editable(AABB(Vector3(126, -50, 190), Vector3.ONE * 4)):
			break
	check(not hit.is_empty(), "voxel collider becomes ready")
	check(not ray(world, 32, 66, 1).is_empty(), "hard-ground collision becomes ready")
	check(ray(world, 32, 48, 1).is_empty(), "hard collider absent below voxel area")
	var before := tool.get_voxel_f(Vector3i(128, -48, 192))
	check(before < 0, "solid soil exists at 12m depth")
	var lowered := false
	if tool.is_area_editable(cut_area):
		tool.mode = VoxelTool.MODE_REMOVE
		tool.do_sphere(cut_center / Profile.VOXEL_SCALE, 2.0 / Profile.VOXEL_SCALE)
		var edit_started := Time.get_ticks_msec()
		while Time.get_ticks_msec() - edit_started < 10000:
			await physics_frame
			hit = ray(world, 32, 48, 3)
			if not hit.is_empty() and (hit.position as Vector3).y < -1.5:
				lowered = true
				break
	check(lowered, "local removal lowers real collider without exposing hard ground")
	if hard.data.get_regions_active().size() == 8:
		for point: Vector2 in [Vector2(-15, 32), Vector2(32, -15), Vector2(79, 32), Vector2(32, 79), Vector2(-15, 100)]:
			check(not ray(world, point.x, point.y, 1).is_empty(), "haul route has physical ground at %s" % point)
		for point: Vector2 in [Vector2(0.125, 40), Vector2(63.875, 40), Vector2(40, 0.125), Vector2(40, 63.875), Vector2(-0.125, 40), Vector2(64.125, 40), Vector2(40, -0.125), Vector2(40, 64.125)]:
			var seam_hit := ray(world, point.x, point.y, 7)
			check(not seam_hit.is_empty() and absf((seam_hit.get("position", Vector3(0, -99, 0)) as Vector3).y) < 0.1, "seam continuous at %s" % point)
		check(world.has_node("SiteDressing/EntryCheckpoint") and world.has_node("SiteDressing/MaterialYard"), "authored worksite sections exist")
		var proxy := Node3D.new()
		proxy.set_script(load("res://scripts/asset_instance.gd"))
		proxy.set("use_source_asset", false)
		world.add_child(proxy)
		check(proxy.get("import_state") == "proxy" and proxy.get_child_count() == 1, "proxy works without loading GLB")
	var result := {"passed":failures.is_empty(),"failures":failures,"regions":hard.data.get_regions_active().size(),"elapsed_ms":Time.get_ticks_msec() - started,"voxel_scale_m":Profile.VOXEL_SCALE,"depth_sample_sdf":before}
	var file := FileAccess.open("res://artifacts/workbench_smoke.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "  "))
	file.close()
	print("WORKBENCH_SMOKE ", JSON.stringify(result))
	world.queue_free()
	await process_frame
	await process_frame
	quit(0 if failures.is_empty() else 1)

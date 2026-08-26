extends SceneTree
## Run the real main scene with rendering for a few seconds and save a
## viewport screenshot to diagnose the ground-material report.


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	for i in 300:
		await process_frame
	var ui := scene.get_node_or_null("OperatorUI")
	if ui != null:
		ui.visible = false
	var world := scene.get_node_or_null("TerrainRoot/TerrainWorld")
	if world != null:
		world.rebuild_mesh_from_snapshot(world.get("_latest_snapshot"))
		print("forced fallback rebuild from latest snapshot")
	var adapter := scene.get_node_or_null("TerrainRoot/Terrain3DAdapter")
	var t: Object = null
	if adapter != null:
		print("adapter last_error: [", adapter.get("last_error"), "]")
		print("adapter available: ", adapter.get("available"))
		t = adapter.get("_terrain_node")
	if t != null:
		print("native visible: ", t.visible, " global_pos: ", (t as Node3D).global_position)
		print("native global_transform origin: ", (t as Node3D).global_transform.origin)
	var cam := root.get_viewport().get_camera_3d()
	if cam != null:
		print("camera at ", cam.global_position, " looking ", -cam.global_transform.basis.z)
		if t != null:
			print("native material set: ", t.get("material") != null, " assets: ", t.get("assets") != null)
			var data: Object = t.get("data")
			if data != null and data.has_method("get_regions_active"):
				print("regions: ", (data.call("get_regions_active") as Array).size())
	var image := root.get_viewport().get_texture().get_image()
	image.save_png("E:/projects/ExcavatorSim/output/can_gateway/ground_check.png")
	print("screenshot saved, size=", image.get_size())
	# Toggle material null -> checkerboard should appear if terrain visible.
	if t != null:
		t.set("material", null)
	# Hide the Terrain3D mouse-picking quad (untextured, renders black).
	var mouse_quad := (t as Node3D).find_child("MouseQuad", true, false) if t != null else null
	if mouse_quad != null:
		print("MouseQuad found, hiding")
		(mouse_quad as MeshInstance3D).visible = false
	for i in 30:
		await process_frame
	var image2 := root.get_viewport().get_texture().get_image()
	image2.save_png("E:/projects/ExcavatorSim/output/can_gateway/ground_check_nullmat.png")
	print("null-material screenshot saved")
	# Fresh default Terrain3DMaterial (bypassing the authored .tres).
	if t != null:
		var fresh: Object = ClassDB.instantiate("Terrain3DMaterial")
		t.set("material", fresh)
	for i in 30:
		await process_frame
	var image4 := root.get_viewport().get_texture().get_image()
	image4.save_png("E:/projects/ExcavatorSim/output/can_gateway/ground_check_freshmat.png")
	print("fresh-material screenshot saved")
	# Re-assert assets AFTER material (ordering suspicion).
	var adapter2 := scene.get_node_or_null("TerrainRoot/Terrain3DAdapter")
	if adapter2 != null and t != null:
		var assets_obj: Object = t.get("assets")
		t.set("assets", null)
		await process_frame
		t.set("assets", assets_obj)
		print("re-set assets: ", t.get("assets") != null)
	for i in 30:
		await process_frame
	var image5 := root.get_viewport().get_texture().get_image()
	image5.save_png("E:/projects/ExcavatorSim/output/can_gateway/ground_check_reassets.png")
	print("re-assets screenshot saved")
	# Inspect dressing: maybe an untextured mesh covers the camera view.
	var dressing := scene.get_node_or_null("TerrainRoot/ConstructionSiteDressing")
	if dressing != null:
		print("dressing children: ", dressing.get_child_count())
		for child in dressing.get_children():
			print("  dressing child: ", child.get_class(), ":", child.name, " pos=", (child as Node3D).global_position if child is Node3D else "")
			for sub in child.get_children():
				var info := "    sub " + str(sub.get_class()) + ":" + String(sub.name)
				if sub is MeshInstance3D:
					var mi := sub as MeshInstance3D
					info += " override=" + ("null" if mi.material_override == null else "set")
					if mi.mesh != null:
						info += " surfmat=" + ("null" if mi.mesh.surface_get_material(0) == null else "set")
					info += " gpos=" + str(mi.global_position)
				print(info)
	# find ALL MeshInstance3D with null mesh-material near camera
	var stack := [root]
	var suspicious := []
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			var has_mat := mi.material_override != null or (mi.mesh != null and mi.mesh.surface_get_material(0) != null)
			if not has_mat and mi.visible and mi.global_position.distance_to(Vector3(0,2,8)) < 30:
				suspicious.append(str(n.get_path()) + " gpos=" + str(mi.global_position))
	print("suspicious untextured meshes near camera:")
	for s in suspicious:
		print("  ", s)
	var fallback := world.get_node_or_null("TerrainMesh") if world != null else null
	if fallback != null:
		print("fallback TerrainMesh visible=", fallback.visible)
		var mesh_res := (fallback as MeshInstance3D).mesh as Mesh
		if mesh_res != null and mesh_res.get_surface_count() > 0:
			var sm = mesh_res.surface_get_material(0)
			var shader_code: String = ""
			if sm is ShaderMaterial:
				shader_code = String((sm as ShaderMaterial).shader.code)
			print("fallback material is_test_grid=", "grid_world_position" in shader_code,
				" is_soil=", "site_world_position" in shader_code, " len=", shader_code.length())
	var foundation := scene.get_node_or_null("TerrainRoot/FoundationGround")
	if foundation != null:
		print("foundation visible=", foundation.visible)
	if t != null:
		(t as Node3D).visible = false
	for i in 30:
		await process_frame
	var image3 := root.get_viewport().get_texture().get_image()
	image3.save_png("E:/projects/ExcavatorSim/output/can_gateway/ground_check_noterrain.png")
	print("no-terrain screenshot saved")
	quit(0)

extends SceneTree

const Profile = preload("res://scripts/site_profile.gd")
const OUTPUT := "res://scenes/earthworks_site_workbench.tscn"
var site: Node3D
var hard: Terrain3D
var sample_only := false


func _initialize() -> void:
	call_deferred("build")


func build() -> void:
	if "--textures-only" in OS.get_cmdline_user_args():
		make_textures()
		quit()
		return
	sample_only = "--sample" in OS.get_cmdline_user_args()
	if sample_only and (FileAccess.file_exists(OUTPUT) or not DirAccess.get_files_at("res://terrain_data").is_empty()):
		push_error("Sample generation requires an empty workbench terrain directory; existing regions are never mixed with a sample.")
		quit(2)
		return
	if FileAccess.file_exists(OUTPUT) and not "--replace-generated" in OS.get_cmdline_user_args():
		push_error("Scene exists. Preserve hand edits; use a fresh checkout or explicit --replace-generated.")
		quit(2)
		return
	for folder in ["scenes", "materials", "terrain_data", "source_maps", "artifacts"]:
		DirAccess.make_dir_recursive_absolute("res://" + folder)
	site = Node3D.new()
	site.name = "EarthworksSite"
	root.add_child(site)
	make_hard_terrain()
	make_soil()
	make_boundary_strips()
	make_lighting()
	make_cameras()
	make_diagnostics()
	if not sample_only:
		make_dressing()
	var authored := Node3D.new()
	authored.name = "HandAuthored"
	attach(authored, site)
	site.set_script(load("res://scripts/site_root.gd"))
	var scene := PackedScene.new()
	assert(scene.pack(site) == OK)
	assert(ResourceSaver.save(scene, OUTPUT) == OK)
	print("SITE_BUILT ", JSON.stringify({"sample":sample_only,"regions":hard.data.get_regions_active().size(),"scene":OUTPUT}))
	# Native voxel jobs must finish before teardown; freeing the node cancels streaming.
	site.queue_free()
	await process_frame
	await process_frame
	quit()


func attach(node: Node, parent: Node) -> void:
	parent.add_child(node, true)
	node.owner = site


func make_hard_terrain() -> void:
	var assets := Terrain3DAssets.new()
	var roles := ["Compacted haul road", "Exposed earth", "Gravel service pad", "Perimeter soil"]
	for index in 4:
		var texture := Terrain3DTextureAsset.new()
		texture.name = roles[index]
		texture.albedo_texture = load("res://materials/ground_%d_albedo.png" % index)
		texture.normal_texture = load("res://materials/ground_%d_normal.png" % index)
		texture.uv_scale = 0.5
		assets.set_texture(index, texture)
	assert(ResourceSaver.save(assets, "res://materials/terrain_assets.tres") == OK)
	assets.take_over_path("res://materials/terrain_assets.tres")
	var material := Terrain3DMaterial.new()
	material.world_background = Terrain3DMaterial.NONE
	assert(ResourceSaver.save(material, "res://materials/terrain_material.tres") == OK)
	material.take_over_path("res://materials/terrain_material.tres")
	hard = Terrain3D.new()
	hard.name = "HardTerrain"
	hard.free_editor_textures = false
	hard.assets = assets
	hard.material = material
	attach(hard, site)
	hard.assets = assets
	hard.material = material
	hard.region_size = Profile.REGION_SIZE
	hard.vertex_spacing = 1.0
	hard.collision_layer = 1
	hard.collision_mask = 1
	hard.collision_mode = 3
	for rz in range(-1, 2):
		for rx in range(-1, 2):
			if rx == 0 and rz == 0:
				continue
			if sample_only and (rx != 0 or rz != 1):
				continue
			var heights := Image.create_empty(64, 64, false, Image.FORMAT_RF)
			var controls := PackedByteArray()
			controls.resize(64 * 64 * 4)
			for z in 64:
				for x in 64:
					var p := Vector2(rx * 64 + x, rz * 64 + z)
					heights.set_pixel(x, z, Color(Profile.hard_height(p), 0, 0, 1))
					var role := Profile.surface_role(p)
					controls.encode_u32((z * 64 + x) * 4, (role << 27) | (role << 22))
			var control := Image.create_from_data(64, 64, false, Image.FORMAT_RF, controls)
			hard.data.import_images([heights, control, null], Vector3(rx * 64, 0, rz * 64), 0, 1)
			ResourceSaver.save(heights, "res://source_maps/hard_%d_%d.res" % [rx, rz])
	hard.data.calc_height_range(true)
	hard.data.save_directory("res://terrain_data")
	hard.data_directory = "res://terrain_data"
	assert(hard.assets.get_texture_count() == 4)
	hard.material.show_checkered = false
	assert(ResourceSaver.save(material, "res://materials/terrain_material.tres") == OK)


func make_textures() -> void:
	DirAccess.make_dir_recursive_absolute("res://materials")
	var colors := [Color(0.42, 0.35, 0.25), Color(0.43, 0.31, 0.19), Color(0.43, 0.42, 0.36), Color(0.34, 0.32, 0.23)]
	for index in 4:
		var noise := FastNoiseLite.new()
		noise.seed = 142 + index
		noise.frequency = 0.12
		var albedo := Image.create_empty(256, 256, false, Image.FORMAT_RGBA8)
		var normal := Image.create_empty(256, 256, false, Image.FORMAT_RGBA8)
		for z in 256:
			for x in 256:
				var n := noise.get_noise_2d(x, z)
				var c: Color = colors[index] * (0.94 + n * 0.20)
				c.a = 0.5 + n * 0.25
				albedo.set_pixel(x, z, c)
				var dx := noise.get_noise_2d(x + 1, z) - n
				var dz := noise.get_noise_2d(x, z + 1) - n
				normal.set_pixel(x, z, Color(0.5 - dx * 0.3, 0.5 - dz * 0.3, 1, 0.95))
		assert(albedo.save_png("res://materials/ground_%d_albedo.png" % index) == OK)
		assert(normal.save_png("res://materials/ground_%d_normal.png" % index) == OK)


func make_soil() -> void:
	var heightmap := Image.create_empty(256, 256, false, Image.FORMAT_RF)
	for z in 256:
		for x in 256:
			# Encode the complete bounded vertical interval. Voxel Tools 1.7's
			# below-height_start shortcut writes raw zero, not a negative float SDF.
			heightmap.set_pixel(x, z, Color((Profile.soil_height(Vector2(x, z) * 0.25) + 16.0) / 20.0, 0, 0, 1))
	assert(ResourceSaver.save(heightmap, "res://source_maps/soil_height.res", ResourceSaver.FLAG_CHANGE_PATH) == OK)
	heightmap.take_over_path("res://source_maps/soil_height.res")
	var generator := VoxelGeneratorImage.new()
	generator.image = heightmap
	generator.channel = VoxelBuffer.CHANNEL_SDF
	generator.height_start = -64.0
	generator.height_range = 80.0
	generator.blur_enabled = false
	var format := VoxelFormat.new()
	format.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	var mesher := VoxelMesherTransvoxel.new()
	mesher.transitions_enabled = false
	var material := ShaderMaterial.new()
	material.shader = load("res://materials/soil.gdshader")
	assert(ResourceSaver.save(material, "res://materials/soil.tres", ResourceSaver.FLAG_CHANGE_PATH) == OK)
	material.take_over_path("res://materials/soil.tres")
	var terrain := VoxelTerrain.new()
	terrain.name = "VoxelTerrain"
	terrain.scale = Vector3.ONE * Profile.VOXEL_SCALE
	terrain.format = format
	terrain.generator = generator
	terrain.mesher = mesher
	terrain.bounds = Profile.VOXEL_BOUNDS
	terrain.mesh_block_size = 16
	terrain.max_view_distance = 400
	terrain.generate_collisions = true
	terrain.collision_layer = 2
	terrain.collision_mask = 2
	terrain.material_override = material
	attach(terrain, site)
	var viewer := VoxelViewer.new()
	viewer.name = "WorkZoneViewer"
	viewer.position = Vector3(32, 0, 32)
	viewer.view_distance = 400
	viewer.view_distance_vertical_ratio = 0.5
	viewer.requires_visuals = true
	viewer.requires_collisions = true
	attach(viewer, site)
	var preview := MeshInstance3D.new()
	preview.name = "InitialSoilPreview"
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for z in 128:
		for x in 128:
			var step := 63.75 / 128.0
			var a := Vector2(x, z) * step
			for p: Vector2 in [a, a + Vector2(step, 0), a + Vector2(0, step), a + Vector2(step, 0), a + Vector2(step, step), a + Vector2(0, step)]:
				surface.add_vertex(Vector3(p.x, Profile.soil_height(p), p.y))
	surface.generate_normals()
	preview.mesh = surface.commit()
	assert(ResourceSaver.save(preview.mesh, "res://source_maps/initial_soil_mesh.res", ResourceSaver.FLAG_CHANGE_PATH) == OK)
	preview.mesh.take_over_path("res://source_maps/initial_soil_mesh.res")
	preview.material_override = material
	preview.visible = false
	attach(preview, site)


func make_boundary_strips() -> void:
	# Constant-LOD meshing ends at the last sample (63.75m), while hard terrain
	# begins at 64m. These two disjoint strips fill only that missing interval.
	var strips := section(site, "BoundaryStrips")
	for spec: Array in [[Vector3(63.875, -0.1, 32), Vector3(0.25, 0.2, 64)], [Vector3(31.875, -0.1, 63.875), Vector3(63.75, 0.2, 0.25)]]:
		var mesh := box(strips, "EdgeStrip", spec[0], spec[1], Color(0.42, 0.31, 0.19))
		mesh.material_override = load("res://materials/soil.tres")
		var body := StaticBody3D.new()
		body.name = "EdgeSupport"
		body.position = spec[0]
		body.collision_layer = 4
		body.collision_mask = 4
		attach(body, strips)
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = spec[1]
		collision.shape = shape
		attach(collision, body)


func make_lighting() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.25, 0.43, 0.63)
	sky_material.sky_horizon_color = Color(0.76, 0.79, 0.77)
	sky_material.ground_horizon_color = sky_material.sky_horizon_color
	sky.sky_material = sky_material
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.45
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.ssao_enabled = true
	environment.ssao_intensity = 0.65
	environment.fog_enabled = true
	environment.fog_light_color = Color(0.77, 0.78, 0.73)
	environment.fog_density = 0.0009
	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	world.environment = environment
	attach(world, site)
	var sun := DirectionalLight3D.new()
	sun.name = "AfternoonSun"
	sun.rotation_degrees = Vector3(-42, -35, 0)
	sun.light_color = Color(1, 0.93, 0.82)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 220
	attach(sun, site)


func make_cameras() -> void:
	var views := {"OverviewCamera":[Vector3(-85, 105, 150), Vector3(32, 0, 32)], "EntranceCamera":[Vector3(-23, 4, 106), Vector3(12, 1, 50)], "WorkFaceCamera":[Vector3(47, 4.8, 49), Vector3(29, 1.4, 22)]}
	for key: String in views:
		var camera := Camera3D.new()
		camera.name = key
		camera.position = views[key][0]
		camera.fov = 60
		camera.far = 800
		attach(camera, site)
		camera.look_at(views[key][1])
	var free := Camera3D.new()
	free.name = "ReviewCamera"
	free.far = 800
	free.set_script(load("res://scripts/review_camera.gd"))
	attach(free, site)
	var hud := CanvasLayer.new()
	hud.name = "ReviewHUD"
	attach(hud, site)
	var label := Label.new()
	label.text = "EARTHWORKS / 地编预览\n1 总览   2 入口   3 工作面   F1 尺寸与边界\n按住右键 + WASD 移动 / QE 升降 / Shift 加速"
	label.position = Vector2(24, 20)
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	attach(label, hud)


func material(color: Color) -> StandardMaterial3D:
	var result := StandardMaterial3D.new()
	result.albedo_color = color
	result.roughness = 0.88
	return result


func box(parent: Node, label: String, position: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = label
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.material_override = material(color)
	node.position = position
	attach(node, parent)
	return node


func line(parent: Node, label: String, a: Vector3, b: Vector3, width: float, color: Color) -> void:
	var node := box(parent, label, (a + b) * 0.5, Vector3(width, width, a.distance_to(b)), color)
	if not a.is_equal_approx(b):
		node.look_at(b)


func make_diagnostics() -> void:
	var diagnostics := Node3D.new()
	diagnostics.name = "Diagnostics"
	attach(diagnostics, site)
	diagnostics.visible = false
	for x in [0, 64]:
		line(diagnostics, "VoxelEdgeX%d" % x, Vector3(x, 0.1, 0), Vector3(x, 0.1, 64), 0.12, Color.CYAN)
	for z in [0, 64]:
		line(diagnostics, "VoxelEdgeZ%d" % z, Vector3(0, 0.1, z), Vector3(64, 0.1, z), 0.12, Color.CYAN)
	for i in 64:
		var a := float(i) / 64.0 * TAU
		var b := float(i + 1) / 64.0 * TAU
		line(diagnostics, "TurnRadius%d" % i, Vector3(-15 + 15 * cos(a), 0.15, 79 + 15 * sin(a)), Vector3(-15 + 15 * cos(b), 0.15, 79 + 15 * sin(b)), 0.07, Color.ORANGE)
	box(diagnostics, "TruckEnvelope8x3", Vector3(-15, 1.75, 69), Vector3(3, 3.5, 8), Color(0.12, 0.36, 0.60))
	box(diagnostics, "ExcavatorEnvelope", Vector3(34, 1.5, 42), Vector3(3, 3, 9), Color(0.70, 0.42, 0.04))
	line(diagnostics, "RoadWidth9m", Vector3(-19.5, 0.15, 50), Vector3(-10.5, 0.15, 50), 0.15, Color.ORANGE)


func make_dressing() -> void:
	var dressing := Node3D.new()
	dressing.name = "SiteDressing"
	attach(dressing, site)
	var entry := section(dressing, "EntryCheckpoint")
	var maintenance := section(dressing, "MaintenanceYard")
	var materials := section(dressing, "MaterialYard")
	var stockpiles := section(dressing, "Stockpiles")
	var perimeter := section(dressing, "Perimeter")
	var boundary := section(dressing, "WorkZoneBoundary")
	var drainage := section(dressing, "Drainage")
	var orange := Color(0.88, 0.27, 0.05)
	var concrete := Color(0.57, 0.56, 0.50)
	# Entrance gate leaves a 10m opening, outside the haul-road envelope.
	for x in [-24, -6]:
		box(entry, "GatePost", Vector3(x, 1.2, 99), Vector3(0.3, 2.4, 0.3), orange)
	box(entry, "SiteOffice", Vector3(-34, 1.45, 92), Vector3(8, 2.9, 3.5), Color(0.68, 0.71, 0.67))
	box(entry, "OfficeRoof", Vector3(-34, 2.96, 92), Vector3(8.3, 0.18, 3.8), Color(0.21, 0.28, 0.29))
	for x in [-36, -33, -30]:
		box(entry, "OfficeWindow", Vector3(x, 1.7, 93.77), Vector3(1.1, 0.9, 0.04), Color(0.12, 0.24, 0.29))
	for z in range(-34, 86, 6):
		box(perimeter, "WestPerimeterPost", Vector3(-48, 0.9, z), Vector3(0.12, 1.8, 0.12), concrete)
		line(perimeter, "PerimeterRail", Vector3(-48, 1.15, z), Vector3(-48, 1.15, z + 6), 0.05, Color(0.28, 0.29, 0.26))
	# Low barriers along three sides; the southern approach stays open.
	for z in range(3, 64, 5):
		for x in [-2, 66]:
			box(boundary, "WorkZoneBarrier", Vector3(x, 0.4, z), Vector3(0.45, 0.8, 3.5), concrete)
			box(boundary, "BarrierMarker", Vector3(x, 0.85, z), Vector3(0.46, 0.14, 0.5), orange)
	for x in range(3, 64, 5):
		box(boundary, "NorthBarrier", Vector3(x, 0.4, -2), Vector3(3.5, 0.8, 0.45), concrete)
	# Drainage follows the outer east yard; stones make the depression readable.
	for z in range(-25, 91, 3):
		box(drainage, "DrainEdge", Vector3(106.7, 0.05, z), Vector3(0.2, 0.12, 2.9), concrete)
		box(drainage, "DrainEdge", Vector3(109.3, 0.05, z), Vector3(0.2, 0.12, 2.9), concrete)
	# Open service shelter, equipment stands and static maintenance bays.
	for x in [-43, -30]:
		for z in [20, 32]:
			box(maintenance, "ServiceColumn", Vector3(x, 2.5, z), Vector3(0.2, 5, 0.2), Color(0.25, 0.28, 0.27))
	box(maintenance, "ServiceRoof", Vector3(-36.5, 5.15, 26), Vector3(14, 0.25, 13), Color(0.31, 0.37, 0.36))
	for z in [10, 40, 49]:
		box(maintenance, "MaintenanceStand", Vector3(-36, 0.55, z), Vector3(2.4, 1.1, 1.4), orange)
	# Material stacks use lightweight reusable primitive geometry.
	for x in [94, 99]:
		for z in [16, 22, 28]:
			box(materials, "MaterialStack", Vector3(x, 0.65, z), Vector3(3, 1.3, 3.2), concrete)
	for i in 5:
		var mound := MeshInstance3D.new()
		mound.name = "Stockpile%d" % i
		var mesh := SphereMesh.new()
		mesh.radius = 1
		mesh.height = 2
		mesh.radial_segments = 24
		mesh.rings = 12
		mound.mesh = mesh
		mound.scale = Vector3(7 + i * 0.7, 2.7 + i * 0.3, 5)
		mound.position = Vector3(-25 + i * 23, -0.3, -35)
		mound.material_override = load("res://materials/soil.tres")
		attach(mound, stockpiles)
	var placements := [["pipe", Vector3(96, 0, 42)], ["pallet", Vector3(-29, 0, 96)], ["sand", Vector3(96, 0, -28)]]
	for placement: Array in placements:
		var anchor := Node3D.new()
		anchor.name = "Asset_" + placement[0]
		anchor.set_script(load("res://scripts/asset_instance.gd"))
		anchor.set("asset_id", placement[0])
		anchor.position = placement[1]
		attach(anchor, dressing)
	for i in 12:
		var plant := Node3D.new()
		plant.name = "EdgePlant%d" % i
		plant.set_script(load("res://scripts/asset_instance.gd"))
		plant.set("asset_id", "plant")
		var p := Vector2(-53 + i * 14, -47 + 3 * sin(i))
		plant.position = Vector3(p.x, Profile.hard_height(p), p.y)
		plant.rotation.y = i * 2.39
		attach(plant, perimeter)
	for info: Array in [["入口 / ENTRY", Vector3(-26, 3.5, 100)], ["设备维护", Vector3(-36, 6, 27)], ["管材堆场", Vector3(96, 3, 32)], ["开挖工作面", Vector3(32, 5, 17)], ["弃土 / 堆料", Vector3(26, 5, -35)]]:
		var sign := Label3D.new()
		sign.name = "ZoneSign"
		sign.text = info[0]
		sign.position = info[1]
		sign.font_size = 48
		sign.pixel_size = 0.018
		sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		attach(sign, dressing)


func section(parent: Node, label: String) -> Node3D:
	var node := Node3D.new()
	node.name = label
	attach(node, parent)
	return node

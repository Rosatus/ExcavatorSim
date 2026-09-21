extends SceneTree
## Forward+ render: --path godot/client --script ../../tools/preview_bucket_soil.gd
## -- res://resources/attachments/<tool>_soil_bake.json <absolute-output-directory>
const Geometry = preload("res://scripts/bucket_soil_geometry.gd")
const Fill = preload("res://scripts/bucket_fill_surface.gd")
const Materials = preload("res://scripts/soil_visual_resources.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2 or not args[1].is_absolute_path():
		return _fail("provide recipe path and absolute output directory")
	var recipe: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	if not recipe is Dictionary or not recipe.get("contract_path") is String:
		return _fail("invalid recipe")
	var contract: Variant = JSON.parse_string(FileAccess.get_file_as_string(recipe.contract_path))
	if not contract is Dictionary:
		return _fail("invalid contract")
	var fill := Fill.new()
	if not fill.configure_contract(contract, Vector3.ONE):
		return _fail("contract/profile failed validation; bake first")
	if DisplayServer.get_name() == "headless":
		return _fail("preview requires a rendering display; omit --headless")
	if DirAccess.make_dir_recursive_absolute(args[1]) != OK:
		return _fail("cannot create output directory")
	var world := Node3D.new()
	root.add_child(world)
	var asset := load(recipe.asset_path).instantiate() as Node3D
	world.add_child(asset)
	var tool := asset.find_child(recipe.root_node, true, false) as Node3D
	if tool == null:
		world.free()
		return _fail("tool root not found")
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.16, 0.18, 0.21)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.8, 0.85, 1)
	environment.environment.ambient_light_energy = 0.65
	world.add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -30, 0)
	light.light_energy = 2.0
	world.add_child(light)
	var local := Geometry.cavity(contract.soil_geometry)
	var cavity_world := tool.global_transform * local
	var size := Geometry.mouth(contract.soil_geometry.mouth_polygon_godot).size as Vector2
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.position = cavity_world * Vector3(size.x, maxf(size.x, size.y) * 1.7, size.y)
	camera.look_at(cavity_world.origin, cavity_world.basis.y)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = maxf(size.x, size.y) * 1.65
	camera.current = true
	var visual := MeshInstance3D.new()
	tool.add_child(visual)
	visual.transform = local
	visual.material_override = Materials.surface_material(false)
	for ratio in [0.05, 0.5, 1.0]:
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, fill.build_arrays(ratio))
		visual.mesh = mesh
		for index in 5:
			await process_frame
		await RenderingServer.frame_post_draw
		var path := args[1].path_join("fill-%03d.png" % roundi(ratio * 100))
		if root.get_texture().get_image().save_png(path) != OK:
			world.free()
			return _fail("cannot save " + path)
		print(path)
	world.free()
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)

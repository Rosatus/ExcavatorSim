extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty() or DisplayServer.get_name() == "headless":
		push_error("Pass an output directory and use a rendering display.")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(args[0])
	root.size = Vector2i(1400, 1000)
	var world := Node3D.new()
	root.add_child(world)
	var presentation_root := Node3D.new()
	presentation_root.name = "PresentationRoot"
	world.add_child(presentation_root)
	var client := MotionClient.new()
	client.name = "MotionClient"
	client.auto_connect = false
	client.auto_reconnect = false
	client.desired_model_id = "sy155w"
	world.add_child(client)
	var presentation := MotionPresentation.new()
	presentation.name = "MotionPresentation"
	world.add_child(presentation)
	var attachments := AttachmentRig.new()
	attachments.motion_presentation_path = NodePath("../MotionPresentation")
	attachments.motion_client_path = NodePath("../MotionClient")
	world.add_child(attachments)
	if not presentation.get_contract_error().is_empty() or attachments.active_attachment_id() != "xtr13+gb12":
		push_error("Preview model/default attachment failed: " + presentation.get_contract_error())
		quit(1)
		return
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.17, 0.2, 0.24)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.85, 0.9, 1)
	environment.environment.ambient_light_energy = 0.7
	world.add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -25, 0)
	light.light_energy = 2.0
	light.shadow_enabled = true
	world.add_child(light)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.23, 0.26, 0.29)
	plane.material = material
	floor_mesh.mesh = plane
	world.add_child(floor_mesh)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 10.0
	camera.current = true
	var views := [
		["overview", Vector3(-10, 6, -11), Vector3(0, 2, -1.6), 10.],
		["side", Vector3(-12, 3, -2), Vector3(0, 2, -2), 9.],
		["hydraulics", Vector3(8, 5, -6), Vector3(0, 3, -2), 7.],
	]
	for view in views:
		camera.size = view[3]
		camera.position = view[1]
		camera.look_at(view[2])
		for frame in 5:
			await process_frame
		await RenderingServer.frame_post_draw
		var path := args[0].path_join(String(view[0]) + ".png")
		root.get_texture().get_image().save_png(path)
		print(path)
	world.free()
	quit(0)

extends SceneTree

func _init() -> void:
	call_deferred("run")

func run() -> void:
	root.get_node("MapCatalog").active_map_id = "training" if "--training" in OS.get_cmdline_user_args() else "urban"
	root.get_node("MapCatalog").retained_model_id = "sy135"
	var scene := load("res://scenes/main.tscn").instantiate() as Node3D
	scene.get_node("OperatorUI").preferences_path = "user://surface-job-test-unused.cfg"
	root.add_child(scene)
	current_scene = scene
	await process_frame
	var session := scene.get_node("ProductSession") as ProductSession
	var chassis := scene.get_node("ChassisMotionRoot") as TrackedChassisController
	session.request_start()
	session.request_simple_digging("--simple" in OS.get_cmdline_user_args())
	for i in 240:
		session.set_focused(true)
		await physics_frame
	var bucket := DtmModel.bucket_state(scene.get_node("MotionPresentation"))
	var sampler := DtmSurfaceSampler.new()
	sampler.zone = scene.get_node("TerrainRoot/VoxelWorkZone")
	var tooth: Vector3 = bucket.tooth
	var axis: Vector2 = bucket.axis
	var side := Vector2(-axis.y, axis.x)
	var center := Vector2(tooth.x, tooth.z)
	var height := sampler.height_at(center)
	print("URBAN_START ", bucket, " surface=", height, " body=", chassis.peek_runtime_snapshot().body_transform.origin)
	if not is_finite(height):
		quit(1)
		return
	var ui := scene.get_node("OperatorUI")
	ui._toggle_dtm()
	var dashboard: DtmDashboard = ui._dtm
	assert(dashboard.visible, "DTM must be open for button acceptance")
	dashboard.controls["urban_trench"].pressed.emit()
	assert(dashboard.model.surface != null, "DTM button must load parsed LandXML")
	dashboard.controls["automatic"].pressed.emit()
	if not chassis.surface_job.active():
		push_error("DTM_START_FAILED " + chassis.surface_job.reason)
		quit(1)
		return
	print("DTM_BUTTON_CHAIN PASS")
	var previous := ""
	var initial: Dictionary = chassis.peek_runtime_snapshot().duplicate()
	var maximum_yaw := 0.0
	var maximum_lateral := 0.0
	for i in 36000:
		session.set_focused(true)
		await physics_frame
		var status := chassis.surface_job.snapshot()
		var physics := chassis.peek_runtime_snapshot()
		var heading: Vector3 = physics.vehicle_forward_world
		var initial_heading: Vector3 = initial.vehicle_forward_world
		maximum_yaw = maxf(maximum_yaw, absf(Vector2(heading.x, heading.z).angle_to(Vector2(initial_heading.x, initial_heading.z))))
		var movement: Vector3 = physics.body_transform.origin - initial.body_transform.origin
		maximum_lateral = maxf(maximum_lateral, absf(Vector2(movement.x, movement.z).dot(side)))
		var key := str(status)
		if previous != key or i % 600 == 0:
			print("JOB ", i, " ", status, " tooth=", DtmModel.bucket_state(scene.get_node("MotionPresentation")).tooth, " goal=", chassis.surface_job.goal)
			previous = key
		if not chassis.surface_job.active():
			break
	var result := chassis.surface_job.snapshot()
	print("URBAN_RESULT ", result)
	var passed: bool = result.state == "completed" and result.completed >= 2
	var max_remaining := -INF
	var min_remaining := INF
	for longitudinal in 20:
		for lateral in 5:
			var p := center - axis * ((longitudinal + 0.5) * 0.1) + side * ((lateral - 2) * 0.2)
			var actual := sampler.height_at(p)
			passed = passed and is_finite(actual)
			max_remaining = maxf(max_remaining, actual - (height - 1.0))
			min_remaining = minf(min_remaining, actual - (height - 1.0))
	print("URBAN_GEOMETRY max_remaining=", max_remaining, " min_remaining=", min_remaining,
		" max_yaw_deg=", rad_to_deg(maximum_yaw), " lateral=", maximum_lateral)
	passed = passed and max_remaining <= SurfaceJobPlanner.TOLERANCE and min_remaining >= -SurfaceJobPlanner.TOLERANCE and maximum_yaw < deg_to_rad(1) and maximum_lateral < 0.05
	scene.queue_free()
	await process_frame
	quit(0 if passed else 1)

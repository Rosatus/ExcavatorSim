extends SceneTree

func _init() -> void:
	call_deferred("run")

func run() -> void:
	root.get_node("MapCatalog").active_map_id = "training"
	root.get_node("MapCatalog").retained_model_id = "sy135"
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	scene.get_node("OperatorUI").preferences_path = "user://surface-training-test.cfg"
	root.add_child(scene)
	current_scene = scene
	var session := scene.get_node("ProductSession") as ProductSession
	var chassis := scene.get_node("ChassisMotionRoot") as TrackedChassisController
	session.request_start()
	for i in 240:
		session.set_focused(true)
		await physics_frame
	var ui := scene.get_node("OperatorUI")
	ui._toggle_dtm()
	var dashboard: DtmDashboard = ui._dtm
	dashboard.controls["simple_digging"].toggled.emit(true)
	var kind := "pit" if "--pit" in OS.get_cmdline_user_args() else "trench"
	dashboard.controls[kind].pressed.emit()
	dashboard.controls["automatic"].pressed.emit()
	for i in 4:
		session.set_focused(true)
		await physics_frame
	print("TRAINING_START ", kind, " ", chassis.surface_job.snapshot())
	var previous := ""
	var elapsed_ticks := 0
	for tick in 300000:
		elapsed_ticks = tick + 1
		session.set_focused(true)
		await physics_frame
		var status := chassis.surface_job.snapshot()
		var key := str(status)
		if key != previous or tick % 1800 == 0:
			print("TRAINING_JOB ", tick, " ", status, " body=", chassis.peek_runtime_snapshot().body_transform.origin, " tooth=", DtmModel.bucket_state(scene.get_node("MotionPresentation")).tooth, " goal=", chassis.surface_job.goal)
			previous = key
			if status.state == "verify":
				print("ROW_HEIGHTS ", dashboard.model.sampler.height_at(Vector2(chassis.surface_job.goal.x, chassis.surface_job.goal.z)), " envelope=", chassis.surface_job.envelope_debug, " cutter=", scene.get_node("TerrainRoot/ExcavationWorld")._voxel_authority.get_status_snapshot().last_cutter_result)
		if not chassis.surface_job.active():
			break
	var result := chassis.surface_job.snapshot()
	print("TRAINING_RESULT ", kind, " ", result)
	var expected := 36 if kind == "pit" else 12
	var passed: bool = result.state == "completed" and result.completed == expected and result.count == expected and result.simple_mode and result.dump_cycles == 0
	print("TRAINING_DURATION frames=", elapsed_ticks, " seconds=", elapsed_ticks / 60.0, " timeout=", chassis.surface_job.active())
	if result.state == "completed":
		# Independent, denser grid, offset from the planner's cell centers.
		var low := INF
		var high := -INF
		var count := 0
		var half_width := 3.0 if kind == "pit" else 0.5
		var start_z := 21.0 if kind == "pit" else 18.0
		var length := 6.0 if kind == "pit" else 12.0
		var target := -1.5 if kind == "pit" else -1.0
		for x_index in int(round(half_width * 2.0 / 0.05)):
			for z_index in int(round(length / 0.05)):
				var point := Vector2(-half_width + 0.025 + x_index * 0.05, start_z + 0.025 + z_index * 0.05)
				var height := dashboard.model.sampler.height_at(point)
				passed = passed and is_finite(height) and absf(height - target) <= 0.08
				low = minf(low, height - target)
				high = maxf(high, height - target)
				count += 1
		print("TRAINING_INDEPENDENT samples=", count, " min=", low, " max=", high)
	print("TRAINING_ACCEPTANCE ", "PASS" if passed else "FAIL")
	scene.queue_free()
	await process_frame
	quit(0 if passed else 1)


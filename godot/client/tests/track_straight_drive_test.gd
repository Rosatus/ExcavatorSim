extends SceneTree

var failures: Array[String] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	if "--training" in OS.get_cmdline_user_args():
		await training()
		quit(0 if failures.is_empty() else 1)
		return
	var models := ["sy135", "sy80u", "sy205"]
	if "--primary" in OS.get_cmdline_user_args():
		models = ["sy135"]
	for model in models:
		for yaw in [0.0, 0.7]:
			await exercise(model, yaw)
	for failure in failures:
		push_error(failure)
	quit(0 if failures.is_empty() else 1)

func training() -> void:
	var map_id := "construction" if "--construction" in OS.get_cmdline_user_args() else ("urban" if "--urban" in OS.get_cmdline_user_args() else "training")
	root.get_node("MapCatalog").active_map_id = map_id
	root.get_node("MapCatalog").retained_model_id = "sy135"
	var scene := load("res://scenes/main.tscn").instantiate() as Node3D
	scene.get_node("OperatorUI").preferences_path = "user://navigation-test-unused.cfg"
	root.add_child(scene)
	current_scene = scene
	await process_frame
	var session := scene.get_node("ProductSession") as ProductSession
	var chassis := scene.get_node("ChassisMotionRoot") as TrackedChassisController
	session.request_start()
	if "--normal" in OS.get_cmdline_user_args():
		session.request_bucket_ground_mode(BucketGroundInteractionMode.NORMAL)
	for i in 180:
		session.set_focused(true)
		await physics_frame
	chassis.set_commands_for_test(1, 1)
	for i in 600:
		session.set_focused(true)
		await physics_frame
		if i % 60 == 0:
			var sample := chassis.get_status_snapshot()
			print("TRAIN_STRAIGHT t=", i/60.0, " p=", sample.body_transform.origin, " forward=", sample.vehicle_forward_world, " w=", sample.angular_velocity, " load=", [sample.left_support_load_n,sample.right_support_load_n], " speed=", [sample.left_speed_mps,sample.right_speed_mps], " sources=",sample.track_support_source_counts, " flags=", sample.quality_flags, " wrench=", sample.applied_chassis_wrench)
	scene.queue_free()
	await process_frame
	await physics_frame

func exercise(model: String, yaw: float) -> void:
	var host := Node3D.new()
	root.add_child(host)
	var ground := StaticBody3D.new()
	ground.name = "FlatGround"
	host.add_child(ground)
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	collision.shape = box
	collision.position.y = -0.5
	ground.add_child(collision)
	var descriptor := PhysicsRigDescriptor.load_for_model(model)
	var runtime := JoltChassisTrackRuntime.new()
	host.add_child(runtime)
	if not runtime.configure(descriptor, null, null, Transform3D(Basis(Vector3.UP, yaw), Vector3(0, 0.1, 0)), ground):
		failures.append("configure " + model)
		host.queue_free()
		await process_frame
		return
	runtime.set_commands(0, 0)
	for i in 180:
		await physics_frame
	var initial := runtime.get_status_snapshot()
	var start: Vector3 = initial.body_transform.origin
	var forward: Vector3 = initial.vehicle_forward_world
	var right := forward.cross(Vector3.UP).normalized()
	runtime.set_commands(1, 1)
	for i in 600:
		await physics_frame
		if i % 120 == 0:
			var sample := runtime.get_status_snapshot()
			print("STRAIGHT_SAMPLE ", model, " yaw=", yaw, " t=", i / 60.0, " x=", (sample.body_transform.origin-start).dot(right), " w=", sample.angular_velocity, " load=", [sample.left_support_load_n, sample.right_support_load_n], " speed=", [sample.left_speed_mps, sample.right_speed_mps], " effort=", [sample.left_effort_n, sample.right_effort_n])
	var final := runtime.get_status_snapshot()
	var moved: Vector3 = final.body_transform.origin - start
	var error := absf(moved.dot(right))
	var heading_error := absf(forward.signed_angle_to(final.vehicle_forward_world, Vector3.UP))
	print("STRAIGHT_RESULT ", model, " yaw=", yaw, " distance=", moved.dot(forward), " lateral=", error, " heading_deg=", rad_to_deg(heading_error))
	if error > 0.1 or heading_error > deg_to_rad(0.5):
		failures.append("%s equal input drift yaw=%.2f lateral=%.4f heading=%.3f" % [model, yaw, error, rad_to_deg(heading_error)])
	host.queue_free()
	await process_frame
	await physics_frame

extends SceneTree

var failures: Array[String] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var catalog := root.get_node("MapCatalog")
	if not catalog.construction_available():
		push_error("construction map pack required")
		quit(1)
		return
	catalog.active_map_id = "construction"
	catalog.retained_model_id = "sy135"
	var scene := load("res://scenes/main.tscn").instantiate() as Node3D
	root.add_child(scene)
	current_scene = scene
	await process_frame
	for i in 120:
		await physics_frame
	scene.get_node("ProductSession").request_model_switch("sy155w")
	await process_frame
	scene.get_node("ProductSession").request_race_mode("--race" in OS.get_cmdline_user_args())
	scene.get_node("ProductSession").request_start()
	scene.get_node("ProductSession").set_focused(true)
	var chassis := scene.get_node("ChassisMotionRoot") as TrackedChassisController
	chassis.set_test_input_focus_bypass_for_test(true)
	print("JOYPADS ", Input.get_connected_joypads())
	var settled := Vector3.ZERO
	var max_drift := 0.0
	var max_speed := 0.0
	var max_angular := 0.0
	for i in 900:
		scene.get_node("ProductSession").set_focused(true)
		await physics_frame
		if i == 120:
			chassis._jolt_runtime._body.angular_velocity.x = 0.02
		var runtime := chassis._jolt_runtime
		if i == 240:
			settled = runtime._body.position
		if i >= 240:
			max_drift = maxf(max_drift, runtime._body.position.distance_to(settled))
			max_speed = maxf(max_speed, runtime._body.linear_velocity.length())
			max_angular = maxf(max_angular, runtime._body.angular_velocity.length())
		if i % 60 == 0:
			print("IDLE ", i, " pos=", runtime._body.position, " vel=", runtime._body.linear_velocity, " command=", runtime._wheel_command)
	if max_drift > 0.005 or max_speed > 0.01 or max_angular > 0.01:
		failures.append("persistent idle motion: drift=%s speed=%s angular=%s" % [max_drift, max_speed, max_angular])
	print("SY155W construction idle: ", "PASS" if failures.is_empty() else failures, " drift=", max_drift, " speed=", max_speed, " angular=", max_angular)
	scene.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)

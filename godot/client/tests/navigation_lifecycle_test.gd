extends SceneTree

const Driver := preload("res://scripts/waypoint_driver.gd")
var failures: Array[String] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	unit_guards()
	root.get_node("MapCatalog").active_map_id = "training"
	var scene := load("res://scenes/main.tscn").instantiate() as Node3D
	scene.get_node("OperatorUI").preferences_path = "user://navigation-test-unused.cfg"
	root.add_child(scene)
	current_scene = scene
	await process_frame
	await physics_frame
	var session := scene.get_node("ProductSession") as ProductSession
	var chassis := scene.get_node("ChassisMotionRoot") as TrackedChassisController
	for model in ["sy135", "sy155w"]:
		if session.active_model_id != model:
			check(session.request_model_switch(model), "switch model")
			await process_frame
			await physics_frame
		session.request_start()
		for i in 120:
			session.set_focused(true)
			await physics_frame
		chassis.set_assist_menu_open(true)
		chassis.activate_assist_entry(2)
		check(chassis.waypoint_driver.is_active() and not chassis.is_assist_menu_open(), model + " menu starts navigation")
		for i in 12:
			await physics_frame
		check(bool(chassis.peek_runtime_snapshot().track_neutral_armed), model + " legal neutral rearm")
		var action := "wheel_forward" if model == "sy155w" else "track_left_forward"
		Input.action_press(action)
		await physics_frame
		await physics_frame
		check(chassis.waypoint_driver.state == "cancelled", model + " manual takeover")
		Input.action_release(action)
		await physics_frame
		check(chassis.start_training_square(), "restart")
		session.set_focused(false)
		check(chassis.waypoint_driver.state == "paused", model + " focus pause")
		session.set_focused(true)
		await physics_frame
		check(chassis.waypoint_driver.state == "paused", model + " no automatic resume")
		check(chassis.resume_navigation(), "explicit resume")
		chassis.set_assist_menu_open(true)
		chassis.set_assist_menu_open(false)
		check(chassis.waypoint_driver.state == "paused", model + " menu pause latched")
		chassis.set_level_assist_enabled(true)
		check(chassis.waypoint_driver.state == "cancelled", "direct assist setter cancels navigation")
		chassis.set_level_assist_enabled(false)
		check(chassis.start_training_square(), "start before reset")
		session.request_reset()
		check(chassis.waypoint_driver.state == "cancelled" and chassis.waypoint_driver.points.is_empty(), "reset retires route")
		session.request_start()
		await physics_frame
	scene.queue_free()
	await process_frame
	await physics_frame
	for failure in failures:
		push_error(failure)
	print("NAVIGATION_LIFECYCLE ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

func sample() -> Dictionary:
	return {"configured": true, "body_transform": Transform3D.IDENTITY,
		"linear_velocity": Vector3.ZERO, "angular_velocity": Vector3.ZERO,
		"vehicle_forward_world": Vector3.FORWARD, "authority_epoch": "sy135:100",
		"physics_tick": 1, "grounded": true, "locomotion_mode": "tracked"}

func unit_guards() -> void:
	alignment_guard()
	precision_arrival_guard()
	var driver := Driver.new()
	var snapshot := sample()
	var route := PackedVector3Array([Vector3(10, 0, 0)])
	check(driver.start(route, snapshot), "valid route")
	snapshot.authority_epoch = "sy135:101"
	check(driver.step(1.0 / 60, snapshot) == Vector3.ZERO and driver.state == "failed", "same-model epoch invalidation")
	snapshot = sample()
	driver.start(route, snapshot)
	for i in 30:
		driver.step(1.0 / 60, snapshot)
	check(driver.state == "failed" and driver.reason == "stale_state", "stale tick stops")
	driver.start(route, snapshot)
	for i in 650:
		snapshot.physics_tick += 1
		driver.step(1.0 / 60, snapshot)
	check(driver.state == "failed" and driver.reason == "no_progress", "blocked pivot stops")
	driver.start(route, snapshot)
	snapshot.grounded = false
	for i in 40:
		snapshot.physics_tick += 1
		driver.step(1.0 / 60, snapshot)
	check(driver.state == "failed" and driver.reason == "unsupported", "unsupported stops")
	check(not driver.start(PackedVector3Array([Vector3(NAN, 0, 0)]), sample()), "nonfinite target rejected")
	snapshot = sample()
	snapshot.locomotion_mode = "wheeled"
	check(not driver.start(PackedVector3Array([Vector3.ZERO, Vector3(1, 0, 0)]), snapshot), "unfeasible short wheel segments rejected")

func precision_arrival_guard() -> void:
	var driver := Driver.new()
	var value := sample()
	driver.start(PackedVector3Array([Vector3(10, 0, 0), Vector3(10, 0, 10)]), value)
	driver.state = "driving"
	value.vehicle_forward_world = Vector3.RIGHT
	value.body_transform.origin = Vector3(9.75, 0, 0)
	value.physics_tick += 1
	var approach := driver.step(1.0 / 60, value)
	check(driver.index == 0 and driver.state == "driving" and approach.x + approach.y > 0, "25 cm short requires continued approach")
	check((approach.x + approach.y) * 0.5 * driver.belt_speed <= 0.21, "final approach is at crawl speed")
	value.body_transform.origin = Vector3(9.98, 0, 0)
	value.linear_velocity = Vector3(0.1, 0, 0)
	for i in 30:
		value.physics_tick += 1
		driver.step(1.0 / 60, value)
	check(driver.index == 0 and driver.state == "braking", "near vertex must stop before switching edge")
	value.linear_velocity = Vector3.ZERO
	for i in 24:
		value.physics_tick += 1
		driver.step(1.0 / 60, value)
	check(driver.index == 1 and driver.state == "aligning", "precise stable arrival advances to pivot")
	value.body_transform.origin = Vector3(9.8, 0, 0)
	value.vehicle_forward_world = Vector3.BACK
	for i in 20:
		value.physics_tick += 1
		driver.step(1.0 / 60, value)
	check(driver.state == "failed" and driver.reason == "position_tolerance", "pivot drift outside next edge cannot start travel")

func alignment_guard() -> void:
	var driver := Driver.new()
	var value := sample()
	driver.start(PackedVector3Array([Vector3(12, 0, 0)]), value)
	# Stopped 25 cm beside the next edge: lookahead points diagonally, but
	# pivot completion must be measured against the eastbound edge itself.
	value.body_transform = Transform3D(Basis.IDENTITY, Vector3(0, 0, 0.25))
	value.vehicle_forward_world = Vector3(cos(deg_to_rad(10)), 0, -sin(deg_to_rad(10)))
	for i in 90:
		value.physics_tick += 1
		var command := driver.step(1.0 / 60, value)
		check(absf(command.x + command.y) < 0.00001, "no forward command before segment alignment")
	check(driver.state == "aligning", "10 degree segment error cannot release pivot")
	value.vehicle_forward_world = Vector3.RIGHT
	value.angular_velocity = Vector3(0, 0.1, 0)
	for i in 20:
		value.physics_tick += 1
		driver.step(1.0 / 60, value)
	check(driver.state == "aligning", "heading crossing with yaw momentum cannot release pivot")
	value.angular_velocity = Vector3.ZERO
	for i in 10:
		value.physics_tick += 1
		driver.step(1.0 / 60, value)
	check(driver.state == "aligning", "alignment needs stable dwell")
	for i in 5:
		value.physics_tick += 1
		driver.step(1.0 / 60, value)
	check(driver.state == "driving", "stable segment alignment releases pivot despite lateral offset")

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)

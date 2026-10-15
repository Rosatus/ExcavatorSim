extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	call_deferred("run")


func run() -> void:
	var model := "sy155w" if "--wheeled" in OS.get_cmdline_user_args() else "sy135"
	root.get_node("MapCatalog").active_map_id = "training"
	root.get_node("MapCatalog").retained_model_id = model
	var scene := load("res://scenes/main.tscn").instantiate() as Node3D
	scene.get_node("OperatorUI").preferences_path = "user://navigation-test-unused.cfg"
	root.add_child(scene)
	current_scene = scene
	await process_frame
	await physics_frame
	var session := scene.get_node("ProductSession") as ProductSession
	var chassis := scene.get_node("ChassisMotionRoot") as TrackedChassisController
	if session.active_model_id != model:
		check(session.request_model_switch(model), "model switch")
		await process_frame
		await physics_frame
	session.request_start()
	session.set_focused(true)
	for i in 180:
		session.set_focused(true)
		await physics_frame
	check(chassis.start_training_square(), "start production square")
	var last_index := -1
	var max_cross_track := 0.0
	var edge_distances := [INF, INF, INF, INF]
	var corners := [Vector2(-6, -8), Vector2(6, -8), Vector2(6, 4), Vector2(-6, 4)]
	var elapsed := 0.0
	var previous_state := ""
	var alignment_count := 0
	var max_departure_angle := 0.0
	var max_departure_offset := 0.0
	var phase_seconds := {}
	for i in 18000:
		session.set_focused(true)
		await physics_frame
		elapsed += 1.0 / 60.0
		var nav := chassis.navigation_snapshot()
		var actual := chassis.peek_runtime_snapshot()
		phase_seconds[nav.state] = float(phase_seconds.get(nav.state, 0.0)) + 1.0 / 60.0
		if model == "sy135" and previous_state == "aligning" and nav.state == "driving":
			var driver = chassis.waypoint_driver
			var direction: Vector3 = driver.points[driver.index] - driver.segment_start
			var heading: Vector3 = actual.vehicle_forward_world
			var angle := absf(Vector2(heading.x, heading.z).angle_to(Vector2(direction.x, direction.z)))
			max_departure_angle = maxf(max_departure_angle, rad_to_deg(angle))
			alignment_count += 1
			check(angle <= deg_to_rad(1.1), "fully aligned before departing: %.3f degrees" % rad_to_deg(angle))
			check(absf(actual.angular_velocity.y) <= 0.04, "yaw settled before departure")
			var p: Vector3 = actual.body_transform.origin
			var a: Vector3 = driver.segment_start
			var b: Vector3 = driver.points[driver.index]
			var offset := Vector2(p.x, p.z).distance_to(Geometry2D.get_closest_point_to_segment(Vector2(p.x, p.z), Vector2(a.x, a.z), Vector2(b.x, b.z)))
			max_departure_offset = maxf(max_departure_offset, offset)
			check(offset <= 0.05, "on next edge before departure: %.4f m" % offset)
		previous_state = String(nav.state)
		if int(nav.index) > 0:
			var position: Vector3 = actual.body_transform.origin
			var xz := Vector2(position.x, position.z)
			var route_error := INF
			for edge in 4:
				var a: Vector2 = corners[edge]
				var b: Vector2 = corners[(edge + 1) % 4]
				route_error = minf(route_error, xz.distance_to(Geometry2D.get_closest_point_to_segment(xz, a, b)))
				edge_distances[edge] = minf(edge_distances[edge], xz.distance_to((a + b) * 0.5))
			max_cross_track = maxf(max_cross_track, route_error)
		if int(nav.index) != last_index or i % 600 == 0:
			last_index = int(nav.index)
			print("NAV ", model, " t=", snappedf(elapsed, 0.1), " ", nav, " p=", actual.body_transform.origin, " v=", actual.forward_speed_m_s, " forward=", actual.vehicle_forward_world)
		if nav.state in ["completed", "failed", "cancelled", "paused"]:
			break
	var final_nav := chassis.navigation_snapshot()
	var final_state := chassis.peek_runtime_snapshot()
	var final_position: Vector3 = final_state.body_transform.origin
	var error := Vector2(final_position.x + 6, final_position.z + 8).length()
	check(final_nav.state == "completed", "square completed: " + JSON.stringify(final_nav))
	check(int(final_nav.completed_points) == 5, "all four sides after approach")
	check(error < (0.55 if model == "sy155w" else 0.05), "final position error %.3f" % error)
	check((final_state.linear_velocity as Vector3).length() < 0.12, "settled arrival")
	check(max_cross_track < (3.0 if model == "sy155w" else 0.65), "square cross track %.3f" % max_cross_track)
	for edge in 4:
		check(float(edge_distances[edge]) < 1.5, "visited side %d midpoint: %.3f" % [edge, edge_distances[edge]])
	if model == "sy135":
		check(alignment_count >= 5, "initial heading and four corners aligned")
		check(elapsed < 95.0, "responsive tracked square including approach: %.2f s" % elapsed)
		print("ALIGNMENT_RESULT count=", alignment_count, " max_departure_degrees=", max_departure_angle, " max_departure_offset_m=", max_departure_offset)
	print("SQUARE_RESULT ", model, " completed=", final_nav.state, " error=", error, " max_cross_track=", max_cross_track, " seconds=", elapsed)
	print("NAVIGATION_PHASE_SECONDS ", phase_seconds)
	scene.queue_free()
	await process_frame
	await physics_frame
	for failure in failures:
		push_error(failure)
	quit(0 if failures.is_empty() else 1)


func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)

extends SceneTree
## Race-mode coverage: overlay math, runtime solver swap, raised speed clamps,
## neutral rearm preservation, and byte-exact restoration of normal parameters.

const Demo = preload("res://scenes/wheeled_vehicle_demo.tscn")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func ticks(count: int) -> void:
	for i in count:
		await physics_frame


func _run() -> void:
	_test_overlay()
	await _test_tracked_race()
	await _test_wheeled_race()
	for failure in failures:
		push_error(failure)
	print("race_mode_test: %s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)


func _test_overlay() -> void:
	var tracked := RaceModeProfile.overlay_for("sy135", "tracked")
	check(not tracked.is_empty(), "tracked race overlay loads")
	check(
		float(tracked.get("params", {}).get("set", {}).get("max_belt_speed_m_s", 0.0)) > 5.0,
		"tracked race overlay raises belt speed"
	)
	var eff := RaceModeProfile.apply_overlay(
		{"max_belt_speed_m_s": 1.55, "friction": 1.1}, tracked.get("params", {})
	)
	check(is_equal_approx(eff["max_belt_speed_m_s"], 14.0), "set applies absolute belt speed")
	check(eff["friction"] > 1.1, "scale applies friction multiplier")
	# "scale" multiplies the original base value, and keys absent from the
	# base dictionary are ignored so solver validation never sees them.
	var merged := RaceModeProfile.apply_overlay(
		{"a": 2.0}, {"set": {"a": 5.0, "unknown": 9.0}, "scale": {"a": 3.0}}
	)
	check(merged["a"] == 6.0 and not merged.has("unknown"), "overlay scales base and ignores unknown keys")
	var wheeled := RaceModeProfile.overlay_for("sy155w", "wheeled")
	check(not wheeled.is_empty(), "wheeled race overlay loads")
	check(
		float(wheeled.get("assist", {}).get("downforce_n_per_m_s2", 0.0)) > 0.0,
		"wheeled overlay carries downforce assist"
	)
	# The product wheeled path must validate the overlaid sy155w profile.
	var sy155w := WheeledMachineProfile.load_for_model("sy155w")
	check(sy155w != null and sy155w.error.is_empty(), "sy155w wheeled profile loads")
	if sy155w != null and sy155w.error.is_empty():
		var base := WheeledLocomotionState.DEFAULTS.duplicate(true)
		for key in sy155w.data.parameters:
			base[key] = sy155w.data.parameters[key]
		var race_params := RaceModeProfile.apply_overlay(base, wheeled.get("params", {}))
		var solver := RaceWheeledLocomotionState.new()
		check(
			solver.configure_race(race_params, sy155w.stations, wheeled.get("assist", {})),
			"sy155w race params validate: %s" % solver.last_error
		)
		check(
			float(solver.parameters.get("max_speed_mps", 0.0)) >= 20.0,
			"sy155w race top speed raised"
		)


func _flat_map(host: Node3D) -> Node3D:
	var map := Node3D.new()
	host.add_child(map)
	var body := StaticBody3D.new()
	body.name = "Ground"
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = Vector3(0, -0.5, 0)
	map.add_child(body)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(700, 1, 700)
	collision.shape = shape
	body.add_child(collision)
	return map


func _test_tracked_race() -> void:
	var host := Node3D.new()
	root.add_child(host)
	var map := _flat_map(host)
	var runtime := JoltChassisTrackRuntime.new()
	host.add_child(runtime)
	await physics_frame
	var descriptor := PhysicsRigDescriptor.load_for_model("sy135")
	if descriptor == null:
		failures.append("sy135 descriptor missing")
		host.queue_free()
		return
	if not runtime.configure(descriptor, null, null, Transform3D(Basis.IDENTITY, Vector3(0, 0.13, 0)), map):
		failures.append("runtime configure: %s" % runtime.contract_error)
		host.queue_free()
		return
	var normal_belt := float(runtime._tracks["max_belt_speed_m_s"])
	runtime.set_commands(0, 0)
	await ticks(150)
	# Normal drive saturates near the work-machine belt speed.
	runtime.set_commands(1, 1)
	var normal_top := 0.0
	for i in 400:
		await physics_frame
		normal_top = maxf(normal_top, float(runtime.get_status_snapshot()["forward_speed_m_s"]))
	check(normal_top > 0.5 and normal_top < 2.4, "normal tracked drive stays near belt speed (%f)" % normal_top)
	# Race on: solver swap raises both belt speed and the body velocity clamp.
	runtime.set_race_mode(true)
	runtime.set_commands(0, 0)
	await ticks(2)
	check(runtime.get_status_snapshot()["race_mode"] == true, "snapshot reports race mode")
	check(float(runtime._tracks["max_belt_speed_m_s"]) > 10.0, "race belt speed applied")
	check(float(runtime._dynamics["max_linear_speed_m_s"]) > 10.0, "race raises body speed clamp")
	# Pivot steering while still slow keeps skid-steer semantics with a faster
	# yaw response (the yaw assist needs ground contact, so test before sprint).
	runtime.set_commands(1, -1)
	var max_yaw := 0.0
	for i in 240:
		await physics_frame
		max_yaw = maxf(max_yaw, absf(runtime._body.angular_velocity.y))
	check(max_yaw > 1.2, "race pivot turn develops strong yaw rate (%f)" % max_yaw)
	runtime.set_commands(1, 1)
	var race_top := 0.0
	var min_up_dot := 1.0
	for i in 480:
		await physics_frame
		var sample := runtime.get_status_snapshot()
		race_top = maxf(race_top, float(sample["forward_speed_m_s"]))
		min_up_dot = minf(min_up_dot, runtime._body.global_basis.y.normalized().dot(Vector3.UP))
	check(race_top > 8.0, "race tracked machine reaches racing speed (%f)" % race_top)
	check(min_up_dot > 0.86, "attitude assist keeps machine composed (min up dot %f)" % min_up_dot)
	# Tank-style turn weight: while the machine is still fast the same
	# asymmetric command rotates far less than a standstill pivot, and
	# scrubbing the turn bleeds speed until the arc tightens.
	runtime.set_commands(1, 0)
	var entry_speed := float(runtime.get_status_snapshot()["forward_speed_m_s"])
	var fast_yaw := 0.0
	var turn_yaw := 0.0
	var min_grip := 1.0
	for i in 180:
		await physics_frame
		var yaw_now := absf(runtime._body.angular_velocity.y)
		var speed_now := float(runtime.get_status_snapshot()["forward_speed_m_s"])
		if speed_now > entry_speed * 0.7:
			fast_yaw = maxf(fast_yaw, yaw_now)
		turn_yaw = maxf(turn_yaw, yaw_now)
		min_grip = minf(min_grip, float(runtime._race_track_solver.assist_telemetry.get("turn_grip", 1.0)))
	var exit_speed := float(runtime.get_status_snapshot()["forward_speed_m_s"])
	check(fast_yaw < 1.6, "race tracked turn stays heavy while fast (%f)" % fast_yaw)
	check(turn_yaw > 0.4, "race tracked machine still rotates in a turn (%f)" % turn_yaw)
	check(
		exit_speed < entry_speed * 0.85,
		"turning at speed bleeds speed (%f -> %f)" % [entry_speed, exit_speed]
	)
	check(min_grip < 1.0, "over-demanded turn slips the tracks (grip %f)" % min_grip)
	# Race off: parameters restore byte-exact and speed decays back to normal.
	runtime.set_race_mode(false)
	check(not runtime.get_status_snapshot()["race_mode"], "snapshot clears race mode")
	check(is_equal_approx(float(runtime._tracks["max_belt_speed_m_s"]), normal_belt), "normal belt speed restored")
	check(float(runtime._dynamics["max_linear_speed_m_s"]) < 3.0, "normal body clamp restored")
	runtime.set_commands(0, 0)
	await ticks(2)
	runtime.set_commands(1, 1)
	var restored_top := 0.0
	for i in 400:
		await physics_frame
		restored_top = maxf(restored_top, float(runtime.get_status_snapshot()["forward_speed_m_s"]))
	check(restored_top < 2.4, "normal mode top speed restored (%f)" % restored_top)
	host.queue_free()


func _test_wheeled_race() -> void:
	var scene = Demo.instantiate()
	root.add_child(scene)
	# The demo ground is only 160m wide; racing speeds need a larger runway.
	for child in scene.get_node("Ground").get_children():
		if child is CollisionShape3D:
			(child.shape as BoxShape3D).size = Vector3(700, 0.5, 700)
	var control = scene.controller
	control.keyboard_input = false
	await ticks(150)
	control.set_commands(1, 0, 0)
	var normal_top := 0.0
	for i in 300:
		await physics_frame
		normal_top = maxf(normal_top, float(control.get_status_snapshot().get("speed_mps", 0)))
	check(normal_top > 3.0 and normal_top < 8.5, "normal wheeled drive bounded (%f)" % normal_top)
	control.set_race_mode(true)
	control.set_commands(0, 0, 0)
	await ticks(2)
	control.set_commands(1, 0, 0)
	var race_top := 0.0
	var min_up_dot := 1.0
	for i in 480:
		await physics_frame
		race_top = maxf(race_top, float(control.get_status_snapshot().get("speed_mps", 0)))
		min_up_dot = minf(min_up_dot, scene.vehicle.global_basis.y.normalized().dot(Vector3.UP))
	check(race_top > 15.0, "race wheeled machine reaches racing speed (%f)" % race_top)
	check(
		float(control._race_locomotion.assist_telemetry.get("downforce_n", 0.0)) > 0.0,
		"wheeled downforce assist active at speed"
	)
	check(min_up_dot > 0.9, "wheeled race stays composed (min up dot %f)" % min_up_dot)
	# Plain steering at speed is weak by design; Shift (handbrake drift) plus
	# steering must rotate the machine decisively without spinning it out.
	control.set_commands(1, 0, 0.6)
	var steer_yaw := 0.0
	for i in 120:
		await physics_frame
		steer_yaw = maxf(steer_yaw, absf(scene.vehicle.angular_velocity.y))
	control.set_commands(1, 0, 0.6, 1.0)
	var drift_yaw := 0.0
	var max_slip := 0.0
	var drift_level_seen := 0.0
	var drift_min_up := 1.0
	for i in 150:
		await physics_frame
		drift_yaw = maxf(drift_yaw, absf(scene.vehicle.angular_velocity.y))
		drift_min_up = minf(drift_min_up, scene.vehicle.global_basis.y.normalized().dot(Vector3.UP))
		var tele: Dictionary = control._race_locomotion.assist_telemetry
		max_slip = maxf(max_slip, absf(float(tele.get("slip_angle_rad", 0))))
		drift_level_seen = maxf(drift_level_seen, float(tele.get("drift", 0)))
	check(drift_level_seen > 0.8, "drift handbrake engages fully (%f)" % drift_level_seen)
	check(
		drift_yaw > steer_yaw * 1.5 and drift_yaw > 0.8,
		"drift rotates far beyond plain steering (drift %f vs steer %f)" % [drift_yaw, steer_yaw]
	)
	check(max_slip > 0.15, "drift develops a real slide angle (%f)" % max_slip)
	check(max_slip < 1.2, "drift stays controllable, no spin-out (%f)" % max_slip)
	check(drift_min_up > 0.85, "drift keeps the machine composed (%f)" % drift_min_up)
	# Release: grip returns and the slide settles instead of spinning out.
	control.set_commands(0.4, 0, -0.2, 0.0)
	var settle_slip := 0.0
	for i in 150:
		await physics_frame
		settle_slip = absf(float(control._race_locomotion.assist_telemetry.get("slip_angle_rad", 0)))
	check(settle_slip < max_slip * 0.7, "releasing drift recovers grip (%f vs %f)" % [settle_slip, max_slip])
	control.set_race_mode(false)
	check(not bool(control.get_status_snapshot().get("race_mode", true)), "wheeled race mode cleared")
	check(
		float(control.locomotion.parameters.get("max_speed_mps", 28.0)) < 9.0,
		"wheeled normal solver parameters restored"
	)
	# Brake to a stop first — the machine still carries racing momentum.
	control.set_commands(0, 1, 0)
	var stopped := 0.0
	for i in 500:
		await physics_frame
		stopped = float(control.get_status_snapshot().get("speed_mps", 0))
		if stopped < 0.5:
			break
	check(stopped < 0.5, "wheeled machine brakes back to stop (%f)" % stopped)
	control.set_commands(0, 0, 0)
	await ticks(2)
	control.set_commands(1, 0, 0)
	var restored_top := 0.0
	for i in 300:
		await physics_frame
		restored_top = maxf(restored_top, float(control.get_status_snapshot().get("speed_mps", 0)))
	check(restored_top < 8.5, "wheeled normal top speed restored (%f)" % restored_top)
	# The normal solver ignores the drift channel entirely.
	control.set_commands(1, 0, 0.6, 1.0)
	var normal_drift_slip := 0.0
	for i in 150:
		await physics_frame
		var local_v: Vector3 = scene.vehicle.global_transform.basis.inverse() * scene.vehicle.linear_velocity
		if local_v.length() > 1.0:
			normal_drift_slip = maxf(normal_drift_slip, absf(atan2(local_v.x, -local_v.z)))
	check(normal_drift_slip < 0.2, "normal mode ignores drift input (%f)" % normal_drift_slip)
	scene.queue_free()

extends SceneTree
const Solver = preload("res://scripts/wheeled_locomotion_state.gd")
const Demo = preload("res://scenes/wheeled_vehicle_demo.tscn")
var failures: Array[String] = []
var scene: Node3D
func _init() -> void:
	if "--hz120" in OS.get_cmdline_user_args():
		Engine.physics_ticks_per_second = 120
	call_deferred("_run")
func _run() -> void:
	scene = Demo.instantiate()
	root.add_child(scene)
	var control = scene.controller
	control.keyboard_input = false
	await ticks(180)
	var settled: Dictionary = control.get_status_snapshot()
	check(settled.get("contact_count", 0) == 4, "four loaded wheels at rest")
	check(absf(scene.vehicle.global_position.y - 0.7624) < 0.15, "spring sag balances vehicle mass")
	var start: Vector3 = scene.vehicle.global_position
	control.set_commands(1, 0, 0)
	await ticks(240)
	var forward: Dictionary = control.get_status_snapshot()
	print("Forward: ", forward.speed_mps, " pos ", scene.vehicle.global_position)
	check(forward.speed_mps > 3.0 and forward.speed_mps < 8.5, "bounded forward acceleration")
	check(scene.vehicle.global_position.z < start.z - 7, "actual rigid body travels forward")
	var animator = scene.vehicle.get_node("WheelVisualAnimator")
	var pivot = scene.vehicle.get_node("WheelPivot0")
	var rolling = pivot.get_node("Roll")
	check(absf(pivot.global_position.y - 0.5) < 0.1, "visual tire center rests one radius above ground")
	var expected_roll := Basis(Vector3.RIGHT, -float(forward.wheels[0].roll_angle_rad))
	check(rolling.basis.is_equal_approx(expected_roll), "visual rolling reads physics angle exactly")
	for wheel in forward.wheels:
		check(wheel.angular_speed_rad_s > 1, "wheel rotates forward")
	control.set_commands(0, 1, 0)
	await ticks(180)
	print("Braked: ", scene.vehicle.linear_velocity)
	check(scene.vehicle.linear_velocity.length() < 0.25, "service brake stops actual body")
	control.set_commands(-1, 0, 0)
	await ticks(180)
	check(float(control.get_status_snapshot().speed_mps) < -1.0, "reverse after braking")
	control.set_commands(0, 1, 0)
	await ticks(150)
	control.set_commands(0.5, 0, 0.7)
	await ticks(150)
	var turn: Dictionary = control.get_status_snapshot()
	print("Turn: ", scene.vehicle.global_position, " yaw velocity ", scene.vehicle.angular_velocity)
	check(scene.vehicle.angular_velocity.y < -0.02, "right steering produces physical right yaw")
	check(float(turn.wheels[1].steer_angle_rad) > float(turn.wheels[0].steer_angle_rad), "right inner wheel Ackermann angle")
	control.set_enabled(false)
	await ticks(150)
	check(not control.neutral_armed, "disabled input disarms")
	control.set_enabled(true)
	control.set_commands(1, 0, 0)
	await ticks(30)
	check(not control.neutral_armed, "held command cannot rearm")
	control.set_commands(0, 0, 0)
	await ticks(2)
	check(control.neutral_armed, "neutral rearms")
	# No physical wheel contacts => no planar thrust even with throttle.
	scene.vehicle.global_position = Vector3(0, 30, 0)
	scene.vehicle.global_basis = Basis.IDENTITY
	scene.vehicle.linear_velocity = Vector3.ZERO
	scene.vehicle.angular_velocity = Vector3.ZERO
	control.reset_motion()
	await ticks(2)
	control.set_commands(1, 0, 0)
	await ticks(30)
	var airborne: Dictionary = control.get_status_snapshot()
	check(airborne.contact_count == 0, "airborne wheels lose support")
	check(Vector2(scene.vehicle.linear_velocity.x, scene.vehicle.linear_velocity.z).length() < 0.1, "airborne throttle cannot move chassis")
	check(float(airborne.wheels[0].angular_speed_rad_s) > 0.1, "airborne driven wheel spins")
	# Reset restores both steering and rolling imported local poses.
	animator.reset_animation()
	check(rolling.basis.is_equal_approx(Basis.IDENTITY), "rolling reset restores rest basis")
	check(pivot.transform.is_equal_approx(Transform3D(Basis.IDENTITY, Vector3(-1.05, 0, -1.4))), "steering and suspension reset restores mount")
	# Low-friction traction is force-limited, rather than scaling world displacement.
	scene.vehicle.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1, 0))
	scene.vehicle.linear_velocity = Vector3.ZERO
	scene.vehicle.angular_velocity = Vector3.ZERO
	control.reset_motion()
	scene.get_node("Ground").set_meta("wheel_friction", 0.05)
	control.set_commands(0, 0, 0)
	await ticks(180)
	control.set_commands(1, 0, 0)
	await ticks(120)
	var slippery: Dictionary = control.get_status_snapshot()
	check(float(slippery.speed_mps) < 1.4, "low-friction surface limits real acceleration")
	for wheel in slippery.wheels:
		check((wheel.tire_force_n as Vector2).length() <= 0.85 * 0.05 * float(wheel.load_n) + 0.01, "combined friction circle")
	scene.get_node("Ground").remove_meta("wheel_friction")
	# The same suspension follows a sloped collider without a terrain-height adapter.
	scene.get_node("Ground").rotation.x = deg_to_rad(6)
	scene.vehicle.global_transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(6)), Vector3(0, 1, 0))
	scene.vehicle.linear_velocity = Vector3.ZERO
	scene.vehicle.angular_velocity = Vector3.ZERO
	control.reset_motion()
	control.set_commands(0, 1, 0)
	await ticks(240)
	check(int(control.get_status_snapshot().contact_count) == 4, "four wheel support on slope")
	check(scene.vehicle.global_basis.y.dot(Basis(Vector3.RIGHT, deg_to_rad(6)).y) > 0.995, "chassis pitches to physical slope")
	var invalid = Solver.new()
	check(not invalid.configure({"max_steer_degrees": 90}, control.wheel_stations), "invalid steering rejected")
	check(not invalid.configure({"friction": NAN}, control.wheel_stations), "nonfinite config rejected")
	scene.queue_free()
	await process_frame
	if failures.is_empty():
		print("Wheeled locomotion and animation checks passed")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)
func ticks(count: int) -> void:
	for i in roundi(count * Engine.physics_ticks_per_second / 60.0):
		await physics_frame
func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)

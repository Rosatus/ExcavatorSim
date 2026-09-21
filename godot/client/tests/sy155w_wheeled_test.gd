extends SceneTree
var failures: Array[String] = []
func _init() -> void:
	call_deferred("run")
func run() -> void:
	var host := Node3D.new()
	root.add_child(host)
	var ground_root := Node3D.new()
	host.add_child(ground_root)
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	shape.shape = box
	shape.position.y = -0.5
	ground.add_child(shape)
	ground_root.add_child(ground)
	var rig := PhysicsRigDescriptor.load_for_model("sy155w")
	check(rig.is_valid_for("sy155w", rig.model_version()), "rig valid")
	var runtime := JoltChassisTrackRuntime.new()
	host.add_child(runtime)
	check(runtime.configure(rig, null, null, Transform3D(Basis.IDENTITY, Vector3(0, 0.04, 0)), ground_root), "wheel runtime configures")
	runtime.set_wheeled_commands(0, 0, 0)
	for i in 180:
		await physics_frame
	var status := runtime.get_status_snapshot()
	print("Settled SY155W origin ", status.body_transform.origin)
	check(status.locomotion_mode == "wheeled", "wheel solver selected")
	check(status.left_contact_count + status.right_contact_count == 4, "all SY155W wheel stations support load")
	var asset := load("res://assets/visual/SY155W_excavator_godot.glb").instantiate() as Node3D
	host.add_child(asset)
	var animator := WheelVisualAnimator.new()
	asset.add_child(animator)
	var profile := WheeledMachineProfile.load_for_model("sy155w")
	check(animator.configure_imported(asset, profile), "imported wheel pin contract validates")
	var front: Node3D = asset.get_node(profile.data.wheels[0].pivot_path)
	var roll: Node3D = asset.get_node(profile.data.wheels[0].roll_path)
	var rest := front.transform
	runtime.set_wheeled_commands(1, 0, 0)
	for i in 180:
		await physics_frame
	status = runtime.get_status_snapshot()
	print("SY155W drive ", status.forward_speed_m_s, " pos ", status.body_transform.origin)
	check(float(status.forward_speed_m_s) > 1.0, "SY155W physical forward drive")
	animator.apply_physics_snapshot(status.wheeled_locomotion)
	check(not roll.basis.is_equal_approx(Basis.IDENTITY), "imported dual tires roll")
	runtime.set_wheeled_commands(0.6, 0, 0.6)
	for i in 120:
		await physics_frame
	status = runtime.get_status_snapshot()
	print("SY155W turn ", status.angular_velocity)
	check(status.angular_velocity.y < -0.01, "SY155W right turn")
	animator.apply_physics_snapshot(status.wheeled_locomotion)
	check(not front.basis.is_equal_approx(rest.basis), "imported front wheel steers")
	animator.reset_animation()
	check(front.transform.is_equal_approx(rest) and roll.transform.is_equal_approx(Transform3D.IDENTITY), "imported wheel reset exact")
	runtime.stop_motion()
	for i in 180:
		await physics_frame
	check(runtime._body.linear_velocity.length() < 0.15, "SY155W auto parking brake")
	runtime.set_wheeled_commands(1, 0, 0)
	check(not runtime.get_status_snapshot().get("track_neutral_armed", true), "stop requires neutral")
	runtime.reset(Transform3D(Basis.IDENTITY, Vector3(0, 0.04, 0)))
	check(runtime.get_status_snapshot().wheeled_locomotion.is_empty(), "reset clears wheel state")
	host.queue_free()
	await process_frame
	if failures.is_empty():
		print("SY155W wheel integration passed")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)
func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)

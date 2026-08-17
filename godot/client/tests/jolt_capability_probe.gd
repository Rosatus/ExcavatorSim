extends SceneTree

var failures: Array[String] = []
var runner: Node3D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if ProjectSettings.get_setting("physics/3d/physics_engine") != "Jolt Physics":
		failures.append("Jolt Physics is not selected")
	runner = Node3D.new()
	runner.set_meta("contacts", 0)
	runner.set_meta("direct_state_seen", false)
	runner.set_meta("direct_state_type", "")
	root.add_child(runner)
	_build_scene()
	for _frame in 180:
		await physics_frame
	if int(runner.get_meta("contacts")) <= 0:
		failures.append("no body contact")
	if not bool(runner.get_meta("direct_state_seen")) or String(runner.get_meta("direct_state_type")) != "JoltPhysicsDirectBodyState3D":
		failures.append("no Jolt direct body state")
	runner.queue_free()
	for _frame in 3:
		await physics_frame
	if is_instance_valid(runner):
		failures.append("probe nodes were not freed")
	if failures.is_empty():
		print("jolt_capability_probe: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _box(size: Vector3) -> BoxShape3D:
	var shape := BoxShape3D.new()
	shape.size = size
	return shape


func _add_box(owner: CollisionObject3D, size: Vector3) -> void:
	var collision := CollisionShape3D.new()
	collision.shape = _box(size)
	owner.add_child(collision)


func _build_scene() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	_add_box(floor_body, Vector3(10.0, 1.0, 10.0))
	runner.add_child(floor_body)

	var body := RigidBody3D.new()
	body.name = "FallingBody"
	body.contact_monitor = true
	body.max_contacts_reported = 8
	body.position = Vector3(0.0, 2.0, 0.0)
	body.body_entered.connect(func(_other: Node) -> void: runner.set_meta("contacts", int(runner.get_meta("contacts")) + 1))
	body.set_script(preload("res://tests/jolt_probe_body.gd"))
	_add_box(body, Vector3.ONE)
	runner.add_child(body)

	var hinge := HingeJoint3D.new()
	hinge.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, -0.5)
	hinge.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, 0.5)
	hinge.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
	if not hinge.get_flag(HingeJoint3D.FLAG_USE_LIMIT):
		failures.append("hinge limit API failed")
	runner.add_child(hinge)

	var joint_6dof := Generic6DOFJoint3D.new()
	joint_6dof.set_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT, true)
	joint_6dof.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, -1.0)
	joint_6dof.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, 1.0)
	if not joint_6dof.get_flag_x(Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT):
		failures.append("6DOF limit API failed")
	runner.add_child(joint_6dof)

extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_contact_boundaries()
	if OS.get_cmdline_user_args().has("--boundaries-only"):
		for failure in failures:
			push_error(failure)
		print("bucket_solid_support boundaries: ", "PASS" if failures.is_empty() else "FAIL")
		quit(0 if failures.is_empty() else 1)
		return
	await _test_lift(false)
	await _test_lift(true)
	if failures.is_empty():
		print("bucket_solid_support_test: PASS")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _test_lift(raised_object: bool) -> void:
	var host := Node3D.new()
	root.add_child(host)
	var ground := _box(Vector3(40, 1, 40), Vector3(0, -0.5, 0))
	host.add_child(ground)
	var runtime := JoltChassisTrackRuntime.new()
	host.add_child(runtime)
	var descriptor := PhysicsRigDescriptor.load_for_model("sy135")
	_check(runtime.configure(descriptor, null, null, Transform3D(Basis.IDENTITY, Vector3(0, 0.3, 0)), host), "configure")
	runtime.set_equipment_commands(Vector4.ZERO, 0)
	for _frame in 180:
		await physics_frame
	var settled := runtime._body.global_position
	var frames := runtime._articulation.accepted_frames()
	var bucket: Transform3D = frames["bucket_link"]
	var edge: Vector3 = bucket * runtime._cutting_edge_local()
	# Raise a reachable support surface below the current teeth. The support is
	# an ordinary object outside the configured map subtree.
	var obstacle := _box(Vector3(3, 1, 3), Vector3(edge.x, edge.y - 0.65, edge.z))
	if raised_object:
		root.add_child(obstacle)
	await physics_frame
	var peak_lift := 0.0
	var peak_force := 0.0
	var peak_depth := 0.0
	var contact_frames := 0
	for frame in 300:
		runtime.set_equipment_commands(Vector4(0, -0.5, 0, 0), frame + 1)
		await physics_frame
		peak_lift = maxf(peak_lift, runtime._body.global_position.y - settled.y)
		var wrench: Dictionary = runtime._applied_support_wrench
		peak_force = maxf(peak_force, (wrench.get("applied_force", Vector3.ZERO) as Vector3).length())
		if not wrench.is_empty():
			contact_frames += 1
		for contact in runtime._bucket_query.get("contacts", []):
			peak_depth = maxf(peak_depth, float(contact["penetration_m"]))
	var held_start := runtime._body.global_position.y
	var hold_min := held_start
	var hold_contacts := 0
	runtime.set_equipment_commands(Vector4.ZERO, 400)
	for _frame in 180:
		await physics_frame
		hold_min = minf(hold_min, runtime._body.global_position.y)
		if not runtime._applied_support_wrench.is_empty():
			hold_contacts += 1
	print("raised_object=", raised_object, " lift=", peak_lift, " force=", peak_force, " depth=", peak_depth, " contacts=", contact_frames,
		" hold_start=", held_start, " hold_min=", hold_min, " hold_contacts=", hold_contacts)
	_check(peak_lift > 0.08, "gravity-on commands must lift chassis at least 8cm")
	_check(peak_depth < 0.12, "solid penetration must stay bounded")
	_check(contact_frames > 120, "support must persist beyond old duration cutoff")
	_check(hold_contacts > 120 and hold_min > settled.y + 0.04, "neutral must sustain lifted support")
	runtime.set_equipment_commands(Vector4(0, 1, 0, 0), 500)
	for _frame in 240:
		await physics_frame
	_check(runtime._applied_support_wrench.is_empty(), "retraction releases support")
	_check(absf(runtime._body.global_position.y - settled.y) < 0.025, "retraction returns chassis to track support")
	# No deferred support can survive stop/disable/reset or a policy change.
	runtime.set_enabled(false)
	_check(runtime._applied_support_wrench.is_empty(), "disable clears support")
	runtime.set_bucket_ground_mode(BucketGroundInteractionMode.PASSTHROUGH)
	await physics_frame
	_check(runtime._bucket_query.get("contacts", []).is_empty(), "pass-through bypasses solid queries")
	runtime.reset(Transform3D(Basis.IDENTITY, Vector3(0, 0.3, 0)))
	_check(runtime._support_wrench_apply_count == 0, "reset clears contact history")
	runtime.teardown()
	host.queue_free()
	if raised_object:
		obstacle.queue_free()
	else:
		obstacle.free()
	await physics_frame
	await physics_frame


func _test_contact_boundaries() -> void:
	var host := Node3D.new()
	root.add_child(host)
	var runtime := JoltChassisTrackRuntime.new()
	host.add_child(runtime)
	_check(runtime.configure(PhysicsRigDescriptor.load_for_model("sy135"), null, null,
		Transform3D(Basis.IDENTITY, Vector3(0, 3, 0)), host), "boundary fixture configure")
	runtime.set_physics_process(false)
	runtime._body.gravity_scale = 0.0
	var ground := _box(Vector3(4, 1, 0.16), Vector3(0, -0.5, -1.23))
	host.add_child(ground)
	await physics_frame
	var solver = runtime._solid_contacts
	var accept := Callable(runtime, "_accept_bucket_solid_hit")
	var space := host.get_world_3d().direct_space_state
	var before := Transform3D(Basis(Vector3.RIGHT, 0.08), Vector3(0, 0.18, 0))
	var after := Transform3D(Basis(Vector3.RIGHT, -0.14), before.origin)
	var rotation: Dictionary = solver.query_contacts(space, before, after, runtime._body, accept)
	_check(not rotation.contacts.is_empty(), "pure bucket rotation finds teeth contact")
	var response: Dictionary = solver.solve(rotation.contacts, before, after, runtime._body, 1.0 / 60.0)
	_check(response.force.y > 1000.0, "pure rotation at fixed bucket pivot produces support")
	_check(rotation.contacts.any(func(c): return c.region_id == "teeth_main_edge"), "teeth are physical regardless of cutting direction")
	var shallow: Dictionary = solver.query_contacts(space, after, after, runtime._body, accept)
	_check(not shallow.contacts.is_empty(), "initial shallow overlap remains valid support")
	(ground.get_child(0).shape as BoxShape3D).size = Vector3(20, 1, 20)
	ground.position.z = 0.0
	# No angle test: a vertical wall yields a horizontal reaction.
	var wall := _box(Vector3(0.1, 5, 5), Vector3(0.58, 2.5, 0))
	host.add_child(wall)
	await physics_frame
	before = Transform3D(Basis.IDENTITY, Vector3(-0.06, 1, 0))
	after = Transform3D(Basis.IDENTITY, Vector3(0.04, 1, 0))
	var side: Dictionary = solver.query_contacts(space, before, after, runtime._body, accept)
	response = solver.solve(side.contacts, before, after, runtime._body, 1.0 / 60.0)
	_check(response.force.x < -1000.0, "wall collision produces horizontal reaction")
	wall.queue_free()
	await physics_frame
	await physics_frame
	# A thin wall crossed entirely within a proposed step must still be hit.
	wall = _box(Vector3(0.015, 5, 5), Vector3(2, 2.5, 0))
	host.add_child(wall)
	await physics_frame
	before = Transform3D(Basis.IDENTITY, Vector3(0.9, 1, 0))
	after = Transform3D(Basis.IDENTITY, Vector3(2.8, 1, 0))
	var swept: Dictionary = solver.query_contacts(space, before, after, runtime._body, accept)
	_check(not swept.contacts.is_empty() and swept.accepted_fraction < 0.9, "thin obstacle sweep limits crossing")
	var chassis_sweep: Dictionary = solver.query_contacts(space, after, after, runtime._body, accept, before)
	_check(not chassis_sweep.contacts.is_empty(), "neutral bucket includes chassis movement in sweep")
	var endpoint_wall := _box(Vector3(0.1, 5, 5), Vector3(3.32, 2.5, 0))
	host.add_child(endpoint_wall)
	await physics_frame
	swept = solver.query_contacts(space, before, after, runtime._body, accept)
	_check(swept.contacts.any(func(c): return c.collider_id == wall.get_instance_id()),
		"endpoint contact cannot hide earlier thin obstacle")
	endpoint_wall.queue_free()
	wall.queue_free()
	await physics_frame
	await physics_frame
	# Voxel descendants share the same layer, and must neither support nor hide
	# a separate solid behind them. This also exercises iterative RID exclusion.
	var voxel := VoxelTerrain.new()
	host.add_child(voxel)
	var voxel_shape := _box(Vector3(5, 1, 5), Vector3(0, 1.9, 0))
	voxel.add_child(voxel_shape)
	var solid := _box(Vector3(5, 1, 5), Vector3(0, 1.87, 0))
	host.add_child(solid)
	await physics_frame
	before = Transform3D(Basis.IDENTITY, Vector3(0, 2.4, 0))
	after = Transform3D(Basis.IDENTITY, Vector3(0, 2.35, 0))
	var filtered: Dictionary = solver.query_contacts(space, before, after, runtime._body, accept)
	_check(not filtered.contacts.is_empty(), "solid remains queryable behind excluded voxel")
	for contact in filtered.contacts:
		_check(contact.collider_id == solid.get_instance_id(), "voxel cannot lend solid contact identity")
	solid.queue_free()
	await physics_frame
	await physics_frame
	filtered = solver.query_contacts(space, before, after, runtime._body, accept)
	_check(filtered.contacts.is_empty(), "voxel-only contact does not block or lift")
	voxel.queue_free()
	await physics_frame
	await physics_frame
	# Movable objects get equal and opposite reaction, with their inverse mass
	# included so a light object cannot act like an immovable lifting platform.
	var movable := RigidBody3D.new()
	movable.mass = 50.0
	movable.gravity_scale = 0.0
	movable.position = Vector3(0, 1.87, 0)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(5, 1, 5)
	collision.shape = shape
	collision.position.x = 0.7
	movable.add_child(collision)
	host.add_child(movable)
	await physics_frame
	_check(absf(solver.center_of_mass_world(movable).x - movable.global_position.x - 0.7) < 0.001,
		"automatic COM follows offset collision geometry")
	var dynamic_contact: Dictionary = solver.query_contacts(space, before, after, runtime._body, accept)
	response = solver.solve(dynamic_contact.contacts, before, after, runtime._body, 1.0 / 60.0)
	_check(response.force.y > 0.0 and response.force.length() < 20000.0, "light object's effective mass limits force")
	runtime._physics_tick += 1
	runtime._apply_solid_contact_response(response, dynamic_contact.contacts)
	await physics_frame
	await physics_frame
	_check(movable.linear_velocity.y < -0.01 and runtime._body.linear_velocity.y > 0.0,
		"dynamic object and chassis receive opposite impulses")
	var momentum := movable.linear_velocity.y * movable.mass + runtime._body.linear_velocity.y * runtime._body.mass
	_check(absf(momentum) < 50.0, "dynamic contact approximately conserves pair momentum")
	runtime.teardown()
	host.queue_free()
	await physics_frame
	await physics_frame


func _box(size: Vector3, center: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = center
	body.collision_layer = 1
	var node := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	node.shape = shape
	body.add_child(node)
	return body


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

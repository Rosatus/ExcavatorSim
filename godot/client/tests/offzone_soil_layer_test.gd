extends SceneTree
const Layer = preload("res://scripts/offzone_soil_layer.gd")
const Field = preload("res://scripts/voxel_soil_material_field.gd")
var failures: Array[String] = []
func _init():
	call_deferred("run")
func check(value: bool, message: String):
	if not value:
		failures.append(message)
func run():
	var world := Node3D.new()
	root.add_child(world)
	var ground := StaticBody3D.new()
	world.add_child(ground)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(100, 1, 100)
	shape.shape = box
	shape.position.y = -0.5
	ground.add_child(shape)
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	var field := Field.new()
	field.configure(contract, 1, 100.0)
	var layer := Layer.new()
	world.add_child(layer)
	layer.configure(ground, null, contract)
	await physics_frame
	await physics_frame
	var amount := field.mass_q_for_volume(0.5)
	field.credit_bucket_mass_for_test(amount)
	var result := layer.deposit(Vector3(2, 3, 2), amount, field)
	print("DEPOSIT ", result, " ", layer.get_status_snapshot())
	check(bool(result.get("accepted", false)), "deposit accepted")
	check(field.bucket_mass_q == 0 and field.conservation_error_q == 0, "deposit exact mass")
	for i in 180:
		await process_frame
		await physics_frame
		if layer._dirty.is_empty():
			break
	await physics_frame
	var hit := world.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(2,3,2),Vector3(2,-1,2),1))
	print("HIT ",hit, " STATUS ",layer.get_status_snapshot())
	check(not hit.is_empty() and hit.position.y > 0.25, "pile collision above ground across chunk seam")
	var body := RigidBody3D.new()
	body.position = Vector3(2, 1.8, 2)
	var bs := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.15
	bs.shape = sphere
	body.add_child(bs)
	world.add_child(body)
	for i in 150:
		await physics_frame
	print("BODY ",body.position)
	check(body.position.y > 0.35, "dynamic load supported")
	body.queue_free()
	# Native swept path across all deposited columns; only ledger-backed soil credits.
	var paths: Array[Dictionary] = []
	for x in range(4,29,2):
		paths.append({"points_voxels": PackedVector3Array([Vector3(x,2,4),Vector3(x,2,28)]), "radii_voxels": PackedFloat32Array([10,10])})
	var proposal := VoxelCutProposal.new()
	proposal.area_voxels = AABB(Vector3(0,-10,0),Vector3(32,32,32))
	proposal.native_paths = paths
	var cut := layer.cut_proposal(proposal, field)
	print("CUT ",cut," bucket=",field.bucket_mass_q," original=",amount)
	check(bool(cut.get("accepted",false)), "native recut accepted")
	check(field.bucket_mass_q > amount * 0.9 and field.bucket_mass_q <= amount, "recut recovers only deposited material")
	var before := field.bucket_mass_q
	layer.cut_proposal(proposal,field)
	check(field.bucket_mass_q == before and field.conservation_error_q == 0, "repeated cut cannot mine ground")
	for i in 120:
		await process_frame
		await physics_frame
		if layer._dirty.is_empty():
			break
	await physics_frame
	hit = world.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(2,3,2),Vector3(2,-1,2),1))
	check(not hit.is_empty() and absf(hit.position.y) < 0.02, "recut restores immutable ground")
	check(layer._blocks.is_empty() and layer._supports.is_empty() and layer._column_spans.is_empty(), "fully recovered pile releases storage")
	# A second location must reuse capacity, with adjacent piles merging.
	field.export_bucket_mass(field.bucket_mass_q)
	for offset in [Vector3(-6,3,-6),Vector3(-5.5,3,-6)]:
		field.credit_bucket_mass_for_test(amount)
		var more := layer.deposit(offset,amount,field)
		check(bool(more.get("accepted",false)), "new location accepts another pile")
	check(field.conservation_error_q == 0, "overlapping piles conserve shared inventory")
	var old_stock := field.bucket_mass_q
	field.credit_bucket_mass_for_test(amount)
	var missing := layer.deposit(Vector3(1000,3,1000),amount,field)
	check(not bool(missing.get("accepted",false)) and field.bucket_mass_q == old_stock + amount, "missing support retains stock")
	world.queue_free()
	await process_frame
	if failures.is_empty():
		print("offzone_soil_layer_test: PASS")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)

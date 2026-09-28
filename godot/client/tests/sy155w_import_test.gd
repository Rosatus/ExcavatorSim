extends SceneTree

var failures: Array[String] = []
const ASSET := "res://assets/visual/SY155W_excavator_godot.glb"
const MANIFEST := "res://resources/visual/sy155w_visual_manifest.json"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var asset := load(ASSET).instantiate() as Node3D
	root.add_child(asset)
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	var hydraulics := PassiveHydraulics.new()
	_check(hydraulics.configure(asset, manifest.passive_hydraulics), "hydraulics configure: " + hydraulics.error)
	var nodes := {}
	var rest := {}
	for frame in manifest.frame_map:
		nodes[frame] = asset.get_node_or_null(manifest.frame_map[frame].node_path)
		if nodes[frame] == null:
			push_error("Missing frame: " + String(manifest.frame_map[frame].node_path))
			asset.free()
			quit(1)
			return
		rest[frame] = nodes[frame].transform
	var fold := asset.get_node(manifest.local_articulation.axes[0].node_path) as Node3D
	var fold_rest := fold.transform
	_check(asset.find_children("BUCKET_ROOT", "", true, false).is_empty(), "source bucket is absent")
	_check(asset.find_children("BUCKET_ROCKER", "", true, false).is_empty(), "four-bar rocker is absent")
	_check(asset.find_children("BUCKET_COUPLER", "", true, false).is_empty(), "four-bar coupler is absent")
	_check(asset.find_children("BUCKET_CYLINDER*", "", true, false).is_empty(), "four-bar bucket cylinder is absent")
	_check(asset.find_children("*", "AnimationPlayer", true, false).is_empty(), "no animation authority remains")
	_check(hydraulics.snapshot().cylinder_count == 5 and hydraulics.snapshot().hose_count == 12, "all cylinders and hoses resolve")
	# Independently authored source samples, converted Blender -> glTF -> -Z forward.
	var conversion := Basis(Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0))
	var gltf := Basis(Vector3.RIGHT, Vector3.FORWARD, Vector3.UP)
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/sy155w_source_poses.json"))
	for pose: Dictionary in source.poses:
		var angles: Array = pose.angles_deg
		_set_joint(nodes.boom_link, rest.boom_link, float(angles[0]) - 58.0)
		_set_joint(fold, fold_rest, float(angles[1]) + 47.0)
		_set_joint(nodes.arm_link, rest.arm_link, float(angles[2]) + 99.0)
		_set_joint(nodes.bucket_link, rest.bucket_link, float(angles[3]) - 97.0)
		_check(hydraulics.update(), "source pose solve: " + hydraulics.error)
		for name: String in pose.nodes:
			var found := asset.find_children(name, "Node3D", true, false)
			_check(found.size() == 1, "source node resolves: " + name)
			if found.size() != 1:
				continue
			var node := found[0] as Node3D
			var sample: Dictionary = pose.nodes[name]
			var q: Array = sample.q
			var expected_basis := conversion * Basis(Quaternion(float(q[1]), float(q[2]), float(q[3]), float(q[0]))) * gltf.inverse()
			var expected_origin := conversion * _vec(sample.t)
			_check(node.position.distance_to(expected_origin) < 0.00005, "source pin match: " + name)
			_check(node.basis.get_rotation_quaternion().angle_to(expected_basis.get_rotation_quaternion()) < 0.001, "source orientation match: " + name)
		for name: String in pose.weights:
			var mesh := asset.find_children(name, "MeshInstance3D", true, false)[0] as MeshInstance3D
			var expected: Array = pose.weights[name]
			for index in expected.size():
				_check(absf(mesh.get_blend_shape_value(index) - float(expected[index])) < 0.001, "source hose match: %s:%d" % [name, index])
		_assert_pins(hydraulics)
	# Independent joint extremes (source Work_Cycle alone couples all inputs).
	for boom in [-7., 0., 7.]:
		for folding in [-10., 0., 10.]:
			for arm in [-9., 0., 39.]:
				for bucket in [-15., 0., 15.]:
					_set_joint(nodes.boom_link, rest.boom_link, boom)
					_set_joint(fold, fold_rest, folding)
					_set_joint(nodes.arm_link, rest.arm_link, arm)
					_set_joint(nodes.bucket_link, rest.bucket_link, bucket)
					_check(hydraulics.update(), "independent pose reachable")
					_assert_pins(hydraulics)
	# Invalid geometry cannot partially write any passive cylinder.
	var barrel := asset.find_children("BOOM_LIFT_L_BARREL", "Node3D", true, false)[0] as Node3D
	var before := barrel.transform
	var arm_before: Transform3D = nodes.arm_link.transform
	nodes.arm_link.position += Vector3(20, 0, 0)
	_check(not hydraulics.update(), "non-planar cylinder pins rejected")
	_check(barrel.transform.is_equal_approx(before), "unreachable retention is atomic")
	nodes.arm_link.transform = arm_before
	for frame in nodes:
		nodes[frame].transform = rest[frame]
	fold.transform = fold_rest
	hydraulics.restore()
	_check(hydraulics.error.is_empty(), "zero restore")
	_assert_pins(hydraulics)
	asset.free()
	if failures.is_empty():
		print("SY155W import test passed: source oracle, 81 independent poses, five cylinders, twelve hoses, invalid-geometry retention.")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _assert_pins(hydraulics: PassiveHydraulics) -> void:
	for pair: Dictionary in hydraulics.snapshot().pins:
		_check(float(pair.barrel_error_m) < 0.00005 and float(pair.rod_error_m) < 0.00005, "cylinder remains pinned: " + String(pair.id))


func _set_joint(node: Node3D, rest: Transform3D, degrees: float) -> void:
	node.transform = Transform3D(rest.basis * Basis(Vector3.RIGHT, deg_to_rad(degrees)), rest.origin)


func _vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _check(ok: bool, message: String) -> void:
	if not ok and not failures.has(message):
		failures.append(message)

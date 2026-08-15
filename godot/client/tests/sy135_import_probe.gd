extends SceneTree

const MotionProtocolScript = preload("res://scripts/motion_protocol.gd")

const ASSET_PATH := "res://assets/visual/SY135_excavator_godot.glb"
const FIXTURE_PATH := "res://tests/fixtures/sy135_frame_parity_cases.json"
const EXPECTED_SHA256 := "8e0f478b265bb0f32f7736a0e388f5bb812b7f36c143edeb1553ff86d2d960c9"
const FRAME_NAMES := [
	"base_link",
	"upper_structure_link",
	"boom_link",
	"arm_link",
	"bucket_link",
]
const FRAME_PATHS := {
	"base_link": "CTRL_EXCAVATOR_ROOT",
	"upper_structure_link": "CTRL_EXCAVATOR_ROOT/PIVOT_SLEW",
	"boom_link": "CTRL_EXCAVATOR_ROOT/PIVOT_SLEW/PIVOT_BOOM_BASE",
	"arm_link": "CTRL_EXCAVATOR_ROOT/PIVOT_SLEW/PIVOT_BOOM_BASE/PIVOT_ARM_JOINT",
	"bucket_link": (
		"CTRL_EXCAVATOR_ROOT/PIVOT_SLEW/PIVOT_BOOM_BASE/PIVOT_ARM_JOINT/PIVOT_BUCKET_JOINT"
	),
}
const FRAME_PARENTS := {
	"base_link": "",
	"upper_structure_link": "base_link",
	"boom_link": "upper_structure_link",
	"arm_link": "boom_link",
	"bucket_link": "arm_link",
}
const FRAME_AXES := {
	"base_link": "none",
	"upper_structure_link": "Y",
	"boom_link": "X",
	"arm_link": "X",
	"bucket_link": "X",
}
const ISOLATED_POSES := {
	"swing_positive_90": {"frame": "upper_structure_link", "joint_index": 0},
	"boom_only": {"frame": "boom_link", "joint_index": 1},
	"arm_only": {"frame": "arm_link", "joint_index": 2},
	"bucket_only": {"frame": "bucket_link", "joint_index": 3},
}
const TIP_PATH := (
	"CTRL_EXCAVATOR_ROOT/PIVOT_SLEW/PIVOT_BOOM_BASE/PIVOT_ARM_JOINT/"
	+ "PIVOT_BUCKET_JOINT/REF_BUCKET_TIP"
)
const ORIGIN_TOLERANCE := 0.002
const AXIS_TOLERANCE := 0.001


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	quit(_validate_import_and_mechanics())


func _validate_import_and_mechanics() -> int:
	if FileAccess.get_sha256(ASSET_PATH) != EXPECTED_SHA256:
		push_error("SY135 repository asset does not match the supplied GLB bytes.")
		return 1
	var packed_scene := load(ASSET_PATH) as PackedScene
	if packed_scene == null:
		push_error("Unable to load the imported SY135 GLB as a PackedScene.")
		return 1
	var asset_root := packed_scene.instantiate() as Node3D
	if asset_root == null:
		push_error("The imported SY135 GLB root is not Node3D.")
		return 1
	root.add_child(asset_root)

	var frame_nodes := {}
	var rest_locals := {}
	var rest_globals := {}
	for frame_name in FRAME_NAMES:
		var frame_node := _resolve_asset_path(asset_root, FRAME_PATHS[frame_name]) as Node3D
		if frame_node == null:
			return _fail(asset_root, "Missing imported SY135 frame: %s" % frame_name)
		var parent_name := String(FRAME_PARENTS[frame_name])
		if not parent_name.is_empty() and frame_node.get_parent() != frame_nodes[parent_name]:
			return _fail(asset_root, "Imported SY135 parent drifted for %s" % frame_name)
		if not frame_node.scale.is_equal_approx(Vector3.ONE):
			return _fail(asset_root, "Imported SY135 scale is not unit for %s" % frame_name)
		frame_nodes[frame_name] = frame_node
		rest_locals[frame_name] = frame_node.transform
		rest_globals[frame_name] = frame_node.global_transform
		print(
			"SY135_REST %s local=%s global=%s scale=%s"
			% [frame_name, frame_node.transform, frame_node.global_transform, frame_node.scale]
		)

	var tip := _resolve_asset_path(asset_root, TIP_PATH) as Node3D
	if tip == null or tip.get_parent() != frame_nodes["bucket_link"]:
		return _fail(asset_root, "SY135 REF_BUCKET_TIP is not parented to bucket_link.")
	if absf(tip.position.length() - 1.2126358) > 0.0001:
		return _fail(asset_root, "SY135 REF_BUCKET_TIP offset drifted.")
	print("SY135_BUCKET_TIP local=%s global=%s" % [tip.transform, tip.global_transform])

	var stats := {
		"node_count": 0,
		"mesh_count": 0,
		"surface_count": 0,
		"material_surface_count": 0,
		"textured_surface_count": 0,
		"animation_player_count": 0,
		"skeleton_count": 0,
		"collision_count": 0,
		"script_count": 0,
		"has_bounds": false,
		"bounds": AABB(),
	}
	_collect_stats(asset_root, stats)
	if stats.node_count != 15 or stats.mesh_count != 8 or stats.surface_count != 9:
		return _fail(asset_root, "SY135 imported node or mesh counts drifted: %s" % stats)
	if stats.material_surface_count != stats.surface_count or stats.textured_surface_count != 3:
		return _fail(asset_root, "SY135 materials or embedded textures did not survive import: %s" % stats)
	if (
		stats.animation_player_count != 0
		or stats.skeleton_count != 0
		or stats.collision_count != 0
		or stats.script_count != 0
	):
		return _fail(asset_root, "SY135 import contains unexpected runtime resources: %s" % stats)
	var bounds: AABB = stats.bounds
	if not _finite_vector(bounds.position) or not _finite_vector(bounds.size):
		return _fail(asset_root, "SY135 aggregate bounds are non-finite.")
	if bounds.size.x < 2.0 or bounds.size.y < 2.0 or bounds.size.z < 2.0 or bounds.size.length() > 30.0:
		return _fail(asset_root, "SY135 aggregate bounds are implausible: %s" % bounds)
	print("SY135_BOUNDS position=%s size=%s" % [bounds.position, bounds.size])

	var fixture := _read_json(FIXTURE_PATH)
	if fixture.get("model_id", "") != "sy135":
		return _fail(asset_root, "SY135 parity fixture is missing or mismatched.")
	var poses: Dictionary = fixture.get("poses", {})
	var zero_frames: Dictionary = (poses.get("zero", {}) as Dictionary).get("frame_transforms", {})
	var authority_zero := _convert_frames(zero_frames)
	if authority_zero.size() != FRAME_NAMES.size():
		return _fail(asset_root, "SY135 zero authority fixture is incomplete.")

	for pose_name in [
		"zero", "swing_positive_90", "boom_only", "arm_only", "bucket_only", "asymmetric"
	]:
		_restore_pose(frame_nodes, rest_locals)
		var pose: Dictionary = poses.get(pose_name, {})
		if not _apply_pose(frame_nodes, rest_locals, authority_zero, pose):
			return _fail(asset_root, "SY135 controlled pose failed: %s" % pose_name)
		if not _validate_local_invariants(frame_nodes, rest_locals):
			return _fail(asset_root, "SY135 local origin or scale drifted in %s" % pose_name)
		if ISOLATED_POSES.has(pose_name):
			var isolated: Dictionary = ISOLATED_POSES[pose_name]
			if not _validate_isolated_pose(
				frame_nodes,
				rest_locals,
				rest_globals,
				String(isolated.frame),
				float((pose.get("joint_angles", []) as Array)[int(isolated.joint_index)])
			):
				return _fail(asset_root, "SY135 isolated pose contract failed: %s" % pose_name)
		print("SY135_POSE_VALIDATED %s" % pose_name)

	_restore_pose(frame_nodes, rest_locals)
	for frame_name in FRAME_NAMES:
		var frame_node := frame_nodes[frame_name] as Node3D
		if not frame_node.transform.is_equal_approx(rest_locals[frame_name]):
			return _fail(asset_root, "SY135 zero restore local drifted for %s" % frame_name)
		if not frame_node.global_transform.is_equal_approx(rest_globals[frame_name]):
			return _fail(asset_root, "SY135 zero restore global drifted for %s" % frame_name)

	asset_root.free()
	print(
		"SY135 import/mechanics gate passed: 15 imported nodes, 8 meshes, 9 surfaces, 6 poses."
	)
	return 0


func _apply_pose(
	frame_nodes: Dictionary,
	rest_locals: Dictionary,
	authority_zero: Dictionary,
	pose: Dictionary
) -> bool:
	var current := _convert_frames(pose.get("frame_transforms", {}))
	if current.size() != FRAME_NAMES.size():
		return false
	var base := frame_nodes["base_link"] as Node3D
	var base_delta := (current["base_link"] as Transform3D) * (
		authority_zero["base_link"] as Transform3D
	).affine_inverse()
	base.global_transform = base_delta * (rest_locals["base_link"] as Transform3D)
	for frame_index in range(1, FRAME_NAMES.size()):
		var frame_name := String(FRAME_NAMES[frame_index])
		var parent_name := String(FRAME_PARENTS[frame_name])
		var rest_relation := (authority_zero[parent_name] as Transform3D).affine_inverse() * (
			authority_zero[frame_name] as Transform3D
		)
		var current_relation := (current[parent_name] as Transform3D).affine_inverse() * (
			current[frame_name] as Transform3D
		)
		if current_relation.origin.distance_to(rest_relation.origin) > ORIGIN_TOLERANCE:
			return false
		var delta_basis := rest_relation.basis.inverse() * current_relation.basis
		var axis_name := String(FRAME_AXES[frame_name])
		var angle := _single_axis_angle(delta_basis, axis_name)
		var clean_delta := Basis(_axis_vector(axis_name), angle)
		if _basis_max_abs_difference(delta_basis, clean_delta) > AXIS_TOLERANCE:
			return false
		var target_local := rest_locals[frame_name] as Transform3D
		target_local.basis = target_local.basis * clean_delta
		(frame_nodes[frame_name] as Node3D).transform = target_local
	return true


func _validate_isolated_pose(
	frame_nodes: Dictionary,
	rest_locals: Dictionary,
	rest_globals: Dictionary,
	active_frame: String,
	expected_angle: float
) -> bool:
	for frame_name in FRAME_NAMES:
		var frame_node := frame_nodes[frame_name] as Node3D
		var local_delta := (rest_locals[frame_name] as Transform3D).basis.inverse() * frame_node.basis
		if frame_name == active_frame:
			var actual_angle := _single_axis_angle(local_delta, FRAME_AXES[frame_name])
			if absf(wrapf(actual_angle - expected_angle, -PI, PI)) > AXIS_TOLERANCE:
				return false
			if frame_node.global_position.distance_to(
				(rest_globals[frame_name] as Transform3D).origin
			) > ORIGIN_TOLERANCE:
				return false
		elif _basis_max_abs_difference(local_delta, Basis.IDENTITY) > AXIS_TOLERANCE:
			return false
	return true


func _validate_local_invariants(frame_nodes: Dictionary, rest_locals: Dictionary) -> bool:
	for frame_name in FRAME_NAMES:
		var frame_node := frame_nodes[frame_name] as Node3D
		var rest := rest_locals[frame_name] as Transform3D
		if frame_node.position.distance_to(rest.origin) > ORIGIN_TOLERANCE:
			return false
		if not frame_node.scale.is_equal_approx(Vector3.ONE):
			return false
	return true


func _restore_pose(frame_nodes: Dictionary, rest_locals: Dictionary) -> void:
	for frame_name in FRAME_NAMES:
		(frame_nodes[frame_name] as Node3D).transform = rest_locals[frame_name]


func _convert_frames(raw_frames: Dictionary) -> Dictionary:
	var converted := {}
	for frame_name in FRAME_NAMES:
		var rows: Variant = raw_frames.get(frame_name)
		if not rows is Array or (rows as Array).size() != 4:
			return {}
		converted[frame_name] = MotionProtocolScript.rows_to_transform(rows)
	return converted


func _collect_stats(node: Node, stats: Dictionary) -> void:
	stats.node_count += 1
	if node.get_script() != null:
		stats.script_count += 1
	if node is MeshInstance3D:
		stats.mesh_count += 1
		var mesh_instance := node as MeshInstance3D
		var mesh := mesh_instance.mesh
		var transformed_bounds := mesh_instance.global_transform * mesh_instance.get_aabb()
		if stats.has_bounds:
			stats.bounds = (stats.bounds as AABB).merge(transformed_bounds)
		else:
			stats.bounds = transformed_bounds
			stats.has_bounds = true
		if mesh != null:
			for surface_index in mesh.get_surface_count():
				stats.surface_count += 1
				var material := mesh_instance.get_active_material(surface_index)
				if material != null:
					stats.material_surface_count += 1
				if material is BaseMaterial3D and material.albedo_texture != null:
					stats.textured_surface_count += 1
	elif node is AnimationPlayer:
		stats.animation_player_count += 1
	elif node is Skeleton3D:
		stats.skeleton_count += 1
	elif node is CollisionObject3D or node is CollisionShape3D:
		stats.collision_count += 1
	for child in node.get_children():
		_collect_stats(child, stats)


func _resolve_asset_path(asset_root: Node, raw_path: String) -> Node:
	if raw_path == asset_root.name:
		return asset_root
	var relative_path := raw_path
	var root_prefix := asset_root.name + "/"
	if relative_path.begins_with(root_prefix):
		relative_path = relative_path.trim_prefix(root_prefix)
	return asset_root.get_node_or_null(NodePath(relative_path))


func _single_axis_angle(basis: Basis, axis_name: String) -> float:
	if axis_name == "Y":
		return atan2(basis.z.x, basis.x.x)
	return atan2(basis.y.z, basis.y.y)


func _axis_vector(axis_name: String) -> Vector3:
	return Vector3.UP if axis_name == "Y" else Vector3.RIGHT


func _basis_max_abs_difference(first: Basis, second: Basis) -> float:
	var difference := 0.0
	var first_columns := [first.x, first.y, first.z]
	var second_columns := [second.x, second.y, second.z]
	for column_index in range(3):
		var first_column: Vector3 = first_columns[column_index]
		var second_column: Vector3 = second_columns[column_index]
		difference = maxf(difference, absf(first_column.x - second_column.x))
		difference = maxf(difference, absf(first_column.y - second_column.y))
		difference = maxf(difference, absf(first_column.z - second_column.z))
	return difference


func _finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}


func _fail(asset_root: Node, message: String) -> int:
	push_error(message)
	asset_root.free()
	return 1

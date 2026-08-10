extends SceneTree

const ASSET_PATH := "res://assets/visual/SY205_excavator_godot.glb"
const MANIFEST_PATH := "res://resources/visual/sy205_visual_manifest.json"
const PARITY_CASES_PATH := "res://tests/fixtures/sy205_frame_parity_cases.json"
const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const EXPECTED_SHA256 := "cf95534b31bcc156980afefef0a9f273e5c6f727547b3db1e9062ca5619b495a"
const EXPECTED_FRAME_NAMES := [
	"base_link",
	"upper_structure_link",
	"boom_link",
	"arm_link",
	"bucket_link",
]
const EXPECTED_FRAME_PATHS := {
	"base_link": "CTRL_EXCAVATOR_ROOT",
	"upper_structure_link": "CTRL_EXCAVATOR_ROOT/PIVOT_SLEW",
	"boom_link": "CTRL_EXCAVATOR_ROOT/PIVOT_SLEW/PIVOT_BOOM_BASE",
	"arm_link": "CTRL_EXCAVATOR_ROOT/PIVOT_SLEW/PIVOT_BOOM_BASE/PIVOT_ARM_JOINT",
	"bucket_link": (
		"CTRL_EXCAVATOR_ROOT/PIVOT_SLEW/PIVOT_BOOM_BASE/PIVOT_ARM_JOINT/PIVOT_BUCKET_JOINT"
	),
}
const EXPECTED_PIVOT_AXES := {
	"base_link": "Z",
	"upper_structure_link": "Z",
	"boom_link": "X",
	"arm_link": "X",
	"bucket_link": "X",
}
const REQUIRED_LINKAGE_NAMES := [
	"bucket_linkage_secondary_a",
	"bucket_linkage_secondary_b",
	"bucket_linkage_primary",
	"bucket_linkage_connector",
]


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	quit(_validate_asset_contract())


func _validate_asset_contract() -> int:
	if FileAccess.get_sha256(ASSET_PATH) != EXPECTED_SHA256:
		push_error("SY205 asset SHA-256 does not match the reviewed source.")
		return 1

	var manifest_file := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if manifest_file == null:
		push_error("Unable to open %s" % MANIFEST_PATH)
		return 1

	var parsed_manifest: Variant = JSON.parse_string(manifest_file.get_as_text())
	if not parsed_manifest is Dictionary:
		push_error("SY205 visual manifest is not a JSON object.")
		return 1
	var manifest: Dictionary = parsed_manifest
	if not _validate_parity_handoff(manifest):
		return 1
	if not _validate_main_scene_mount():
		return 1

	var packed_scene := load(ASSET_PATH) as PackedScene
	if packed_scene == null:
		push_error("Unable to load imported GLB as PackedScene: %s" % ASSET_PATH)
		return 1

	var asset_root := packed_scene.instantiate()
	root.add_child(asset_root)
	var frame_map: Dictionary = manifest.get("frame_map", {})
	var observed_rest_transforms: Dictionary = {}
	for frame_name in EXPECTED_FRAME_NAMES:
		var frame_entry: Dictionary = frame_map.get(frame_name, {})
		var node_path := String(frame_entry.get("node_path", ""))
		if node_path != EXPECTED_FRAME_PATHS[frame_name]:
			push_error("SY205 frame path drifted for %s." % frame_name)
			asset_root.free()
			return 1
		if frame_entry.get("pivot_axis", "") != EXPECTED_PIVOT_AXES[frame_name]:
			push_error("SY205 pivot axis drifted for %s." % frame_name)
			asset_root.free()
			return 1
		var pivot := _resolve_asset_path(asset_root, node_path)
		if pivot == null:
			push_error("Missing SY205 pivot for %s: %s" % [frame_name, node_path])
			asset_root.free()
			return 1
		var observed_rest := _transform_rows((pivot as Node3D).global_transform)
		observed_rest_transforms[frame_name] = observed_rest
		print("SY205_REST %s %s" % [frame_name, observed_rest])
		var visual_nodes: Array = frame_entry.get("visual_nodes", [])
		if visual_nodes.is_empty():
			push_error("SY205 frame %s must own at least one visual node." % frame_name)
			asset_root.free()
			return 1
		for visual_path in visual_nodes:
			if _resolve_asset_path(asset_root, String(visual_path)) == null:
				push_error("Missing mapped SY205 visual node: %s" % visual_path)
				asset_root.free()
				return 1

	if not _validate_rest_calibration(manifest, observed_rest_transforms):
		asset_root.free()
		return 1

	for linkage_name in REQUIRED_LINKAGE_NAMES:
		if asset_root.find_child(linkage_name, true, false) == null:
			push_error("Missing required SY205 linkage node: %s" % linkage_name)
			asset_root.free()
			return 1

	var stats := {
		"mesh_count": 0,
		"surface_count": 0,
		"material_surface_count": 0,
		"textured_surface_count": 0,
		"animation_player_count": 0,
		"skeleton_count": 0,
		"collision_count": 0,
		"has_bounds": false,
		"bounds": AABB(),
	}
	_collect_stats(asset_root, stats)

	if stats.mesh_count != 11:
		push_error("Expected 11 imported meshes, got %d." % stats.mesh_count)
		asset_root.free()
		return 1
	if stats.material_surface_count != stats.surface_count:
		push_error("Every imported mesh surface must retain a material.")
		asset_root.free()
		return 1
	if stats.textured_surface_count != stats.surface_count:
		push_error("Every imported mesh surface must retain its embedded albedo texture.")
		asset_root.free()
		return 1
	if stats.animation_player_count != 0 or stats.skeleton_count != 0:
		push_error("The reviewed SY205 GLB must remain a pivot-driven, non-skinned asset.")
		asset_root.free()
		return 1
	if stats.collision_count != 0:
		push_error("Visual GLB import unexpectedly created collision authority resources.")
		asset_root.free()
		return 1
	var imported_bounds: AABB = stats["bounds"]
	print("SY205_BOUNDS position=%s size=%s" % [imported_bounds.position, imported_bounds.size])
	if not _bounds_within_inspection_envelope(imported_bounds):
		push_error("Imported SY205 bounds fall outside the reviewed inspection envelope.")
		asset_root.free()
		return 1
	if not _validate_manifest_bounds(manifest, imported_bounds):
		asset_root.free()
		return 1

	asset_root.free()
	print(
		"SY205 GLB contract passed: %d pivots, %d meshes, %d textured surfaces."
		% [EXPECTED_FRAME_NAMES.size(), stats.mesh_count, stats.textured_surface_count]
	)
	return 0


func _validate_rest_calibration(manifest: Dictionary, observed: Dictionary) -> bool:
	var calibration: Dictionary = manifest.get("calibration", {})
	if calibration.get("status", "") != "imported_rest_pose_captured_frame_parity_pending":
		push_error("SY205 calibration status must record a captured imported rest pose.")
		return false
	var rest_transforms: Dictionary = calibration.get("rest_transforms_godot", {})
	for frame_name in EXPECTED_FRAME_NAMES:
		var expected: Variant = rest_transforms.get(frame_name)
		if not expected is Array or (expected as Array).size() != 4:
			push_error("SY205 calibration is missing a 4x4 rest transform for %s." % frame_name)
			return false
		var expected_rows: Array = expected
		var observed_rows: Array = observed.get(frame_name, [])
		for row_index in range(4):
			if not expected_rows[row_index] is Array or (expected_rows[row_index] as Array).size() != 4:
				push_error("SY205 calibration row is malformed for %s." % frame_name)
				return false
			var expected_row: Array = expected_rows[row_index]
			var observed_row: Array = observed_rows[row_index]
			for column_index in range(4):
				if abs(float(expected_row[column_index]) - float(observed_row[column_index])) > 0.0001:
					push_error("SY205 rest transform drifted for %s." % frame_name)
					return false
	return true


func _validate_main_scene_mount() -> bool:
	var packed_scene := load(MAIN_SCENE_PATH) as PackedScene
	if packed_scene == null:
		push_error("Unable to load %s for the fallback mount check." % MAIN_SCENE_PATH)
		return false
	var scene_root := packed_scene.instantiate()
	var fallback := scene_root.get_node_or_null("ExcavatorRig") as Node3D
	var mounted_asset := scene_root.get_node_or_null(
		"PresentationRoot/SY205Excavator/CTRL_EXCAVATOR_ROOT"
	)
	if fallback == null or fallback.visible:
		push_error("Placeholder ExcavatorRig must remain present but hidden behind the imported asset.")
		scene_root.free()
		return false
	if mounted_asset == null:
		push_error("The SY205 GLB is not mounted below PresentationRoot.")
		scene_root.free()
		return false
	scene_root.free()
	return true


func _bounds_within_inspection_envelope(bounds: AABB) -> bool:
	var min_bound := bounds.position
	var max_bound := bounds.position + bounds.size
	var minimum := Vector3(-1.7, -0.1, -3.1)
	var maximum := Vector3(1.7, 6.8, 4.4)
	var minimum_size := Vector3(3.0, 6.3, 6.8)
	return (
		min_bound.x >= minimum.x
		and min_bound.y >= minimum.y
		and min_bound.z >= minimum.z
		and max_bound.x <= maximum.x
		and max_bound.y <= maximum.y
		and max_bound.z <= maximum.z
		and bounds.size.x >= minimum_size.x
		and bounds.size.y >= minimum_size.y
		and bounds.size.z >= minimum_size.z
	)


func _validate_manifest_bounds(manifest: Dictionary, bounds: AABB) -> bool:
	var inspection: Dictionary = manifest.get("inspection", {})
	var recorded: Dictionary = inspection.get("imported_bounds_godot", {})
	var actual := {
		"min": bounds.position,
		"max": bounds.position + bounds.size,
		"size": bounds.size,
	}
	for key in ["min", "max", "size"]:
		var values: Variant = recorded.get(key)
		if not values is Array or (values as Array).size() != 3:
			push_error("SY205 manifest bounds are malformed for %s." % key)
			return false
		var vector := actual[key] as Vector3
		for index in range(3):
			if abs(float(values[index]) - vector[index]) > 0.0001:
				push_error("SY205 manifest bounds drifted for %s." % key)
				return false
	return true


func _validate_parity_handoff(manifest: Dictionary) -> bool:
	var parity_file := FileAccess.open(PARITY_CASES_PATH, FileAccess.READ)
	if parity_file == null:
		push_error("Unable to open %s" % PARITY_CASES_PATH)
		return false
	var parsed_parity: Variant = JSON.parse_string(parity_file.get_as_text())
	if not parsed_parity is Dictionary:
		push_error("SY205 frame-parity handoff is not a JSON object.")
		return false
	var parity: Dictionary = parsed_parity
	var calibration: Dictionary = manifest.get("calibration", {})
	if parity.get("source_fixture_sha256", "") != calibration.get("authority_fixture_sha256", ""):
		push_error("SY205 frame-parity handoff does not match the authority fixture hash.")
		return false
	var poses: Dictionary = parity.get("poses", {})
	for pose_name in ["zero", "asymmetric"]:
		var pose: Dictionary = poses.get(pose_name, {})
		if (pose.get("joint_angles", []) as Array).size() != 4:
			push_error("Frame-parity pose %s must contain four joint angles." % pose_name)
			return false
		var frame_transforms: Dictionary = pose.get("frame_transforms", {})
		for frame_name in EXPECTED_FRAME_NAMES:
			if not frame_transforms.has(frame_name):
				push_error("Frame-parity pose %s is missing %s." % [pose_name, frame_name])
				return false
	return true


func _resolve_asset_path(asset_root: Node, raw_path: String) -> Node:
	if raw_path == asset_root.name:
		return asset_root
	var relative_path := raw_path
	var root_prefix := asset_root.name + "/"
	if relative_path.begins_with(root_prefix):
		relative_path = relative_path.trim_prefix(root_prefix)
	return asset_root.get_node_or_null(NodePath(relative_path))


func _collect_stats(node: Node, stats: Dictionary) -> void:
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


func _transform_rows(transform: Transform3D) -> Array:
	return [
		[
			transform.basis.x.x,
			transform.basis.y.x,
			transform.basis.z.x,
			transform.origin.x,
		],
		[
			transform.basis.x.y,
			transform.basis.y.y,
			transform.basis.z.y,
			transform.origin.y,
		],
		[
			transform.basis.x.z,
			transform.basis.y.z,
			transform.basis.z.z,
			transform.origin.z,
		],
		[0.0, 0.0, 0.0, 1.0],
	]

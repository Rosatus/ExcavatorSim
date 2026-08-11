class_name MotionPresentation
extends Node3D

## Applies converted Python named-frame transforms to the imported SY205 visual
## skin. MotionProtocol owns the Python Z-up -> Godot Y-up conversion. The
## calibration offset keeps the imported GLB rest pose while Python remains the
## only owner of the world-space link transforms.

const MANIFEST_PATH := "res://resources/visual/sy205_visual_manifest.json"
const PARITY_FIXTURE_PATH := "res://tests/fixtures/sy205_frame_parity_cases.json"

@export var motion_client_path := NodePath("../MotionClient")
@export var asset_root_path := NodePath("../PresentationRoot/SY205Excavator")

var _motion_client: MotionClient
var _asset_root: Node3D
var _frame_nodes: Dictionary = {}
var _calibration_offsets: Dictionary = {}
var _rest_globals: Dictionary = {}
var _has_pose := false
var _last_render_revision := -1
var _contract_error := ""

# The imported GLB intentionally contains no Blender drivers or animation
# tracks. These nodes are the Godot-only passive four-bar presentation seam
# described by SY205_Godot_Import_Guide.md. They consume already-converted
# authoritative frame globals and never publish transforms back to Python.
var _linkage_arm: Node3D
var _linkage_bucket: Node3D
var _linkage_a_pin: Node3D
var _linkage_b_pin: Node3D
var _linkage_c_pin: Node3D
var _linkage_d_pin: Node3D
var _linkage_side_controller: Node3D
var _linkage_a0 := Vector3.ZERO
var _linkage_b0 := Vector3.ZERO
var _linkage_c0 := Vector3.ZERO
var _linkage_d0 := Vector3.ZERO
var _linkage_ab_length := 0.0
var _linkage_ac_length := 0.0
var _linkage_cd_length := 0.0
var _linkage_rest_b_transform := Transform3D.IDENTITY
var _linkage_rest_side_transform := Transform3D.IDENTITY
var _linkage_previous_a_yz := Vector2.ZERO
var _linkage_last_valid_a := Vector3.ZERO
var _linkage_reachable := false
var _linkage_reason := "uninitialized"
var _linkage_last_warning_reason := ""
var _linkage_initialized := false


func _ready() -> void:
	_motion_client = get_node_or_null(motion_client_path) as MotionClient
	_asset_root = get_node_or_null(asset_root_path) as Node3D
	if _motion_client == null or _asset_root == null:
		_contract_error = "MotionPresentation requires MotionClient and imported SY205 asset"
		push_warning(_contract_error)
		return
	if not _load_mapping_contract():
		return
	_motion_client.pose_accepted.connect(_on_pose_accepted)
	_motion_client.pose_cleared.connect(_on_pose_cleared)
	_restore_rest_pose()


func _process(_delta: float) -> void:
	if _motion_client == null or not _has_pose:
		return
	var render_pose := _motion_client.get_render_pose()
	if render_pose.is_empty():
		return
	var revision := int(render_pose.get("view_revision", -1))
	if revision != _last_render_revision or _motion_client.interpolation_enabled:
		_apply_render_pose(render_pose)
		_last_render_revision = revision


func get_contract_error() -> String:
	return _contract_error


func get_frame_node(frame_name: String) -> Node3D:
	return _frame_nodes.get(frame_name) as Node3D


func apply_pose_for_test(pose: Dictionary) -> bool:
	if not _has_required_frames():
		return false
	var transforms: Dictionary = pose.get("frame_transforms", {})
	if not transforms.has("base_link"):
		return false
	var converted := {}
	for frame_name in MotionProtocol.FRAME_NAMES:
		if not transforms.has(frame_name):
			return false
		converted[frame_name] = MotionProtocol.rows_to_transform(transforms[frame_name])
	_apply_render_pose({"transforms": converted, "view_revision": 0})
	return true


func restore_rest_pose_for_test() -> void:
	_restore_rest_pose()


func _load_mapping_contract() -> bool:
	var manifest := _read_json(MANIFEST_PATH)
	var fixture := _read_json(PARITY_FIXTURE_PATH)
	if manifest.is_empty() or fixture.is_empty():
		_contract_error = "SY205 mapping or parity fixture could not be loaded"
		push_error(_contract_error)
		return false
	var frame_map: Dictionary = manifest.get("frame_map", {})
	var zero_pose: Dictionary = fixture.get("poses", {}).get("zero", {})
	var zero_frames: Dictionary = zero_pose.get("frame_transforms", {})
	for frame_name in MotionProtocol.FRAME_NAMES:
		var mapping: Dictionary = frame_map.get(frame_name, {})
		var node_path := String(mapping.get("node_path", ""))
		var frame_node := _asset_root.get_node_or_null(NodePath(node_path)) as Node3D
		if frame_node == null or not zero_frames.has(frame_name):
			_contract_error = "SY205 mapping is missing %s" % frame_name
			push_error(_contract_error)
			return false
		_frame_nodes[frame_name] = frame_node
		_rest_globals[frame_name] = frame_node.global_transform
		var authority_zero_godot := MotionProtocol.rows_to_transform(zero_frames[frame_name])
		_calibration_offsets[frame_name] = authority_zero_godot.affine_inverse() * frame_node.global_transform
	var passive_linkage: Dictionary = manifest.get("passive_linkage", {})
	return _load_passive_linkage_contract(passive_linkage)


func _on_pose_accepted(_pose: Dictionary) -> void:
	_has_pose = true
	_last_render_revision = -1
	_apply_render_pose(_motion_client.get_render_pose())


func _on_pose_cleared(_generation: int, _reason: String) -> void:
	_has_pose = false
	_last_render_revision = -1
	_restore_rest_pose()


func _apply_render_pose(pose: Dictionary) -> void:
	var transforms: Dictionary = pose.get("transforms", {})
	for frame_name in MotionProtocol.FRAME_NAMES:
		var frame_node := _frame_nodes.get(frame_name) as Node3D
		var incoming: Variant = transforms.get(frame_name)
		var offset: Variant = _calibration_offsets.get(frame_name)
		if frame_node != null and incoming is Transform3D and offset is Transform3D:
			frame_node.global_transform = (incoming as Transform3D) * (offset as Transform3D)
	_apply_passive_linkage()


func _restore_rest_pose() -> void:
	for frame_name in _rest_globals:
		var frame_node := _frame_nodes.get(frame_name) as Node3D
		if frame_node != null:
			frame_node.global_transform = _rest_globals[frame_name]
	if _linkage_initialized:
		_linkage_b_pin.transform = _linkage_rest_b_transform
		_linkage_side_controller.transform = _linkage_rest_side_transform
		_linkage_previous_a_yz = Vector2(_linkage_a0.y, _linkage_a0.z)
		_linkage_last_valid_a = _linkage_a0
		_linkage_reachable = true
		_linkage_reason = "restored"
		_linkage_last_warning_reason = ""


func recompute_passive_linkage_for_test() -> void:
	_apply_passive_linkage()


func get_passive_linkage_snapshot_for_test() -> Dictionary:
	if not _linkage_initialized:
		return {"reachable": false, "reason": _linkage_reason}
	var a_local := _linkage_arm.to_local(_linkage_a_pin.global_position)
	var b_local := _linkage_arm.to_local(_linkage_b_pin.global_position)
	var c_local := _linkage_arm.to_local(_linkage_c_pin.global_position)
	var d_local := _linkage_arm.to_local(_linkage_d_pin.global_position)
	return {
		"reachable": _linkage_reachable,
		"reason": _linkage_reason,
		"a_local": a_local,
		"b_local": b_local,
		"c_local": c_local,
		"d_local": d_local,
		"a_world": _linkage_a_pin.global_position,
		"b_world": _linkage_b_pin.global_position,
		"c_world": _linkage_c_pin.global_position,
		"d_world": _linkage_d_pin.global_position,
		"ab_length": _linkage_yz_distance(a_local, b_local),
		"ac_length": _linkage_yz_distance(a_local, c_local),
		"cd_length": _linkage_yz_distance(c_local, d_local),
		"rest_ab_length": _linkage_ab_length,
		"rest_ac_length": _linkage_ac_length,
		"rest_cd_length": _linkage_cd_length,
		"b_rotation": _linkage_b_pin.rotation,
		"side_position": _linkage_side_controller.position,
		"side_rotation": _linkage_side_controller.rotation,
	}


func _load_passive_linkage_contract(passive_linkage: Dictionary) -> bool:
	if passive_linkage.get("mode", "") != "godot_visual_four_bar":
		_contract_error = "SY205 passive linkage mode is missing or unsupported"
		push_error(_contract_error)
		return false
	if passive_linkage.get("solver_plane", "") != "arm_link_local_yz":
		_contract_error = "SY205 passive linkage must solve in arm-local Y-Z"
		push_error(_contract_error)
		return false
	var paths: Dictionary = passive_linkage.get("pin_paths_relative_to_arm", {})
	_linkage_arm = _frame_nodes.get("arm_link") as Node3D
	_linkage_bucket = _linkage_arm.get_node_or_null(NodePath("PIVOT_BUCKET_JOINT")) as Node3D
	_linkage_b_pin = _linkage_arm.get_node_or_null(NodePath(paths.get("B", ""))) as Node3D
	_linkage_a_pin = _linkage_arm.get_node_or_null(NodePath(paths.get("A", ""))) as Node3D
	_linkage_c_pin = _linkage_arm.get_node_or_null(NodePath(paths.get("C", ""))) as Node3D
	_linkage_d_pin = _linkage_arm.get_node_or_null(NodePath(paths.get("D", ""))) as Node3D
	_linkage_side_controller = _linkage_arm.get_node_or_null(NodePath(paths.get("side_controller", ""))) as Node3D
	if (
		_linkage_arm == null
		or _linkage_bucket == null
		or _linkage_a_pin == null
		or _linkage_b_pin == null
		or _linkage_c_pin == null
		or _linkage_d_pin == null
		or _linkage_side_controller == null
	):
		_contract_error = "SY205 passive linkage A/B/C/D nodes are missing"
		push_error(_contract_error)
		return false
	_linkage_a0 = _linkage_arm.to_local(_linkage_a_pin.global_position)
	_linkage_b0 = _linkage_arm.to_local(_linkage_b_pin.global_position)
	_linkage_c0 = _linkage_arm.to_local(_linkage_c_pin.global_position)
	_linkage_d0 = _linkage_arm.to_local(_linkage_d_pin.global_position)
	_linkage_ab_length = _linkage_yz_distance(_linkage_a0, _linkage_b0)
	_linkage_ac_length = _linkage_yz_distance(_linkage_a0, _linkage_c0)
	_linkage_cd_length = _linkage_yz_distance(_linkage_c0, _linkage_d0)
	if (
		_linkage_ab_length <= 0.000001
		or _linkage_ac_length <= 0.000001
		or _linkage_cd_length <= 0.000001
	):
		_contract_error = "SY205 passive linkage rest geometry is degenerate"
		push_error(_contract_error)
		return false
	_linkage_rest_b_transform = _linkage_b_pin.transform
	_linkage_rest_side_transform = _linkage_side_controller.transform
	_linkage_previous_a_yz = Vector2(_linkage_a0.y, _linkage_a0.z)
	_linkage_last_valid_a = _linkage_a0
	_linkage_reachable = true
	_linkage_reason = "rest"
	_linkage_last_warning_reason = ""
	_linkage_initialized = true
	return true


func _apply_passive_linkage() -> void:
	if not _linkage_initialized:
		return
	var c_local := _linkage_arm.to_local(_linkage_c_pin.global_position)
	var b_local := _linkage_arm.to_local(_linkage_b_pin.global_position)
	if not _finite_vector(c_local) or not _finite_vector(b_local):
		_linkage_mark_unreachable("non_finite_pin")
		return
	var b2 := Vector2(b_local.y, b_local.z)
	var c2 := Vector2(c_local.y, c_local.z)
	var delta := c2 - b2
	var distance := delta.length()
	var radius_sum := _linkage_ab_length + _linkage_ac_length
	var radius_difference := absf(_linkage_ab_length - _linkage_ac_length)
	if (
		distance <= 0.000001
		or distance > radius_sum + 0.0001
		or distance < radius_difference - 0.0001
	):
		_linkage_mark_unreachable("unreachable_circle_intersection")
		return
	var along := (_linkage_ab_length * _linkage_ab_length - _linkage_ac_length * _linkage_ac_length + distance * distance) / (2.0 * distance)
	var height_squared := _linkage_ab_length * _linkage_ab_length - along * along
	if height_squared < -0.0001:
		_linkage_mark_unreachable("negative_circle_height")
		return
	var height := sqrt(maxf(0.0, height_squared))
	var midpoint := b2 + delta * (along / distance)
	var normal := Vector2(-delta.y, delta.x) * (height / distance)
	var candidate_a1 := midpoint + normal
	var candidate_a2 := midpoint - normal
	var previous := _linkage_previous_a_yz
	var solved_a := candidate_a1 if candidate_a1.distance_to(previous) <= candidate_a2.distance_to(previous) else candidate_a2
	if not _finite_vector(Vector3(_linkage_a0.x, solved_a.x, solved_a.y)):
		_linkage_mark_unreachable("non_finite_solution")
		return
	var phi := atan2(solved_a.y - b2.y, solved_a.x - b2.x)
	var phi0 := atan2(_linkage_a0.z - _linkage_b0.z, _linkage_a0.y - _linkage_b0.y)
	var psi := atan2(c2.y - solved_a.y, c2.x - solved_a.x)
	var psi0 := atan2(_linkage_c0.z - _linkage_a0.z, _linkage_c0.y - _linkage_a0.y)
	var b_rotation := _linkage_rest_b_transform.basis.get_euler()
	b_rotation.x += _angle_delta(phi, phi0)
	var side_rotation := _linkage_rest_side_transform.basis.get_euler()
	side_rotation.x += _angle_delta(psi, psi0)
	_linkage_b_pin.rotation = b_rotation
	_linkage_side_controller.position = Vector3(_linkage_a0.x, solved_a.x, solved_a.y)
	_linkage_side_controller.rotation = side_rotation
	_linkage_previous_a_yz = solved_a
	_linkage_last_valid_a = Vector3(_linkage_a0.x, solved_a.x, solved_a.y)
	_linkage_reachable = true
	_linkage_reason = "solved"
	_linkage_last_warning_reason = ""


func _linkage_mark_unreachable(reason: String) -> void:
	_linkage_reachable = false
	_linkage_reason = reason
	if _linkage_last_warning_reason != reason:
		push_warning("SY205 passive linkage retained its last valid pose: %s" % reason)
		_linkage_last_warning_reason = reason


func _linkage_yz_distance(first: Vector3, second: Vector3) -> float:
	return Vector2(first.y - second.y, first.z - second.z).length()


func _angle_delta(current: float, rest: float) -> float:
	return wrapf(current - rest, -PI, PI)


func _finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


func _has_required_frames() -> bool:
	return _frame_nodes.size() == MotionProtocol.FRAME_NAMES.size() and _calibration_offsets.size() == _frame_nodes.size()


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}

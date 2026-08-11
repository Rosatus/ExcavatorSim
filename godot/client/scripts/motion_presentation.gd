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
	return true


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


func _restore_rest_pose() -> void:
	for frame_name in _rest_globals:
		var frame_node := _frame_nodes.get(frame_name) as Node3D
		if frame_node != null:
			frame_node.global_transform = _rest_globals[frame_name]


func _has_required_frames() -> bool:
	return _frame_nodes.size() == MotionProtocol.FRAME_NAMES.size() and _calibration_offsets.size() == _frame_nodes.size()


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}

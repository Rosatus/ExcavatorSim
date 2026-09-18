class_name AttachmentRig
extends Node3D

## Runtime owner for the coupler + tool attachment stack mounted on the active
## model's bucket_link frame node. The catalog declares quick couplers (e.g. a
## tiltrotator) separately from tools (e.g. a bucket); each tool lists the
## couplers it supports, so switching one side auto-resolves the other. The
## coupler GLB subtree mounts unchanged at identity (per 装配与动画说明.md),
## the tool mounts at identity under the coupler's socket, and the baked
## passive-mechanism table drives cylinders and hoses under tilt. Tilt/rotate
## are presentation-level DOFs: the physics rig keeps the native curl body.

const CATALOG_PATH := "res://resources/models/attachment_catalog.json"
const DIRECT_PIN_COUPLER_ID := "none"
const NATIVE_TOOL_ID := "standard_bucket"

@export var motion_presentation_path: NodePath
@export var product_session_path: NodePath
@export var motion_client_path: NodePath

signal attachment_activated(attachment_id: String)
signal attachment_activation_failed(attachment_id: String, reason: String)

var _presentation: MotionPresentation
var _product_session: ProductSession
var _motion_client: MotionClient

var _catalog: Dictionary = {}
var _couplers: Dictionary = {}
var _tools: Dictionary = {}
var _catalog_error := ""

var _active_coupler_id := DIRECT_PIN_COUPLER_ID
var _active_tool_id := NATIVE_TOOL_ID
var _mount_root: Node3D = null
var _tool_node: Node3D = null
var _mount_owned: Dictionary = {}
var _tilt_node: Node3D = null
var _rotate_node: Node3D = null
var _hidden_visuals: Array[Node3D] = []
var _passive_nodes: Dictionary = {}
var _weight_meshes: Dictionary = {}
var _tilt_samples: Array = []
var _tilt_min_deg := -45.0
var _tilt_max_deg := 45.0
var _tilt_rate_dps := 60.0
var _rotate_rate_dps := 90.0
var _tilt_axis := Vector3.BACK
var _rotate_axis := Vector3.UP
var _tilt_sign := 1.0
var _rotate_sign := 1.0

var _tilt_deg := 0.0
var _rotate_deg := 0.0
var _use_test_axes := false
var _test_axes := Vector2.ZERO
var _remount_pending := false
var _remount_coupler_id := ""
var _remount_tool_id := ""


func _ready() -> void:
	_presentation = get_node_or_null(motion_presentation_path) as MotionPresentation
	_product_session = get_node_or_null(product_session_path) as ProductSession
	_motion_client = get_node_or_null(motion_client_path) as MotionClient
	_load_catalog()
	if _presentation != null:
		_presentation.model_replacing.connect(_on_model_replacing)
		_presentation.model_activated.connect(_on_model_activated)


func _physics_process(delta: float) -> void:
	if _tilt_node == null and _rotate_node == null:
		return
	var axes := _test_axes if _use_test_axes else _read_session_axes()
	if not axes.is_finite():
		return
	var next_tilt := _tilt_deg
	var next_rotate := _rotate_deg
	if _tilt_node != null:
		next_tilt = clampf(_tilt_deg + axes.x * _tilt_rate_dps * delta, _tilt_min_deg, _tilt_max_deg)
	if _rotate_node != null:
		next_rotate = wrapf(_rotate_deg + axes.y * _rotate_rate_dps * delta, -180.0, 180.0)
	if not is_equal_approx(next_tilt, _tilt_deg) or not is_equal_approx(next_rotate, _rotate_deg):
		_tilt_deg = next_tilt
		_rotate_deg = next_rotate
		_apply_pose()


## Switch the tool side. The tool's supported_couplers list is the contract:
## when the current coupler is not in it, the coupler auto-resolves to the
## tool's first supported entry (e.g. GB12 pulls in the XTR13).
func request_tool(tool_id: String) -> bool:
	if not _tools.has(tool_id):
		return _fail(_descriptor(_active_coupler_id, tool_id), "unknown_tool")
	return _apply_combination(_resolve_coupler_for(tool_id), tool_id)


## Switch the coupler side. When the active tool cannot mount on the new
## coupler, the tool auto-resolves to the first catalog tool that can.
func request_coupler(coupler_id: String) -> bool:
	if not _couplers.has(coupler_id):
		return _fail(_descriptor(coupler_id, _active_tool_id), "unknown_coupler")
	return _apply_combination(coupler_id, _resolve_tool_for(coupler_id))


func active_coupler_id() -> String:
	return _active_coupler_id


func active_tool_id() -> String:
	return _active_tool_id


func active_attachment_id() -> String:
	return _descriptor(_active_coupler_id, _active_tool_id)


func active_tool_node() -> Node3D:
	return _tool_node


func is_tiltrotator_active() -> bool:
	return _mount_root != null


func coupler_ids() -> Array[String]:
	return _ids_from(_catalog.get("couplers", []), "coupler_id")


func tool_ids() -> Array[String]:
	return _ids_from(_catalog.get("tools", []), "tool_id")


func coupler_display_name(coupler_id: String) -> String:
	return String((_couplers.get(coupler_id, {}) as Dictionary).get("display_name", coupler_id))


func tool_display_name(tool_id: String) -> String:
	return String((_tools.get(tool_id, {}) as Dictionary).get("display_name", tool_id))


func tool_supported_couplers(tool_id: String) -> Array[String]:
	var supported: Array[String] = []
	for value in (_tools.get(tool_id, {}) as Dictionary).get("supported_couplers", []):
		supported.append(String(value))
	return supported


func get_catalog_error() -> String:
	return _catalog_error


func set_axes_for_test(axes: Vector2) -> void:
	_use_test_axes = true
	_test_axes = axes


func clear_axes_for_test() -> void:
	_use_test_axes = false


func joint_state_for_test() -> Dictionary:
	return {
		"coupler_id": _active_coupler_id,
		"tool_id": _active_tool_id,
		"attachment_id": active_attachment_id(),
		"tilt_deg": _tilt_deg,
		"rotate_deg": _rotate_deg,
		"mounted": _mount_root != null,
		"tool_node": is_instance_valid(_tool_node),
	}


func get_status_snapshot() -> Dictionary:
	return {
		"coupler_id": _active_coupler_id,
		"tool_id": _active_tool_id,
		"attachment_id": active_attachment_id(),
		"tiltrotator_mounted": _mount_root != null,
		"tilt_deg": _tilt_deg,
		"rotate_deg": _rotate_deg,
		"catalog_error": _catalog_error,
	}


func _read_session_axes() -> Vector2:
	if _product_session == null:
		return Vector2.ZERO
	return _product_session.get_attachment_input_axes()


func _descriptor(coupler_id: String, tool_id: String) -> String:
	return "%s+%s" % [coupler_id, tool_id]


func _fail(descriptor: String, reason: String) -> bool:
	_catalog_error = reason
	attachment_activation_failed.emit(descriptor, reason)
	return false


func _ids_from(entries: Variant, key: String) -> Array[String]:
	var ids: Array[String] = []
	for entry_value in entries:
		var entry := entry_value as Dictionary
		if entry != null and not String(entry.get(key, "")).is_empty():
			ids.append(String(entry[key]))
	return ids


func _load_catalog() -> void:
	_catalog_error = ""
	_couplers.clear()
	_tools.clear()
	if not FileAccess.file_exists(CATALOG_PATH):
		_catalog_error = "attachment_catalog_unavailable"
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG_PATH))
	if not parsed is Dictionary:
		_catalog_error = "attachment_catalog_invalid_json"
		return
	_catalog = parsed as Dictionary
	for entry_value in _catalog.get("couplers", []):
		var entry := entry_value as Dictionary
		if entry == null:
			continue
		var coupler_id := String(entry.get("coupler_id", ""))
		if not coupler_id.is_empty():
			_couplers[coupler_id] = entry
	for entry_value in _catalog.get("tools", []):
		var entry := entry_value as Dictionary
		if entry == null:
			continue
		var tool_id := String(entry.get("tool_id", ""))
		if not tool_id.is_empty():
			_tools[tool_id] = entry
	if _couplers.is_empty() or _tools.is_empty():
		_catalog_error = "attachment_catalog_empty"


func _tool_supports(tool_id: String, coupler_id: String) -> bool:
	return tool_supported_couplers(tool_id).has(coupler_id)


func _resolve_coupler_for(tool_id: String) -> String:
	if _tool_supports(tool_id, _active_coupler_id):
		return _active_coupler_id
	var supported := tool_supported_couplers(tool_id)
	return supported[0] if not supported.is_empty() else DIRECT_PIN_COUPLER_ID


func _resolve_tool_for(coupler_id: String) -> String:
	if _tool_supports(_active_tool_id, coupler_id):
		return _active_tool_id
	for tool_id in tool_ids():
		if _tool_supports(tool_id, coupler_id):
			return tool_id
	return NATIVE_TOOL_ID


func _apply_combination(coupler_id: String, tool_id: String) -> bool:
	if coupler_id == _active_coupler_id and tool_id == _active_tool_id and _mount_state_consistent():
		return true
	var coupler := _couplers.get(coupler_id, {}) as Dictionary
	var tool := _tools.get(tool_id, {}) as Dictionary
	if coupler.is_empty():
		return _fail(_descriptor(coupler_id, tool_id), "unknown_coupler")
	if tool.is_empty():
		return _fail(_descriptor(coupler_id, tool_id), "unknown_tool")
	if not _tool_supports(tool_id, coupler_id):
		return _fail(_descriptor(coupler_id, tool_id), "incompatible_pair")
	_clear_attachment()
	if coupler_id == DIRECT_PIN_COUPLER_ID:
		# The native bucket visual IS the standard bucket: any other tool on a
		# bare pin means the bucket was physically removed.
		if tool_id != NATIVE_TOOL_ID:
			_hide_native_bucket(String(coupler.get("hidden_frame", "bucket_link")))
		_active_coupler_id = coupler_id
		_active_tool_id = tool_id
		_apply_attachment_state()
		return true
	if not _mount_tiltrotator(coupler_id, coupler, tool_id, tool):
		_clear_attachment()
		_apply_attachment_state()
		return false
	_active_coupler_id = coupler_id
	_active_tool_id = tool_id
	_apply_attachment_state()
	return true


func _mount_state_consistent() -> bool:
	if _active_coupler_id == DIRECT_PIN_COUPLER_ID:
		return _mount_root == null
	return _mount_root != null and is_instance_valid(_mount_root)


func _mount_tiltrotator(coupler_id: String, coupler: Dictionary, tool_id: String, tool: Dictionary) -> bool:
	var descriptor := _descriptor(coupler_id, tool_id)
	var parent := _presentation.get_frame_node(String((coupler.get("mount", {}) as Dictionary).get("parent_frame", "bucket_link"))) if _presentation != null else null
	if parent == null:
		return _fail(descriptor, "mount_frame_unavailable")
	var rotator_path := String(coupler.get("rotator_glb_path", ""))
	if not _sha256_matches(rotator_path, String(coupler.get("rotator_glb_sha256", ""))):
		return _fail(descriptor, "rotator_glb_sha256_mismatch")
	var rotator_scene := load(rotator_path) as PackedScene
	if rotator_scene == null:
		return _fail(descriptor, "rotator_glb_unavailable")
	var instance := rotator_scene.instantiate() as Node3D
	if instance == null:
		return _fail(descriptor, "rotator_scene_not_3d")
	_mount_root = Node3D.new()
	_mount_root.name = "AttachmentMount"
	parent.add_child(_mount_root)
	_mount_root.transform = Transform3D.IDENTITY
	var rotator_root := _find_named(instance, String(coupler.get("rotator_root_node", "XTR13_ROOT")))
	if rotator_root == null:
		instance.free()
		return _fail(descriptor, "rotator_root_node_missing")
	rotator_root.owner = null
	if rotator_root != instance:
		instance.remove_child(rotator_root)
		_mount_root.add_child(rotator_root)
		instance.free()
	else:
		_mount_root.add_child(rotator_root)
	rotator_root.transform = Transform3D.IDENTITY
	var joints := coupler.get("joints", {}) as Dictionary
	_tilt_node = _find_path(rotator_root, String(joints.get("tilt_node_path", "")))
	_rotate_node = _find_path(rotator_root, String(joints.get("rotate_node_path", "")))
	if _tilt_node == null or _rotate_node == null:
		return _fail(descriptor, "joint_nodes_missing")
	_tilt_axis = _axis_from_name(String(joints.get("tilt_local_axis", "z")))
	_rotate_axis = _axis_from_name(String(joints.get("rotate_local_axis", "y")))
	var tilt_range := joints.get("tilt_range_deg", [-45.0, 45.0]) as Array
	_tilt_min_deg = float(tilt_range[0])
	_tilt_max_deg = float(tilt_range[1])
	_tilt_rate_dps = float(joints.get("tilt_rate_dps", 60.0))
	_rotate_rate_dps = float(joints.get("rotate_rate_dps", 90.0))
	_tilt_sign = float(joints.get("tilt_axis_sign", 1.0))
	_rotate_sign = float(joints.get("rotate_axis_sign", 1.0))
	if not _load_tilt_rig(coupler, descriptor, rotator_root):
		return false
	if not String(tool.get("tool_glb_path", "")).is_empty():
		if not _mount_tool(coupler, tool, descriptor, rotator_root):
			return false
	_hide_native_bucket(String(coupler.get("hidden_frame", "bucket_link")))
	_mark_owned(_mount_root)
	_tilt_deg = 0.0
	_rotate_deg = 0.0
	_apply_pose()
	return true


func _mount_tool(coupler: Dictionary, tool: Dictionary, descriptor: String, rotator_root: Node3D) -> bool:
	var socket := _find_path(rotator_root, String(coupler.get("socket_node_path", "")))
	if socket == null:
		return _fail(descriptor, "tool_socket_missing")
	var tool_path := String(tool.get("tool_glb_path", ""))
	if not _sha256_matches(tool_path, String(tool.get("tool_glb_sha256", ""))):
		return _fail(descriptor, "tool_glb_sha256_mismatch")
	var tool_scene := load(tool_path) as PackedScene
	if tool_scene == null:
		return _fail(descriptor, "tool_glb_unavailable")
	var instance := tool_scene.instantiate() as Node3D
	if instance == null:
		return _fail(descriptor, "tool_scene_not_3d")
	var tool_root := _find_named(instance, String(tool.get("tool_root_node", "GB12_ROOT")))
	if tool_root == null:
		instance.free()
		return _fail(descriptor, "tool_root_node_missing")
	tool_root.owner = null
	if tool_root != instance:
		instance.remove_child(tool_root)
		socket.add_child(tool_root)
		instance.free()
	else:
		socket.add_child(tool_root)
	tool_root.transform = Transform3D.IDENTITY
	_tool_node = tool_root
	return true


func _mark_owned(node: Node) -> void:
	_mount_owned[node] = true
	for child in node.get_children():
		_mark_owned(child)


func _load_tilt_rig(coupler: Dictionary, descriptor: String, rotator_root: Node3D) -> bool:
	_passive_nodes.clear()
	_weight_meshes.clear()
	_tilt_samples = []
	var rig_path := String(coupler.get("tilt_rig_path", ""))
	if rig_path.is_empty():
		return true
	if not _sha256_matches(rig_path, String(coupler.get("tilt_rig_sha256", ""))):
		return _fail(descriptor, "tilt_rig_sha256_mismatch")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(rig_path))
	if not parsed is Dictionary or String((parsed as Dictionary).get("schema_version", "")) != "steelwrist-tilt-rig-v1":
		return _fail(descriptor, "tilt_rig_invalid")
	var rig := parsed as Dictionary
	var expected_glb := String(rig.get("source_sha256", ""))
	if not expected_glb.is_empty() and expected_glb != String(coupler.get("rotator_glb_sha256", "")):
		return _fail(descriptor, "tilt_rig_glb_mismatch")
	_tilt_samples = rig.get("tilt_samples", [])
	if _tilt_samples.is_empty():
		return _fail(descriptor, "tilt_rig_empty")
	# The authored clip walks 0 -> +45 -> 0 -> -45 -> 0, so raw sample order is
	# not monotonic; the lookup table must be keyed by angle for _sample_table.
	_tilt_samples.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("angle_deg", 0.0)) < float(b.get("angle_deg", 0.0)))
	var first := _tilt_samples[0] as Dictionary
	for path_value in (first.get("nodes", {}) as Dictionary).keys():
		var node := _find_path(rotator_root, String(path_value))
		if node != null:
			_passive_nodes[String(path_value)] = node
	for path_value in (first.get("weights", {}) as Dictionary).keys():
		var node := _find_path(rotator_root, String(path_value)) as MeshInstance3D
		if node != null:
			_weight_meshes[String(path_value)] = node
	return true


func _hide_native_bucket(frame_name: String) -> void:
	_hidden_visuals.clear()
	if _presentation == null or frame_name.is_empty():
		return
	for visual in _presentation.get_frame_visual_nodes(frame_name):
		if visual.visible:
			visual.visible = false
			_hidden_visuals.append(visual)


## Foreign nodes reparented into the mount subtree (the bucket fill mesh binds
## to the soil cavity frame) must be parked on the rig before the mount is
## freed; they rebind through the next soil snapshot.
func _release_foreign_children() -> void:
	if _mount_root == null or not is_instance_valid(_mount_root):
		_mount_owned.clear()
		return
	var stack: Array[Node] = [_mount_root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			if not _mount_owned.has(child):
				child.reparent(self, false)
			else:
				stack.append(child)
	_mount_owned.clear()


func _clear_attachment() -> void:
	_release_foreign_children()
	if _mount_root != null and is_instance_valid(_mount_root):
		_mount_root.free()
	_mount_root = null
	_tool_node = null
	_tilt_node = null
	_rotate_node = null
	_passive_nodes.clear()
	_weight_meshes.clear()
	_tilt_samples = []
	for visual in _hidden_visuals:
		if is_instance_valid(visual):
			visual.visible = true
	_hidden_visuals.clear()
	_tilt_deg = 0.0
	_rotate_deg = 0.0
	_active_coupler_id = DIRECT_PIN_COUPLER_ID
	_active_tool_id = NATIVE_TOOL_ID


func _apply_attachment_state() -> void:
	var coupler := _couplers.get(_active_coupler_id, {}) as Dictionary
	var tool := _tools.get(_active_tool_id, {}) as Dictionary
	if _presentation != null:
		if _tool_node != null and not String(tool.get("soil_contract_path", "")).is_empty():
			var contract := _load_attachment_contract(tool)
			if not contract.is_empty():
				_presentation.set_attachment_context(_tool_node, contract, active_attachment_id())
			else:
				_presentation.set_attachment_context(_tool_node, {}, active_attachment_id())
		elif _mount_root != null or _active_tool_id != NATIVE_TOOL_ID:
			_presentation.set_attachment_context(null, {}, active_attachment_id())
		else:
			_presentation.clear_attachment_context()
	if _motion_client != null:
		var controls := coupler.get("controls", {}) as Dictionary
		if controls.is_empty():
			_motion_client.clear_attachment_profile()
		else:
			_motion_client.configure_attachment_profile(controls)
	attachment_activated.emit(active_attachment_id())


func _load_attachment_contract(tool: Dictionary) -> Dictionary:
	var path := String(tool.get("soil_contract_path", ""))
	if path.is_empty() or not _sha256_matches(path, String(tool.get("soil_contract_sha256", ""))):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		return {}
	var contract := (parsed as Dictionary).duplicate(true)
	var host_model := _presentation.get_active_model_id() if _presentation != null else ""
	if host_model.is_empty():
		return {}
	contract["model_id"] = host_model
	return contract


func _apply_pose() -> void:
	# The authored clips (and therefore the baked passive table) drive absolute
	# local joint rotations — frame zero is identity, not "rest plus delta" —
	# so the driven joints must be assigned the same absolute axis-angle pose
	# or the cylinders/pistons aim one rest-angle off the real bracket pose.
	# The joint quaternion and the passive lookup must agree on the effective
	# angle — applying _tilt_sign to only one of them mirrors the linkage.
	var tilt_eff := _tilt_deg * _tilt_sign
	if _tilt_node != null:
		_tilt_node.quaternion = Quaternion(_tilt_axis, deg_to_rad(tilt_eff))
	if _rotate_node != null:
		_rotate_node.quaternion = Quaternion(_rotate_axis, deg_to_rad(_rotate_deg * _rotate_sign))
	var sample := _sample_table(tilt_eff)
	if sample.is_empty():
		return
	for path_value in _passive_nodes:
		var node := _passive_nodes[path_value] as Node3D
		var state := (sample.get("nodes", {}) as Dictionary).get(path_value, {}) as Dictionary
		if state.is_empty() or not is_instance_valid(node):
			continue
		var quat := _quat_from_array(state.get("r", []))
		var offset := _vec3_from_array(state.get("t", []))
		node.quaternion = quat
		if state.has("t"):
			node.position = offset
	for path_value in _weight_meshes:
		var mesh_instance := _weight_meshes[path_value] as MeshInstance3D
		var weights := (sample.get("weights", {}) as Dictionary).get(path_value, []) as Array
		if not is_instance_valid(mesh_instance) or weights.is_empty():
			continue
		var count := mini(weights.size(), mesh_instance.get_blend_shape_count())
		for index in count:
			mesh_instance.set_blend_shape_value(index, float(weights[index]))


func _sample_table(tilt_deg: float) -> Dictionary:
	if _tilt_samples.is_empty():
		return {}
	var lo := _tilt_samples[0] as Dictionary
	var hi := _tilt_samples[_tilt_samples.size() - 1] as Dictionary
	if tilt_deg <= float(lo.get("angle_deg", 0.0)):
		return lo
	if tilt_deg >= float(hi.get("angle_deg", 0.0)):
		return hi
	var index := 1
	while index < _tilt_samples.size() - 1 and float((_tilt_samples[index] as Dictionary).get("angle_deg", 0.0)) < tilt_deg:
		index += 1
	lo = _tilt_samples[index - 1]
	hi = _tilt_samples[index]
	var a0 := float(lo.get("angle_deg", 0.0))
	var a1 := float(hi.get("angle_deg", 0.0))
	var f := 0.0 if is_equal_approx(a0, a1) else (tilt_deg - a0) / (a1 - a0)
	return _lerp_sample(lo, hi, f)


func _lerp_sample(a: Dictionary, b: Dictionary, f: float) -> Dictionary:
	var out := {"nodes": {}, "weights": {}}
	var a_nodes := a.get("nodes", {}) as Dictionary
	var b_nodes := b.get("nodes", {}) as Dictionary
	for path_value in a_nodes:
		var a_state := a_nodes[path_value] as Dictionary
		var b_state := b_nodes.get(path_value, {}) as Dictionary
		var merged := {}
		var qa := _quat_from_array(a_state.get("r", []))
		var qb := _quat_from_array(b_state.get("r", []))
		if a_state.has("r"):
			merged["r"] = qa.slerp(qb, f)
		if a_state.has("t") and b_state.has("t"):
			merged["t"] = _vec3_from_array(a_state["t"]).lerp(_vec3_from_array(b_state["t"]), f)
		out["nodes"][path_value] = merged
	var a_weights := a.get("weights", {}) as Dictionary
	var b_weights := b.get("weights", {}) as Dictionary
	for path_value in a_weights:
		var aw := a_weights[path_value] as Array
		var bw := b_weights.get(path_value, []) as Array
		var merged_weights: Array = []
		for index in mini(aw.size(), bw.size()):
			merged_weights.append(lerpf(float(aw[index]), float(bw[index]), f))
		out["weights"][path_value] = merged_weights
	return out


func _quat_from_array(value: Variant) -> Quaternion:
	if value is Quaternion:
		return value
	if value is Array and (value as Array).size() == 4:
		return Quaternion(float(value[0]), float(value[1]), float(value[2]), float(value[3]))
	return Quaternion.IDENTITY


func _vec3_from_array(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	if value is Array and (value as Array).size() == 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ZERO


func _axis_from_name(name: String) -> Vector3:
	# Local axis names mean the positive axis: the baked table keys angles to
	# the quaternion's +z/+y component sign, so "z" must be Vector3.BACK —
	# using FORWARD (-z) mirrors the joint against the passive samples.
	match name.to_lower():
		"x": return Vector3.RIGHT
		"y": return Vector3.UP
		_: return Vector3.BACK


func _sha256_matches(path: String, expected: String) -> bool:
	if path.is_empty() or expected.is_empty() or not FileAccess.file_exists(path):
		return false
	return FileAccess.get_sha256(path) == expected


func _find_named(root: Node, target: String) -> Node3D:
	var queue: Array[Node] = [root]
	var sanitized := _sanitize_name(target)
	while not queue.is_empty():
		var node: Node = queue.pop_front()
		if node is Node3D and (node.name == target or node.name == sanitized):
			return node as Node3D
		queue.append_array(node.get_children())
	return null


func _find_path(rotator_root: Node3D, catalog_path: String) -> Node3D:
	if rotator_root == null or catalog_path.is_empty():
		return null
	var segments := catalog_path.split("/", false)
	if segments.size() > 0 and segments[0] == rotator_root.name:
		segments = segments.slice(1)
	var node: Node = rotator_root
	for segment in segments:
		var next := _find_named_direct(node, String(segment))
		if next == null:
			return null
		node = next
	return node as Node3D


func _find_named_direct(parent: Node, segment: String) -> Node:
	var sanitized := _sanitize_name(segment)
	for child in parent.get_children():
		if child.name == segment or child.name == sanitized:
			return child
	return null


func _sanitize_name(name: String) -> String:
	# Match Godot's node-name validation used on glTF import: characters such
	# as ".", ":", "/", "@", "\", "%" are replaced by "_" (not stripped), so
	# "piston.001" resolves against the imported "piston_001".
	return name.validate_node_name()


func _on_model_replacing() -> void:
	if _mount_root != null or _active_tool_id != NATIVE_TOOL_ID:
		_remount_pending = true
		_remount_coupler_id = _active_coupler_id
		_remount_tool_id = _active_tool_id
		_clear_attachment()
		if _presentation != null:
			_presentation.clear_attachment_context()


func _on_model_activated(_model_id: String, _asset_root: Node3D) -> void:
	if not _remount_pending:
		return
	_remount_pending = false
	if not _remount_coupler_id.is_empty() and not _remount_tool_id.is_empty():
		_apply_combination(_remount_coupler_id, _remount_tool_id)
	_remount_coupler_id = ""
	_remount_tool_id = ""

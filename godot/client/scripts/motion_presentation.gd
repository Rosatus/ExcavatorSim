class_name MotionPresentation
extends Node3D

## Applies named-frame transforms to the selected imported visual skin. Python
## poses arrive already converted by MotionProtocol. In jolt_authoritative the
## same post-step physics snapshot drives both the visual pivots and truth output.

const MODEL_CATALOG_PATH := "res://resources/models/model_catalog.json"
const RIGID_BASIS_TOLERANCE := 0.001
const JOINT_ORIGIN_TOLERANCE_M := 0.002
const JOINT_AXIS_RESIDUAL_TOLERANCE := 0.001

@export var motion_client_path := NodePath("../MotionClient")
@export var presentation_root_path := NodePath("../PresentationRoot")
@export_enum("python_kinematic", "jolt_shadow", "jolt_authoritative") var authority_profile := AuthorityProfile.PYTHON_KINEMATIC
@export var use_project_authority_profile := true

var _motion_client: MotionClient
var _presentation_root: Node3D
var _asset_root: Node3D
var _manifest: Dictionary = {}
var _active_model_id := ""
var _manifest_path := ""
var _parity_fixture_path := ""
var _soil_contract_path := ""
var _soil_contract: Dictionary = {}
var _frame_nodes: Dictionary = {}
var _authority_zero_globals: Dictionary = {}
var _physics_rest_globals: Dictionary = {}
var _frame_parent_names: Dictionary = {}
var _frame_runtime_axes: Dictionary = {}
var _rest_locals: Dictionary = {}
var _rest_globals: Dictionary = {}
var _rest_presentation_locals: Dictionary = {}
var _pivot_reasons: Dictionary = {}
var _pivot_last_warning_reasons: Dictionary = {}
var _has_pose := false
var _last_render_revision := -1
var _contract_error := ""
var _previous_bucket_proxies: Dictionary = {}
var _previous_bucket_identity := ""
var _soil_debug_root: Node3D

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
signal model_activated(model_id: String, asset_root: Node3D)


func _ready() -> void:
	if use_project_authority_profile:
		authority_profile = String(ProjectSettings.get_setting("simulation/authority_profile", authority_profile))
	_motion_client = get_node_or_null(motion_client_path) as MotionClient
	_presentation_root = get_node_or_null(presentation_root_path) as Node3D
	if _motion_client == null or _presentation_root == null:
		_contract_error = "MotionPresentation requires MotionClient and PresentationRoot"
		push_warning(_contract_error)
		return
	_motion_client.model_changed.connect(_on_model_changed)
	if not _activate_model(_motion_client.get_desired_model_id()):
		return
	_motion_client.pose_accepted.connect(_on_pose_accepted)
	_motion_client.pose_cleared.connect(_on_pose_cleared)
	_restore_rest_pose()


func _process(_delta: float) -> void:
	if AuthorityProfile.writes_product_pose(authority_profile) or _motion_client == null or not _has_pose:
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


func get_active_model_id() -> String:
	return _active_model_id


func get_soil_contract() -> Dictionary:
	return _soil_contract.duplicate(true)


func sample_bucket_pose_fixed(world_generation: int, authority_generation: int) -> Dictionary:
	if not _has_pose or _soil_contract.is_empty():
		return {"valid": false, "reason": "pose_unavailable"}
	if not AuthorityProfile.writes_product_pose(authority_profile):
		if _motion_client == null:
			return {"valid": false, "reason": "motion_client_unavailable"}
		var accepted_pose := _motion_client.get_latest_accepted_pose()
		if not accepted_pose.is_empty():
			_apply_render_pose(accepted_pose)
	var current := {}
	for proxy_name in ["cutting_edge", "top_edge", "opening", "cavity", "shell", "rear_support"]:
		var proxy_transform: Variant = _soil_proxy_transform(proxy_name)
		if not proxy_transform is Transform3D:
			clear_bucket_pose_history()
			return {"valid": false, "reason": "proxy_unavailable", "proxy": proxy_name}
		current[proxy_name] = proxy_transform
	var status := _motion_client.get_status_snapshot() if _motion_client != null else {}
	var session_id := String(status.get("session_id", ""))
	var simulation_epoch := String(status.get("simulation_epoch", ""))
	var model_id := _active_model_id
	var identity := "%s|%s|%s|%d|%d" % [model_id, session_id, simulation_epoch, world_generation, authority_generation]
	var reason := "ok"
	var valid := not _previous_bucket_proxies.is_empty() and identity == _previous_bucket_identity
	if not valid:
		reason = "history_unavailable"
	else:
		var previous_cutting: Transform3D = _previous_bucket_proxies["cutting_edge"]
		var current_cutting: Transform3D = current["cutting_edge"]
		if previous_cutting.origin.distance_to(current_cutting.origin) > 2.0:
			valid = false
			reason = "discontinuous_pose"
	var proxies := _soil_contract.get("proxies", {}) as Dictionary
	var cutting_contract := proxies.get("cutting_edge", {}) as Dictionary
	var opening_contract := proxies.get("opening", {}) as Dictionary
	var cutting_direction_world := (current["cutting_edge"] as Transform3D).basis * _vector3_from_array(cutting_contract.get("direction_godot", []))
	var opening_normal_world := (current["opening"] as Transform3D).basis * _vector3_from_array(opening_contract.get("normal_godot", []))
	var snapshot := {
		"valid": valid,
		"reason": reason,
		"model_id": model_id,
		"session_id": session_id,
		"simulation_epoch": simulation_epoch,
		"world_generation": world_generation,
		"authority_generation": authority_generation,
		"identity": identity,
		"previous": _previous_bucket_proxies.duplicate(true),
		"current": current.duplicate(true),
		"cutting_direction_world": cutting_direction_world.normalized(),
		"opening_normal_world": opening_normal_world.normalized(),
		"contract": _soil_contract.duplicate(true),
	}
	_previous_bucket_proxies = current.duplicate(true)
	_previous_bucket_identity = identity
	_update_soil_debug_proxies(current)
	return snapshot


func clear_bucket_pose_history() -> void:
	_previous_bucket_proxies.clear()
	_previous_bucket_identity = ""


func set_soil_debug_visible(value: bool) -> void:
	_ensure_soil_debug_root()
	_soil_debug_root.visible = value
	if value and not _previous_bucket_proxies.is_empty():
		_update_soil_debug_proxies(_previous_bucket_proxies)


func get_bucket_contact_world() -> Variant:
	var contact: Dictionary = _manifest.get("excavation_contact", {})
	var mode := String(contact.get("mode", ""))
	if mode == "node":
		var path := String(contact.get("node_path", ""))
		var node: Node3D = null
		if _asset_root != null:
			node = _asset_root.get_node_or_null(NodePath(path)) as Node3D
		if node != null:
			return node.global_position
		return null
	if mode == "frame_offset":
		var frame := get_frame_node(String(contact.get("frame", "bucket_link")))
		var raw_offset: Variant = contact.get("offset_godot", [0.0, 0.0, 0.0])
		if frame != null and raw_offset is Array and (raw_offset as Array).size() == 3:
			return frame.global_transform * Vector3(float(raw_offset[0]), float(raw_offset[1]), float(raw_offset[2]))
	return null


func get_pivot_diagnostics_for_test() -> Dictionary:
	return _pivot_reasons.duplicate(true)


func apply_pose_for_test(pose: Dictionary) -> bool:
	if AuthorityProfile.writes_product_pose(authority_profile):
		return false
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
	_has_pose = true
	return true


func restore_rest_pose_for_test() -> void:
	_restore_rest_pose()


func set_authority_profile_for_test(profile: String) -> bool:
	if not AuthorityProfile.is_valid(profile):
		return false
	authority_profile = profile
	if AuthorityProfile.writes_product_pose(authority_profile):
		_has_pose = false
		_last_render_revision = -1
		clear_bucket_pose_history()
		_restore_rest_pose()
	return true


func activate_model_for_test(model_id: String) -> bool:
	return _activate_model(model_id)


func _activate_model(model_id: String) -> bool:
	var catalog := _read_json(MODEL_CATALOG_PATH)
	var entries: Array = catalog.get("models", [])
	var entry: Dictionary = {}
	for candidate in entries:
		if candidate is Dictionary and String(candidate.get("model_id", "")) == model_id:
			entry = candidate
			break
	if entry.is_empty():
		_contract_error = "unknown_model: %s" % model_id
		push_error(_contract_error)
		return false
	var glb_path := String(entry.get("glb_path", ""))
	_manifest_path = String(entry.get("manifest_path", ""))
	_parity_fixture_path = String(entry.get("parity_fixture_path", ""))
	_soil_contract_path = String(entry.get("soil_contract_path", ""))
	if glb_path.is_empty() or _manifest_path.is_empty() or _parity_fixture_path.is_empty() or _soil_contract_path.is_empty():
		_contract_error = "model_contract_mismatch: incomplete catalog entry for %s" % model_id
		push_error(_contract_error)
		return false
	var previous := _asset_root
	var candidate_root: Node3D = null
	var candidate_is_new := false
	if model_id == "sy205":
		candidate_root = _presentation_root.get_node_or_null("SY205Excavator") as Node3D
	if candidate_root == null:
		var packed := load(glb_path) as PackedScene
		if packed == null:
			_contract_error = "model_unavailable: %s" % glb_path
			push_error(_contract_error)
			return false
		candidate_root = packed.instantiate() as Node3D
		if candidate_root == null:
			_contract_error = "model_contract_mismatch: %s is not a Node3D scene" % model_id
			return false
		candidate_root.name = "ActiveExcavator"
		_presentation_root.add_child(candidate_root)
		candidate_root.owner = _presentation_root.owner
		candidate_is_new = true
	_asset_root = candidate_root
	_asset_root.visible = true
	_clear_contract_state()
	if not _load_mapping_contract(model_id):
		_asset_root.visible = false
		# A failed candidate must not leave the old model visible as an implicit
		# cross-model fallback.  Keep the presentation owner empty until a
		# matching contract can be activated.
		if previous != null:
			previous.visible = false
		if candidate_is_new and is_instance_valid(_asset_root):
			_asset_root.queue_free()
		_asset_root = null
		_frame_nodes.clear()
		_has_pose = false
		return false
	if previous != null and previous != _asset_root:
		previous.visible = false
		if previous.name == "ActiveExcavator":
			previous.queue_free()
	_active_model_id = model_id
	_restore_rest_pose()
	model_activated.emit(model_id, _asset_root)
	return true


func _clear_contract_state() -> void:
	_frame_nodes.clear()
	_authority_zero_globals.clear()
	_physics_rest_globals.clear()
	_frame_parent_names.clear()
	_frame_runtime_axes.clear()
	_rest_locals.clear()
	_rest_globals.clear()
	_rest_presentation_locals.clear()
	_soil_contract.clear()
	clear_bucket_pose_history()
	_pivot_reasons.clear()
	_pivot_last_warning_reasons.clear()
	_linkage_initialized = false
	_linkage_reachable = false
	_linkage_reason = "uninitialized"
	_contract_error = ""


func _on_model_changed(model_id: String) -> void:
	if model_id != _active_model_id:
		_activate_model(model_id)


func _load_mapping_contract(model_id: String) -> bool:
	var manifest := _read_json(_manifest_path)
	var fixture := _read_json(_parity_fixture_path)
	_manifest = manifest
	if manifest.is_empty() or fixture.is_empty():
		_contract_error = "%s mapping or parity fixture could not be loaded" % model_id
		push_error(_contract_error)
		return false
	var frame_map: Dictionary = manifest.get("frame_map", {})
	var local_kinematics: Dictionary = manifest.get("local_kinematics", {})
	if local_kinematics.get("mode", "") != "adjacent_frame_local_rotation_delta":
		_contract_error = "%s local kinematics mode is missing or unsupported" % model_id
		push_error(_contract_error)
		return false
	if local_kinematics.get("base_frame", "") != "base_link":
		_contract_error = "%s local kinematics must use base_link as the whole-machine base" % model_id
		push_error(_contract_error)
		return false
	var frame_contracts: Dictionary = local_kinematics.get("frame_contracts", {})
	var zero_pose: Dictionary = fixture.get("poses", {}).get("zero", {})
	var zero_frames: Dictionary = zero_pose.get("frame_transforms", {})
	var physics_descriptor := PhysicsRigDescriptor.load_for_model(model_id)
	if physics_descriptor == null or not physics_descriptor.is_valid_for(model_id, physics_descriptor.model_version()):
		_contract_error = "%s physics rest contract is unavailable" % model_id
		push_error(_contract_error)
		return false
	for body_value in physics_descriptor.bodies():
		var body := body_value as Dictionary
		_physics_rest_globals[String(body["frame"])] = _rows_to_transform(body["rest_transform_godot"])
	for frame_name in MotionProtocol.FRAME_NAMES:
		var mapping: Dictionary = frame_map.get(frame_name, {})
		var frame_contract: Dictionary = frame_contracts.get(frame_name, {})
		var node_path := String(mapping.get("node_path", ""))
		var frame_node := _asset_root.get_node_or_null(NodePath(node_path)) as Node3D
		if frame_node == null or not zero_frames.has(frame_name):
			_contract_error = "%s mapping is missing %s" % [model_id, frame_name]
			push_error(_contract_error)
			return false
		_frame_nodes[frame_name] = frame_node
		_rest_locals[frame_name] = frame_node.transform
		_rest_globals[frame_name] = frame_node.global_transform
		_rest_presentation_locals[frame_name] = _presentation_root.global_transform.affine_inverse() * frame_node.global_transform
		_authority_zero_globals[frame_name] = MotionProtocol.rows_to_transform(zero_frames[frame_name])
		var parent_frame := String(frame_contract.get("parent_frame", ""))
		var runtime_axis := String(frame_contract.get("runtime_axis", ""))
		var expected_position: Variant = frame_contract.get("parent_local_position", [])
		var expected_scale: Variant = frame_contract.get("scale", [])
		if (
			not expected_position is Array
			or (expected_position as Array).size() != 3
			or not expected_scale is Array
			or (expected_scale as Array).size() != 3
		):
			_contract_error = "%s local pivot contract is missing position/scale for %s" % [model_id, frame_name]
			push_error(_contract_error)
			return false
		var expected_position_vector := Vector3(
			float((expected_position as Array)[0]),
			float((expected_position as Array)[1]),
			float((expected_position as Array)[2])
		)
		var expected_scale_vector := Vector3(
			float((expected_scale as Array)[0]),
			float((expected_scale as Array)[1]),
			float((expected_scale as Array)[2])
		)
		if frame_node.position.distance_to(expected_position_vector) > JOINT_ORIGIN_TOLERANCE_M:
			_contract_error = "%s imported local pivot origin drifted for %s" % [model_id, frame_name]
			push_error(_contract_error)
			return false
		if not frame_node.scale.is_equal_approx(expected_scale_vector):
			_contract_error = "%s imported local pivot scale drifted for %s" % [model_id, frame_name]
			push_error(_contract_error)
			return false
		if frame_name == "base_link":
			if not parent_frame.is_empty() or runtime_axis != "none":
				_contract_error = "%s base_link must be a whole-machine base, not a slew joint" % model_id
				push_error(_contract_error)
				return false
		else:
			if not _frame_nodes.has(parent_frame) or not ["X", "Y"].has(runtime_axis):
				_contract_error = "%s local kinematics contract is invalid for %s" % [model_id, frame_name]
				push_error(_contract_error)
				return false
			if frame_node.get_parent() != _frame_nodes.get(parent_frame):
				_contract_error = "%s imported pivot parent drifted for %s" % [model_id, frame_name]
				push_error(_contract_error)
				return false
		_frame_parent_names[frame_name] = parent_frame
		_frame_runtime_axes[frame_name] = runtime_axis
	var passive_linkage: Dictionary = manifest.get("passive_linkage", {})
	if not _load_passive_linkage_contract(passive_linkage, model_id):
		return false
	return _load_soil_contract(model_id)


func _on_pose_accepted(_pose: Dictionary) -> void:
	if AuthorityProfile.writes_product_pose(authority_profile):
		return
	_has_pose = true
	_last_render_revision = -1
	_apply_render_pose(_motion_client.get_render_pose())


func _on_pose_cleared(_generation: int, _reason: String) -> void:
	_has_pose = false
	_last_render_revision = -1
	clear_bucket_pose_history()
	_restore_rest_pose()


func _load_soil_contract(model_id: String) -> bool:
	var contract := _read_json(_soil_contract_path)
	if contract.get("schema_version", "") != "excavator-soil-contract-v1" or contract.get("model_id", "") != model_id:
		_contract_error = "%s soil contract identity is invalid" % model_id
		push_error(_contract_error)
		return false
	for scalar_name in ["material_density_kg_m3", "nominal_capacity_m3", "heaped_capacity_m3"]:
		var scalar := float(contract.get(scalar_name, 0.0))
		if scalar <= 0.0 or is_nan(scalar) or is_inf(scalar):
			_contract_error = "%s soil contract has invalid %s" % [model_id, scalar_name]
			push_error(_contract_error)
			return false
	if float(contract["heaped_capacity_m3"]) < float(contract["nominal_capacity_m3"]):
		_contract_error = "%s heaped capacity is below nominal capacity" % model_id
		push_error(_contract_error)
		return false
	var grid: Variant = contract.get("cell_grid", [])
	if not grid is Array or (grid as Array).size() != 3:
		_contract_error = "%s soil cell grid is invalid" % model_id
		push_error(_contract_error)
		return false
	var proxies: Dictionary = contract.get("proxies", {})
	for proxy_name in ["cutting_edge", "top_edge", "opening", "cavity", "shell", "rear_support"]:
		var proxy: Dictionary = proxies.get(proxy_name, {})
		var frame_name := String(proxy.get("frame", ""))
		if not _frame_nodes.has(frame_name) or not _valid_vector3_array(proxy.get("center_godot", [])):
			_contract_error = "%s soil proxy is invalid: %s" % [model_id, proxy_name]
			push_error(_contract_error)
			return false
	if not _valid_vector3_array((proxies["cutting_edge"] as Dictionary).get("direction_godot", [])):
		_contract_error = "%s cutting direction is invalid" % model_id
		return false
	if not _valid_vector3_array((proxies["opening"] as Dictionary).get("normal_godot", [])):
		_contract_error = "%s opening normal is invalid" % model_id
		return false
	for oriented_proxy_name in ["opening", "cavity", "shell"]:
		var oriented_proxy := proxies[oriented_proxy_name] as Dictionary
		if not _valid_direction_array(oriented_proxy.get("up_godot", [])):
			_contract_error = "%s %s orientation is invalid" % [model_id, oriented_proxy_name]
			return false
	for edge_name in ["cutting_edge", "top_edge"]:
		if float((proxies[edge_name] as Dictionary).get("half_width_m", 0.0)) <= 0.0:
			_contract_error = "%s %s width is invalid" % [model_id, edge_name]
			return false
	var opening_size: Variant = (proxies["opening"] as Dictionary).get("size_m", [])
	if not _valid_positive_array(opening_size, 2):
		_contract_error = "%s opening size is invalid" % model_id
		return false
	if not _valid_positive_array((proxies["cavity"] as Dictionary).get("size_m", []), 3):
		_contract_error = "%s cavity size is invalid" % model_id
		return false
	if not _valid_positive_array((proxies["shell"] as Dictionary).get("size_m", []), 3):
		_contract_error = "%s shell size is invalid" % model_id
		return false
	if float((proxies["rear_support"] as Dictionary).get("radius_m", 0.0)) <= 0.0:
		_contract_error = "%s rear support radius is invalid" % model_id
		return false
	var interaction := contract.get("interaction", {}) as Dictionary
	var spill_threshold := float(interaction.get("spill_opening_down_dot", -2.0))
	var dump_threshold := float(interaction.get("dump_opening_down_dot", -2.0))
	if spill_threshold < -1.0 or dump_threshold > 1.0 or spill_threshold >= dump_threshold:
		_contract_error = "%s spill/dump thresholds are invalid" % model_id
		return false
	_soil_contract = contract
	return true


func _soil_proxy_transform(proxy_name: String) -> Variant:
	var proxies: Dictionary = _soil_contract.get("proxies", {})
	var proxy: Dictionary = proxies.get(proxy_name, {})
	var frame := get_frame_node(String(proxy.get("frame", "")))
	if frame == null:
		return null
	var center := _vector3_from_array(proxy.get("center_godot", []))
	var local_basis := Basis.IDENTITY
	if proxy.has("up_godot"):
		var local_up := _vector3_from_array(proxy.get("up_godot", [])).normalized()
		var local_width := Vector3.RIGHT
		var local_depth := local_width.cross(local_up).normalized()
		local_basis = Basis(local_width, local_up, local_depth).orthonormalized()
	return frame.global_transform * Transform3D(local_basis, center)


func _valid_vector3_array(value: Variant) -> bool:
	if not value is Array or (value as Array).size() != 3:
		return false
	for component in value:
		var number := float(component)
		if is_nan(number) or is_inf(number):
			return false
	return true


func _valid_positive_array(value: Variant, expected_size: int) -> bool:
	if not value is Array or (value as Array).size() != expected_size:
		return false
	for component in value:
		var number := float(component)
		if number <= 0.0 or is_nan(number) or is_inf(number):
			return false
	return true


func _valid_direction_array(value: Variant) -> bool:
	return _valid_vector3_array(value) and not _vector3_from_array(value).is_zero_approx()


func _vector3_from_array(value: Variant) -> Vector3:
	if not _valid_vector3_array(value):
		return Vector3.ZERO
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


func _ensure_soil_debug_root() -> void:
	if _soil_debug_root != null:
		return
	_soil_debug_root = Node3D.new()
	_soil_debug_root.name = "SoilProxyDebug"
	_soil_debug_root.visible = false
	add_child(_soil_debug_root)
	var colors := {
		"cutting_edge": Color(1.0, 0.2, 0.1, 0.7),
		"top_edge": Color(1.0, 0.75, 0.1, 0.55),
		"opening": Color(0.1, 0.8, 1.0, 0.45),
		"cavity": Color(0.15, 1.0, 0.35, 0.28),
		"shell": Color(0.95, 0.45, 0.1, 0.4),
		"rear_support": Color(0.85, 0.2, 1.0, 0.5),
	}
	for proxy_name in ["cutting_edge", "top_edge", "opening", "cavity", "shell", "rear_support"]:
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.name = proxy_name
		var proxy_mesh: PrimitiveMesh
		if proxy_name == "rear_support":
			proxy_mesh = SphereMesh.new()
		else:
			proxy_mesh = BoxMesh.new()
		var material := StandardMaterial3D.new()
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = colors[proxy_name]
		proxy_mesh.material = material
		mesh_instance.mesh = proxy_mesh
		_soil_debug_root.add_child(mesh_instance)


func _update_soil_debug_proxies(current: Dictionary) -> void:
	if _soil_debug_root == null or not _soil_debug_root.visible:
		return
	var proxies: Dictionary = _soil_contract.get("proxies", {})
	for proxy_name in ["cutting_edge", "top_edge", "opening", "cavity", "shell", "rear_support"]:
		var mesh_instance := _soil_debug_root.get_node_or_null(NodePath(proxy_name)) as MeshInstance3D
		if mesh_instance == null or not current.has(proxy_name):
			continue
		mesh_instance.global_transform = current[proxy_name]
		var proxy: Dictionary = proxies.get(proxy_name, {})
		if proxy_name == "rear_support":
			var diameter := 2.0 * float(proxy.get("radius_m", 0.1))
			(mesh_instance.mesh as SphereMesh).radius = 0.5
			(mesh_instance.mesh as SphereMesh).height = 1.0
			mesh_instance.scale = Vector3.ONE * diameter
		elif proxy_name == "cavity" or proxy_name == "shell":
			var cavity_size := _vector3_from_array(proxy.get("size_m", []))
			(mesh_instance.mesh as BoxMesh).size = cavity_size
			mesh_instance.scale = Vector3.ONE
		elif proxy_name == "opening":
			var opening_size: Array = proxy.get("size_m", [0.5, 0.5])
			(mesh_instance.mesh as BoxMesh).size = Vector3(float(opening_size[0]), 0.025, float(opening_size[1]))
			mesh_instance.scale = Vector3.ONE
		else:
			var width := 2.0 * float(proxy.get("half_width_m", 0.25))
			(mesh_instance.mesh as BoxMesh).size = Vector3(width, 0.035, 0.035)
			mesh_instance.scale = Vector3.ONE


func _apply_render_pose(pose: Dictionary) -> void:
	if AuthorityProfile.writes_product_pose(authority_profile):
		return
	var transforms: Dictionary = pose.get("transforms", {})
	_apply_base_transform(transforms)
	for frame_index in range(1, MotionProtocol.FRAME_NAMES.size()):
		_apply_local_joint_transform(MotionProtocol.FRAME_NAMES[frame_index], transforms)
	_apply_passive_linkage()


func apply_physics_snapshot(snapshot: Dictionary) -> bool:
	if not AuthorityProfile.writes_product_pose(authority_profile) or _asset_root == null:
		return false
	var body_values: Variant = snapshot.get("bodies", [])
	var frame_values: Variant = snapshot.get("kinematic_frames", [])
	if (
		not body_values is Array or (body_values as Array).size() != 1
		or not frame_values is Array or (frame_values as Array).size() != MotionProtocol.FRAME_NAMES.size() - 1
	):
		return false
	var transforms := {}
	for body_value in body_values as Array:
		if not body_value is Dictionary:
			return false
		var body := body_value as Dictionary
		var frame_name := "base_link" if String(body.get("name", "")) == "chassis" else ""
		var transform_value: Variant = body.get("transform")
		if frame_name.is_empty() or transforms.has(frame_name) or not transform_value is Transform3D:
			return false
		if not _is_rigid_transform(transform_value as Transform3D):
			return false
		transforms[frame_name] = transform_value
	for frame_value in frame_values as Array:
		if not frame_value is Dictionary:
			return false
		var frame := frame_value as Dictionary
		var frame_name := String(frame.get("name", ""))
		var transform_value: Variant = frame.get("transform")
		if (
			not MotionProtocol.FRAME_NAMES.has(frame_name) or frame_name == "base_link"
			or transforms.has(frame_name) or not transform_value is Transform3D
			or not _is_rigid_transform(transform_value as Transform3D)
		):
			return false
		transforms[frame_name] = transform_value
	if transforms.size() != MotionProtocol.FRAME_NAMES.size():
		return false
	var base_node := _frame_nodes.get("base_link") as Node3D
	var base_rest: Variant = _rest_locals.get("base_link")
	if base_node == null or not base_rest is Transform3D:
		return false
	base_node.transform = base_rest as Transform3D
	_pivot_reasons.erase("base_link")
	for frame_index in range(1, MotionProtocol.FRAME_NAMES.size()):
		_apply_physics_joint_transform(MotionProtocol.FRAME_NAMES[frame_index], transforms)
	if not _pivot_reasons.is_empty():
		return false
	_apply_passive_linkage()
	_has_pose = true
	_last_render_revision = int(snapshot.get("physics_tick", _last_render_revision + 1))
	return true


func _apply_physics_joint_transform(frame_name: String, transforms: Dictionary) -> void:
	var frame_node := _frame_nodes.get(frame_name) as Node3D
	var parent_name := String(_frame_parent_names.get(frame_name, ""))
	if _pivot_reasons.has(parent_name):
		_pivot_mark_invalid(frame_name, "parent_invalid")
		return
	var parent_current: Variant = transforms.get(parent_name)
	var child_current: Variant = transforms.get(frame_name)
	var parent_rest: Variant = _physics_rest_globals.get(parent_name)
	var child_rest: Variant = _physics_rest_globals.get(frame_name)
	var visual_rest: Variant = _rest_locals.get(frame_name)
	if (
		frame_node == null or not parent_current is Transform3D or not child_current is Transform3D
		or not parent_rest is Transform3D or not child_rest is Transform3D
		or not visual_rest is Transform3D
	):
		_pivot_mark_invalid(frame_name, "missing_physics_transform")
		return
	for candidate in [parent_current, child_current, parent_rest, child_rest]:
		if not _is_rigid_transform(candidate as Transform3D):
			_pivot_mark_invalid(frame_name, "non_rigid_physics_transform")
			return
	var rest_relation := (parent_rest as Transform3D).affine_inverse() * (child_rest as Transform3D)
	var current_relation := (parent_current as Transform3D).affine_inverse() * (child_current as Transform3D)
	var delta_basis := rest_relation.basis.inverse() * current_relation.basis
	var runtime_axis := String(_frame_runtime_axes.get(frame_name, ""))
	var angle := _twist_angle(delta_basis, _axis_vector(runtime_axis))
	var clean_delta := Basis(_axis_vector(runtime_axis), angle)
	var target_local := visual_rest as Transform3D
	target_local.basis = target_local.basis * clean_delta
	if not _finite_transform(target_local):
		_pivot_mark_invalid(frame_name, "non_finite_physics_transform")
		return
	frame_node.transform = target_local
	_pivot_mark_valid(frame_name)


func _rows_to_transform(value: Variant) -> Transform3D:
	var rows := value as Array
	return Transform3D(
		Basis(
			Vector3(float(rows[0][0]), float(rows[1][0]), float(rows[2][0])),
			Vector3(float(rows[0][1]), float(rows[1][1]), float(rows[2][1])),
			Vector3(float(rows[0][2]), float(rows[1][2]), float(rows[2][2])),
		),
		Vector3(float(rows[0][3]), float(rows[1][3]), float(rows[2][3])),
	)


func _restore_rest_pose() -> void:
	for frame_name in MotionProtocol.FRAME_NAMES:
		var frame_node := _frame_nodes.get(frame_name) as Node3D
		var rest_local: Variant = _rest_locals.get(frame_name)
		if frame_node != null and rest_local is Transform3D:
			frame_node.transform = rest_local as Transform3D
	_pivot_reasons.clear()
	_pivot_last_warning_reasons.clear()
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


func _load_passive_linkage_contract(passive_linkage: Dictionary, model_id: String) -> bool:
	if passive_linkage.get("mode", "") == "none":
		_linkage_initialized = false
		_linkage_reachable = true
		_linkage_reason = "not_applicable"
		return true
	if passive_linkage.get("mode", "") != "godot_visual_four_bar":
		_contract_error = "%s passive linkage mode is missing or unsupported" % model_id
		push_error(_contract_error)
		return false
	if passive_linkage.get("solver_plane", "") != "arm_link_local_yz":
		_contract_error = "SY205 passive linkage must solve in arm-local Y-Z"
		push_error(_contract_error)
		return false
	var paths: Dictionary = passive_linkage.get("pin_paths_relative_to_arm", {})
	_linkage_arm = _frame_nodes.get("arm_link") as Node3D
	if _linkage_arm == null:
		_contract_error = "SY205 passive linkage arm pivot is missing"
		push_error(_contract_error)
		return false
	_linkage_bucket = _linkage_arm.get_node_or_null(NodePath("PIVOT_BUCKET_JOINT")) as Node3D
	_linkage_b_pin = _linkage_arm.get_node_or_null(NodePath(paths.get("B", ""))) as Node3D
	_linkage_a_pin = _linkage_arm.get_node_or_null(NodePath(paths.get("A", ""))) as Node3D
	_linkage_c_pin = _linkage_arm.get_node_or_null(NodePath(paths.get("C", ""))) as Node3D
	_linkage_d_pin = _linkage_arm.get_node_or_null(NodePath(paths.get("D", ""))) as Node3D
	_linkage_side_controller = _linkage_arm.get_node_or_null(NodePath(paths.get("side_controller", ""))) as Node3D
	if (
		_linkage_bucket == null
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


func _apply_base_transform(transforms: Dictionary) -> void:
	var frame_name := "base_link"
	var frame_node := _frame_nodes.get(frame_name) as Node3D
	var incoming: Variant = transforms.get(frame_name)
	var authority_zero: Variant = _authority_zero_globals.get(frame_name)
	var rest_presentation_local: Variant = _rest_presentation_locals.get(frame_name)
	if (
		frame_node == null
		or not incoming is Transform3D
		or not authority_zero is Transform3D
		or not rest_presentation_local is Transform3D
	):
		_pivot_mark_invalid(frame_name, "missing_transform")
		return
	var current := incoming as Transform3D
	var zero := authority_zero as Transform3D
	if not _is_rigid_transform(current) or not _is_rigid_transform(zero):
		_pivot_mark_invalid(frame_name, "non_rigid_transform")
		return
	var current_rigid := Transform3D(current.basis.orthonormalized(), current.origin)
	var zero_rigid := Transform3D(zero.basis.orthonormalized(), zero.origin)
	var base_delta := current_rigid * zero_rigid.affine_inverse()
	var target_global := _presentation_root.global_transform * base_delta * (rest_presentation_local as Transform3D)
	if not _finite_transform(target_global):
		_pivot_mark_invalid(frame_name, "non_finite_base_delta")
		return
	frame_node.global_transform = target_global
	_pivot_mark_valid(frame_name)


func _apply_local_joint_transform(frame_name: String, transforms: Dictionary) -> void:
	var frame_node := _frame_nodes.get(frame_name) as Node3D
	var parent_name := String(_frame_parent_names.get(frame_name, ""))
	if _pivot_reasons.has(parent_name):
		_pivot_mark_invalid(frame_name, "parent_invalid")
		return
	var parent_current: Variant = transforms.get(parent_name)
	var child_current: Variant = transforms.get(frame_name)
	var parent_zero: Variant = _authority_zero_globals.get(parent_name)
	var child_zero: Variant = _authority_zero_globals.get(frame_name)
	var rest_local: Variant = _rest_locals.get(frame_name)
	if (
		frame_node == null
		or not parent_current is Transform3D
		or not child_current is Transform3D
		or not parent_zero is Transform3D
		or not child_zero is Transform3D
		or not rest_local is Transform3D
	):
		_pivot_mark_invalid(frame_name, "missing_transform")
		return
	var transforms_to_validate: Array[Transform3D] = [
		parent_current as Transform3D,
		child_current as Transform3D,
		parent_zero as Transform3D,
		child_zero as Transform3D,
	]
	for candidate_transform in transforms_to_validate:
		if not _is_rigid_transform(candidate_transform):
			_pivot_mark_invalid(frame_name, "non_rigid_transform")
			return
	var parent_zero_rigid := _rigid_transform(parent_zero as Transform3D)
	var child_zero_rigid := _rigid_transform(child_zero as Transform3D)
	var parent_current_rigid := _rigid_transform(parent_current as Transform3D)
	var child_current_rigid := _rigid_transform(child_current as Transform3D)
	var rest_relation := parent_zero_rigid.affine_inverse() * child_zero_rigid
	var current_relation := parent_current_rigid.affine_inverse() * child_current_rigid
	if current_relation.origin.distance_to(rest_relation.origin) > JOINT_ORIGIN_TOLERANCE_M:
		_pivot_mark_invalid(frame_name, "authority_joint_origin_drift")
		return
	var delta_basis := rest_relation.basis.inverse() * current_relation.basis
	var runtime_axis := String(_frame_runtime_axes.get(frame_name, ""))
	var angle := _single_axis_angle(delta_basis, runtime_axis)
	var clean_delta := Basis(_axis_vector(runtime_axis), angle)
	if _basis_max_abs_difference(delta_basis, clean_delta) > JOINT_AXIS_RESIDUAL_TOLERANCE:
		_pivot_mark_invalid(frame_name, "non_axis_rotation_residual")
		return
	var target_local := rest_local as Transform3D
	target_local.basis = target_local.basis * clean_delta
	if not _finite_transform(target_local):
		_pivot_mark_invalid(frame_name, "non_finite_local_transform")
		return
	frame_node.transform = target_local
	_pivot_mark_valid(frame_name)


func _rigid_transform(value: Transform3D) -> Transform3D:
	return Transform3D(value.basis.orthonormalized(), value.origin)


func _is_rigid_transform(value: Transform3D) -> bool:
	if not _finite_transform(value):
		return false
	var rigid_basis := value.basis
	return (
		absf(rigid_basis.x.length() - 1.0) <= RIGID_BASIS_TOLERANCE
		and absf(rigid_basis.y.length() - 1.0) <= RIGID_BASIS_TOLERANCE
		and absf(rigid_basis.z.length() - 1.0) <= RIGID_BASIS_TOLERANCE
		and absf(rigid_basis.x.dot(rigid_basis.y)) <= RIGID_BASIS_TOLERANCE
		and absf(rigid_basis.x.dot(rigid_basis.z)) <= RIGID_BASIS_TOLERANCE
		and absf(rigid_basis.y.dot(rigid_basis.z)) <= RIGID_BASIS_TOLERANCE
		and absf(rigid_basis.determinant() - 1.0) <= RIGID_BASIS_TOLERANCE
	)


func _finite_transform(value: Transform3D) -> bool:
	return (
		_finite_vector(value.origin)
		and _finite_vector(value.basis.x)
		and _finite_vector(value.basis.y)
		and _finite_vector(value.basis.z)
	)


func _axis_vector(axis_name: String) -> Vector3:
	return Vector3.UP if axis_name == "Y" else Vector3.RIGHT


func _single_axis_angle(rotation_basis: Basis, axis_name: String) -> float:
	if axis_name == "Y":
		return atan2(rotation_basis.z.x, rotation_basis.x.x)
	return atan2(rotation_basis.y.z, rotation_basis.y.y)


func _twist_angle(rotation_basis: Basis, axis: Vector3) -> float:
	var rotation := Quaternion(rotation_basis.orthonormalized()).normalized()
	var projected := Vector3(rotation.x, rotation.y, rotation.z).dot(axis.normalized())
	return wrapf(2.0 * atan2(projected, rotation.w), -PI, PI)


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


func _pivot_mark_invalid(frame_name: String, reason: String) -> void:
	_pivot_reasons[frame_name] = reason
	if _pivot_last_warning_reasons.get(frame_name, "") != reason:
		push_warning("SY205 pivot %s retained its last valid local pose: %s" % [frame_name, reason])
		_pivot_last_warning_reasons[frame_name] = reason


func _pivot_mark_valid(frame_name: String) -> void:
	_pivot_reasons.erase(frame_name)
	_pivot_last_warning_reasons.erase(frame_name)


func _has_required_frames() -> bool:
	return (
		_frame_nodes.size() == MotionProtocol.FRAME_NAMES.size()
		and _authority_zero_globals.size() == _frame_nodes.size()
		and _rest_locals.size() == _frame_nodes.size()
	)


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}

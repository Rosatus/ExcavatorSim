class_name TrackedChassisController
extends Node3D

const MODEL_CATALOG_PATH := "res://resources/models/model_catalog.json"
const INPUT_ACTIONS := {
	"track_left_forward": KEY_W,
	"track_left_reverse": KEY_S,
	"track_right_forward": KEY_UP,
	"track_right_reverse": KEY_DOWN,
}

@export var controller_enabled := false
@export_enum("python_kinematic", "jolt_shadow", "jolt_authoritative") var authority_profile := AuthorityProfile.JOLT_AUTHORITATIVE
@export var use_project_authority_profile := true
@export var ground_lift_enabled := true
@export var use_jolt_support_hints := true
@export var jolt_probe_height_m := 4.0
@export var jolt_hint_max_error_m := 0.2
@export_flags_3d_physics var terrain_collision_mask := 1
@export var motion_client_path := NodePath("../MotionClient")
@export var product_session_path := NodePath("../ProductSession")
@export var motion_presentation_path := NodePath("../MotionPresentation")
@export var terrain_world_path := NodePath("../TerrainRoot/TerrainWorld")
@export var terrain_collider_path := NodePath("../TerrainRoot/TerrainCollider")
@export var excavation_world_path := NodePath("../TerrainRoot/ExcavationWorld")

var locomotion_state := TrackedLocomotionState.new()
var ground_lift_reaction := BucketGroundLiftReaction.new()
var active_model_id := ""
var contract_error := ""
var _motion_client: MotionClient
var _product_session: ProductSession
var _motion_presentation: MotionPresentation
var _terrain_world: TerrainWorld
var _terrain_collider: TerrainCollider
var _excavation_world: ExcavationWorld
var _input_focused := true
var _jolt_hint_status := "unavailable"
var _base_local_transform := Transform3D.IDENTITY
var _jolt_runtime: JoltChassisTrackRuntime
var _use_test_commands := false
var _test_commands := Vector2.ZERO
var _use_test_equipment_commands := false
var _test_equipment_commands := Vector4.ZERO
var _test_input_focus_bypass := false
var _payload_identity := -1
var _last_payload_sample: Dictionary = {}


func _ready() -> void:
	process_physics_priority = -20
	if use_project_authority_profile:
		authority_profile = String(ProjectSettings.get_setting("simulation/authority_profile", authority_profile))
	if not AuthorityProfile.is_valid(authority_profile):
		contract_error = "unknown authority profile: %s" % authority_profile
		set_physics_process(false)
		push_error(contract_error)
		return
	if AuthorityProfile.writes_product_pose(authority_profile):
		controller_enabled = true
	_ensure_input_actions()
	call_deferred("_connect_runtime")


func _physics_process(delta: float) -> void:
	if AuthorityProfile.writes_product_pose(authority_profile):
		_step_authoritative_chassis()
		return
	if not controller_enabled or not locomotion_state.configured or _terrain_world == null:
		return
	var left := 0.0
	var right := 0.0
	if _input_focused:
		left = Input.get_action_strength("track_left_forward") - Input.get_action_strength("track_left_reverse")
		right = Input.get_action_strength("track_right_forward") - Input.get_action_strength("track_right_reverse")
	locomotion_state.set_commands(left, right)
	locomotion_state.step_fixed(delta, Callable(self, "_sample_terrain_height"))
	_base_local_transform = locomotion_state.chassis_transform
	ground_lift_reaction.enabled = ground_lift_enabled
	if not ground_lift_enabled:
		ground_lift_reaction.clear_target()
	transform = _base_local_transform * ground_lift_reaction.step_fixed(delta)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_input_focused = false
		locomotion_state.stop_motion()
		if _jolt_runtime != null:
			_jolt_runtime.stop_motion()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_input_focused = true


func _exit_tree() -> void:
	var parent := get_parent()
	if parent != null and parent.is_queued_for_deletion():
		_jolt_runtime = null
		return
	if _jolt_runtime != null and is_instance_valid(_jolt_runtime) and not _jolt_runtime.is_inside_tree():
		_jolt_runtime.retire_deferred()
		_jolt_runtime = null
		return
	_destroy_jolt_runtime()


func set_controller_enabled(value: bool) -> void:
	controller_enabled = value
	if not value:
		if AuthorityProfile.writes_product_pose(authority_profile):
			if _jolt_runtime != null:
				_jolt_runtime.set_enabled(false)
		else:
			_reset_motion()


func set_product_session_state(running: bool, focused: bool) -> void:
	if AuthorityProfile.writes_product_pose(authority_profile):
		controller_enabled = running
	_input_focused = focused
	if not running or not focused:
		stop_product_motion()


func stop_product_motion() -> void:
	locomotion_state.stop_motion()
	_test_commands = Vector2.ZERO
	_test_equipment_commands = Vector4.ZERO
	if _jolt_runtime != null:
		_jolt_runtime.stop_motion()
		_jolt_runtime.set_commands(0.0, 0.0)
		_jolt_runtime.set_equipment_commands(Vector4.ZERO, Engine.get_physics_frames())


func configure_model_for_test(model_id: String) -> bool:
	if active_model_id == model_id and contract_error.is_empty():
		if AuthorityProfile.writes_product_pose(authority_profile):
			if _jolt_runtime != null and _jolt_runtime.configured:
				return true
		elif locomotion_state.configured:
			return true
	return _configure_model(model_id)


func set_commands_for_test(left: float, right: float) -> void:
	_use_test_commands = true
	_test_commands = Vector2(
		clampf(left, -1.0, 1.0) if is_finite(left) else 0.0,
		clampf(right, -1.0, 1.0) if is_finite(right) else 0.0
	)
	locomotion_state.set_commands(left, right)
	if _jolt_runtime != null:
		_jolt_runtime.set_commands(_test_commands.x, _test_commands.y)


func clear_commands_for_test() -> void:
	_use_test_commands = false
	_test_commands = Vector2.ZERO
	locomotion_state.set_commands(0.0, 0.0)
	if _jolt_runtime != null:
		_jolt_runtime.set_commands(0.0, 0.0)


func set_equipment_commands_for_test(commands: Vector4) -> void:
	_use_test_equipment_commands = true
	_test_equipment_commands = commands if commands.is_finite() else Vector4.ZERO
	if _jolt_runtime != null:
		_jolt_runtime.set_equipment_commands(_test_equipment_commands)


func set_test_input_focus_bypass_for_test(enabled: bool) -> void:
	_test_input_focus_bypass = enabled
	if not enabled and not _input_focused and _jolt_runtime != null:
		_jolt_runtime.stop_motion()


func clear_equipment_commands_for_test() -> void:
	_use_test_equipment_commands = false
	_test_equipment_commands = Vector4.ZERO
	_payload_identity = -1
	_last_payload_sample.clear()
	if _jolt_runtime != null:
		_jolt_runtime.set_equipment_commands(Vector4.ZERO)


func step_fixed_for_test(delta: float, height_sampler: Callable) -> bool:
	var changed := locomotion_state.step_fixed(delta, height_sampler)
	_base_local_transform = locomotion_state.chassis_transform
	ground_lift_reaction.enabled = ground_lift_enabled
	if not ground_lift_enabled:
		ground_lift_reaction.clear_target()
	transform = _base_local_transform * ground_lift_reaction.step_fixed(delta)
	return changed


func submit_bucket_support_contact(contact: Dictionary) -> void:
	if AuthorityProfile.writes_product_pose(authority_profile):
		ground_lift_reaction.reset()
		return
	ground_lift_reaction.enabled = ground_lift_enabled
	ground_lift_reaction.submit_contact(contact, _base_global_transform())


func clear_bucket_support_contact() -> void:
	if AuthorityProfile.writes_product_pose(authority_profile):
		ground_lift_reaction.reset()
		return
	ground_lift_reaction.submit_contact({}, _base_global_transform())


func raw_world_transform(world_transform: Transform3D) -> Transform3D:
	var effective_global := global_transform
	var base_global := _base_global_transform()
	return base_global * effective_global.affine_inverse() * world_transform


func reset_for_test() -> void:
	_reset_motion()


func sample_terrain_height_for_test(world_xz: Vector2) -> float:
	return _sample_terrain_height(world_xz)


func get_status_snapshot() -> Dictionary:
	var status := (
		(
			_jolt_runtime.get_status_snapshot()
			if _jolt_runtime != null
			else _empty_authoritative_status()
		)
		if AuthorityProfile.writes_product_pose(authority_profile)
		else locomotion_state.get_status_snapshot()
	)
	status["enabled"] = controller_enabled
	status["focused"] = _input_focused
	status["model_id"] = active_model_id
	status["contract_error"] = contract_error
	status["jolt_hint_status"] = _jolt_hint_status
	status["ground_lift"] = (
		{"enabled": false, "active": false, "reason": "jolt_authoritative_contact_response"}
		if AuthorityProfile.writes_product_pose(authority_profile)
		else ground_lift_reaction.get_status_snapshot()
	)
	status["authority_profile"] = authority_profile
	return status


func _empty_authoritative_status() -> Dictionary:
	return {
		"authority_mode": AuthorityProfile.JOLT_AUTHORITATIVE,
		"configured": false,
		"body_transform": global_transform,
		"linear_velocity": Vector3.ZERO,
		"angular_velocity": Vector3.ZERO,
		"sleeping": false,
		"left_command": 0.0,
		"right_command": 0.0,
		"left_speed_mps": 0.0,
		"right_speed_mps": 0.0,
		"left_slip_ratio": 0.0,
		"right_slip_ratio": 0.0,
		"left_contact_count": 0,
		"right_contact_count": 0,
		"left_saturated": false,
		"right_saturated": false,
		"grounded": false,
		"terrain_generation": -1,
		"terrain_revision": -1,
		"terrain_identity_valid": false,
		"contacts": [],
		"quality_flags": ["authoritative_runtime_unavailable"],
	}


func _connect_runtime() -> void:
	_motion_client = get_node_or_null(motion_client_path) as MotionClient
	_product_session = get_node_or_null(product_session_path) as ProductSession
	_motion_presentation = get_node_or_null(motion_presentation_path) as MotionPresentation
	_terrain_world = get_node_or_null(terrain_world_path) as TerrainWorld
	_terrain_collider = get_node_or_null(terrain_collider_path) as TerrainCollider
	_excavation_world = get_node_or_null(excavation_world_path) as ExcavationWorld
	if _motion_client != null and not _motion_client.pose_cleared.is_connected(_on_pose_cleared):
		_motion_client.pose_cleared.connect(_on_pose_cleared)
	if _motion_presentation != null:
		if not _motion_presentation.model_activated.is_connected(_on_model_activated):
			_motion_presentation.model_activated.connect(_on_model_activated)
		var current_model := _motion_presentation.get_active_model_id()
		if not current_model.is_empty():
			_configure_model(current_model)
	if _terrain_world != null and not _terrain_world.world_reset.is_connected(_on_world_reset):
		_terrain_world.world_reset.connect(_on_world_reset)
	if _motion_presentation == null or _terrain_world == null:
		contract_error = "TrackedChassisController requires MotionPresentation and TerrainWorld"
		push_warning(contract_error)


func _configure_model(model_id: String) -> bool:
	var catalog := _read_json(MODEL_CATALOG_PATH)
	var entries: Array = catalog.get("models", [])
	for candidate in entries:
		if candidate is Dictionary and String(candidate.get("model_id", "")) == model_id:
			var parameters: Variant = candidate.get("tracked_locomotion")
			if not parameters is Dictionary or not locomotion_state.configure(parameters as Dictionary):
				contract_error = "model_contract_mismatch: invalid tracked locomotion for %s" % model_id
				active_model_id = ""
				if AuthorityProfile.writes_product_pose(authority_profile):
					_destroy_jolt_runtime()
				_reset_motion()
				return false
			active_model_id = model_id
			contract_error = ""
			_base_local_transform = locomotion_state.chassis_transform
			ground_lift_reaction.configure(parameters as Dictionary)
			if AuthorityProfile.writes_product_pose(authority_profile):
				if not _configure_jolt_runtime(candidate as Dictionary):
					active_model_id = ""
					return false
			else:
				transform = _base_local_transform * ground_lift_reaction.step_fixed(0.0)
			return true
	contract_error = "unknown_model: %s" % model_id
	active_model_id = ""
	if AuthorityProfile.writes_product_pose(authority_profile):
		_destroy_jolt_runtime()
	_reset_motion()
	return false


func _sample_terrain_height(world_xz: Vector2) -> float:
	if _terrain_world == null or _terrain_world.terrain_state == null:
		_jolt_hint_status = "terrain_unavailable"
		return NAN
	var authoritative_height := _terrain_world.terrain_state.sample_surface_bilinear_at(world_xz)
	if not is_finite(authoritative_height):
		_jolt_hint_status = "outside_terrain"
		return NAN
	if not use_jolt_support_hints:
		_jolt_hint_status = "disabled"
		return authoritative_height
	if _terrain_collider == null or not _terrain_collider.available:
		_jolt_hint_status = "collider_unavailable"
		return authoritative_height
	var terrain_identity := Vector2i(
		_terrain_world.terrain_state.world_generation,
		_terrain_world.terrain_state.terrain_revision
	)
	if _terrain_collider.get_applied_identity() != terrain_identity:
		_jolt_hint_status = "identity_mismatch"
		return authoritative_height
	if not is_inside_tree() or get_world_3d() == null:
		_jolt_hint_status = "physics_unavailable"
		return authoritative_height
	var ray_from := Vector3(world_xz.x, authoritative_height + jolt_probe_height_m, world_xz.y)
	var ray_to := Vector3(world_xz.x, authoritative_height - jolt_probe_height_m, world_xz.y)
	var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to, terrain_collision_mask)
	query.collide_with_areas = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var collider: Variant = hit.get("collider")
	if hit.is_empty() or not collider is Node or not _terrain_collider.is_ancestor_of(collider as Node):
		_jolt_hint_status = "ray_miss"
		return authoritative_height
	var hit_position: Variant = hit.get("position")
	if not hit_position is Vector3:
		_jolt_hint_status = "invalid_hit"
		return authoritative_height
	var hinted_height := (hit_position as Vector3).y
	if not is_finite(hinted_height) or absf(hinted_height - authoritative_height) > jolt_hint_max_error_m:
		_jolt_hint_status = "height_mismatch"
		return authoritative_height
	_jolt_hint_status = "used"
	return hinted_height


func _reset_motion() -> void:
	locomotion_state.reset()
	ground_lift_reaction.reset()
	_base_local_transform = Transform3D.IDENTITY
	_use_test_commands = false
	_test_commands = Vector2.ZERO
	_use_test_equipment_commands = false
	_test_equipment_commands = Vector4.ZERO
	if AuthorityProfile.writes_product_pose(authority_profile) and _jolt_runtime != null:
		var descriptor := PhysicsRigDescriptor.load_for_model(active_model_id)
		var spawn := _authoritative_spawn_transform(descriptor) if descriptor != null else Transform3D.IDENTITY
		_jolt_runtime.reset(spawn)
		_sync_visual_to_jolt_body()
	else:
		transform = Transform3D.IDENTITY


func _base_global_transform() -> Transform3D:
	var parent := get_parent_node_3d()
	return (parent.global_transform if parent != null else Transform3D.IDENTITY) * _base_local_transform


func _on_model_activated(model_id: String, _asset_root: Node3D) -> void:
	_configure_model(model_id)


func _on_pose_cleared(_generation: int, _reason: String) -> void:
	_reset_motion()


func _on_world_reset(_generation: int) -> void:
	if AuthorityProfile.writes_product_pose(authority_profile):
		_ensure_authoritative_terrain_collider()
	_reset_motion()


func _step_authoritative_chassis() -> void:
	if _jolt_runtime == null or not _jolt_runtime.configured:
		return
	var left := 0.0
	var right := 0.0
	if controller_enabled and (
		_input_focused or (_test_input_focus_bypass and _use_test_commands)
	):
		if _use_test_commands:
			left = _test_commands.x
			right = _test_commands.y
		else:
			left = Input.get_action_strength("track_left_forward") - Input.get_action_strength("track_left_reverse")
			right = Input.get_action_strength("track_right_forward") - Input.get_action_strength("track_right_reverse")
	_jolt_runtime.set_enabled(controller_enabled)
	_jolt_runtime.set_commands(left, right)
	var equipment_axes := Vector4.ZERO
	if controller_enabled and (
		_input_focused or (_test_input_focus_bypass and _use_test_equipment_commands)
	):
			equipment_axes = (
			_test_equipment_commands
			if _use_test_equipment_commands
			else (
				_product_session.get_equipment_input_axes()
				if _product_session != null
				else (_motion_client.get_authoritative_input_axes() if _motion_client != null else Vector4.ZERO)
			)
		)
	_jolt_runtime.set_equipment_commands(equipment_axes, Engine.get_physics_frames())
	_submit_authoritative_payload()


func _configure_jolt_runtime(catalog_entry: Dictionary) -> bool:
	_destroy_jolt_runtime()
	_payload_identity = -1
	_last_payload_sample.clear()
	if _terrain_world == null or _terrain_world.terrain_state == null or _terrain_collider == null:
		contract_error = "jolt_authoritative requires TerrainWorld and TerrainCollider"
		return false
	var descriptor := PhysicsRigDescriptor.load_for_model(active_model_id)
	var model_version := String(catalog_entry.get("model_version", ""))
	if descriptor == null or not descriptor.is_valid_for(active_model_id, model_version):
		contract_error = (
			"missing physics rig descriptor for %s" % active_model_id
			if descriptor == null
			else descriptor.validation_error()
		)
		return false
	if not _ensure_authoritative_terrain_collider():
		contract_error = "jolt_authoritative terrain collider identity is unavailable"
		return false
	_jolt_runtime = JoltChassisTrackRuntime.new()
	_jolt_runtime.name = "JoltChassisTrackRuntime"
	var parent := get_parent()
	if parent == null:
		contract_error = "jolt_authoritative chassis has no scene parent"
		_jolt_runtime.free()
		_jolt_runtime = null
		return false
	parent.add_child(_jolt_runtime)
	if not _jolt_runtime.post_step_snapshot_captured.is_connected(_on_jolt_post_step_snapshot):
		_jolt_runtime.post_step_snapshot_captured.connect(_on_jolt_post_step_snapshot)
	if not _jolt_runtime.configure(
		descriptor,
		_terrain_world,
		_terrain_collider,
		_authoritative_spawn_transform(descriptor)
	):
		contract_error = _jolt_runtime.contract_error
		_destroy_jolt_runtime()
		return false
	_jolt_runtime.set_enabled(controller_enabled)
	_on_jolt_post_step_snapshot(_jolt_runtime.get_post_step_snapshot())
	return true


func _destroy_jolt_runtime() -> void:
	if _jolt_runtime == null:
		return
	_jolt_runtime.teardown()
	if _jolt_runtime.is_inside_tree():
		_jolt_runtime.name = "RetiredJoltChassisTrackRuntime"
		_jolt_runtime.queue_free()
	else:
		_jolt_runtime.free()
	_jolt_runtime = null


func _ensure_authoritative_terrain_collider() -> bool:
	if _terrain_world == null or _terrain_world.terrain_state == null or _terrain_collider == null:
		return false
	_terrain_collider.enabled = true
	var identity := Vector2i(
		_terrain_world.terrain_state.world_generation,
		_terrain_world.terrain_state.terrain_revision
	)
	if _terrain_collider.get_applied_identity() != identity:
		_terrain_collider.queue_snapshot(_terrain_world.terrain_state.surface_snapshot())
		_terrain_collider.apply_pending()
	return _terrain_collider.available and _terrain_collider.get_applied_identity() == identity


func _authoritative_spawn_transform(descriptor: PhysicsRigDescriptor) -> Transform3D:
	var parent := get_parent_node_3d()
	var spawn := parent.global_transform if parent != null else Transform3D.IDENTITY
	spawn.basis = spawn.basis.orthonormalized()
	var surface_y := 0.0
	if _terrain_world != null and _terrain_world.terrain_state != null:
		var sampled := _terrain_world.terrain_state.sample_surface_bilinear_at(Vector2(spawn.origin.x, spawn.origin.z))
		if is_finite(sampled):
			surface_y = sampled
	var data := descriptor.to_dictionary()
	var dynamics := data.get("chassis_dynamics", {}) as Dictionary
	var minimum_bottom := INF
	for shape_value in dynamics.get("compound_shapes", []):
		if not shape_value is Dictionary:
			continue
		var shape := shape_value as Dictionary
		var center := _vector3(shape.get("center_m", [0.0, 0.0, 0.0]))
		var size := _vector3(shape.get("size_m", [1.0, 1.0, 1.0]))
		minimum_bottom = minf(minimum_bottom, center.y - 0.5 * size.y)
	if is_inf(minimum_bottom):
		minimum_bottom = 0.0
	spawn.origin.y = surface_y - minimum_bottom + float(dynamics.get("ground_clearance_m", 0.05))
	return spawn


func _sync_visual_to_jolt_body() -> void:
	if _jolt_runtime == null or not _jolt_runtime.has_body():
		return
	_on_jolt_post_step_snapshot(_jolt_runtime.get_post_step_snapshot())


func _on_jolt_post_step_snapshot(snapshot: Dictionary) -> void:
	var body_transform: Variant = snapshot.get("body_transform")
	if not body_transform is Transform3D or not (body_transform as Transform3D).is_finite():
		return
	global_transform = body_transform as Transform3D
	_base_local_transform = transform
	ground_lift_reaction.reset()
	if _motion_presentation != null:
		_motion_presentation.apply_physics_snapshot(snapshot)


func _submit_authoritative_payload() -> void:
	if _jolt_runtime == null or _excavation_world == null:
		return
	var soil := _excavation_world.get_status_snapshot()
	var center: Variant = soil.get("center_of_mass_local", Vector3.ZERO)
	if not center is Vector3:
		center = Vector3.ZERO
	var sample := {
		"mass_kg": float(soil.get("payload_mass_kg", 0.0)),
		"center_of_mass_local": center as Vector3,
		"world_generation": int(soil.get("world_generation", 0)),
	}
	if sample == _last_payload_sample:
		return
	_payload_identity += 1
	if _jolt_runtime.set_bucket_payload(sample["mass_kg"], sample["center_of_mass_local"], _payload_identity):
		_last_payload_sample = sample


func _vector3(value: Variant) -> Vector3:
	var data := value as Array
	return Vector3(float(data[0]), float(data[1]), float(data[2]))


func _ensure_input_actions() -> void:
	for action in INPUT_ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.08)
		_add_key_event(action, int(INPUT_ACTIONS[action]))


func _add_key_event(action: String, keycode: int) -> void:
	for existing in InputMap.action_get_events(action):
		if existing is InputEventKey and (existing as InputEventKey).physical_keycode == keycode:
			return
	var event := InputEventKey.new()
	event.physical_keycode = keycode as Key
	InputMap.action_add_event(action, event)


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}

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
@export var use_jolt_support_hints := true
@export var jolt_probe_height_m := 4.0
@export var jolt_hint_max_error_m := 0.2
@export_flags_3d_physics var terrain_collision_mask := 1
@export var motion_client_path := NodePath("../MotionClient")
@export var motion_presentation_path := NodePath("../MotionPresentation")
@export var terrain_world_path := NodePath("../TerrainRoot/TerrainWorld")
@export var terrain_collider_path := NodePath("../TerrainRoot/TerrainCollider")

var locomotion_state := TrackedLocomotionState.new()
var active_model_id := ""
var contract_error := ""
var _motion_client: MotionClient
var _motion_presentation: MotionPresentation
var _terrain_world: TerrainWorld
var _terrain_collider: TerrainCollider
var _input_focused := true
var _jolt_hint_status := "unavailable"


func _ready() -> void:
	process_physics_priority = -20
	_ensure_input_actions()
	call_deferred("_connect_runtime")


func _physics_process(delta: float) -> void:
	if not controller_enabled or not locomotion_state.configured or _terrain_world == null:
		return
	var left := 0.0
	var right := 0.0
	if _input_focused:
		left = Input.get_action_strength("track_left_forward") - Input.get_action_strength("track_left_reverse")
		right = Input.get_action_strength("track_right_forward") - Input.get_action_strength("track_right_reverse")
	locomotion_state.set_commands(left, right)
	if locomotion_state.step_fixed(delta, Callable(self, "_sample_terrain_height")):
		transform = locomotion_state.chassis_transform


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_input_focused = false
		locomotion_state.stop_motion()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_input_focused = true


func set_controller_enabled(value: bool) -> void:
	controller_enabled = value
	if not value:
		_reset_motion()


func configure_model_for_test(model_id: String) -> bool:
	return _configure_model(model_id)


func set_commands_for_test(left: float, right: float) -> void:
	locomotion_state.set_commands(left, right)


func step_fixed_for_test(delta: float, height_sampler: Callable) -> bool:
	var changed := locomotion_state.step_fixed(delta, height_sampler)
	if changed:
		transform = locomotion_state.chassis_transform
	return changed


func reset_for_test() -> void:
	_reset_motion()


func sample_terrain_height_for_test(world_xz: Vector2) -> float:
	return _sample_terrain_height(world_xz)


func get_status_snapshot() -> Dictionary:
	var status := locomotion_state.get_status_snapshot()
	status["enabled"] = controller_enabled
	status["focused"] = _input_focused
	status["model_id"] = active_model_id
	status["contract_error"] = contract_error
	status["jolt_hint_status"] = _jolt_hint_status
	return status


func _connect_runtime() -> void:
	_motion_client = get_node_or_null(motion_client_path) as MotionClient
	_motion_presentation = get_node_or_null(motion_presentation_path) as MotionPresentation
	_terrain_world = get_node_or_null(terrain_world_path) as TerrainWorld
	_terrain_collider = get_node_or_null(terrain_collider_path) as TerrainCollider
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
				_reset_motion()
				return false
			active_model_id = model_id
			contract_error = ""
			transform = locomotion_state.chassis_transform
			return true
	contract_error = "unknown_model: %s" % model_id
	active_model_id = ""
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
	transform = Transform3D.IDENTITY


func _on_model_activated(model_id: String, _asset_root: Node3D) -> void:
	_configure_model(model_id)


func _on_pose_cleared(_generation: int, _reason: String) -> void:
	_reset_motion()


func _on_world_reset(_generation: int) -> void:
	_reset_motion()


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

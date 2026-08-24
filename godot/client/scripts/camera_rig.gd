class_name CameraRig
extends Camera3D

signal mode_changed(mode: String, display_name: String)

const MODE_OPERATOR := "operator"
const MODE_CHASE := "chase"
const MODE_WORK_TOOL := "work_tool"
const MODE_INSPECTION := "inspection"
const MODES := [MODE_OPERATOR, MODE_CHASE, MODE_WORK_TOOL, MODE_INSPECTION]
const MODE_NAMES := {
	MODE_OPERATOR: "Operator",
	MODE_CHASE: "Chase",
	MODE_WORK_TOOL: "Work Tool",
	MODE_INSPECTION: "Inspection",
}
const CAMERA_ACTIONS := {
	"camera_view_operator": {"key": KEY_1, "joy": JOY_BUTTON_DPAD_UP, "mode": MODE_OPERATOR},
	"camera_view_chase": {"key": KEY_2, "joy": JOY_BUTTON_DPAD_RIGHT, "mode": MODE_CHASE},
	"camera_view_work_tool": {"key": KEY_3, "joy": JOY_BUTTON_DPAD_DOWN, "mode": MODE_WORK_TOOL},
	"camera_view_inspection": {"key": KEY_4, "joy": JOY_BUTTON_DPAD_LEFT, "mode": MODE_INSPECTION},
}
const RESET_ACTION := "camera_reset_view"
const PRESETS := {
	"sy205": {
		MODE_OPERATOR: {"anchor": "upper_structure_link", "reference": "upper_structure_link", "yaw": 2.25, "pitch": 0.28, "distance": 5.8, "focus_height": 1.15, "minimum": 3.2},
		MODE_CHASE: {"anchor": "base_link", "reference": "base_link", "yaw": 0.0, "pitch": 0.30, "distance": 12.0, "focus_height": 1.85, "minimum": 5.5},
		MODE_WORK_TOOL: {"anchor": "bucket_link", "reference": "base_link", "yaw": 0.82, "pitch": 0.34, "distance": 7.4, "focus_height": 0.15, "minimum": 3.8},
		MODE_INSPECTION: {"anchor": "base_link", "reference": "base_link", "yaw": 0.72, "pitch": 0.34, "distance": 12.0, "focus_height": 2.15, "minimum": 4.0},
	},
	"sy135": {
		MODE_OPERATOR: {"anchor": "upper_structure_link", "reference": "upper_structure_link", "yaw": 2.18, "pitch": 0.30, "distance": 5.2, "focus_height": 0.95, "minimum": 3.0},
		MODE_CHASE: {"anchor": "base_link", "reference": "base_link", "yaw": 0.0, "pitch": 0.31, "distance": 11.2, "focus_height": 1.55, "minimum": 5.0},
		MODE_WORK_TOOL: {"anchor": "bucket_link", "reference": "base_link", "yaw": 0.76, "pitch": 0.36, "distance": 6.8, "focus_height": 0.12, "minimum": 3.5},
		MODE_INSPECTION: {"anchor": "base_link", "reference": "base_link", "yaw": 0.68, "pitch": 0.35, "distance": 11.5, "focus_height": 1.85, "minimum": 3.8},
	},
}

@export var target_path := NodePath("../PresentationRoot/SY205Excavator/CTRL_EXCAVATOR_ROOT")
@export var motion_presentation_path := NodePath("../MotionPresentation")
@export var product_session_path := NodePath("../ProductSession")
@export var motion_client_path := NodePath("../MotionClient")
@export var default_mode := MODE_CHASE
@export var distance_m := 12.0
@export var min_distance_m := 3.0
@export var max_distance_m := 24.0
@export var orbit_sensitivity := 0.008
@export var transition_speed := 7.0
@export var recovery_speed := 3.5
@export var occlusion_clearance_m := 0.35
@export_flags_3d_physics var occlusion_mask := 3

var _presentation: MotionPresentation
var _target: Node3D
var _reference: Node3D
var _active_model_id := "sy205"
var _mode := MODE_CHASE
var _yaw := 0.0
var _pitch := 0.3
var _focus_height_m := 1.8
var _mode_minimum_m := 3.0
var _dragging := false
var _initialized := false
var _current_focus := Vector3.ZERO
var _desired_position := Vector3.ZERO
var _resolved_position := Vector3.ZERO
var _occluded := false
var _last_query_usec := 0
var _occlusion_probe_override := Callable()


func _ready() -> void:
	_ensure_input_actions()
	_presentation = get_node_or_null(motion_presentation_path) as MotionPresentation
	if _presentation != null:
		_presentation.model_activated.connect(_on_model_activated)
		if not _presentation.get_active_model_id().is_empty():
			_active_model_id = _presentation.get_active_model_id()
	var product_session := get_node_or_null(product_session_path) as ProductSession
	if product_session != null:
		product_session.authority_changed.connect(_on_authority_changed)
	var motion_client := get_node_or_null(motion_client_path) as MotionClient
	if motion_client != null:
		motion_client.authority_changed.connect(_on_authority_changed)
	_mode = default_mode if MODES.has(default_mode) else MODE_CHASE
	_reset_mode_state()
	_resolve_anchors()
	_step_camera(1.0, true)
	mode_changed.emit(_mode, get_mode_display_name())


func _process(delta: float) -> void:
	if not _anchors_valid():
		_resolve_anchors()
	if _target != null:
		_step_camera(delta, false)


func _unhandled_input(event: InputEvent) -> void:
	for action in CAMERA_ACTIONS:
		if event.is_action_pressed(action):
			set_mode(String((CAMERA_ACTIONS[action] as Dictionary)["mode"]))
			return
	if event.is_action_pressed(RESET_ACTION):
		reset_view()
		return
	var button := event as InputEventMouseButton
	if button != null:
		if button.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = button.pressed
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance_m = maxf(maxf(min_distance_m, _mode_minimum_m), distance_m - 0.75)
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance_m = minf(max_distance_m, distance_m + 0.75)
		return
	var motion := event as InputEventMouseMotion
	if motion != null and _dragging:
		_yaw = wrapf(_yaw - motion.relative.x * orbit_sensitivity, -PI, PI)
		_pitch = clampf(_pitch - motion.relative.y * orbit_sensitivity, 0.12, 0.92)


func set_mode(value: String) -> bool:
	if not MODES.has(value):
		return false
	if value == _mode:
		return true
	_mode = value
	_reset_mode_state()
	_resolve_anchors()
	mode_changed.emit(_mode, get_mode_display_name())
	return true


func reset_view() -> void:
	_reset_mode_state()
	_resolve_anchors()


func get_mode() -> String:
	return _mode


func get_mode_display_name() -> String:
	return String(MODE_NAMES.get(_mode, _mode.capitalize()))


func set_quality_distance_for_test(max_distance: float) -> void:
	max_distance_m = maxf(min_distance_m, max_distance)
	distance_m = clampf(distance_m, maxf(min_distance_m, _mode_minimum_m), max_distance_m)


func set_occlusion_probe_for_test(probe: Callable) -> void:
	_occlusion_probe_override = probe


func force_camera_update_for_test(delta: float = 1.0) -> void:
	if not _anchors_valid():
		_resolve_anchors()
	_step_camera(delta, false)


func get_view_snapshot_for_test() -> Dictionary:
	return {
		"mode": _mode,
		"display_name": get_mode_display_name(),
		"model_id": _active_model_id,
		"anchor_name": _target.name if is_instance_valid(_target) else "",
		"anchor_instance_id": _target.get_instance_id() if is_instance_valid(_target) else 0,
		"focus": _current_focus,
		"desired_position": _desired_position,
		"resolved_position": _resolved_position,
		"camera_position": global_position,
		"distance_m": distance_m,
		"resolved_distance_m": _current_focus.distance_to(_resolved_position),
		"yaw": _yaw,
		"pitch": _pitch,
		"near": near,
		"far": far,
		"occluded": _occluded,
		"query_usec": _last_query_usec,
		"finite": _finite_vector3(global_position) and _finite_vector3(_current_focus),
	}


func _step_camera(delta: float, snap: bool) -> void:
	if _target == null or not is_instance_valid(_target):
		return
	var focus := _resolve_focus()
	var reference := _reference if is_instance_valid(_reference) else _target
	var rear := reference.global_basis.z
	rear.y = 0.0
	rear = rear.normalized() if rear.length_squared() > 0.0001 else Vector3.BACK
	var right := reference.global_basis.x
	right.y = 0.0
	right = right.normalized() if right.length_squared() > 0.0001 else Vector3.RIGHT
	var horizontal_direction := (rear * cos(_yaw) + right * sin(_yaw)).normalized()
	var intended_distance := clampf(distance_m, maxf(min_distance_m, _mode_minimum_m), max_distance_m)
	var horizontal := cos(_pitch) * intended_distance
	_desired_position = focus + horizontal_direction * horizontal + Vector3.UP * (sin(_pitch) * intended_distance)
	_resolved_position = _resolve_occlusion(focus, _desired_position)
	var resolved_distance := maxf(0.01, focus.distance_to(_resolved_position))
	near = clampf(resolved_distance * 0.025, 0.08, 0.22)
	if snap or not _initialized:
		_current_focus = focus
		global_position = _resolved_position
		_initialized = true
	else:
		var focus_alpha := 1.0 - exp(-transition_speed * maxf(delta, 0.0))
		_current_focus = _current_focus.lerp(focus, focus_alpha)
		var current_distance := global_position.distance_to(_current_focus)
		var resolved_is_inward := _occluded and resolved_distance < current_distance
		if resolved_is_inward:
			global_position = _resolved_position
		else:
			var speed := recovery_speed if not _occluded else transition_speed
			var position_alpha := 1.0 - exp(-speed * maxf(delta, 0.0))
			global_position = global_position.lerp(_resolved_position, position_alpha)
	if global_position.distance_squared_to(_current_focus) > 0.0001:
		look_at(_current_focus, Vector3.UP)


func _resolve_focus() -> Vector3:
	if _mode == MODE_WORK_TOOL and _presentation != null:
		var contact: Variant = _presentation.get_bucket_contact_world()
		if contact is Vector3:
			return (contact as Vector3) + Vector3.UP * _focus_height_m
	return _target.global_position + Vector3.UP * _focus_height_m


func _resolve_occlusion(focus: Vector3, desired: Vector3) -> Vector3:
	_occluded = false
	_last_query_usec = 0
	var ray := desired - focus
	var full_distance := ray.length()
	if full_distance <= _mode_minimum_m + occlusion_clearance_m:
		return desired
	var direction := ray / full_distance
	var query_from := focus + direction * _mode_minimum_m
	var started_usec := Time.get_ticks_usec()
	var hit: Dictionary = {}
	if _occlusion_probe_override.is_valid():
		hit = _occlusion_probe_override.call(query_from, desired, occlusion_mask) as Dictionary
	elif is_inside_tree() and get_world_3d() != null:
		var query := PhysicsRayQueryParameters3D.create(query_from, desired, occlusion_mask)
		query.collide_with_areas = false
		query.collide_with_bodies = true
		hit = get_world_3d().direct_space_state.intersect_ray(query)
	_last_query_usec = Time.get_ticks_usec() - started_usec
	if hit.is_empty() or not (hit.get("position") is Vector3):
		return desired
	var hit_position := hit["position"] as Vector3
	var hit_distance := focus.distance_to(hit_position)
	var safe_distance := clampf(hit_distance - occlusion_clearance_m, _mode_minimum_m, full_distance)
	if safe_distance >= full_distance - 0.001:
		return desired
	_occluded = true
	return focus + direction * safe_distance


func _reset_mode_state() -> void:
	var preset := _current_preset()
	_yaw = float(preset.get("yaw", 0.0))
	_pitch = float(preset.get("pitch", 0.3))
	_focus_height_m = float(preset.get("focus_height", 1.2))
	_mode_minimum_m = float(preset.get("minimum", min_distance_m))
	distance_m = clampf(float(preset.get("distance", 12.0)), maxf(min_distance_m, _mode_minimum_m), max_distance_m)
	_dragging = false
	_occluded = false


func _resolve_anchors() -> void:
	var preset := _current_preset()
	_target = _frame_or_fallback(String(preset.get("anchor", "base_link")))
	_reference = _frame_or_fallback(String(preset.get("reference", "base_link")))
	if _target == null:
		_target = get_node_or_null(target_path) as Node3D
	if _reference == null:
		_reference = _target


func _frame_or_fallback(frame_name: String) -> Node3D:
	if _presentation == null:
		return null
	var frame := _presentation.get_frame_node(frame_name)
	if frame != null and is_instance_valid(frame):
		return frame
	frame = _presentation.get_frame_node("base_link")
	return frame if frame != null and is_instance_valid(frame) else null


func _anchors_valid() -> bool:
	return _target != null and _reference != null and is_instance_valid(_target) and is_instance_valid(_reference)


func _current_preset() -> Dictionary:
	var model_presets := PRESETS.get(_active_model_id, PRESETS["sy205"]) as Dictionary
	return model_presets.get(_mode, model_presets[MODE_CHASE]) as Dictionary


func _on_model_activated(model_id: String, _asset_root: Node3D) -> void:
	_target = null
	_reference = null
	_active_model_id = model_id if PRESETS.has(model_id) else "sy205"
	_reset_mode_state()
	_resolve_anchors()
	_initialized = false
	_step_camera(1.0, true)
	mode_changed.emit(_mode, get_mode_display_name())


func _on_authority_changed(_session_id: String, _epoch: String, _generation: int) -> void:
	reset_view()


func _ensure_input_actions() -> void:
	for action in CAMERA_ACTIONS:
		var binding := CAMERA_ACTIONS[action] as Dictionary
		_ensure_action(action)
		_add_event_once(action, _key_event(int(binding["key"])))
		_add_event_once(action, _joy_button_event(int(binding["joy"])))
	_ensure_action(RESET_ACTION)
	_add_event_once(RESET_ACTION, _key_event(KEY_C))
	_add_event_once(RESET_ACTION, _joy_button_event(JOY_BUTTON_RIGHT_STICK))


func _ensure_action(action: String) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)


func _add_event_once(action: String, event: InputEvent) -> void:
	for existing in InputMap.action_get_events(action):
		if existing.is_match(event):
			return
	InputMap.action_add_event(action, event)


func _key_event(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	return event


func _joy_button_event(button_index: JoyButton) -> InputEventJoypadButton:
	var event := InputEventJoypadButton.new()
	event.button_index = button_index
	return event


func _finite_vector3(value: Vector3) -> bool:
	return not is_nan(value.x) and not is_inf(value.x) and not is_nan(value.y) and not is_inf(value.y) and not is_nan(value.z) and not is_inf(value.z)

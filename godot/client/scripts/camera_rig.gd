class_name CameraRig
extends Camera3D

@export var target_path := NodePath("../PresentationRoot/SY205Excavator/CTRL_EXCAVATOR_ROOT")
@export var motion_presentation_path := NodePath("../MotionPresentation")
@export var distance_m := 12.0
@export var min_distance_m := 6.0
@export var max_distance_m := 24.0
@export var orbit_sensitivity := 0.008
@export var focus_height_m := 1.2

var _target: Node3D
var _yaw := 0.72
var _pitch := 0.34
var _dragging := false


func _ready() -> void:
	_target = get_node_or_null(target_path) as Node3D
	var presentation := get_node_or_null(motion_presentation_path) as MotionPresentation
	if presentation != null:
		presentation.model_activated.connect(_on_model_activated)
		if presentation.get_frame_node("base_link") != null:
			_target = presentation.get_frame_node("base_link")
	_apply_transform()


func _process(_delta: float) -> void:
	if _target != null:
		_apply_transform()


func _unhandled_input(event: InputEvent) -> void:
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null:
		if button.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = button.pressed
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance_m = maxf(min_distance_m, distance_m - 0.75)
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance_m = minf(max_distance_m, distance_m + 0.75)
		return
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion != null and _dragging:
		_yaw -= motion.relative.x * orbit_sensitivity
		_pitch = clampf(_pitch - motion.relative.y * orbit_sensitivity, 0.12, 0.9)


func set_quality_distance_for_test(max_distance: float) -> void:
	max_distance_m = maxf(min_distance_m, max_distance)
	distance_m = clampf(distance_m, min_distance_m, max_distance_m)


func _apply_transform() -> void:
	if _target == null:
		return
	var focus := _target.global_position + Vector3.UP * focus_height_m
	var horizontal := cos(_pitch) * distance_m
	global_position = focus + Vector3(sin(_yaw) * horizontal, sin(_pitch) * distance_m, cos(_yaw) * horizontal)
	look_at(focus, Vector3.UP)


func _on_model_activated(_model_id: String, _asset_root: Node3D) -> void:
	var presentation := get_node_or_null(motion_presentation_path) as MotionPresentation
	_target = presentation.get_frame_node("base_link") if presentation != null else null

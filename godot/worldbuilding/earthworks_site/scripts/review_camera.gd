extends Camera3D

@export var speed_mps := 14.0
var mouse_look := false


func _ready() -> void:
	make_current()
	jump_to("EntranceCamera")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		mouse_look = event.pressed
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if mouse_look else Input.MOUSE_MODE_VISIBLE
	if event is InputEventMouseMotion and mouse_look:
		rotation.y -= event.relative.x * 0.0025
		rotation.x = clampf(rotation.x - event.relative.y * 0.0025, -1.5, 1.5)
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_1: jump_to("OverviewCamera")
			KEY_2: jump_to("EntranceCamera")
			KEY_3: jump_to("WorkFaceCamera")
			KEY_F1:
				var diagnostics := get_parent().get_node("Diagnostics") as Node3D
				diagnostics.visible = not diagnostics.visible
			KEY_ESCAPE:
				mouse_look = false
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(delta: float) -> void:
	if not mouse_look:
		return
	var axes := Vector3(float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)), float(Input.is_physical_key_pressed(KEY_E)) - float(Input.is_physical_key_pressed(KEY_Q)), float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	var multiplier := 3.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0
	global_position += global_basis * axes.limit_length() * speed_mps * multiplier * delta


func jump_to(marker_name: String) -> void:
	var marker := get_parent().get_node(marker_name) as Camera3D
	global_transform = marker.global_transform
	fov = marker.fov


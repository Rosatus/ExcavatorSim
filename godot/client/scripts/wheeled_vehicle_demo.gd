extends Node3D
## Runnable reference wiring; replace procedural meshes with imported visual nodes.
const Controller = preload("res://scripts/wheeled_vehicle_controller.gd")
const Animator = preload("res://scripts/wheel_visual_animator.gd")
var vehicle: RigidBody3D
var controller: Node
var camera: Camera3D
var label: Label

func _ready() -> void:
	var ground := StaticBody3D.new()
	ground.name = "Ground"
	ground.position.y = -0.25
	_box(ground, Vector3(160, 0.5, 160), Color(0.25, 0.31, 0.27), true)
	add_child(ground)
	# A visible gentle ramp and obstacle test full body pitch/contact, not height snapping.
	var ramp := StaticBody3D.new()
	ramp.position = Vector3(8, 0.7, -18)
	ramp.rotation.x = deg_to_rad(8)
	_box(ramp, Vector3(5, 0.3, 12), Color(0.48, 0.45, 0.36), true)
	add_child(ramp)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -30, 0)
	light.shadow_enabled = true
	add_child(light)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.48, 0.67, 0.82)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 0.6
	add_child(env)
	vehicle = RigidBody3D.new()
	vehicle.name = "WheeledMachine"
	vehicle.mass = 2500
	vehicle.position = Vector3(0, 1.0, 0)
	vehicle.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	vehicle.center_of_mass = Vector3(0, 0.0, 0)
	vehicle.continuous_cd = true
	vehicle.can_sleep = false
	vehicle.collision_layer = 2
	vehicle.collision_mask = 1
	var material := PhysicsMaterial.new()
	material.friction = 0.5
	vehicle.physics_material_override = material
	_box(vehicle, Vector3(1.7, 0.5, 3.5), Color(0.92, 0.62, 0.12), true)
	var cab := Node3D.new()
	cab.position = Vector3(0, 0.65, -0.35)
	_box(cab, Vector3(1.2, 0.85, 1.3), Color(0.19, 0.28, 0.32), false)
	vehicle.add_child(cab)
	var animator := Animator.new()
	animator.name = "WheelVisualAnimator"
	vehicle.add_child(animator)
	var stations: Array[Dictionary] = []
	for index in 4:
		var mount := Vector3(-1.05 if index % 2 == 0 else 1.05, 0, -1.4 if index < 2 else 1.4)
		stations.append({"mount": mount, "radius_m": 0.5, "steered": index < 2, "driven": true})
		var pivot := Node3D.new()
		pivot.name = "WheelPivot%d" % index
		pivot.position = mount
		vehicle.add_child(pivot)
		var roll := Node3D.new()
		roll.name = "Roll"
		pivot.add_child(roll)
		var tire := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.5
		cylinder.bottom_radius = 0.5
		cylinder.height = 0.3
		cylinder.radial_segments = 32
		tire.mesh = cylinder
		tire.rotation.z = PI * 0.5
		var rubber := StandardMaterial3D.new()
		rubber.albedo_color = Color(0.045, 0.05, 0.055)
		tire.material_override = rubber
		roll.add_child(tire)
		# Radial bars make direction and actual angular velocity visible.
		for spoke in 4:
			var marker := Node3D.new()
			marker.rotation.x = spoke * PI / 4
			_box(marker, Vector3(0.32, 0.08, 0.76), Color(0.7, 0.74, 0.77), false)
			roll.add_child(marker)
		animator.wheel_paths.append(NodePath("../WheelPivot%d/Roll" % index))
		animator.steering_pivot_paths.append(NodePath("../WheelPivot%d" % index))
	controller = Controller.new()
	controller.name = "WheelMotion"
	controller.wheel_stations = stations
	controller.keyboard_input = true
	vehicle.add_child(controller)
	add_child(vehicle)
	camera = Camera3D.new()
	camera.current = true
	add_child(camera)
	var canvas := CanvasLayer.new()
	label = Label.new()
	label.position = Vector2(24, 20)
	label.add_theme_font_size_override("font_size", 22)
	canvas.add_child(label)
	add_child(canvas)

func _process(delta: float) -> void:
	var target := vehicle.global_position
	camera.global_position = camera.global_position.lerp(target + Vector3(7, 5, 9), 1.0 - exp(-4.0 * delta))
	if camera.global_position.distance_squared_to(target) > 0.01:
		camera.look_at(target)
	var status: Dictionary = controller.get_status_snapshot()
	label.text = "WHEELED MACHINE TEST\nG forward / V left / B reverse / N right   Space: brake\nSpeed %.1f km/h   Grounded wheels %d/4" % [float(status.get("speed_mps", 0)) * 3.6, int(status.get("contact_count", 0))]

func _box(parent: Node3D, size: Vector3, color: Color, collision: bool) -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh.material_override = mat
	parent.add_child(mesh)
	if collision:
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = size
		shape.shape = box_shape
		parent.add_child(shape)

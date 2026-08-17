class_name JoltChassisTrackRuntime
extends Node3D

## Owns the Phase 1 Jolt chassis body and distributed crawler traction. The
## visual ChassisMotionRoot follows this body's snapshot; it never drives it.

const GRAVITY_M_S2 := 9.80665
const MIN_SPEED_DENOMINATOR := 0.25

var configured := false
var enabled := false
var model_id := ""
var rig_id := ""
var rig_version := ""
var contract_error := ""

var _body: RigidBody3D
var _terrain_world: TerrainWorld
var _terrain_collider: TerrainCollider
var _descriptor: Dictionary = {}
var _dynamics: Dictionary = {}
var _tracks: Dictionary = {}
var _spawn_global_transform := Transform3D.IDENTITY
var _left_command := 0.0
var _right_command := 0.0
var _physics_tick := 0
var _terrain_identity := Vector2i(-1, -1)
var _terrain_identity_valid := false
var _left_contact_count := 0
var _right_contact_count := 0
var _left_speed_m_s := 0.0
var _right_speed_m_s := 0.0
var _left_slip_ratio := 0.0
var _right_slip_ratio := 0.0
var _left_saturated := false
var _right_saturated := false
var _contacts: Array[Dictionary] = []
var _quality_flags: Array[String] = []
var _last_step_usec := 0
var _peak_step_usec := 0


func _ready() -> void:
	process_physics_priority = 0


func _physics_process(_delta: float) -> void:
	if not configured or _body == null:
		return
	var started_usec := Time.get_ticks_usec()
	_physics_tick = Engine.get_physics_frames()
	_update_terrain_identity()
	_clear_tick_telemetry()
	if enabled and _terrain_identity_valid:
		_apply_track_forces()
	elif enabled:
		_quality_flags.append("terrain_collider_unavailable")
	_clamp_body_velocity()
	if _left_contact_count + _right_contact_count == 0:
		_quality_flags.append("no_track_contact")
	_last_step_usec = Time.get_ticks_usec() - started_usec
	_peak_step_usec = maxi(_peak_step_usec, _last_step_usec)


func configure(
	descriptor: PhysicsRigDescriptor,
	terrain_world: TerrainWorld,
	terrain_collider: TerrainCollider,
	spawn_global_transform: Transform3D
) -> bool:
	teardown()
	if descriptor == null:
		return _reject("missing physics rig descriptor")
	_descriptor = descriptor.to_dictionary()
	model_id = String(_descriptor.get("model_id", ""))
	rig_id = String(_descriptor.get("rig_id", ""))
	rig_version = String(_descriptor.get("rig_version", ""))
	_dynamics = (_descriptor.get("chassis_dynamics", {}) as Dictionary).duplicate(true)
	_tracks = (_descriptor.get("tracks", {}) as Dictionary).duplicate(true)
	_terrain_world = terrain_world
	_terrain_collider = terrain_collider
	_spawn_global_transform = spawn_global_transform
	if (_dynamics.get("compound_shapes", []) as Array).size() < 2:
		return _reject("Phase 1 chassis requires compound primitive collision proxies")
	_body = _build_body()
	if _body == null:
		return _reject("could not build Jolt chassis body")
	add_child(_body)
	_body.global_transform = _spawn_global_transform
	configured = true
	enabled = true
	contract_error = ""
	_update_terrain_identity()
	return true


func teardown() -> void:
	configured = false
	enabled = false
	set_commands(0.0, 0.0)
	if _body != null and is_instance_valid(_body):
		_body.linear_velocity = Vector3.ZERO
		_body.angular_velocity = Vector3.ZERO
		_body.collision_layer = 0
		_body.collision_mask = 0
		_body.freeze = true
		if _body.is_inside_tree():
			_body.queue_free()
		else:
			_body.free()
	_body = null
	_descriptor.clear()
	_dynamics.clear()
	_tracks.clear()
	_contacts.clear()
	_quality_flags.clear()
	_terrain_identity = Vector2i(-1, -1)
	_terrain_identity_valid = false
	_clear_tick_telemetry()


func set_enabled(value: bool) -> void:
	enabled = value and configured
	if not enabled:
		set_commands(0.0, 0.0)


func set_commands(left: float, right: float) -> void:
	_left_command = clampf(left, -1.0, 1.0) if is_finite(left) else 0.0
	_right_command = clampf(right, -1.0, 1.0) if is_finite(right) else 0.0


func stop_motion() -> void:
	set_commands(0.0, 0.0)


func reset(spawn_global_transform := Transform3D.IDENTITY) -> void:
	_spawn_global_transform = spawn_global_transform
	set_commands(0.0, 0.0)
	if not has_body():
		return
	_body.linear_velocity = Vector3.ZERO
	_body.angular_velocity = Vector3.ZERO
	_body.global_transform = _spawn_global_transform
	_body.sleeping = false
	_clear_tick_telemetry()


func has_body() -> bool:
	return configured and _body != null and is_instance_valid(_body) and _body.is_inside_tree()


func get_body_global_transform() -> Transform3D:
	return _body.global_transform if has_body() else Transform3D.IDENTITY


func get_status_snapshot() -> Dictionary:
	return {
		"authority_mode": AuthorityProfile.JOLT_AUTHORITATIVE,
		"configured": configured,
		"enabled": enabled,
		"model_id": model_id,
		"rig_id": rig_id,
		"rig_version": rig_version,
		"contract_error": contract_error,
		"physics_tick": _physics_tick,
		"body_transform": get_body_global_transform(),
		"linear_velocity": _body.linear_velocity if has_body() else Vector3.ZERO,
		"angular_velocity": _body.angular_velocity if has_body() else Vector3.ZERO,
		"sleeping": _body.sleeping if has_body() else false,
		"left_command": _left_command,
		"right_command": _right_command,
		"left_speed_mps": _left_speed_m_s,
		"right_speed_mps": _right_speed_m_s,
		"left_slip_ratio": _left_slip_ratio,
		"right_slip_ratio": _right_slip_ratio,
		"left_contact_count": _left_contact_count,
		"right_contact_count": _right_contact_count,
		"left_saturated": _left_saturated,
		"right_saturated": _right_saturated,
		"grounded": _left_contact_count + _right_contact_count > 0,
		"terrain_generation": _terrain_identity.x,
		"terrain_revision": _terrain_identity.y,
		"terrain_identity_valid": _terrain_identity_valid,
		"contacts": _contacts.duplicate(true),
		"quality_flags": _quality_flags.duplicate(),
		"last_step_usec": _last_step_usec,
		"peak_step_usec": _peak_step_usec,
	}


func _build_body() -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = "AuthoritativeChassisBody"
	body.mass = float(_dynamics["mass_kg"])
	body.inertia = _vector3(_dynamics["inertia_diagonal_kg_m2"])
	body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	body.center_of_mass = _vector3(_dynamics["center_of_mass_m"])
	body.linear_damp = float(_dynamics["linear_damp"])
	body.angular_damp = float(_dynamics["angular_damp"])
	body.can_sleep = bool(_dynamics["can_sleep"])
	body.continuous_cd = bool(_dynamics["continuous_collision_detection"])
	body.contact_monitor = true
	body.max_contacts_reported = 32
	body.collision_layer = _layer_mask(int(_descriptor["collision_layers"]["machine"]))
	body.collision_mask = _layer_mask(int(_descriptor["collision_layers"]["terrain"]))
	var shape_index := 0
	for shape_data in _dynamics["compound_shapes"]:
		var collision := CollisionShape3D.new()
		collision.name = "ChassisCollision_%d" % shape_index
		collision.position = _vector3(shape_data["center_m"])
		var box := BoxShape3D.new()
		box.size = _vector3(shape_data["size_m"])
		collision.shape = box
		body.add_child(collision)
		shape_index += 1
	return body


func _apply_track_forces() -> void:
	if not is_inside_tree() or get_world_3d() == null:
		_quality_flags.append("physics_space_unavailable")
		return
	var count := int(_tracks["traction_points_per_side"])
	var length := float(_tracks["contact_length_m"])
	var half_gauge := 0.5 * float(_tracks["gauge_m"])
	var result_left := _apply_track_side(-half_gauge, _left_command, count, length, "left")
	var result_right := _apply_track_side(half_gauge, _right_command, count, length, "right")
	_left_contact_count = int(result_left["contact_count"])
	_right_contact_count = int(result_right["contact_count"])
	_left_speed_m_s = float(result_left["speed_m_s"])
	_right_speed_m_s = float(result_right["speed_m_s"])
	_left_slip_ratio = float(result_left["slip_ratio"])
	_right_slip_ratio = float(result_right["slip_ratio"])
	_left_saturated = bool(result_left["saturated"])
	_right_saturated = bool(result_right["saturated"])
	if _left_contact_count > 0 and _right_contact_count > 0:
		_apply_differential_yaw_torque()


func _apply_differential_yaw_torque() -> void:
	var demand := 0.5 * (_right_command - _left_command)
	if is_zero_approx(demand):
		return
	var max_torque := (
		float(_tracks["max_drive_force_n"])
		* float(_tracks["gauge_m"])
		* 0.5
		* float(_tracks["yaw_torque_scale"])
	)
	var target_yaw_rate := (
		2.0 * demand * float(_tracks["max_belt_speed_m_s"])
		/ float(_tracks["gauge_m"])
	)
	var current_yaw_rate := _body.angular_velocity.dot(Vector3.UP)
	var torque := clampf(
		(target_yaw_rate - current_yaw_rate) * max_torque,
		-max_torque,
		max_torque
	)
	_body.apply_torque(Vector3.UP * torque)


func _apply_track_side(
	local_x: float,
	command: float,
	point_count: int,
	contact_length: float,
	side_name: String
) -> Dictionary:
	var contacts := 0
	var speed_sum := 0.0
	var slip_sum := 0.0
	var saturated := false
	var max_side_force := float(_tracks["max_drive_force_n"])
	var max_point_force := max_side_force / float(point_count)
	var friction_cap := (
		float(_tracks["friction"])
		* float(_dynamics["mass_kg"])
		* GRAVITY_M_S2
		/ float(2 * point_count)
	)
	for index in point_count:
		var alpha := (float(index) + 0.5) / float(point_count)
		var local_z := lerpf(-0.5 * contact_length, 0.5 * contact_length, alpha)
		var hit := _track_raycast(Vector3(local_x, 0.0, local_z))
		if hit.is_empty():
			continue
		contacts += 1
		var point := hit["position"] as Vector3
		var normal := (hit["normal"] as Vector3).normalized()
		var offset := point - _body.global_position
		var point_velocity := _body.linear_velocity + _body.angular_velocity.cross(offset)
		var forward := (-_body.global_basis.z).slide(normal).normalized()
		var lateral := _body.global_basis.x.slide(normal).normalized()
		if forward.length_squared() < 0.5 or lateral.length_squared() < 0.5:
			continue
		var longitudinal_speed := point_velocity.dot(forward)
		var target_speed := command * float(_tracks["max_belt_speed_m_s"])
		var speed_error := target_speed - longitudinal_speed
		var drive_force := speed_error * float(_tracks["traction_response_n_per_m_s"]) / float(point_count)
		if is_zero_approx(command):
			drive_force = clampf(
				-longitudinal_speed * float(_tracks["brake_force_n"]) / float(point_count),
				-max_point_force,
				max_point_force
			)
		var bounded_drive := clampf(drive_force, -minf(max_point_force, friction_cap), minf(max_point_force, friction_cap))
		if not is_equal_approx(bounded_drive, drive_force):
			saturated = true
		var lateral_force := clampf(
			-point_velocity.dot(lateral) * float(_tracks["lateral_resistance_n_per_m_s"]) / float(point_count),
			-friction_cap,
			friction_cap
		)
		_body.apply_force(forward * bounded_drive + lateral * lateral_force, offset)
		speed_sum += longitudinal_speed
		slip_sum += clampf(speed_error / maxf(absf(target_speed), MIN_SPEED_DENOMINATOR), -4.0, 4.0)
		_contacts.append({
			"body": "chassis",
			"other": String((hit["collider"] as Node).name),
			"point": point,
			"normal": normal,
			"impulse_n_s": 0.0,
			"penetration_m": 0.0,
			"track_side": side_name,
		})
	return {
		"contact_count": contacts,
		"speed_m_s": speed_sum / float(contacts) if contacts > 0 else 0.0,
		"slip_ratio": slip_sum / float(contacts) if contacts > 0 else 0.0,
		"saturated": saturated,
	}


func _track_raycast(local_point: Vector3) -> Dictionary:
	var center := _body.global_transform * local_point
	var ray_from := center + Vector3.UP * float(_tracks["probe_height_m"])
	var ray_to := center - Vector3.UP * float(_tracks["probe_depth_m"])
	var query := PhysicsRayQueryParameters3D.create(
		ray_from,
		ray_to,
		_layer_mask(int(_descriptor["collision_layers"]["terrain"]))
	)
	query.collide_with_areas = false
	query.exclude = [_body.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var collider: Variant = hit.get("collider")
	if hit.is_empty() or not collider is Node or _terrain_collider == null:
		return {}
	if not _terrain_collider.is_ancestor_of(collider as Node):
		return {}
	return hit


func _update_terrain_identity() -> void:
	_terrain_identity_valid = false
	if _terrain_world == null or _terrain_world.terrain_state == null or _terrain_collider == null:
		_terrain_identity = Vector2i(-1, -1)
		return
	_terrain_identity = Vector2i(
		_terrain_world.terrain_state.world_generation,
		_terrain_world.terrain_state.terrain_revision
	)
	_terrain_identity_valid = (
		_terrain_collider.available
		and _terrain_collider.get_applied_identity() == _terrain_identity
	)


func _clamp_body_velocity() -> void:
	if _body == null:
		return
	if not _body.linear_velocity.is_finite():
		_body.linear_velocity = Vector3.ZERO
		_quality_flags.append("invalid_linear_velocity_cleared")
	if not _body.angular_velocity.is_finite():
		_body.angular_velocity = Vector3.ZERO
		_quality_flags.append("invalid_angular_velocity_cleared")
	var max_linear := float(_dynamics["max_linear_speed_m_s"])
	var max_angular := float(_dynamics["max_angular_speed_rad_s"])
	if _body.linear_velocity.length() > max_linear:
		_body.linear_velocity = _body.linear_velocity.normalized() * max_linear
		_quality_flags.append("linear_speed_clamped")
	if _body.angular_velocity.length() > max_angular:
		_body.angular_velocity = _body.angular_velocity.normalized() * max_angular
		_quality_flags.append("angular_speed_clamped")


func _clear_tick_telemetry() -> void:
	_left_contact_count = 0
	_right_contact_count = 0
	_left_speed_m_s = 0.0
	_right_speed_m_s = 0.0
	_left_slip_ratio = 0.0
	_right_slip_ratio = 0.0
	_left_saturated = false
	_right_saturated = false
	_contacts.clear()
	_quality_flags.clear()


func _reject(message: String) -> bool:
	contract_error = message
	configured = false
	enabled = false
	return false


func _vector3(value: Variant) -> Vector3:
	var data := value as Array
	return Vector3(float(data[0]), float(data[1]), float(data[2]))


func _layer_mask(layer_number: int) -> int:
	return 1 << (layer_number - 1)

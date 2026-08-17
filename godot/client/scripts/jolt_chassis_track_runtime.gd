class_name JoltChassisTrackRuntime
extends Node3D

signal post_step_snapshot_captured(snapshot: Dictionary)

## Sole owner of the Jolt-authoritative five-body excavator rig. Consumers read
## copied snapshots; presentation nodes never drive these bodies or joints.

const GRAVITY_M_S2 := 9.80665
const MIN_SPEED_DENOMINATOR := 0.25
const JOINT_POSITION_GAIN := 4.0
const JOINT_LIMIT_MARGIN_RAD := 0.08
const MAX_PAYLOAD_MASS_KG := 5000.0
const BODY_NAMES := ["chassis", "upper", "boom", "arm", "bucket"]
const JOINT_NAMES := ["swing_joint", "boom_joint", "arm_joint", "bucket_joint"]

var configured := false
var enabled := false
var model_id := ""
var rig_id := ""
var rig_version := ""
var contract_error := ""

var _body: RigidBody3D
var _bodies: Dictionary = {}
var _joints: Dictionary = {}
var _body_descriptors: Dictionary = {}
var _joint_descriptors: Dictionary = {}
var _terrain_world: TerrainWorld
var _terrain_collider: TerrainCollider
var _descriptor: Dictionary = {}
var _dynamics: Dictionary = {}
var _tracks: Dictionary = {}
var _spawn_global_transform := Transform3D.IDENTITY
var _left_command := 0.0
var _right_command := 0.0
var _equipment_commands := Vector4.ZERO
var _joint_targets: Dictionary = {}
var _joint_command_velocities: Dictionary = {}
var _joint_command_accelerations: Dictionary = {}
var _joint_efforts: Dictionary = {}
var _joint_states: Array[Dictionary] = []
var _neutral_armed := false
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
var _pending_payload := {"mass_kg": 0.0, "center_of_mass_local": Vector3.ZERO, "identity": -1}
var _applied_payload := {"mass_kg": 0.0, "center_of_mass_local": Vector3.ZERO, "identity": -1}
var _post_step_snapshot: Dictionary = {}
var _command_identity := -1


func _ready() -> void:
	process_physics_priority = 0


func _physics_process(delta: float) -> void:
	if not configured or not has_body():
		return
	var started_usec := Time.get_ticks_usec()
	_physics_tick = Engine.get_physics_frames()
	_update_terrain_identity()
	_clear_tick_telemetry()
	_apply_pending_payload()
	_update_joint_actuators(delta)
	if enabled and _terrain_identity_valid:
		_apply_track_forces()
	elif enabled:
		_quality_flags.append("terrain_collider_unavailable")
	_clamp_body_velocities()
	_collect_equipment_contacts()
	if _left_contact_count + _right_contact_count == 0:
		_quality_flags.append("no_track_contact")
	_last_step_usec = Time.get_ticks_usec() - started_usec
	_peak_step_usec = maxi(_peak_step_usec, _last_step_usec)
	_capture_post_step_snapshot()
	post_step_snapshot_captured.emit(get_post_step_snapshot())


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
	_index_descriptors()
	if _body_descriptors.size() != BODY_NAMES.size() or _joint_descriptors.size() != JOINT_NAMES.size():
		return _reject("descriptor does not contain the complete articulated rig")
	if not _build_rig():
		_destroy_rig()
		return _reject("could not build complete Jolt articulated rig")
	configured = true
	enabled = true
	contract_error = ""
	_neutral_armed = false
	_update_terrain_identity()
	_capture_post_step_snapshot()
	return true


func teardown() -> void:
	configured = false
	enabled = false
	set_commands(0.0, 0.0)
	set_equipment_commands(Vector4.ZERO)
	_destroy_rig()
	_descriptor.clear()
	_dynamics.clear()
	_tracks.clear()
	_body_descriptors.clear()
	_joint_descriptors.clear()
	_contacts.clear()
	_quality_flags.clear()
	_joint_states.clear()
	_joint_targets.clear()
	_joint_command_velocities.clear()
	_joint_command_accelerations.clear()
	_joint_efforts.clear()
	_post_step_snapshot.clear()
	_pending_payload = {"mass_kg": 0.0, "center_of_mass_local": Vector3.ZERO, "identity": -1}
	_applied_payload = _pending_payload.duplicate(true)
	_terrain_identity = Vector2i(-1, -1)
	_terrain_identity_valid = false
	_neutral_armed = false
	_command_identity = -1
	_clear_tick_telemetry()


func set_enabled(value: bool) -> void:
	enabled = value and configured
	if not enabled:
		stop_motion()


func set_commands(left: float, right: float) -> void:
	_left_command = clampf(left, -1.0, 1.0) if is_finite(left) else 0.0
	_right_command = clampf(right, -1.0, 1.0) if is_finite(right) else 0.0


func set_equipment_commands(commands: Vector4, identity: int = -1) -> void:
	if identity >= 0 and identity < _command_identity:
		return
	if identity >= 0:
		_command_identity = identity
	if not _finite_vector4(commands):
		_equipment_commands = Vector4.ZERO
		_neutral_armed = false
		return
	_equipment_commands = Vector4(
		clampf(commands.x, -1.0, 1.0),
		clampf(commands.y, -1.0, 1.0),
		clampf(commands.z, -1.0, 1.0),
		clampf(commands.w, -1.0, 1.0),
	)


func set_bucket_payload(mass_kg: float, center_of_mass_local: Vector3, identity: int) -> bool:
	var latest_identity := maxi(int(_pending_payload["identity"]), int(_applied_payload["identity"]))
	if (
		not is_finite(mass_kg) or mass_kg < 0.0 or not center_of_mass_local.is_finite()
		or identity <= latest_identity or not _payload_center_in_bucket(center_of_mass_local)
	):
		return false
	_pending_payload = {
		"mass_kg": minf(mass_kg, MAX_PAYLOAD_MASS_KG),
		"center_of_mass_local": center_of_mass_local,
		"identity": identity,
	}
	return true


func _payload_center_in_bucket(center: Vector3) -> bool:
	var bucket_data := _body_descriptors.get("bucket", {}) as Dictionary
	if bucket_data.is_empty():
		return false
	var shape := bucket_data.get("shape", {}) as Dictionary
	if shape.is_empty():
		return false
	var shape_center := _vector3(shape["center_m"])
	var half_size := 0.5 * _vector3(shape["size_m"])
	var offset := center - shape_center
	return absf(offset.x) <= half_size.x and absf(offset.y) <= half_size.y and absf(offset.z) <= half_size.z


func stop_motion() -> void:
	set_commands(0.0, 0.0)
	set_equipment_commands(Vector4.ZERO)
	for joint_value in _joints.values():
		(joint_value as HingeJoint3D).set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, 0.0)


func reset(spawn_global_transform := Transform3D.IDENTITY) -> void:
	_spawn_global_transform = spawn_global_transform
	stop_motion()
	_destroy_rig()
	_joint_targets.clear()
	_joint_command_velocities.clear()
	_joint_command_accelerations.clear()
	_joint_efforts.clear()
	_joint_states.clear()
	_neutral_armed = false
	_command_identity = -1
	_applied_payload = {"mass_kg": 0.0, "center_of_mass_local": Vector3.ZERO, "identity": -1}
	_pending_payload = _applied_payload.duplicate(true)
	configured = _build_rig()
	enabled = configured
	if not configured:
		contract_error = "could not rebuild complete Jolt articulated rig"
	_clear_tick_telemetry()
	_capture_post_step_snapshot()


func has_body() -> bool:
	return (
		configured
		and _body != null
		and is_instance_valid(_body)
		and _body.is_inside_tree()
		and _bodies.size() == BODY_NAMES.size()
		and _joints.size() == JOINT_NAMES.size()
	)


func get_body_global_transform() -> Transform3D:
	return _body.global_transform if has_body() else Transform3D.IDENTITY


func get_post_step_snapshot() -> Dictionary:
	return _post_step_snapshot.duplicate(true)


func get_status_snapshot() -> Dictionary:
	var snapshot := get_post_step_snapshot()
	if snapshot.is_empty():
		snapshot = _empty_snapshot()
	snapshot["authority_mode"] = AuthorityProfile.JOLT_AUTHORITATIVE
	snapshot["configured"] = configured
	snapshot["enabled"] = enabled
	snapshot["model_id"] = model_id
	snapshot["rig_id"] = rig_id
	snapshot["rig_version"] = rig_version
	snapshot["contract_error"] = contract_error
	snapshot["peak_step_usec"] = _peak_step_usec
	return snapshot


func _index_descriptors() -> void:
	_body_descriptors.clear()
	_joint_descriptors.clear()
	for body_value in _descriptor.get("bodies", []):
		var body := body_value as Dictionary
		_body_descriptors[String(body.get("name", ""))] = body.duplicate(true)
	for joint_value in _descriptor.get("joints", []):
		var joint := joint_value as Dictionary
		_joint_descriptors[String(joint.get("name", ""))] = joint.duplicate(true)


func _build_rig() -> bool:
	var base_rest := _rows_to_transform((_body_descriptors["chassis"] as Dictionary)["rest_transform_godot"])
	var spawn_delta := _spawn_global_transform * base_rest.affine_inverse()
	for body_name in BODY_NAMES:
		var body_data := _body_descriptors[body_name] as Dictionary
		var body := _build_body(body_name, body_data)
		add_child(body)
		body.global_transform = spawn_delta * _rows_to_transform(body_data["rest_transform_godot"])
		_bodies[body_name] = body
	_body = _bodies["chassis"] as RigidBody3D
	for joint_name in JOINT_NAMES:
		if not _build_joint(joint_name, _joint_descriptors[joint_name] as Dictionary, spawn_delta):
			return false
	for joint_name in JOINT_NAMES:
		_joint_targets[joint_name] = 0.0
		_joint_command_velocities[joint_name] = 0.0
		_joint_command_accelerations[joint_name] = 0.0
		_joint_efforts[joint_name] = 0.0
	return true


func _build_body(body_name: String, body_data: Dictionary) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = "Authoritative%sBody" % body_name.capitalize()
	body.mass = float(body_data["mass_kg"])
	body.inertia = _vector3(body_data["inertia_diagonal_kg_m2"])
	body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	body.center_of_mass = _vector3(body_data["center_of_mass_m"])
	body.linear_damp = float(_dynamics["linear_damp"]) if body_name == "chassis" else 0.08
	body.angular_damp = float(_dynamics["angular_damp"]) if body_name == "chassis" else 0.18
	body.can_sleep = bool(_dynamics["can_sleep"])
	body.continuous_cd = bool(_dynamics["continuous_collision_detection"])
	body.contact_monitor = true
	body.max_contacts_reported = 32
	var machine_mask := _layer_mask(int(_descriptor["collision_layers"]["machine"]))
	var terrain_mask := _layer_mask(int(_descriptor["collision_layers"]["terrain"]))
	body.collision_layer = machine_mask
	# Provisional box proxies overlap at the imported rest pose. Until Phase 2
	# receives non-overlapping proxies, machine self-collision is explicitly off.
	body.collision_mask = (
		terrain_mask
		if String(_descriptor["self_collision_mode"]) == "disabled_provisional"
		else terrain_mask | machine_mask
	)
	var shape_data := body_data["shape"] as Dictionary
	var collision := CollisionShape3D.new()
	collision.name = "%sCollision" % body_name.capitalize()
	collision.position = _vector3(shape_data["center_m"])
	var box := BoxShape3D.new()
	box.size = _vector3(shape_data["size_m"])
	collision.shape = box
	body.add_child(collision)
	return body


func _build_joint(joint_name: String, joint_data: Dictionary, spawn_delta: Transform3D) -> bool:
	var parent_body := _bodies.get(String(joint_data["parent_body"])) as RigidBody3D
	var child_body := _bodies.get(String(joint_data["child_body"])) as RigidBody3D
	if parent_body == null or child_body == null:
		return false
	var joint := HingeJoint3D.new()
	joint.name = joint_name
	joint.node_a = NodePath("../%s" % parent_body.name)
	joint.node_b = NodePath("../%s" % child_body.name)
	joint.exclude_nodes_from_collision = not bool(joint_data["collide_connected"])
	if joint.exclude_nodes_from_collision:
		parent_body.add_collision_exception_with(child_body)
		child_body.add_collision_exception_with(parent_body)
	var parent_data := _body_descriptors[String(joint_data["parent_body"])] as Dictionary
	var parent_rest := _rows_to_transform(parent_data["rest_transform_godot"])
	var anchor := parent_rest * _rows_to_transform(joint_data["parent_anchor_godot"])
	var axis_world := (anchor.basis * _vector3(joint_data["axis"])).normalized()
	joint.global_transform = Transform3D(_basis_with_z_axis(axis_world), (spawn_delta * anchor).origin)
	var limits := joint_data["limit_rad"] as Array
	joint.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, float(limits[0]))
	joint.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, float(limits[1]))
	joint.set_flag(HingeJoint3D.FLAG_USE_LIMIT, String(joint_data["type"]) != "continuous_hinge")
	joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, 0.0)
	joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, 0.0)
	joint.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)
	add_child(joint)
	_joints[joint_name] = joint
	return true


func _update_joint_actuators(delta: float) -> void:
	if not enabled:
		_disable_joint_motors()
		return
	if not _neutral_armed:
		if _equipment_commands.length_squared() <= 0.000001:
			_neutral_armed = true
		else:
			_disable_joint_motors()
			_quality_flags.append("equipment_neutral_rearm_required")
			return
	var commands := [_equipment_commands.x, _equipment_commands.y, _equipment_commands.z, _equipment_commands.w]
	for index in JOINT_NAMES.size():
		var joint_name: String = JOINT_NAMES[index]
		var joint_data := _joint_descriptors[joint_name] as Dictionary
		var joint := _joints[joint_name] as HingeJoint3D
		var actuator := joint_data["actuator"] as Dictionary
		var max_velocity := float(actuator["max_velocity_rad_s"])
		var desired_velocity := float(commands[index]) * max_velocity
		var actual_position := _joint_position(joint_data)
		var limits := joint_data["limit_rad"] as Array
		if String(joint_data["type"]) != "continuous_hinge":
			var lower := float(limits[0])
			var upper := float(limits[1])
			if desired_velocity < 0.0 and actual_position < lower + JOINT_LIMIT_MARGIN_RAD:
				desired_velocity *= clampf((actual_position - lower) / JOINT_LIMIT_MARGIN_RAD, 0.0, 1.0)
			if desired_velocity > 0.0 and actual_position > upper - JOINT_LIMIT_MARGIN_RAD:
				desired_velocity *= clampf((upper - actual_position) / JOINT_LIMIT_MARGIN_RAD, 0.0, 1.0)
		var current_velocity_command := float(_joint_command_velocities.get(joint_name, 0.0))
		var max_acceleration := float(actuator["max_acceleration_rad_s2"])
		var desired_acceleration := clampf(
			(desired_velocity - current_velocity_command) / maxf(delta, 0.000001),
			-max_acceleration, max_acceleration,
		)
		var shaped_acceleration := move_toward(
			float(_joint_command_accelerations.get(joint_name, 0.0)), desired_acceleration,
			float(actuator["max_jerk_rad_s3"]) * delta,
		)
		_joint_command_accelerations[joint_name] = shaped_acceleration
		var shaped_velocity := move_toward(
			current_velocity_command, desired_velocity, absf(shaped_acceleration) * delta,
		)
		_joint_command_velocities[joint_name] = shaped_velocity
		var target_position := float(_joint_targets.get(joint_name, actual_position)) + shaped_velocity * delta
		if String(joint_data["type"]) != "continuous_hinge":
			target_position = clampf(target_position, float(limits[0]), float(limits[1]))
		else:
			target_position = wrapf(target_position, -PI, PI)
		_joint_targets[joint_name] = target_position
		var motor_velocity := clampf(wrapf(target_position - actual_position, -PI, PI) * JOINT_POSITION_GAIN, -max_velocity, max_velocity)
		if joint_name != "swing_joint":
			motor_velocity *= clampf(1.0 - 0.45 * float(_applied_payload["mass_kg"]) / MAX_PAYLOAD_MASS_KG, 0.55, 1.0)
		var actual_velocity := _joint_velocity(joint_data)
		var effort := clampf(
			(motor_velocity - actual_velocity) * float(actuator["damping"]),
			-float(actuator["max_torque_nm"]), float(actuator["max_torque_nm"]),
		)
		_joint_efforts[joint_name] = effort
		# HingeJoint3D's positive motor direction is opposite the declared
		# right-handed axis used by the rig, visual manifest and truth contract.
		joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, -motor_velocity)
		joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, absf(effort) * delta)
		joint.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)


func _disable_joint_motors() -> void:
	_joint_efforts.clear()
	for joint_value in _joints.values():
		var joint := joint_value as HingeJoint3D
		joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, 0.0)
		joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, 0.0)


func _apply_pending_payload() -> void:
	if _pending_payload == _applied_payload:
		return
	var bucket := _bodies.get("bucket") as RigidBody3D
	var bucket_data := _body_descriptors.get("bucket", {}) as Dictionary
	if bucket == null or bucket_data.is_empty():
		return
	var base_mass := float(bucket_data["mass_kg"])
	var payload_mass := float(_pending_payload["mass_kg"])
	var base_center := _vector3(bucket_data["center_of_mass_m"])
	var payload_center := _pending_payload["center_of_mass_local"] as Vector3
	bucket.mass = base_mass + payload_mass
	bucket.center_of_mass = (
		(base_center * base_mass + payload_center * payload_mass) / (base_mass + payload_mass)
		if payload_mass > 0.0 else base_center
	)
	_applied_payload = _pending_payload.duplicate(true)
	bucket.sleeping = false


func _capture_post_step_snapshot() -> void:
	var body_states: Array[Dictionary] = []
	for body_name in BODY_NAMES:
		var body := _bodies.get(body_name) as RigidBody3D
		if body != null:
			body_states.append({
				"name": body_name, "transform": body.global_transform,
				"linear_velocity": body.linear_velocity,
				"angular_velocity": body.angular_velocity, "sleeping": body.sleeping,
			})
	_joint_states.clear()
	for joint_name in JOINT_NAMES:
		var joint_data := _joint_descriptors.get(joint_name, {}) as Dictionary
		if joint_data.is_empty():
			continue
		var position := _joint_position(joint_data)
		var commanded_velocity := float(_joint_command_velocities.get(joint_name, 0.0))
		_joint_states.append({
			"name": joint_name,
			"target_position_rad": float(_joint_targets.get(joint_name, position)),
			"target_velocity_rad_s": commanded_velocity,
			"position_rad": position,
			"velocity_rad_s": _joint_velocity(joint_data),
			"effort_n": float(_joint_efforts.get(joint_name, 0.0)),
		})
	var chassis := _bodies.get("chassis") as RigidBody3D
	_post_step_snapshot = {
		"physics_tick": _physics_tick,
		"body_transform": chassis.global_transform if chassis != null else Transform3D.IDENTITY,
		"linear_velocity": chassis.linear_velocity if chassis != null else Vector3.ZERO,
		"angular_velocity": chassis.angular_velocity if chassis != null else Vector3.ZERO,
		"sleeping": chassis.sleeping if chassis != null else false,
		"bodies": body_states, "joints": _joint_states.duplicate(true),
		"payload": _applied_payload.duplicate(true), "neutral_armed": _neutral_armed,
		"command_identity": _command_identity,
		"left_command": _left_command, "right_command": _right_command,
		"left_speed_mps": _left_speed_m_s, "right_speed_mps": _right_speed_m_s,
		"left_slip_ratio": _left_slip_ratio, "right_slip_ratio": _right_slip_ratio,
		"left_contact_count": _left_contact_count, "right_contact_count": _right_contact_count,
		"left_saturated": _left_saturated, "right_saturated": _right_saturated,
		"grounded": _left_contact_count + _right_contact_count > 0,
		"terrain_generation": _terrain_identity.x, "terrain_revision": _terrain_identity.y,
		"terrain_identity_valid": _terrain_identity_valid,
		"contacts": _contacts.duplicate(true), "quality_flags": _quality_flags.duplicate(),
		"last_step_usec": _last_step_usec,
	}


func _joint_position(joint_data: Dictionary) -> float:
	var parent := _bodies.get(String(joint_data["parent_body"])) as RigidBody3D
	var child := _bodies.get(String(joint_data["child_body"])) as RigidBody3D
	if parent == null or child == null:
		return 0.0
	var parent_data := _body_descriptors[String(joint_data["parent_body"])] as Dictionary
	var child_data := _body_descriptors[String(joint_data["child_body"])] as Dictionary
	var rest_relation := _rows_to_transform(parent_data["rest_transform_godot"]).affine_inverse() * _rows_to_transform(child_data["rest_transform_godot"])
	var current_relation := parent.global_transform.affine_inverse() * child.global_transform
	var rotation := Quaternion((rest_relation.basis.inverse() * current_relation.basis).orthonormalized()).normalized()
	if rotation.length_squared() <= 0.000001:
		return 0.0
	var axis := _vector3(joint_data["axis"]).normalized()
	var projected := Vector3(rotation.x, rotation.y, rotation.z).dot(axis)
	return wrapf(2.0 * atan2(projected, rotation.w), -PI, PI)


func _joint_velocity(joint_data: Dictionary) -> float:
	var parent := _bodies.get(String(joint_data["parent_body"])) as RigidBody3D
	var child := _bodies.get(String(joint_data["child_body"])) as RigidBody3D
	if parent == null or child == null:
		return 0.0
	var child_anchor := _rows_to_transform(joint_data["child_anchor_godot"])
	var axis_world := (child.global_basis * child_anchor.basis * _vector3(joint_data["axis"])).normalized()
	return (child.angular_velocity - parent.angular_velocity).dot(axis_world)


func _collect_equipment_contacts() -> void:
	for body_name in ["upper", "boom", "arm", "bucket"]:
		var body := _bodies.get(body_name) as RigidBody3D
		if body == null:
			continue
		for other in body.get_colliding_bodies():
			if other is Node and _terrain_collider != null and _terrain_collider.is_ancestor_of(other as Node):
				_contacts.append({"body": body_name, "other": String((other as Node).name), "point": body.global_position, "normal": Vector3.UP, "impulse_n_s": 0.0, "penetration_m": 0.0})
				if not _quality_flags.has("jolt_contact_manifold_unavailable"):
					_quality_flags.append("jolt_contact_manifold_unavailable")


func _destroy_rig() -> void:
	for joint_value in _joints.values():
		var joint := joint_value as HingeJoint3D
		joint.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, false)
		joint.queue_free() if joint.is_inside_tree() else joint.free()
	_joints.clear()
	for body_value in _bodies.values():
		var body := body_value as RigidBody3D
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
		body.collision_layer = 0
		body.collision_mask = 0
		body.freeze = true
		body.queue_free() if body.is_inside_tree() else body.free()
	_bodies.clear()
	_body = null


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
	var max_torque := float(_tracks["max_drive_force_n"]) * float(_tracks["gauge_m"]) * 0.5 * float(_tracks["yaw_torque_scale"])
	var target_yaw_rate := 2.0 * demand * float(_tracks["max_belt_speed_m_s"]) / float(_tracks["gauge_m"])
	var torque := clampf((target_yaw_rate - _body.angular_velocity.dot(Vector3.UP)) * max_torque, -max_torque, max_torque)
	_body.apply_torque(Vector3.UP * torque)


func _apply_track_side(local_x: float, command: float, point_count: int, contact_length: float, side_name: String) -> Dictionary:
	var contacts := 0
	var speed_sum := 0.0
	var slip_sum := 0.0
	var saturated := false
	var max_side_force := float(_tracks["max_drive_force_n"])
	var max_point_force := max_side_force / float(point_count)
	var friction_cap := float(_tracks["friction"]) * float(_dynamics["mass_kg"]) * GRAVITY_M_S2 / float(2 * point_count)
	for index in point_count:
		var alpha := (float(index) + 0.5) / float(point_count)
		var hit := _track_raycast(Vector3(local_x, 0.0, lerpf(-0.5 * contact_length, 0.5 * contact_length, alpha)))
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
			drive_force = clampf(-longitudinal_speed * float(_tracks["brake_force_n"]) / float(point_count), -max_point_force, max_point_force)
		var bounded_drive := clampf(drive_force, -minf(max_point_force, friction_cap), minf(max_point_force, friction_cap))
		if not is_equal_approx(bounded_drive, drive_force):
			saturated = true
		var lateral_force := clampf(-point_velocity.dot(lateral) * float(_tracks["lateral_resistance_n_per_m_s"]) / float(point_count), -friction_cap, friction_cap)
		_body.apply_force(forward * bounded_drive + lateral * lateral_force, offset)
		speed_sum += longitudinal_speed
		slip_sum += clampf(speed_error / maxf(absf(target_speed), MIN_SPEED_DENOMINATOR), -4.0, 4.0)
		_contacts.append({"body": "chassis", "other": String((hit["collider"] as Node).name), "point": point, "normal": normal, "impulse_n_s": 0.0, "penetration_m": 0.0, "track_side": side_name})
	return {"contact_count": contacts, "speed_m_s": speed_sum / float(contacts) if contacts > 0 else 0.0, "slip_ratio": slip_sum / float(contacts) if contacts > 0 else 0.0, "saturated": saturated}


func _track_raycast(local_point: Vector3) -> Dictionary:
	var center := _body.global_transform * local_point
	var query := PhysicsRayQueryParameters3D.create(center + Vector3.UP * float(_tracks["probe_height_m"]), center - Vector3.UP * float(_tracks["probe_depth_m"]), _layer_mask(int(_descriptor["collision_layers"]["terrain"])))
	query.collide_with_areas = false
	query.exclude = [_body.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var collider: Variant = hit.get("collider")
	if hit.is_empty() or not collider is Node or _terrain_collider == null or not _terrain_collider.is_ancestor_of(collider as Node):
		return {}
	return hit


func _update_terrain_identity() -> void:
	_terrain_identity_valid = false
	if _terrain_world == null or _terrain_world.terrain_state == null or _terrain_collider == null:
		_terrain_identity = Vector2i(-1, -1)
		return
	_terrain_identity = Vector2i(_terrain_world.terrain_state.world_generation, _terrain_world.terrain_state.terrain_revision)
	_terrain_identity_valid = _terrain_collider.available and _terrain_collider.get_applied_identity() == _terrain_identity


func _clamp_body_velocities() -> void:
	for body_name in BODY_NAMES:
		var body := _bodies.get(body_name) as RigidBody3D
		if body == null:
			continue
		if not body.linear_velocity.is_finite():
			body.linear_velocity = Vector3.ZERO
			_quality_flags.append("invalid_%s_linear_velocity_cleared" % body_name)
			if body_name == "chassis":
				_quality_flags.append("invalid_linear_velocity_cleared")
		if not body.angular_velocity.is_finite():
			body.angular_velocity = Vector3.ZERO
			_quality_flags.append("invalid_%s_angular_velocity_cleared" % body_name)
			if body_name == "chassis":
				_quality_flags.append("invalid_angular_velocity_cleared")
		var speed_scale := 2.0 if body_name != "chassis" else 1.0
		var max_linear := float(_dynamics["max_linear_speed_m_s"]) * speed_scale
		var max_angular := float(_dynamics["max_angular_speed_rad_s"]) * speed_scale
		if body.linear_velocity.length() > max_linear:
			body.linear_velocity = body.linear_velocity.normalized() * max_linear
			_quality_flags.append("%s_linear_speed_clamped" % body_name)
		if body.angular_velocity.length() > max_angular:
			body.angular_velocity = body.angular_velocity.normalized() * max_angular
			_quality_flags.append("%s_angular_speed_clamped" % body_name)


func _clamp_body_velocity() -> void:
	# Phase 1 test seam retained while the implementation now clamps every body.
	_clamp_body_velocities()
	_capture_post_step_snapshot()


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


func _empty_snapshot() -> Dictionary:
	return {"physics_tick": _physics_tick, "body_transform": Transform3D.IDENTITY, "linear_velocity": Vector3.ZERO, "angular_velocity": Vector3.ZERO, "sleeping": false, "bodies": [], "joints": [], "payload": _applied_payload.duplicate(true), "neutral_armed": false, "contacts": [], "quality_flags": ["authoritative_runtime_unavailable"]}


func _reject(message: String) -> bool:
	contract_error = message
	configured = false
	enabled = false
	return false


func _rows_to_transform(value: Variant) -> Transform3D:
	var rows := value as Array
	return Transform3D(Basis(Vector3(float(rows[0][0]), float(rows[1][0]), float(rows[2][0])), Vector3(float(rows[0][1]), float(rows[1][1]), float(rows[2][1])), Vector3(float(rows[0][2]), float(rows[1][2]), float(rows[2][2]))), Vector3(float(rows[0][3]), float(rows[1][3]), float(rows[2][3])))


func _basis_with_z_axis(axis: Vector3) -> Basis:
	var z_axis := axis.normalized()
	var helper := Vector3.UP if absf(z_axis.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var x_axis := helper.cross(z_axis).normalized()
	return Basis(x_axis, z_axis.cross(x_axis).normalized(), z_axis)


func _vector3(value: Variant) -> Vector3:
	var data := value as Array
	return Vector3(float(data[0]), float(data[1]), float(data[2]))


func _finite_vector4(value: Vector4) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z) and is_finite(value.w)


func _layer_mask(layer_number: int) -> int:
	return 1 << (layer_number - 1)

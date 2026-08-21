class_name KinematicArticulationState
extends RefCounted

const JOINT_NAMES := ["swing_joint", "boom_joint", "arm_joint", "bucket_joint"]
const BODY_NAMES := ["chassis", "upper", "boom", "arm", "bucket"]
const MAX_PAYLOAD_MASS_KG := 5000.0
const JOINT_LIMIT_MARGIN_RAD := 0.08
# Saturating digging resistance: at full cut engagement the work-equipment
# joints keep this fraction of their commanded dig speed, mirroring hydraulic
# relief instead of a geometric wall.
const MIN_CUT_SPEED_SCALE := 0.15

var configured := false
var neutral_armed := false
var command_identity := -1
var payload_identity := -1
var payload_mass_kg := 0.0
var payload_center_of_mass_local := Vector3.ZERO
var motion_load_factor := 1.0
var cut_engagement := 0.0

var _commands := Vector4.ZERO
var _body_descriptors: Dictionary = {}
var _joint_descriptors: Dictionary = {}
var _positions: Dictionary = {}
var _velocities: Dictionary = {}
var _accelerations: Dictionary = {}
var _targets: Dictionary = {}
var _accepted_frames: Dictionary = {}


func configure(descriptor: Dictionary, chassis_transform: Transform3D) -> bool:
	reset()
	for body_value in descriptor.get("bodies", []):
		if body_value is Dictionary:
			var body := body_value as Dictionary
			_body_descriptors[String(body.get("name", ""))] = body.duplicate(true)
	for joint_value in descriptor.get("joints", []):
		if joint_value is Dictionary:
			var joint := joint_value as Dictionary
			_joint_descriptors[String(joint.get("name", ""))] = joint.duplicate(true)
	if _body_descriptors.size() != BODY_NAMES.size() or _joint_descriptors.size() != JOINT_NAMES.size():
		reset()
		return false
	for joint_name in JOINT_NAMES:
		_positions[joint_name] = 0.0
		_velocities[joint_name] = 0.0
		_accelerations[joint_name] = 0.0
		_targets[joint_name] = 0.0
	_accepted_frames = _compute_frames(chassis_transform, _positions)
	configured = _accepted_frames.size() == BODY_NAMES.size()
	return configured


func reset() -> void:
	configured = false
	neutral_armed = false
	command_identity = -1
	payload_identity = -1
	payload_mass_kg = 0.0
	payload_center_of_mass_local = Vector3.ZERO
	motion_load_factor = 1.0
	cut_engagement = 0.0
	_commands = Vector4.ZERO
	_body_descriptors.clear()
	_joint_descriptors.clear()
	_positions.clear()
	_velocities.clear()
	_accelerations.clear()
	_targets.clear()
	_accepted_frames.clear()


func reset_motion(chassis_transform: Transform3D) -> void:
	_commands = Vector4.ZERO
	neutral_armed = false
	command_identity = -1
	cut_engagement = 0.0
	for joint_name in JOINT_NAMES:
		_positions[joint_name] = 0.0
		_velocities[joint_name] = 0.0
		_accelerations[joint_name] = 0.0
		_targets[joint_name] = 0.0
	_accepted_frames = _compute_frames(chassis_transform, _positions)


func set_commands(commands: Vector4, identity: int = -1) -> bool:
	if identity >= 0 and identity < command_identity:
		return false
	if identity >= 0:
		command_identity = identity
	if not commands.is_finite():
		_commands = Vector4.ZERO
		neutral_armed = false
		return false
	_commands = Vector4(
		clampf(commands.x, -1.0, 1.0),
		clampf(commands.y, -1.0, 1.0),
		clampf(commands.z, -1.0, 1.0),
		clampf(commands.w, -1.0, 1.0),
	)
	return true


func set_payload(mass_kg: float, center_of_mass_local: Vector3, identity: int) -> bool:
	if (
		identity <= payload_identity or not is_finite(mass_kg) or mass_kg < 0.0
		or not center_of_mass_local.is_finite()
	):
		return false
	payload_identity = identity
	payload_mass_kg = minf(mass_kg, MAX_PAYLOAD_MASS_KG)
	payload_center_of_mass_local = center_of_mass_local
	motion_load_factor = clampf(1.0 - 0.45 * payload_mass_kg / MAX_PAYLOAD_MASS_KG, 0.55, 1.0)
	return true


func set_cut_resistance(engagement: float) -> void:
	cut_engagement = clampf(engagement if is_finite(engagement) else 0.0, 0.0, 1.0)


func propose_step(delta: float, chassis_transform: Transform3D, enabled: bool) -> Dictionary:
	if not configured or delta <= 0.0 or not is_finite(delta) or not chassis_transform.is_finite():
		return {}
	var commands := [_commands.x, _commands.y, _commands.z, _commands.w]
	if not enabled:
		commands = [0.0, 0.0, 0.0, 0.0]
	if not neutral_armed:
		if _commands.length_squared() <= 0.000001:
			neutral_armed = true
		else:
			return _stationary_proposal(chassis_transform, "equipment_neutral_rearm_required")
	var positions := _positions.duplicate(true)
	var velocities := _velocities.duplicate(true)
	var accelerations := _accelerations.duplicate(true)
	var targets := _targets.duplicate(true)
	for index in JOINT_NAMES.size():
		var joint_name: String = JOINT_NAMES[index]
		var joint := _joint_descriptors[joint_name] as Dictionary
		var actuator := joint["actuator"] as Dictionary
		var load_factor := 1.0 if joint_name == "swing_joint" else motion_load_factor
		var max_velocity := float(actuator["max_velocity_rad_s"]) * load_factor
		var desired_velocity := float(commands[index]) * max_velocity
		# Dig-direction commands (negative per rig convention) slow down with
		# cut engagement, flooring at MIN_CUT_SPEED_SCALE — resistance only
		# ever slows the stroke, never stalls it. Retraction and swing stay at
		# full authority so the operator can always back out of the hole.
		if joint_name != "swing_joint" and cut_engagement > 0.0 and desired_velocity < 0.0:
			desired_velocity *= lerpf(1.0, MIN_CUT_SPEED_SCALE, cut_engagement)
		var position := float(_positions[joint_name])
		var limits := joint["limit_rad"] as Array
		if String(joint["type"]) != "continuous_hinge":
			var lower := float(limits[0])
			var upper := float(limits[1])
			if desired_velocity < 0.0 and position < lower + JOINT_LIMIT_MARGIN_RAD:
				desired_velocity *= clampf((position - lower) / JOINT_LIMIT_MARGIN_RAD, 0.0, 1.0)
			if desired_velocity > 0.0 and position > upper - JOINT_LIMIT_MARGIN_RAD:
				desired_velocity *= clampf((upper - position) / JOINT_LIMIT_MARGIN_RAD, 0.0, 1.0)
		var current_velocity := float(_velocities[joint_name])
		var max_acceleration := float(actuator["max_acceleration_rad_s2"]) * load_factor
		var desired_acceleration := clampf(
			(desired_velocity - current_velocity) / delta,
			-max_acceleration,
			max_acceleration,
		)
		var acceleration := move_toward(
			float(_accelerations[joint_name]),
			desired_acceleration,
			float(actuator["max_jerk_rad_s3"]) * load_factor * delta,
		)
		var velocity := move_toward(current_velocity, desired_velocity, maxf(absf(acceleration), 0.000001) * delta)
		var target := float(_targets[joint_name]) + velocity * delta
		if String(joint["type"]) == "continuous_hinge":
			target = wrapf(target, -PI, PI)
		else:
			target = clampf(target, float(limits[0]), float(limits[1]))
		positions[joint_name] = target
		velocities[joint_name] = velocity
		accelerations[joint_name] = acceleration
		targets[joint_name] = target
	return {
		"positions": positions,
		"velocities": velocities,
		"accelerations": accelerations,
		"targets": targets,
		"frames": _compute_frames(chassis_transform, positions),
		"quality_flags": [],
	}


func accept_step(proposal: Dictionary, accepted_fraction: float) -> bool:
	if proposal.is_empty():
		return false
	var fraction := clampf(accepted_fraction, 0.0, 1.0)
	var proposed_positions := proposal.get("positions", {}) as Dictionary
	var proposed_velocities := proposal.get("velocities", {}) as Dictionary
	var proposed_accelerations := proposal.get("accelerations", {}) as Dictionary
	var proposed_targets := proposal.get("targets", {}) as Dictionary
	for joint_name in JOINT_NAMES:
		var previous_position := float(_positions[joint_name])
		_positions[joint_name] = lerpf(previous_position, float(proposed_positions[joint_name]), fraction)
		_velocities[joint_name] = float(proposed_velocities[joint_name]) * fraction
		_accelerations[joint_name] = float(proposed_accelerations[joint_name]) * fraction
		_targets[joint_name] = lerpf(previous_position, float(proposed_targets[joint_name]), fraction)
	var proposed_frames := proposal.get("frames", {}) as Dictionary
	if fraction >= 0.999999:
		_accepted_frames = proposed_frames.duplicate(true)
	else:
		var chassis_transform := proposed_frames.get("base_link", Transform3D.IDENTITY) as Transform3D
		_accepted_frames = _compute_frames(chassis_transform, _positions)
	return true


func accepted_frames() -> Dictionary:
	return _accepted_frames.duplicate(true)


func joint_states() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for joint_name in JOINT_NAMES:
		result.append({
			"name": joint_name,
			"target_position_rad": float(_targets.get(joint_name, 0.0)),
			"target_velocity_rad_s": float(_velocities.get(joint_name, 0.0)),
			"position_rad": float(_positions.get(joint_name, 0.0)),
			"velocity_rad_s": float(_velocities.get(joint_name, 0.0)),
			"acceleration_rad_s2": float(_accelerations.get(joint_name, 0.0)),
			"effort_n": 0.0,
		})
	return result


func payload_snapshot() -> Dictionary:
	return {
		"mass_kg": payload_mass_kg,
		"center_of_mass_local": payload_center_of_mass_local,
		"identity": payload_identity,
		"motion_load_factor": motion_load_factor,
		"cut_engagement": cut_engagement,
	}


func _stationary_proposal(chassis_transform: Transform3D, flag: String) -> Dictionary:
	return {
		"positions": _positions.duplicate(true),
		"velocities": _velocities.duplicate(true),
		"accelerations": _accelerations.duplicate(true),
		"targets": _targets.duplicate(true),
		"frames": _compute_frames(chassis_transform, _positions),
		"quality_flags": [flag],
	}


func _compute_frames(chassis_transform: Transform3D, positions: Dictionary) -> Dictionary:
	var frames := {"base_link": chassis_transform}
	var body_transforms := {"chassis": chassis_transform}
	for joint_name in JOINT_NAMES:
		var joint := _joint_descriptors.get(joint_name, {}) as Dictionary
		if joint.is_empty():
			return {}
		var parent_name := String(joint["parent_body"])
		var child_name := String(joint["child_body"])
		var parent_transform := body_transforms.get(parent_name) as Transform3D
		var parent_anchor := _rows_to_transform(joint["parent_anchor_godot"])
		var child_anchor := _rows_to_transform(joint["child_anchor_godot"])
		var rotation := Transform3D(Basis(_vector3(joint["axis"]).normalized(), float(positions[joint_name])), Vector3.ZERO)
		var child_transform := parent_transform * parent_anchor * rotation * child_anchor.affine_inverse()
		body_transforms[child_name] = child_transform
		frames[String(joint["frame"])] = child_transform
	return frames


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


func _vector3(value: Variant) -> Vector3:
	var data := value as Array
	return Vector3(float(data[0]), float(data[1]), float(data[2]))

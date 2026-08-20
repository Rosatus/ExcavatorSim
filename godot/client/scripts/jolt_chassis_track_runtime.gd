class_name JoltChassisTrackRuntime
extends Node3D

signal post_step_snapshot_captured(snapshot: Dictionary)

## Owns one dynamic Jolt chassis plus a bounded kinematic work-equipment chain.
## Consumers read copied snapshots; queries and presentation never drive bodies.

const GRAVITY_M_S2 := 9.80665
const MIN_SPEED_DENOMINATOR := 0.25
const MAX_PAYLOAD_MASS_KG := 5000.0
const BODY_NAMES := ["chassis", "upper", "boom", "arm", "bucket"]
const JOINT_NAMES := ["swing_joint", "boom_joint", "arm_joint", "bucket_joint"]
const SUPPORT_FORCE_PER_BLOCKED_M_N := 240000.0
const MAX_SUPPORT_FORCE_N := 180000.0
const MAX_SUPPORT_TORQUE_NM := 320000.0
const SUPPORT_REQUEST_LIFETIME_TICKS := 2
const MAX_SUPPORT_FORCE_DELTA_N_PER_TICK := 30000.0
const MAX_SUPPORT_TORQUE_DELTA_NM_PER_TICK := 60000.0
const MAX_SUPPORT_DURATION_TICKS := 45
const MAX_SUPPORT_HEAVE_SPEED_M_S := 0.8
const MAX_SUPPORT_TILT_RATE_RAD_S := 0.65
const MIN_SUPPORT_NORMAL_UP_DOT := 0.2
const MIN_SUPPORT_INTO_SURFACE_M := 0.001
const SUPPORT_FORCE_SMOOTHING_ALPHA := 0.35
const MIN_SUPPORT_LOAD_TO_RELEASE_HULL_RATIO := 0.72
const MAX_SUPPORT_LOAD_TO_RESTORE_HULL_RATIO := 0.32
const SUPPORT_READY_TICKS_TO_RELEASE_HULL := 3
const SUPPORT_LOSS_TICKS_TO_RESTORE_HULL := 3

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
var _articulation := KinematicArticulationState.new()
var _bucket_sweeper := BucketProxySweeper.new()
var _soil_contract: Dictionary = {}
var _physics_tick := 0
var _terrain_identity := Vector2i(-1, -1)
var _terrain_identity_valid := false
var _left_contact_count := 0
var _right_contact_count := 0
var _left_speed_m_s := 0.0
var _right_speed_m_s := 0.0
var _left_slip_ratio := 0.0
var _right_slip_ratio := 0.0
var _left_support_load_n := 0.0
var _right_support_load_n := 0.0
var _previous_left_support_load_n := 0.0
var _previous_right_support_load_n := 0.0
var _previous_probe_support_loads: Dictionary = {}
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
var _authority_epoch := ""
var _bucket_motion_sequence := 0
var _bucket_query: Dictionary = {}
var _queued_support_wrench: Dictionary = {}
var _applied_support_wrench: Dictionary = {}
var _support_contact_ticks := 0
var _support_contact_observed := false
var _last_support_force := Vector3.ZERO
var _last_support_torque := Vector3.ZERO
var _last_applied_support_request_id := ""
var _support_wrench_apply_count := 0
var _retirement_queued := false
var _hull_terrain_collision_released := false
var _support_ready_ticks := 0
var _support_loss_ticks := 0
var _hull_collision_switch_count := 0
var _smoothed_support_normal := Vector3.UP


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
	_apply_queued_support_wrench()
	_update_joint_actuators(delta)
	if enabled and _terrain_identity_valid:
		_apply_track_forces()
	elif enabled:
		_set_hull_terrain_collision_released(false)
		_quality_flags.append("terrain_collider_unavailable")
	_clamp_body_velocities()
	_collect_bucket_query_contacts()
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
		return _reject("descriptor does not contain the complete kinematic chain")
	if not _build_rig():
		_destroy_rig()
		return _reject("could not build hybrid Jolt rig")
	configured = true
	enabled = true
	contract_error = ""
	_authority_epoch = "%s:%d" % [model_id, Time.get_ticks_usec()]
	_update_terrain_identity()
	_set_invalid_bucket_query("bucket_query_not_sampled")
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
	_articulation.reset()
	_bucket_sweeper.reset()
	_soil_contract.clear()
	_post_step_snapshot.clear()
	_pending_payload = {"mass_kg": 0.0, "center_of_mass_local": Vector3.ZERO, "identity": -1}
	_applied_payload = _pending_payload.duplicate(true)
	_terrain_identity = Vector2i(-1, -1)
	_terrain_identity_valid = false
	_command_identity = -1
	_authority_epoch = ""
	_bucket_motion_sequence = 0
	_bucket_query.clear()
	_queued_support_wrench.clear()
	_applied_support_wrench.clear()
	_support_wrench_apply_count = 0
	_hull_terrain_collision_released = false
	_previous_left_support_load_n = 0.0
	_previous_right_support_load_n = 0.0
	_previous_probe_support_loads.clear()
	_support_ready_ticks = 0
	_support_loss_ticks = 0
	_hull_collision_switch_count = 0
	_smoothed_support_normal = Vector3.UP
	_reset_support_response(true)
	_clear_tick_telemetry()


func retire_deferred() -> void:
	if _retirement_queued or is_queued_for_deletion():
		return
	_retirement_queued = true
	call_deferred("_complete_deferred_retirement")


func _complete_deferred_retirement() -> void:
	teardown()
	queue_free()


func set_enabled(value: bool) -> void:
	enabled = value and configured
	if not enabled:
		stop_motion()
		_set_hull_terrain_collision_released(false)


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
		_articulation.neutral_armed = false
		return
	_equipment_commands = Vector4(
		clampf(commands.x, -1.0, 1.0),
		clampf(commands.y, -1.0, 1.0),
		clampf(commands.z, -1.0, 1.0),
		clampf(commands.w, -1.0, 1.0),
	)
	_articulation.set_commands(_equipment_commands, identity)


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


func reset(spawn_global_transform := Transform3D.IDENTITY) -> void:
	_spawn_global_transform = spawn_global_transform
	stop_motion()
	_destroy_rig()
	_command_identity = -1
	_applied_payload = {"mass_kg": 0.0, "center_of_mass_local": Vector3.ZERO, "identity": -1}
	_pending_payload = _applied_payload.duplicate(true)
	configured = _build_rig()
	enabled = configured
	if not configured:
		contract_error = "could not rebuild hybrid Jolt rig"
	_authority_epoch = "%s:%d" % [model_id, Time.get_ticks_usec()]
	_bucket_motion_sequence = 0
	_update_terrain_identity()
	_set_invalid_bucket_query("bucket_query_not_sampled")
	_queued_support_wrench.clear()
	_applied_support_wrench.clear()
	_support_wrench_apply_count = 0
	_hull_terrain_collision_released = false
	_previous_left_support_load_n = 0.0
	_previous_right_support_load_n = 0.0
	_previous_probe_support_loads.clear()
	_support_ready_ticks = 0
	_support_loss_ticks = 0
	_hull_collision_switch_count = 0
	_smoothed_support_normal = Vector3.UP
	_reset_support_response(true)
	_clear_tick_telemetry()
	_capture_post_step_snapshot()


func has_body() -> bool:
	return (
		configured
		and _body != null
		and is_instance_valid(_body)
		and _body.is_inside_tree()
		and _bodies.size() == 1
		and _joints.is_empty()
		and _articulation.configured
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
	_body = _build_body()
	if _body == null:
		return false
	add_child(_body)
	_body.global_transform = _spawn_global_transform
	_bodies["chassis"] = _body
	if not _articulation.configure(_descriptor, _spawn_global_transform):
		return false
	_soil_contract = _load_soil_contract()
	if _soil_contract.is_empty():
		return false
	return _bucket_sweeper.configure(
		model_id,
		_soil_contract,
		_terrain_collider,
		_layer_mask(int(_descriptor["collision_layers"]["terrain"])),
	)


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
	var contact_material := PhysicsMaterial.new()
	contact_material.bounce = 0.0
	contact_material.friction = 0.35
	contact_material.rough = true
	body.physics_material_override = contact_material
	body.contact_monitor = true
	body.max_contacts_reported = 32
	body.collision_layer = _layer_mask(int(_descriptor["collision_layers"]["machine"]))
	# Keep the hull as a startup/recovery safety surface. It is released only
	# after the distributed probes provide a near-weight support load.
	body.collision_mask = _layer_mask(int(_descriptor["collision_layers"]["terrain"]))
	var shape_index := 0
	for shape_value in _dynamics["compound_shapes"]:
		var shape_data := shape_value as Dictionary
		var collision := CollisionShape3D.new()
		collision.name = "ChassisCollision_%d" % shape_index
		collision.position = _vector3(shape_data["center_m"])
		var box := BoxShape3D.new()
		box.size = _vector3(shape_data["size_m"])
		collision.shape = box
		body.add_child(collision)
		shape_index += 1
	return body


func _update_joint_actuators(delta: float) -> void:
	var proposal := _articulation.propose_step(delta, _body.global_transform, enabled)
	if proposal.is_empty():
		_quality_flags.append("kinematic_articulation_unavailable")
		return
	for flag in proposal.get("quality_flags", []):
		_quality_flags.append(String(flag))
	var accepted_fraction := 1.0
	_support_contact_observed = false
	var previous_frames := _articulation.accepted_frames()
	var candidate_frames := proposal.get("frames", {}) as Dictionary
	if _terrain_identity_valid and previous_frames.has("bucket_link") and candidate_frames.has("bucket_link"):
		_bucket_motion_sequence += 1
		_bucket_query = _bucket_sweeper.sweep(
			get_world_3d(),
			previous_frames["bucket_link"] as Transform3D,
			candidate_frames["bucket_link"] as Transform3D,
			_terrain_identity,
			_physics_tick,
			_authority_epoch,
			_bucket_motion_sequence,
		)
		_bucket_query["previous_bucket_transform"] = previous_frames["bucket_link"]
		_bucket_query["candidate_bucket_transform"] = candidate_frames["bucket_link"]
		var support_queued := false
		var support_evidence := _has_noninitial_support_contact()
		if bool(_bucket_query.get("valid", false)) or support_evidence:
			accepted_fraction = float(_bucket_query.get("accepted_fraction", 1.0))
			support_queued = _queue_support_wrench(previous_frames, candidate_frames, accepted_fraction)
		if not support_queued and not _support_contact_observed:
			_reset_support_response()
		for flag in _bucket_query.get("quality_flags", []):
			_quality_flags.append(String(flag))
	else:
		_set_invalid_bucket_query(
			"bucket_query_terrain_identity_mismatch",
			previous_frames.get("bucket_link", Transform3D.IDENTITY) as Transform3D,
			candidate_frames.get("bucket_link", Transform3D.IDENTITY) as Transform3D,
		)
	_articulation.accept_step(proposal, accepted_fraction)
	var accepted_frames := _articulation.accepted_frames()
	if not _bucket_query.is_empty() and accepted_frames.has("bucket_link"):
		_bucket_query["accepted_bucket_transform"] = accepted_frames["bucket_link"]


func _has_noninitial_support_contact() -> bool:
	for contact_value in _bucket_query.get("contacts", []):
		var contact := contact_value as Dictionary
		if (
			["shell", "rear_support"].has(String(contact.get("proxy_role", "")))
			and not bool(contact.get("initial_overlap", false))
		):
			return true
	return false


func _apply_pending_payload() -> void:
	if int(_pending_payload["identity"]) <= int(_applied_payload.get("identity", -1)):
		return
	if not _articulation.set_payload(
		float(_pending_payload["mass_kg"]),
		_pending_payload["center_of_mass_local"] as Vector3,
		int(_pending_payload["identity"]),
	):
		return
	_applied_payload = _articulation.payload_snapshot()


func _capture_post_step_snapshot() -> void:
	var body_states: Array[Dictionary] = []
	var chassis := _bodies.get("chassis") as RigidBody3D
	var chassis_available := chassis != null and is_instance_valid(chassis) and chassis.is_inside_tree()
	if chassis_available:
		body_states.append({
			"name": "chassis",
			"transform": chassis.global_transform,
			"linear_velocity": chassis.linear_velocity,
			"angular_velocity": chassis.angular_velocity,
			"sleeping": chassis.sleeping,
		})
	var frame_states: Array[Dictionary] = []
	var frames := _articulation.accepted_frames()
	for frame_name in ["upper_structure_link", "boom_link", "arm_link", "bucket_link"]:
		if frames.has(frame_name):
			frame_states.append({"name": frame_name, "transform": frames[frame_name]})
	_post_step_snapshot = {
		"physics_tick": _physics_tick,
		"authority_epoch": _authority_epoch,
		"body_transform": chassis.global_transform if chassis_available else Transform3D.IDENTITY,
		"linear_velocity": chassis.linear_velocity if chassis_available else Vector3.ZERO,
		"angular_velocity": chassis.angular_velocity if chassis_available else Vector3.ZERO,
		"sleeping": chassis.sleeping if chassis_available else false,
		"bodies": body_states,
		"kinematic_frames": frame_states,
		"joints": _articulation.joint_states(),
		"payload": _articulation.payload_snapshot(),
		"neutral_armed": _articulation.neutral_armed,
		"command_identity": _command_identity,
		"bucket_motion_sequence": _bucket_motion_sequence,
		"bucket_query": _bucket_query.duplicate(true),
		"queued_chassis_wrench": _queued_support_wrench.duplicate(true),
		"applied_chassis_wrench": _applied_support_wrench.duplicate(true),
		"support_wrench_apply_count": _support_wrench_apply_count,
		"left_command": _left_command, "right_command": _right_command,
		"left_speed_mps": _left_speed_m_s, "right_speed_mps": _right_speed_m_s,
		"left_slip_ratio": _left_slip_ratio, "right_slip_ratio": _right_slip_ratio,
		"left_support_load_n": _left_support_load_n, "right_support_load_n": _right_support_load_n,
		"hull_terrain_collision_released": _hull_terrain_collision_released,
		"hull_collision_switch_count": _hull_collision_switch_count,
		"left_contact_count": _left_contact_count, "right_contact_count": _right_contact_count,
		"left_saturated": _left_saturated, "right_saturated": _right_saturated,
		"grounded": _left_contact_count + _right_contact_count > 0,
		"terrain_generation": _terrain_identity.x, "terrain_revision": _terrain_identity.y,
		"terrain_identity_valid": _terrain_identity_valid,
		"contacts": _contacts.duplicate(true), "quality_flags": _quality_flags.duplicate(),
		"last_step_usec": _last_step_usec,
	}


func _collect_bucket_query_contacts() -> void:
	for contact_value in _bucket_query.get("contacts", []):
		var contact := contact_value as Dictionary
		_contacts.append({
			"body": "bucket_kinematic",
			"other": String(contact.get("collider_name", "terrain")),
			"point": contact.get("point_world", Vector3.ZERO),
			"normal": contact.get("normal_world", Vector3.UP),
			"impulse_n_s": 0.0,
			"penetration_m": 0.0,
			"proxy_role": String(contact.get("proxy_role", "")),
			"travel_fraction": float(contact.get("travel_fraction", 1.0)),
		})


func _destroy_rig() -> void:
	_joints.clear()
	for body_value in _bodies.values():
		var body := body_value as RigidBody3D
		if not is_instance_valid(body):
			continue
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
		body.collision_layer = 0
		body.collision_mask = 0
		body.freeze = true
		if body.is_inside_tree():
			body.queue_free()
		else:
			body.free()
	_bodies.clear()
	_body = null
	_articulation.reset()
	_bucket_sweeper.reset()
	_soil_contract.clear()
	_bucket_query.clear()
	_queued_support_wrench.clear()
	_applied_support_wrench.clear()
	_reset_support_response(true)


func _set_invalid_bucket_query(
	reason: String,
	previous_bucket := Transform3D.IDENTITY,
	candidate_bucket := Transform3D.IDENTITY
) -> void:
	var frames := _articulation.accepted_frames()
	var accepted_bucket := frames.get("bucket_link", previous_bucket) as Transform3D
	_bucket_query = {
		"valid": false,
		"accepted_fraction": 1.0,
		"authority_epoch": _authority_epoch,
		"physics_tick": _physics_tick,
		"motion_sequence": _bucket_motion_sequence,
		"terrain_generation": _terrain_identity.x,
		"terrain_revision": _terrain_identity.y,
		"previous_bucket_transform": previous_bucket if previous_bucket != Transform3D.IDENTITY else accepted_bucket,
		"candidate_bucket_transform": candidate_bucket if candidate_bucket != Transform3D.IDENTITY else accepted_bucket,
		"accepted_bucket_transform": accepted_bucket,
		"contacts": [],
		"quality_flags": [reason],
	}


func _queue_support_wrench(previous_frames: Dictionary, candidate_frames: Dictionary, accepted_fraction: float) -> bool:
	if accepted_fraction >= 0.999999 or not _queued_support_wrench.is_empty():
		return false
	var support_contact: Dictionary = {}
	var support_diagnostics: Array[Dictionary] = []
	for contact_value in _bucket_query.get("contacts", []):
		var contact := contact_value as Dictionary
		if ["shell", "rear_support"].has(String(contact.get("proxy_role", ""))):
			var diagnostic := {
				"role": String(contact.get("proxy_role", "")),
				"initial_overlap": bool(contact.get("initial_overlap", false)),
				"eligible": false,
			}
			if bool(diagnostic["initial_overlap"]):
				diagnostic["rejection"] = "initial_overlap"
				support_diagnostics.append(diagnostic)
				continue
			var normal := contact.get("normal_world", Vector3.UP) as Vector3
			if not normal.is_finite() or normal.length_squared() < 0.5:
				diagnostic["rejection"] = "invalid_normal"
				support_diagnostics.append(diagnostic)
				continue
			var normalized_normal := normal.normalized()
			diagnostic["normal_up_dot"] = normalized_normal.dot(Vector3.UP)
			var role := String(contact.get("proxy_role", ""))
			var proxy := (_soil_contract.get("proxies", {}) as Dictionary).get(role, {}) as Dictionary
			if proxy.is_empty():
				diagnostic["rejection"] = "missing_proxy"
				support_diagnostics.append(diagnostic)
				continue
			var local_center := _vector3(proxy.get("center_godot", [0.0, 0.0, 0.0]))
			var previous_point := (previous_frames.get("bucket_link", Transform3D.IDENTITY) as Transform3D) * local_center
			var candidate_point := (candidate_frames.get("bucket_link", Transform3D.IDENTITY) as Transform3D) * local_center
			var motion_into_surface := -(candidate_point - previous_point).dot(normalized_normal)
			diagnostic["motion_into_surface_m"] = motion_into_surface
			if float(diagnostic["normal_up_dot"]) < MIN_SUPPORT_NORMAL_UP_DOT:
				diagnostic["rejection"] = "normal_direction"
				support_diagnostics.append(diagnostic)
				continue
			if motion_into_surface < MIN_SUPPORT_INTO_SURFACE_M:
				diagnostic["rejection"] = "motion_direction"
				support_diagnostics.append(diagnostic)
				continue
			diagnostic["eligible"] = true
			support_diagnostics.append(diagnostic)
			support_contact = contact.duplicate(true)
			support_contact["classification"] = "support"
			support_contact["motion_into_surface_m"] = motion_into_surface
			break
	_bucket_query["support_diagnostics"] = support_diagnostics
	if support_contact.is_empty():
		return false
	_support_contact_observed = true
	if _support_contact_ticks >= MAX_SUPPORT_DURATION_TICKS:
		_quality_flags.append("support_wrench_duration_capped")
		return false
	_support_contact_ticks += 1
	var previous_bucket := previous_frames.get("bucket_link", Transform3D.IDENTITY) as Transform3D
	var candidate_bucket := candidate_frames.get("bucket_link", Transform3D.IDENTITY) as Transform3D
	var blocked_distance := previous_bucket.origin.distance_to(candidate_bucket.origin) * (1.0 - accepted_fraction)
	var normal := support_contact.get("normal_world", Vector3.UP) as Vector3
	if not normal.is_finite() or normal.length_squared() < 0.5:
		normal = Vector3.UP
	var point := support_contact.get("point_world", candidate_bucket.origin) as Vector3
	if not point.is_finite() or point.is_zero_approx():
		point = candidate_bucket.origin
	var target_force := normal.normalized() * minf(MAX_SUPPORT_FORCE_N, blocked_distance * SUPPORT_FORCE_PER_BLOCKED_M_N)
	var force := _last_support_force.move_toward(target_force, MAX_SUPPORT_FORCE_DELTA_N_PER_TICK)
	var torque := (point - _body.global_position).cross(force)
	if torque.length() > MAX_SUPPORT_TORQUE_NM:
		torque = torque.normalized() * MAX_SUPPORT_TORQUE_NM
	torque = _last_support_torque.move_toward(torque, MAX_SUPPORT_TORQUE_DELTA_NM_PER_TICK)
	_last_support_force = force
	_last_support_torque = torque
	_queued_support_wrench = {
		"request_id": "%s:%d:%d" % [_authority_epoch, _physics_tick, _bucket_motion_sequence],
		"authority_epoch": _authority_epoch,
		"source_physics_tick": _physics_tick,
		"eligible_apply_tick": _physics_tick + 1,
		"expiry_tick": _physics_tick + SUPPORT_REQUEST_LIFETIME_TICKS,
		"model_id": model_id,
		"terrain_generation": _terrain_identity.x,
		"terrain_revision": _terrain_identity.y,
		"point_world": point,
		"normal_world": normal.normalized(),
		"blocked_distance_m": blocked_distance,
		"requested_force": force,
		"requested_torque": torque,
		"classification": "support",
		"support_contact_ticks": _support_contact_ticks,
	}
	return true


func _apply_queued_support_wrench() -> void:
	_applied_support_wrench.clear()
	if _queued_support_wrench.is_empty():
		return
	var eligible_tick := int(_queued_support_wrench.get("eligible_apply_tick", -1))
	var expiry_tick := int(_queued_support_wrench.get("expiry_tick", -1))
	if _physics_tick < eligible_tick:
		return
	if (
		_physics_tick > expiry_tick
		or String(_queued_support_wrench.get("authority_epoch", "")) != _authority_epoch
		or String(_queued_support_wrench.get("model_id", "")) != model_id
		or int(_queued_support_wrench.get("terrain_generation", -1)) != _terrain_identity.x
		or int(_queued_support_wrench.get("terrain_revision", -1)) != _terrain_identity.y
	):
		_quality_flags.append("support_wrench_stale_rejected")
		_queued_support_wrench.clear()
		return
	var request_id := String(_queued_support_wrench.get("request_id", ""))
	if request_id.is_empty() or request_id == _last_applied_support_request_id:
		_quality_flags.append("support_wrench_duplicate_rejected")
		_queued_support_wrench.clear()
		return
	var force := _queued_support_wrench.get("requested_force", Vector3.ZERO) as Vector3
	var torque := _queued_support_wrench.get("requested_torque", Vector3.ZERO) as Vector3
	var point := _queued_support_wrench.get("point_world", _body.global_position) as Vector3
	if not force.is_finite() or not torque.is_finite() or not point.is_finite():
		_quality_flags.append("support_wrench_invalid_rejected")
		_queued_support_wrench.clear()
		return
	if _body.linear_velocity.dot(Vector3.UP) >= MAX_SUPPORT_HEAVE_SPEED_M_S and force.dot(Vector3.UP) > 0.0:
		force -= Vector3.UP * force.dot(Vector3.UP)
	var tilt_rate := Vector2(_body.angular_velocity.x, _body.angular_velocity.z).length()
	if tilt_rate >= MAX_SUPPORT_TILT_RATE_RAD_S:
		torque.x = 0.0
		torque.z = 0.0
	_body.apply_central_force(force)
	_body.apply_torque(torque)
	_applied_support_wrench = _queued_support_wrench.duplicate(true)
	_applied_support_wrench["applied_physics_tick"] = _physics_tick
	_applied_support_wrench["applied_force"] = force
	_applied_support_wrench["applied_torque"] = torque
	_last_applied_support_request_id = request_id
	_support_wrench_apply_count += 1
	_queued_support_wrench.clear()


func _reset_support_response(clear_request_identity := false) -> void:
	_support_contact_ticks = 0
	_support_contact_observed = false
	_last_support_force = Vector3.ZERO
	_last_support_torque = Vector3.ZERO
	if clear_request_identity:
		_last_applied_support_request_id = ""


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
	_left_support_load_n = float(result_left["support_load_n"])
	_right_support_load_n = float(result_right["support_load_n"])
	_previous_left_support_load_n = _left_support_load_n
	_previous_right_support_load_n = _right_support_load_n
	_left_saturated = bool(result_left["saturated"])
	_right_saturated = bool(result_right["saturated"])
	var expected_weight := float(_dynamics["mass_kg"]) * GRAVITY_M_S2
	var total_support_load := _left_support_load_n + _right_support_load_n
	var both_tracks_supported := _left_contact_count > 0 and _right_contact_count > 0
	if not _hull_terrain_collision_released:
		_support_loss_ticks = 0
		if both_tracks_supported and total_support_load >= expected_weight * MIN_SUPPORT_LOAD_TO_RELEASE_HULL_RATIO:
			_support_ready_ticks += 1
		else:
			_support_ready_ticks = 0
		if _support_ready_ticks >= SUPPORT_READY_TICKS_TO_RELEASE_HULL:
			_set_hull_terrain_collision_released(true)
	else:
		_support_ready_ticks = 0
		if not both_tracks_supported or total_support_load < expected_weight * MAX_SUPPORT_LOAD_TO_RESTORE_HULL_RATIO:
			_support_loss_ticks += 1
		else:
			_support_loss_ticks = 0
		if _support_loss_ticks >= SUPPORT_LOSS_TICKS_TO_RESTORE_HULL:
			_set_hull_terrain_collision_released(false)
	if _left_contact_count > 0 and _right_contact_count > 0:
		_apply_attitude_stabilization(result_left, result_right)
		_apply_differential_yaw_torque()


func _apply_attitude_stabilization(result_left: Dictionary, result_right: Dictionary) -> void:
	var contact_count := int(result_left["contact_count"]) + int(result_right["contact_count"])
	if contact_count <= 0:
		return
	var normal_sum := result_left["normal_sum"] as Vector3
	normal_sum += result_right["normal_sum"] as Vector3
	if normal_sum.length_squared() < 0.25:
		return
	var target_normal := normal_sum.normalized()
	_smoothed_support_normal = _smoothed_support_normal.lerp(target_normal, 0.18).normalized()
	var current_up := _body.global_basis.y.normalized()
	var attitude_error := current_up.cross(_smoothed_support_normal)
	var tilt_rate := _body.angular_velocity - Vector3.UP * _body.angular_velocity.dot(Vector3.UP)
	var torque := (
		attitude_error * float(_dynamics["attitude_stiffness_nm_per_rad"])
		- tilt_rate * float(_dynamics["attitude_damping_nm_s_per_rad"])
	)
	var max_torque := float(_dynamics["max_attitude_torque_nm"])
	if torque.length() > max_torque:
		torque = torque.normalized() * max_torque
	_body.apply_torque(torque)


func _apply_differential_yaw_torque() -> void:
	var demand := 0.5 * (_right_command - _left_command)
	if is_zero_approx(demand):
		return
	var yaw_assist_scale := float(_tracks["yaw_assist_scale"])
	if yaw_assist_scale <= 0.0:
		return
	var supported_force := minf(_left_support_load_n, _right_support_load_n) * float(_tracks["friction"])
	var max_torque := supported_force * float(_tracks["gauge_m"]) * 0.5 * yaw_assist_scale
	var target_yaw_rate := 2.0 * demand * float(_tracks["max_belt_speed_m_s"]) / float(_tracks["gauge_m"])
	var torque := clampf((target_yaw_rate - _body.angular_velocity.dot(Vector3.UP)) * max_torque, -max_torque, max_torque)
	_body.apply_torque(Vector3.UP * torque)


func _apply_track_side(local_x: float, command: float, point_count: int, contact_length: float, side_name: String) -> Dictionary:
	var contacts := 0
	var speed_sum := 0.0
	var slip_sum := 0.0
	var support_load_sum := 0.0
	var normal_sum := Vector3.ZERO
	var saturated := false
	var max_side_force := float(_tracks["max_drive_force_n"])
	var max_point_force := max_side_force / float(point_count)
	var ray_hits: Array[Dictionary] = []
	for index in point_count:
		var alpha := (float(index) + 0.5) / float(point_count)
		var hit := _track_raycast(Vector3(local_x, 0.0, lerpf(-0.5 * contact_length, 0.5 * contact_length, alpha)))
		ray_hits.append(hit)
	for probe_index in ray_hits.size():
		var hit := ray_hits[probe_index]
		if hit.is_empty():
			_previous_probe_support_loads.erase("%s:%d" % [side_name, probe_index])
			continue
		contacts += 1
		var point := hit["position"] as Vector3
		var normal := (hit["normal"] as Vector3).normalized()
		var ray_start := hit.get("ray_start", point) as Vector3
		var offset := point - _body.global_position
		var center_of_mass_world := _body.global_transform * _body.center_of_mass
		var point_offset_from_com := point - center_of_mass_world
		var point_velocity := _body.linear_velocity + _body.angular_velocity.cross(point_offset_from_com)
		var compression_distance := maxf(0.0, (ray_start - point).dot(normal))
		var compression := clampf(float(_tracks["support_rest_length_m"]) - compression_distance, 0.0, float(_tracks["probe_depth_m"]))
		if compression < 0.005:
			compression = 0.0
		# Positive compression velocity means the probe is moving into the terrain.
		# The damper must oppose that motion by increasing upward support; the old
		# subtraction inverted the feedback and produced a repeating pitch bounce.
		var compression_velocity := -point_velocity.dot(normal)
		var raw_support_force := clampf(
			compression * float(_tracks["support_stiffness_n_per_m"]) + compression_velocity * float(_tracks["support_damping_n_s_per_m"]),
			0.0,
			float(_tracks["max_support_force_n"])
		)
		var probe_key := "%s:%d" % [side_name, probe_index]
		var previous_support_force := float(_previous_probe_support_loads.get(probe_key, raw_support_force))
		var support_force := lerpf(previous_support_force, raw_support_force, SUPPORT_FORCE_SMOOTHING_ALPHA)
		_previous_probe_support_loads[probe_key] = support_force
		var friction_cap := float(_tracks["friction"]) * support_force
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
		var pivot_blend := clampf(sqrt(maxf(0.0, -_left_command * _right_command)), 0.0, 1.0)
		var lateral_scale := lerpf(1.0, float(_tracks["pivot_lateral_resistance_scale"]), pivot_blend)
		var lateral_force := clampf(-point_velocity.dot(lateral) * float(_tracks["lateral_resistance_n_per_m_s"]) * lateral_scale / float(point_count), -friction_cap, friction_cap)
		_body.apply_force(normal * support_force, offset)
		# The simplified chassis intentionally keeps traction at COM height. Track
		# side offset still creates differential yaw, while longitudinal braking no
		# longer injects a large pitch impulse through the provisional high COM.
		var traction_force := forward * bounded_drive + lateral * lateral_force
		_body.apply_central_force(traction_force)
		_body.apply_torque((_body.global_basis.x * local_x).cross(traction_force))
		speed_sum += longitudinal_speed
		slip_sum += clampf(speed_error / maxf(absf(target_speed), MIN_SPEED_DENOMINATOR), -4.0, 4.0)
		support_load_sum += support_force
		normal_sum += normal
		_contacts.append({"body": "chassis", "other": String((hit["collider"] as Node).name), "point": point, "normal": normal, "impulse_n_s": 0.0, "penetration_m": 0.0, "track_side": side_name})
	return {"contact_count": contacts, "speed_m_s": speed_sum / float(contacts) if contacts > 0 else 0.0, "slip_ratio": slip_sum / float(contacts) if contacts > 0 else 0.0, "support_load_n": support_load_sum, "normal_sum": normal_sum, "saturated": saturated}


func _set_hull_terrain_collision_released(released: bool) -> void:
	if _body == null or not is_instance_valid(_body):
		_hull_terrain_collision_released = false
		return
	if released == _hull_terrain_collision_released:
		return
	_hull_terrain_collision_released = released
	_body.collision_mask = 0 if released else _layer_mask(int(_descriptor["collision_layers"]["terrain"]))
	_support_ready_ticks = 0
	_support_loss_ticks = 0
	_hull_collision_switch_count += 1


func _track_raycast(local_point: Vector3) -> Dictionary:
	var center := _body.global_transform * local_point
	var ray_start := center + Vector3.UP * float(_tracks["probe_height_m"])
	var ray_end := center - Vector3.UP * float(_tracks["probe_depth_m"])
	var query := PhysicsRayQueryParameters3D.create(ray_start, ray_end, _layer_mask(int(_descriptor["collision_layers"]["terrain"])))
	query.collide_with_areas = false
	query.exclude = [_body.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var collider: Variant = hit.get("collider")
	if not hit.is_empty() and collider is Node and _terrain_collider != null and _terrain_collider.is_ancestor_of(collider as Node):
		hit["ray_start"] = ray_start
		hit["support_source"] = "terrain_collider"
		return hit
	return _heightfield_support_hit(center, ray_start, ray_end)


func _heightfield_support_hit(center: Vector3, ray_start: Vector3, ray_end: Vector3) -> Dictionary:
	if not _terrain_identity_valid or _terrain_world == null or _terrain_world.terrain_state == null:
		return {}
	var state := _terrain_world.terrain_state
	var world_xz := Vector2(center.x, center.z)
	if not state.is_inside_grid(world_xz):
		return {}
	var height := state.sample_surface_bilinear_at(world_xz)
	if not is_finite(height) or height > ray_start.y or height < ray_end.y:
		return {}
	var spacing := state.spacing_m
	var left_height := _sample_heightfield_clamped(state, world_xz - Vector2(spacing, 0.0))
	var right_height := _sample_heightfield_clamped(state, world_xz + Vector2(spacing, 0.0))
	var rear_height := _sample_heightfield_clamped(state, world_xz - Vector2(0.0, spacing))
	var front_height := _sample_heightfield_clamped(state, world_xz + Vector2(0.0, spacing))
	var terrain_normal := Vector3(
		(left_height - right_height) / (2.0 * spacing),
		1.0,
		(rear_height - front_height) / (2.0 * spacing)
	).normalized()
	return {
		"position": Vector3(center.x, height, center.z),
		"normal": terrain_normal,
		"collider": _terrain_collider,
		"ray_start": ray_start,
		"support_source": "terrain_state_fallback",
	}


func _sample_heightfield_clamped(state: TerrainState, world_xz: Vector2) -> float:
	var maximum := state.origin_xz + Vector2(
		float(state.columns - 1) * state.spacing_m,
		float(state.rows - 1) * state.spacing_m
	)
	var clamped_xz := Vector2(
		clampf(world_xz.x, state.origin_xz.x, maximum.x),
		clampf(world_xz.y, state.origin_xz.y, maximum.y)
	)
	return state.sample_surface_bilinear_at(clamped_xz)


func _update_terrain_identity() -> void:
	_terrain_identity_valid = false
	if _terrain_world == null or _terrain_world.terrain_state == null or _terrain_collider == null:
		_terrain_identity = Vector2i(-1, -1)
		return
	_terrain_identity = Vector2i(_terrain_world.terrain_state.world_generation, _terrain_world.terrain_state.terrain_revision)
	_terrain_identity_valid = _terrain_collider.available and _terrain_collider.get_applied_identity() == _terrain_identity


func _clamp_body_velocities() -> void:
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


func _clamp_body_velocity() -> void:
	# Phase 1 test seam retained for the single dynamic chassis.
	_clamp_body_velocities()
	_capture_post_step_snapshot()


func _clear_tick_telemetry() -> void:
	_left_contact_count = 0
	_right_contact_count = 0
	_left_speed_m_s = 0.0
	_right_speed_m_s = 0.0
	_left_slip_ratio = 0.0
	_right_slip_ratio = 0.0
	_left_support_load_n = 0.0
	_right_support_load_n = 0.0
	_left_saturated = false
	_right_saturated = false
	_contacts.clear()
	_quality_flags.clear()


func _empty_snapshot() -> Dictionary:
	return {
		"physics_tick": _physics_tick,
		"authority_epoch": _authority_epoch,
		"body_transform": Transform3D.IDENTITY,
		"linear_velocity": Vector3.ZERO,
		"angular_velocity": Vector3.ZERO,
		"sleeping": false,
		"bodies": [],
		"kinematic_frames": [],
		"joints": [],
		"payload": _articulation.payload_snapshot(),
		"neutral_armed": false,
		"bucket_query": {},
		"queued_chassis_wrench": {},
		"applied_chassis_wrench": {},
		"left_support_load_n": 0.0,
		"right_support_load_n": 0.0,
		"contacts": [],
		"quality_flags": ["authoritative_runtime_unavailable"],
	}


func _reject(message: String) -> bool:
	contract_error = message
	configured = false
	enabled = false
	return false


func _load_soil_contract() -> Dictionary:
	var path := "res://resources/models/%s_soil_contract.json" % model_id
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		return {}
	var contract := parsed as Dictionary
	if String(contract.get("model_id", "")) != model_id:
		return {}
	return contract.duplicate(true)


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

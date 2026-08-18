class_name SimulationTruthPublisher
extends Node

const LOCAL_SESSION_ID := "godot-local-authority"
const CALIBRATION_VERSION := "machine-calibration-v2"

@export_enum("python_kinematic", "jolt_shadow", "jolt_authoritative") var authority_profile := AuthorityProfile.PYTHON_KINEMATIC
@export var use_project_authority_profile := true
@export var motion_client_path := NodePath("../MotionClient")
@export var motion_presentation_path := NodePath("../MotionPresentation")
@export var terrain_world_path := NodePath("../TerrainRoot/TerrainWorld")
@export var excavation_world_path := NodePath("../TerrainRoot/ExcavationWorld")
@export var chassis_path := NodePath("../ChassisMotionRoot")

var _motion_client: MotionClient
var _presentation: MotionPresentation
var _terrain_world: TerrainWorld
var _excavation_world: ExcavationWorld
var _chassis: TrackedChassisController
var _descriptor: PhysicsRigDescriptor
var _authority_epoch := ""
var _sequence := 0
var _last_model_id := ""
var _last_authority_identity := ""
var _last_runtime_authority_epoch := ""
var _last_snapshot: SimulationTruthSnapshot
var contract_error := ""


func _ready() -> void:
	process_physics_priority = 100
	_motion_client = get_node_or_null(motion_client_path) as MotionClient
	_presentation = get_node_or_null(motion_presentation_path) as MotionPresentation
	_terrain_world = get_node_or_null(terrain_world_path) as TerrainWorld
	_excavation_world = get_node_or_null(excavation_world_path) as ExcavationWorld
	_chassis = get_node_or_null(chassis_path) as TrackedChassisController
	if use_project_authority_profile:
		authority_profile = String(ProjectSettings.get_setting("simulation/authority_profile", authority_profile))
	if not AuthorityProfile.is_valid(authority_profile):
		_fail_closed("unknown authority profile: %s" % authority_profile)
		return
	_rotate_epoch()
	if _motion_client != null and not _motion_client.authority_changed.is_connected(_on_authority_changed):
		_motion_client.authority_changed.connect(_on_authority_changed)


func _physics_process(_delta: float) -> void:
	if not AuthorityProfile.produces_truth(authority_profile):
		return
	var snapshot := build_snapshot()
	if snapshot == null:
		return
	_last_snapshot = snapshot
	if AuthorityProfile.publishes_shadow(authority_profile) and _motion_client != null:
		_motion_client.queue_simulation_truth_shadow(snapshot.to_dictionary())


func build_snapshot() -> SimulationTruthSnapshot:
	var authoritative := AuthorityProfile.writes_product_pose(authority_profile)
	if _presentation == null or _terrain_world == null or _terrain_world.terrain_state == null:
		return null
	var pose: Dictionary = {}
	if not authoritative:
		if _motion_client == null or _motion_client.connection_state != MotionClient.STATE_READY:
			return null
		pose = _motion_client.get_latest_accepted_pose()
		if not _pose_matches_authority(pose):
			return null
		var authority_identity := "%s|%s|%s" % [
			_motion_client.session_id, _motion_client.simulation_epoch, _motion_client.active_model_id,
		]
		if authority_identity != _last_authority_identity:
			_last_authority_identity = authority_identity
			_rotate_epoch()
	var model_id := _presentation.get_active_model_id()
	if model_id.is_empty():
		return null
	if model_id != _last_model_id:
		_descriptor = PhysicsRigDescriptor.load_for_model(model_id)
		_last_model_id = model_id
		_rotate_epoch()
	if _descriptor == null:
		contract_error = "missing physics rig descriptor for %s" % model_id
		return null
	var model_version := (
		_descriptor.model_version()
		if authoritative
		else String(_motion_client.accepted_versions.get("model_version", ""))
	)
	if model_version.is_empty() or not _descriptor.is_valid_for(model_id, model_version):
		contract_error = _descriptor.validation_error() if not model_version.is_empty() else "model version unavailable"
		return null
	var terrain := _terrain_world.terrain_state.surface_snapshot()
	var excavation := _excavation_world.get_status_snapshot() if _excavation_world != null else {}
	var chassis := _chassis.get_status_snapshot() if _chassis != null else {}
	if authoritative and not bool(chassis.get("configured", false)):
		contract_error = "authoritative chassis is not configured"
		return null
	var snapshot_authority_epoch := _authority_epoch
	var snapshot_physics_tick := Engine.get_physics_frames()
	if authoritative:
		snapshot_authority_epoch = String(chassis.get("authority_epoch", ""))
		snapshot_physics_tick = int(chassis.get("physics_tick", -1))
		var query := chassis.get("bucket_query", {}) as Dictionary
		if (
			snapshot_authority_epoch.is_empty() or snapshot_physics_tick < 0
			or String(query.get("authority_epoch", "")) != snapshot_authority_epoch
			or int(query.get("physics_tick", -1)) != snapshot_physics_tick
		):
			contract_error = "authoritative bucket query identity is not aligned with the post-step snapshot"
			return null
		if snapshot_authority_epoch != _last_runtime_authority_epoch:
			_last_runtime_authority_epoch = snapshot_authority_epoch
			_sequence = 0
	contract_error = ""
	var raw: Dictionary = pose.get("raw", {}) if not authoritative else {}
	var joint_positions: Array = raw.get("joint_position", [0.0, 0.0, 0.0, 0.0])
	var joint_velocities: Array = raw.get("joint_velocity", [0.0, 0.0, 0.0, 0.0])
	var body_frames := {
		"chassis": "base_link", "upper": "upper_structure_link", "boom": "boom_link",
		"arm": "arm_link", "bucket": "bucket_link",
	}
	var bodies: Array[Dictionary] = []
	var kinematic_frames: Array[Dictionary] = []
	if authoritative:
		for body_value in chassis.get("bodies", []):
			if not body_value is Dictionary:
				return null
			var body := body_value as Dictionary
			bodies.append({
				"name": String(body.get("name", "")),
				"transform": MotionProtocol.transform_to_canonical_rows(body.get("transform", Transform3D.IDENTITY) as Transform3D),
				"linear_velocity_m_s": MotionProtocol.vector_to_canonical_array(body.get("linear_velocity", Vector3.ZERO) as Vector3),
				"angular_velocity_rad_s": MotionProtocol.vector_to_canonical_array(body.get("angular_velocity", Vector3.ZERO) as Vector3),
				"sleeping": bool(body.get("sleeping", false)),
			})
		for frame_value in chassis.get("kinematic_frames", []):
			if not frame_value is Dictionary:
				return null
			var frame := frame_value as Dictionary
			kinematic_frames.append({
				"name": String(frame.get("name", "")),
				"transform": MotionProtocol.transform_to_canonical_rows(frame.get("transform", Transform3D.IDENTITY) as Transform3D),
			})
	else:
		for body_name in body_frames:
			var frame := _presentation.get_frame_node(body_frames[body_name])
			if frame == null:
				return null
			bodies.append({
				"name": body_name,
				"transform": MotionProtocol.transform_to_canonical_rows(frame.global_transform),
				"linear_velocity_m_s": MotionProtocol.vector_to_canonical_array(Vector3.ZERO),
				"angular_velocity_rad_s": MotionProtocol.vector_to_canonical_array(Vector3.ZERO),
				"sleeping": false,
			})
	var joints: Array[Dictionary] = []
	if authoritative:
		for joint_value in chassis.get("joints", []):
			if not joint_value is Dictionary:
				return null
			var joint := joint_value as Dictionary
			joints.append({
				"name": String(joint.get("name", "")),
				"target_position_rad": float(joint.get("target_position_rad", 0.0)),
				"target_velocity_rad_s": float(joint.get("target_velocity_rad_s", 0.0)),
				"position_rad": float(joint.get("position_rad", 0.0)),
				"velocity_rad_s": float(joint.get("velocity_rad_s", 0.0)),
				"effort_n": float(joint.get("effort_n", 0.0)),
			})
	else:
		for index in MotionProtocol.JOINT_NAMES.size():
			joints.append({
				"name": MotionProtocol.JOINT_NAMES[index],
				"position_rad": float(joint_positions[index]),
				"velocity_rad_s": float(joint_velocities[index]),
				"effort_n": 0.0,
			})
	var session_id := LOCAL_SESSION_ID
	var simulation_epoch := _authority_epoch
	var calibration_version := CALIBRATION_VERSION
	if _motion_client != null:
		if not _motion_client.session_id.is_empty():
			session_id = _motion_client.session_id
		if not _motion_client.simulation_epoch.is_empty():
			simulation_epoch = _motion_client.simulation_epoch
		calibration_version = String(_motion_client.accepted_versions.get("calibration_version", CALIBRATION_VERSION))
	var contacts: Array[Dictionary] = []
	if authoritative:
		for contact in chassis.get("contacts", []):
			if contact is Dictionary:
				contacts.append({
					"body": String(contact.get("body", "chassis")),
					"other": String(contact.get("other", "terrain")),
					"point_m": MotionProtocol.vector_to_canonical_array(contact.get("point", Vector3.ZERO) as Vector3),
					"normal": MotionProtocol.vector_to_canonical_array(contact.get("normal", Vector3.UP) as Vector3),
					"impulse_n_s": maxf(0.0, float(contact.get("impulse_n_s", 0.0))),
					"penetration_m": maxf(0.0, float(contact.get("penetration_m", 0.0))),
				})
	var quality_flags: Array[String] = []
	for flag in _descriptor.to_dictionary().get("quality_flags", []):
		quality_flags.append(String(flag))
	if authoritative:
		quality_flags.append("jolt_chassis_kinematic_articulation_authority")
		quality_flags.append("bucket_query_contact_evidence")
		for flag in chassis.get("quality_flags", []):
			if not quality_flags.has(String(flag)):
				quality_flags.append(String(flag))
	else:
		quality_flags.append_array(["shadow_observation", "kinematic_body_velocity_unavailable", "jolt_contact_manifold_unavailable"])
	var applied_payload := chassis.get("payload", {}) as Dictionary if authoritative else {}
	var center := (
		applied_payload.get("center_of_mass_local", Vector3.ZERO)
		if authoritative else excavation.get("center_of_mass_local", Vector3.ZERO)
	) as Vector3
	var result := {
		"schema_version": "simulation-truth-v1",
		"authority_profile": authority_profile,
		"authority_epoch": snapshot_authority_epoch,
		"sequence": _sequence,
		"physics_tick": snapshot_physics_tick,
		"monotonic_time_ns": Time.get_ticks_usec() * 1000,
		"coordinate_basis": "canonical-z-up-right-handed-meters",
		"identity": {
			"session_id": session_id,
			"simulation_epoch": simulation_epoch,
			"model_id": model_id,
			"model_version": model_version,
			"rig_id": _descriptor.rig_id(),
			"rig_version": _descriptor.rig_version(),
			"calibration_version": calibration_version,
			"terrain_epoch": String(terrain.get("terrain_epoch", "unknown")),
			"terrain_revision": int(terrain.get("terrain_revision", 0)),
			"world_generation": int(terrain.get("world_generation", 0)),
		},
		"gravity_m_s2": [0.0, 0.0, -9.80665],
		"bodies": bodies,
		"kinematic_frames": kinematic_frames,
		"joints": joints,
		"tracks": {
			"left_command": float(chassis.get("left_command", 0.0)),
			"right_command": float(chassis.get("right_command", 0.0)),
			"left_speed_m_s": float(chassis.get("left_speed_mps", 0.0)),
			"right_speed_m_s": float(chassis.get("right_speed_mps", 0.0)),
			"grounded": bool(chassis.get("grounded", not authoritative)),
			"left_contact_count": int(chassis.get("left_contact_count", 0)),
			"right_contact_count": int(chassis.get("right_contact_count", 0)),
			"left_slip_ratio": float(chassis.get("left_slip_ratio", 0.0)),
			"right_slip_ratio": float(chassis.get("right_slip_ratio", 0.0)),
			"left_saturated": bool(chassis.get("left_saturated", false)),
			"right_saturated": bool(chassis.get("right_saturated", false)),
			"terrain_identity_valid": bool(chassis.get("terrain_identity_valid", not authoritative)),
		},
		"payload": {
			"mass_kg": float(applied_payload.get("mass_kg", 0.0)) if authoritative else float(excavation.get("payload_mass_kg", 0.0)),
			"volume_m3": float(excavation.get("bucket_volume_m3", 0.0)),
			"fill_ratio": clampf(float(excavation.get("fill_ratio", 0.0)), 0.0, 1.5),
			"center_of_mass_m": MotionProtocol.vector_to_canonical_array(center),
			"motion_load_factor": float(applied_payload.get("motion_load_factor", 1.0)),
		},
		"contacts": contacts,
		"quality_flags": quality_flags,
	}
	if authoritative:
		result["bucket_query"] = _canonical_bucket_query(chassis.get("bucket_query", {}) as Dictionary)
		result["soil_interaction_batch"] = _canonical_soil_batch(excavation.get("soil_interaction_batch", {}) as Dictionary)
		result["queued_chassis_wrench"] = _canonical_support_wrench(chassis.get("queued_chassis_wrench", {}) as Dictionary)
		result["applied_chassis_wrench"] = _canonical_support_wrench(chassis.get("applied_chassis_wrench", {}) as Dictionary)
	_sequence += 1
	return SimulationTruthSnapshot.from_dictionary(result)


func _canonical_bucket_query(query: Dictionary) -> Dictionary:
	var contacts: Array[Dictionary] = []
	for contact_value in query.get("contacts", []):
		if contact_value is Dictionary:
			var contact := contact_value as Dictionary
			contacts.append({
				"contact_id": String(contact.get("contact_id", "")),
				"proxy_role": String(contact.get("proxy_role", "")),
				"travel_fraction": float(contact.get("travel_fraction", 1.0)),
				"point_m": MotionProtocol.vector_to_canonical_array(contact.get("point_world", Vector3.ZERO) as Vector3),
				"normal": MotionProtocol.vector_to_canonical_array(contact.get("normal_world", Vector3.UP) as Vector3),
				"initial_overlap": bool(contact.get("initial_overlap", false)),
				"quality": String(contact.get("quality", "unknown")),
			})
	var previous := query.get("previous_bucket_transform", Transform3D.IDENTITY) as Transform3D
	var candidate := query.get("candidate_bucket_transform", previous) as Transform3D
	var accepted := query.get("accepted_bucket_transform", previous) as Transform3D
	return {
		"valid": bool(query.get("valid", false)),
		"accepted_fraction": clampf(float(query.get("accepted_fraction", 1.0)), 0.0, 1.0),
		"authority_epoch": String(query.get("authority_epoch", "")),
		"physics_tick": int(query.get("physics_tick", -1)),
		"motion_sequence": int(query.get("motion_sequence", 0)),
		"terrain_generation": int(query.get("terrain_generation", 0)),
		"terrain_revision": int(query.get("terrain_revision", 0)),
		"previous_bucket_transform": MotionProtocol.transform_to_canonical_rows(previous),
		"candidate_bucket_transform": MotionProtocol.transform_to_canonical_rows(candidate),
		"accepted_bucket_transform": MotionProtocol.transform_to_canonical_rows(accepted),
		"contacts": contacts,
		"quality_flags": Array(query.get("quality_flags", []), TYPE_STRING, "", null),
	}


func _canonical_soil_batch(batch: Dictionary) -> Dictionary:
	var classifications: Array[Dictionary] = []
	for record_value in batch.get("classifications", []):
		if record_value is Dictionary:
			var record := record_value as Dictionary
			classifications.append({
				"contact_id": String(record.get("contact_id", "")),
				"proxy_role": String(record.get("proxy_role", "")),
				"classification": String(record.get("classification", "blocked")),
				"travel_fraction": float(record.get("travel_fraction", 1.0)),
			})
	return {
		"key": String(batch.get("key", "unavailable")),
		"eligible": bool(batch.get("eligible", false)),
		"duplicate": bool(batch.get("duplicate", false)),
		"operation": String(batch.get("operation", "none")),
		"transaction_queued": bool(batch.get("transaction_queued", false)),
		"consumed_contact_ids": Array(batch.get("consumed_contact_ids", []), TYPE_STRING, "", null),
		"classifications": classifications,
	}


func _canonical_support_wrench(wrench: Dictionary) -> Variant:
	if wrench.is_empty():
		return null
	return {
		"request_id": String(wrench.get("request_id", "")),
		"source_physics_tick": int(wrench.get("source_physics_tick", 0)),
		"eligible_apply_tick": int(wrench.get("eligible_apply_tick", 0)),
		"expiry_tick": int(wrench.get("expiry_tick", 0)),
		"terrain_generation": int(wrench.get("terrain_generation", 0)),
		"terrain_revision": int(wrench.get("terrain_revision", 0)),
		"point_m": MotionProtocol.vector_to_canonical_array(wrench.get("point_world", Vector3.ZERO) as Vector3),
		"normal": MotionProtocol.vector_to_canonical_array(wrench.get("normal_world", Vector3.UP) as Vector3),
		"force_n": MotionProtocol.vector_to_canonical_array(wrench.get("applied_force", wrench.get("requested_force", Vector3.ZERO)) as Vector3),
		"torque_nm": MotionProtocol.vector_to_canonical_array(wrench.get("applied_torque", wrench.get("requested_torque", Vector3.ZERO)) as Vector3),
		"blocked_distance_m": maxf(0.0, float(wrench.get("blocked_distance_m", 0.0))),
		"classification": String(wrench.get("classification", "support")),
		"support_contact_ticks": int(wrench.get("support_contact_ticks", 0)),
		"applied_physics_tick": int(wrench.get("applied_physics_tick", -1)),
	}


func get_last_snapshot() -> Dictionary:
	return _last_snapshot.to_dictionary() if _last_snapshot != null else {}


func get_status_snapshot() -> Dictionary:
	return {
		"authority_profile": authority_profile,
		"contract_error": contract_error,
		"publishing": AuthorityProfile.produces_truth(authority_profile) and contract_error.is_empty(),
		"transport_publishing": AuthorityProfile.publishes_shadow(authority_profile) and contract_error.is_empty(),
		"sequence": _sequence,
		"model_id": _last_model_id,
	}


func _on_authority_changed(_session_id: String, _simulation_epoch: String, _generation: int) -> void:
	if _motion_client != null:
		_motion_client.clear_simulation_truth_shadow()
	if not AuthorityProfile.writes_product_pose(authority_profile):
		_rotate_epoch()


func _pose_matches_authority(pose: Dictionary) -> bool:
	if _motion_client == null or pose.is_empty():
		return false
	return (
		String(pose.get("session_id", "")) == _motion_client.session_id
		and String(pose.get("simulation_epoch", "")) == _motion_client.simulation_epoch
	)


func _rotate_epoch() -> void:
	_authority_epoch = ("%s-%s" % [Time.get_ticks_usec(), Crypto.new().generate_random_bytes(8).hex_encode()])
	_sequence = 0


func _fail_closed(message: String) -> void:
	contract_error = message
	push_error(message)
	set_physics_process(false)
	if _motion_client != null:
		_motion_client.disconnect_from_service()

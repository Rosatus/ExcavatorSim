class_name SimulationTruthPublisher
extends Node

@export_enum("python_kinematic", "jolt_shadow", "jolt_authoritative") var authority_profile := AuthorityProfile.PYTHON_KINEMATIC
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
var _last_snapshot: SimulationTruthSnapshot
var contract_error := ""


func _ready() -> void:
	process_physics_priority = 100
	_motion_client = get_node_or_null(motion_client_path) as MotionClient
	_presentation = get_node_or_null(motion_presentation_path) as MotionPresentation
	_terrain_world = get_node_or_null(terrain_world_path) as TerrainWorld
	_excavation_world = get_node_or_null(excavation_world_path) as ExcavationWorld
	_chassis = get_node_or_null(chassis_path) as TrackedChassisController
	authority_profile = String(ProjectSettings.get_setting("simulation/authority_profile", authority_profile))
	if not AuthorityProfile.is_valid(authority_profile):
		_fail_closed("unknown authority profile: %s" % authority_profile)
		return
	if authority_profile == AuthorityProfile.JOLT_AUTHORITATIVE:
		_fail_closed("jolt_authoritative is declared but not implemented")
		return
	_rotate_epoch()
	if _motion_client != null:
		_motion_client.authority_changed.connect(_on_authority_changed)


func _physics_process(_delta: float) -> void:
	if not AuthorityProfile.publishes_shadow(authority_profile):
		return
	var snapshot := build_snapshot()
	if snapshot == null:
		return
	_last_snapshot = snapshot
	_motion_client.queue_simulation_truth_shadow(snapshot.to_dictionary())


func build_snapshot() -> SimulationTruthSnapshot:
	if _motion_client == null or _presentation == null or _terrain_world == null or _terrain_world.terrain_state == null:
		return null
	if _motion_client.connection_state != MotionClient.STATE_READY:
		return null
	var pose := _motion_client.get_latest_accepted_pose()
	if not _pose_matches_authority(pose):
		return null
	var authority_identity := "%s|%s|%s" % [
		_motion_client.session_id, _motion_client.simulation_epoch, _motion_client.active_model_id,
	]
	if authority_identity != _last_authority_identity:
		_last_authority_identity = authority_identity
		_rotate_epoch()
	var model_id := _presentation.get_active_model_id()
	var model_version := String(_motion_client.accepted_versions.get("model_version", ""))
	if model_id.is_empty() or model_version.is_empty():
		return null
	if model_id != _last_model_id:
		_descriptor = PhysicsRigDescriptor.load_for_model(model_id)
		_last_model_id = model_id
	if _descriptor == null:
		contract_error = "missing physics rig descriptor for %s" % model_id
		return null
	if not _descriptor.is_valid_for(model_id, model_version):
		contract_error = _descriptor.validation_error()
		return null
	contract_error = ""
	var terrain := _terrain_world.terrain_state.surface_snapshot()
	var excavation := _excavation_world.get_status_snapshot() if _excavation_world != null else {}
	var chassis := _chassis.get_status_snapshot() if _chassis != null else {}
	var raw: Dictionary = pose.get("raw", {})
	var joint_positions: Array = raw.get("joint_position", [0.0, 0.0, 0.0, 0.0])
	var joint_velocities: Array = raw.get("joint_velocity", [0.0, 0.0, 0.0, 0.0])
	var body_frames := {
		"chassis": "base_link", "upper": "upper_structure_link", "boom": "boom_link",
		"arm": "arm_link", "bucket": "bucket_link",
	}
	var bodies: Array[Dictionary] = []
	for body_name in body_frames:
		var frame := _presentation.get_frame_node(body_frames[body_name])
		if frame == null:
			return null
		bodies.append({
			"name": body_name,
			"transform": MotionProtocol.transform_to_canonical_rows(frame.global_transform),
			"linear_velocity_m_s": [0.0, 0.0, 0.0],
			"angular_velocity_rad_s": [0.0, 0.0, 0.0],
			"sleeping": false,
		})
	var joints: Array[Dictionary] = []
	for index in MotionProtocol.JOINT_NAMES.size():
		joints.append({
			"name": MotionProtocol.JOINT_NAMES[index],
			"position_rad": float(joint_positions[index]),
			"velocity_rad_s": float(joint_velocities[index]),
			"effort_n": 0.0,
		})
	var center := excavation.get("center_of_mass_local", Vector3.ZERO) as Vector3
	var result := {
		"schema_version": "simulation-truth-v1",
		"authority_profile": AuthorityProfile.JOLT_SHADOW,
		"authority_epoch": _authority_epoch,
		"sequence": _sequence,
		"physics_tick": Engine.get_physics_frames(),
		"monotonic_time_ns": Time.get_ticks_usec() * 1000,
		"coordinate_basis": "canonical-z-up-right-handed-meters",
		"identity": {
			"session_id": _motion_client.session_id,
			"simulation_epoch": _motion_client.simulation_epoch,
			"model_id": model_id,
			"model_version": model_version,
			"rig_id": _descriptor.rig_id(),
			"rig_version": _descriptor.rig_version(),
			"calibration_version": String(_motion_client.accepted_versions.get("calibration_version", "")),
			"terrain_epoch": String(terrain.get("terrain_epoch", "unknown")),
			"terrain_revision": int(terrain.get("terrain_revision", 0)),
			"world_generation": int(terrain.get("world_generation", 0)),
		},
		"gravity_m_s2": [0.0, 0.0, -9.80665],
		"bodies": bodies,
		"joints": joints,
		"tracks": {
			"left_command": float(chassis.get("left_command", 0.0)),
			"right_command": float(chassis.get("right_command", 0.0)),
			"left_speed_m_s": float(chassis.get("left_speed_mps", 0.0)),
			"right_speed_m_s": float(chassis.get("right_speed_mps", 0.0)),
			"grounded": true,
		},
		"payload": {
			"mass_kg": float(excavation.get("payload_mass_kg", 0.0)),
			"volume_m3": float(excavation.get("bucket_volume_m3", 0.0)),
			"fill_ratio": clampf(float(excavation.get("fill_ratio", 0.0)), 0.0, 1.5),
			"center_of_mass_m": MotionProtocol.vector_to_canonical_array(center),
		},
		"contacts": [],
		"quality_flags": ["shadow_observation", "kinematic_body_velocity_unavailable", "jolt_contact_manifold_unavailable"],
	}
	_sequence += 1
	return SimulationTruthSnapshot.from_dictionary(result)


func get_last_snapshot() -> Dictionary:
	return _last_snapshot.to_dictionary() if _last_snapshot != null else {}


func get_status_snapshot() -> Dictionary:
	return {
		"authority_profile": authority_profile,
		"contract_error": contract_error,
		"publishing": AuthorityProfile.publishes_shadow(authority_profile) and contract_error.is_empty(),
		"sequence": _sequence,
		"model_id": _last_model_id,
	}


func _on_authority_changed(_session_id: String, _simulation_epoch: String, _generation: int) -> void:
	if _motion_client != null:
		_motion_client.clear_simulation_truth_shadow()


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

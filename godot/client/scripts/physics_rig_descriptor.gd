class_name PhysicsRigDescriptor
extends RefCounted

const CATALOG_PATH := "res://resources/models/model_catalog.json"
const BODY_NAMES := ["chassis", "upper", "boom", "arm", "bucket"]
const JOINT_NAMES := ["swing_joint", "boom_joint", "arm_joint", "bucket_joint"]
const TOP_LEVEL_FIELDS := [
	"schema_version", "rig_id", "rig_version", "model_id", "model_version",
	"coordinate_basis", "provenance", "collision_layers", "bodies", "joints",
	"self_collision_mode", "chassis_dynamics", "tracks", "quality_flags",
]
const BODY_FIELDS := ["name", "frame", "rest_transform_godot", "mass_kg", "center_of_mass_m", "inertia_diagonal_kg_m2", "shape"]
const SHAPE_FIELDS := ["kind", "center_m", "size_m"]
const JOINT_FIELDS := [
	"name", "type", "parent_body", "child_body", "frame", "parent_anchor_godot",
	"child_anchor_godot", "axis", "axis_frame", "limit_rad", "collide_connected",
	"actuator",
]
const ACTUATOR_FIELDS := [
	"mode", "max_torque_nm", "max_velocity_rad_s", "max_acceleration_rad_s2",
	"max_jerk_rad_s3", "damping",
]
const CHASSIS_DYNAMICS_FIELDS := [
	"mass_kg", "center_of_mass_m", "inertia_diagonal_kg_m2", "linear_damp",
	"angular_damp", "max_linear_speed_m_s", "max_angular_speed_rad_s",
	"attitude_stiffness_nm_per_rad", "attitude_damping_nm_s_per_rad",
	"max_attitude_torque_nm",
	"ground_clearance_m", "can_sleep", "continuous_collision_detection",
	"compound_shapes",
]
const OPTIONAL_CHASSIS_DYNAMICS_FIELDS := ["spawn_yaw_rad"]
const TRACK_FIELDS := [
	"gauge_m", "contact_length_m", "contact_width_m", "traction_points_per_side",
	"friction", "max_drive_force_n", "max_belt_speed_m_s", "brake_force_n",
	"traction_response_n_per_m_s", "lateral_resistance_n_per_m_s",
	"probe_height_m", "probe_depth_m", "support_rest_length_m",
	"support_stiffness_n_per_m", "support_damping_n_s_per_m",
	"max_support_force_n", "pivot_lateral_resistance_scale", "yaw_assist_scale",
	]
const OPTIONAL_TRACK_RESPONSE_FIELDS := [
	"drive_effort_slew_n_per_tick", "brake_effort_slew_n_per_tick",
	"acceleration_window_s", "brake_stop_window_s",
]
const OPTIONAL_TRACK_ORIENTATION_FIELDS := ["local_forward_axis"]
const BODY_FRAMES := {
	"chassis": "base_link",
	"upper": "upper_structure_link",
	"boom": "boom_link",
	"arm": "arm_link",
	"bucket": "bucket_link",
}
const JOINT_TOPOLOGY := {
	"swing_joint": ["continuous_hinge", "chassis", "upper", "upper_structure_link"],
	"boom_joint": ["hinge", "upper", "boom", "boom_link"],
	"arm_joint": ["hinge", "boom", "arm", "arm_link"],
	"bucket_joint": ["hinge", "arm", "bucket", "bucket_link"],
}

var _data: Dictionary = {}
var _validation_error := ""
var _expected_sha256 := ""
var _actual_sha256 := ""


static func load_for_model(model_id: String) -> PhysicsRigDescriptor:
	var catalog := _load_json(CATALOG_PATH)
	for candidate in catalog.get("models", []):
		if candidate is Dictionary and String(candidate.get("model_id", "")) == model_id:
			var descriptor := PhysicsRigDescriptor.new()
			var rig_path := String(candidate.get("physics_rig_path", ""))
			descriptor._data = _load_json(rig_path)
			descriptor._expected_sha256 = String(candidate.get("physics_rig_sha256", ""))
			descriptor._actual_sha256 = FileAccess.get_sha256(rig_path) if FileAccess.file_exists(rig_path) else ""
			return descriptor
	return null


static func from_dictionary_for_test(data: Dictionary) -> PhysicsRigDescriptor:
	var descriptor := PhysicsRigDescriptor.new()
	descriptor._data = data.duplicate(true)
	return descriptor


func is_valid_for(model_id: String, model_version: String) -> bool:
	_validation_error = ""
	if not _expected_sha256.is_empty() and _actual_sha256 != _expected_sha256:
		return _reject("physics_rig_sha256", "does not match model catalog")
	if not _exact_fields(_data, TOP_LEVEL_FIELDS, "descriptor"):
		return false
	if _data.get("schema_version") != "physics-rig-v1":
		return _reject("schema_version", "must equal physics-rig-v1")
	if _data.get("coordinate_basis") != "godot-y-up-right-handed-meters":
		return _reject("coordinate_basis", "must equal godot-y-up-right-handed-meters")
	if _data.get("model_id") != model_id:
		return _reject("model_id", "does not match active model")
	if _data.get("model_version") != model_version:
		return _reject("model_version", "does not match active model")
	if String(_data.get("rig_id", "")).is_empty():
		return _reject("rig_id", "must be a non-empty string")
	if String(_data.get("rig_version", "")).is_empty():
		return _reject("rig_version", "must be a non-empty string")
	if not _validate_provenance(_data.get("provenance")):
		return false
	if not _validate_collision_layers(_data.get("collision_layers")):
		return false
	if not ["disabled_provisional", "non_adjacent"].has(String(_data.get("self_collision_mode", ""))):
		return _reject("self_collision_mode", "has an unsupported value")
	if not _validate_bodies(_data.get("bodies")):
		return false
	if not _validate_joints(_data.get("joints")):
		return false
	if not _validate_chassis_dynamics(_data.get("chassis_dynamics")):
		return false
	if not _validate_tracks(_data.get("tracks")):
		return false
	return _validate_quality_flags(_data.get("quality_flags"))


func validation_error() -> String:
	return _validation_error


func to_dictionary() -> Dictionary:
	return _data.duplicate(true)


func rig_id() -> String:
	return String(_data.get("rig_id", ""))


func rig_version() -> String:
	return String(_data.get("rig_version", ""))


func model_version() -> String:
	return String(_data.get("model_version", ""))


func chassis_dynamics() -> Dictionary:
	return (_data.get("chassis_dynamics", {}) as Dictionary).duplicate(true)


func tracks() -> Dictionary:
	return (_data.get("tracks", {}) as Dictionary).duplicate(true)


func bodies() -> Array:
	return (_data.get("bodies", []) as Array).duplicate(true)


func joints() -> Array:
	return (_data.get("joints", []) as Array).duplicate(true)


func _validate_provenance(value: Variant) -> bool:
	if not value is Dictionary:
		return _reject("provenance", "must be an object")
	var provenance := value as Dictionary
	if not _exact_fields(provenance, ["status", "source_paths", "notes"], "provenance"):
		return false
	if not ["observed", "derived", "provisional"].has(String(provenance.get("status", ""))):
		return _reject("provenance.status", "has an unsupported value")
	var paths: Variant = provenance.get("source_paths")
	if not paths is Array or paths.is_empty():
		return _reject("provenance.source_paths", "must contain at least one path")
	for index in paths.size():
		if not paths[index] is String or String(paths[index]).is_empty():
			return _reject("provenance.source_paths[%d]" % index, "must be a non-empty string")
	if not provenance.get("notes") is String or String(provenance.get("notes")).is_empty():
		return _reject("provenance.notes", "must be a non-empty string")
	return true


func _validate_collision_layers(value: Variant) -> bool:
	if not value is Dictionary:
		return _reject("collision_layers", "must be an object")
	var layers := value as Dictionary
	if not _exact_fields(layers, ["machine", "terrain", "payload"], "collision_layers"):
		return false
	for name in ["machine", "terrain", "payload"]:
		var layer: Variant = layers.get(name)
		if not _integer_in_range(layer, 1, 32):
			return _reject("collision_layers.%s" % name, "must be an integer from 1 to 32")
	return true


func _validate_bodies(value: Variant) -> bool:
	if not value is Array or value.size() != BODY_NAMES.size():
		return _reject("bodies", "must contain exactly five bodies")
	var found: Array[String] = []
	for index in value.size():
		if not value[index] is Dictionary:
			return _reject("bodies[%d]" % index, "must be an object")
		var body := value[index] as Dictionary
		var path := "bodies[%d]" % index
		if not _exact_fields(body, BODY_FIELDS, path):
			return false
		var name := String(body.get("name", ""))
		if not BODY_NAMES.has(name) or found.has(name):
			return _reject("%s.name" % path, "must be a unique known body")
		if body.get("frame") != BODY_FRAMES[name]:
			return _reject("%s.frame" % path, "does not match body topology")
		if not _transform_rows(body.get("rest_transform_godot"), "%s.rest_transform_godot" % path):
			return false
		if not _positive_number(body.get("mass_kg")):
			return _reject("%s.mass_kg" % path, "must be finite and positive")
		if not _vec3(body.get("center_of_mass_m"), "%s.center_of_mass_m" % path):
			return false
		if not _vec3(body.get("inertia_diagonal_kg_m2"), "%s.inertia_diagonal_kg_m2" % path, true):
			return false
		if not _validate_shape(body.get("shape"), "%s.shape" % path):
			return false
		found.append(name)
	return true


func _validate_shape(value: Variant, path: String) -> bool:
	if not value is Dictionary:
		return _reject(path, "must be an object")
	var shape := value as Dictionary
	if not _exact_fields(shape, SHAPE_FIELDS, path):
		return false
	if not ["box", "capsule", "convex_proxy"].has(String(shape.get("kind", ""))):
		return _reject("%s.kind" % path, "has an unsupported value")
	if not _vec3(shape.get("center_m"), "%s.center_m" % path):
		return false
	return _vec3(shape.get("size_m"), "%s.size_m" % path, true)


func _validate_joints(value: Variant) -> bool:
	if not value is Array or value.size() != JOINT_NAMES.size():
		return _reject("joints", "must contain exactly four joints")
	var found: Array[String] = []
	for index in value.size():
		if not value[index] is Dictionary:
			return _reject("joints[%d]" % index, "must be an object")
		var joint := value[index] as Dictionary
		var path := "joints[%d]" % index
		if not _exact_fields(joint, JOINT_FIELDS, path):
			return false
		var name := String(joint.get("name", ""))
		if not JOINT_NAMES.has(name) or found.has(name):
			return _reject("%s.name" % path, "must be a unique known joint")
		var topology: Array = JOINT_TOPOLOGY[name]
		var topology_fields: Array[String] = ["type", "parent_body", "child_body", "frame"]
		for field_index in 4:
			var field: String = topology_fields[field_index]
			if joint.get(field) != topology[field_index]:
				return _reject("%s.%s" % [path, field], "does not match joint topology")
		if not _transform_rows(joint.get("parent_anchor_godot"), "%s.parent_anchor_godot" % path):
			return false
		if not _transform_rows(joint.get("child_anchor_godot"), "%s.child_anchor_godot" % path):
			return false
		if not _vec3(joint.get("axis"), "%s.axis" % path):
			return false
		var axis_data := joint.get("axis") as Array
		var axis := Vector3(float(axis_data[0]), float(axis_data[1]), float(axis_data[2]))
		if not is_equal_approx(axis.length(), 1.0):
			return _reject("%s.axis" % path, "must be a unit vector")
		if joint.get("axis_frame") != "child_anchor_local":
			return _reject("%s.axis_frame" % path, "must equal child_anchor_local")
		if not joint.get("collide_connected") is bool:
			return _reject("%s.collide_connected" % path, "must be boolean")
		var limits: Variant = joint.get("limit_rad")
		if not limits is Array or limits.size() != 2:
			return _reject("%s.limit_rad" % path, "must contain lower and upper limits")
		if not _finite_number(limits[0]) or not _finite_number(limits[1]) or float(limits[0]) >= float(limits[1]):
			return _reject("%s.limit_rad" % path, "must be finite and strictly increasing")
		if float(limits[0]) > 0.0 or float(limits[1]) < 0.0:
			return _reject("%s.limit_rad" % path, "must contain the descriptor rest pose")
		if not _validate_actuator(joint.get("actuator"), "%s.actuator" % path):
			return false
		found.append(name)
	return _validate_rest_closure(value)


func _validate_rest_closure(joints: Array) -> bool:
	var bodies_by_name := {}
	for body_value in _data.get("bodies", []):
		var body := body_value as Dictionary
		bodies_by_name[String(body.get("name", ""))] = _rows_to_transform(body.get("rest_transform_godot", []))
	for index in joints.size():
		var joint := joints[index] as Dictionary
		var parent_rest := bodies_by_name.get(String(joint.get("parent_body", ""))) as Transform3D
		var child_rest := bodies_by_name.get(String(joint.get("child_body", ""))) as Transform3D
		var parent_anchor := _rows_to_transform(joint.get("parent_anchor_godot", []))
		var child_anchor := _rows_to_transform(joint.get("child_anchor_godot", []))
		var parent_world := parent_rest * parent_anchor
		var child_world := child_rest * child_anchor
		if parent_world.origin.distance_to(child_world.origin) > 0.0001:
			return _reject("joints[%d].parent_anchor_godot" % index, "does not close against child anchor at rest")
		if _basis_max_abs_difference(parent_world.basis, child_world.basis) > 0.0001:
			return _reject("joints[%d].parent_anchor_godot" % index, "has a rest orientation mismatch")
	return true


func _validate_actuator(value: Variant, path: String) -> bool:
	if not value is Dictionary:
		return _reject(path, "must be an object")
	var actuator := value as Dictionary
	if not _exact_fields(actuator, ACTUATOR_FIELDS, path):
		return false
	if actuator.get("mode") != "velocity_motor":
		return _reject("%s.mode" % path, "must equal velocity_motor")
	for field in ["max_torque_nm", "max_velocity_rad_s", "max_acceleration_rad_s2", "max_jerk_rad_s3"]:
		if not _positive_number(actuator.get(field)):
			return _reject("%s.%s" % [path, field], "must be finite and positive")
	if not _finite_number(actuator.get("damping")) or float(actuator.get("damping")) < 0.0:
		return _reject("%s.damping" % path, "must be finite and non-negative")
	return true


func _validate_tracks(value: Variant) -> bool:
	if not value is Dictionary:
		return _reject("tracks", "must be an object")
	var tracks := value as Dictionary
	if not _fields_with_optional(tracks, TRACK_FIELDS, OPTIONAL_TRACK_RESPONSE_FIELDS + OPTIONAL_TRACK_ORIENTATION_FIELDS, "tracks"):
		return false
	if tracks.has("local_forward_axis") and String(tracks.get("local_forward_axis", "")) not in ["-Z", "+Z"]:
		return _reject("tracks.local_forward_axis", "must equal -Z or +Z")
	for field in TRACK_FIELDS:
		if field == "traction_points_per_side" or field == "friction":
			continue
		if not _positive_number(tracks.get(field)):
			return _reject("tracks.%s" % field, "must be finite and positive")
	for field in OPTIONAL_TRACK_RESPONSE_FIELDS:
		if tracks.has(field) and not _positive_number(tracks.get(field)):
			return _reject("tracks.%s" % field, "must be finite and positive when present")
	var points: Variant = tracks.get("traction_points_per_side")
	if not _integer_in_range(points, 2, 16):
		return _reject("tracks.traction_points_per_side", "must be an integer from 2 to 16")
	if not _finite_number(tracks.get("friction")) or float(tracks.get("friction")) < 0.0 or float(tracks.get("friction")) > 4.0:
		return _reject("tracks.friction", "must be finite and between 0 and 4")
	for field in ["pivot_lateral_resistance_scale", "yaw_assist_scale"]:
		if float(tracks.get(field)) > 1.0:
			return _reject("tracks.%s" % field, "must be at most 1")
	if float(tracks.get("pivot_lateral_resistance_scale")) <= 0.0:
		return _reject("tracks.pivot_lateral_resistance_scale", "must be greater than 0")
	return true


func _validate_chassis_dynamics(value: Variant) -> bool:
	if not value is Dictionary:
		return _reject("chassis_dynamics", "must be an object")
	var dynamics := value as Dictionary
	if not _fields_with_optional(dynamics, CHASSIS_DYNAMICS_FIELDS, OPTIONAL_CHASSIS_DYNAMICS_FIELDS, "chassis_dynamics"):
		return false
	if dynamics.has("spawn_yaw_rad"):
		var spawn_yaw := float(dynamics.get("spawn_yaw_rad", 0.0))
		if not _finite_number(dynamics.get("spawn_yaw_rad")) or absf(spawn_yaw) > PI:
			return _reject("chassis_dynamics.spawn_yaw_rad", "must be finite and within [-PI, PI]")
	for field in [
		"mass_kg", "max_linear_speed_m_s", "max_angular_speed_rad_s",
		"attitude_stiffness_nm_per_rad", "attitude_damping_nm_s_per_rad",
		"max_attitude_torque_nm", "ground_clearance_m",
	]:
		if not _positive_number(dynamics.get(field)):
			return _reject("chassis_dynamics.%s" % field, "must be finite and positive")
	for field in ["linear_damp", "angular_damp"]:
		if not _finite_number(dynamics.get(field)) or float(dynamics.get(field)) < 0.0:
			return _reject("chassis_dynamics.%s" % field, "must be finite and non-negative")
	if not dynamics.get("can_sleep") is bool:
		return _reject("chassis_dynamics.can_sleep", "must be boolean")
	if not dynamics.get("continuous_collision_detection") is bool:
		return _reject("chassis_dynamics.continuous_collision_detection", "must be boolean")
	if not _vec3(dynamics.get("center_of_mass_m"), "chassis_dynamics.center_of_mass_m"):
		return false
	if not _vec3(dynamics.get("inertia_diagonal_kg_m2"), "chassis_dynamics.inertia_diagonal_kg_m2", true):
		return false
	var compound_shapes: Variant = dynamics.get("compound_shapes")
	if not compound_shapes is Array or compound_shapes.size() < 2 or compound_shapes.size() > 8:
		return _reject("chassis_dynamics.compound_shapes", "must contain 2 to 8 primitive shapes")
	for index in compound_shapes.size():
		if not _validate_shape(compound_shapes[index], "chassis_dynamics.compound_shapes[%d]" % index):
			return false
		if String(compound_shapes[index].get("kind", "")) != "box":
			return _reject("chassis_dynamics.compound_shapes[%d].kind" % index, "must equal box in Phase 1")
	var inertia_data := dynamics.get("inertia_diagonal_kg_m2") as Array
	var inertia := Vector3(float(inertia_data[0]), float(inertia_data[1]), float(inertia_data[2]))
	if inertia.x >= inertia.y + inertia.z or inertia.y >= inertia.x + inertia.z or inertia.z >= inertia.x + inertia.y:
		return _reject("chassis_dynamics.inertia_diagonal_kg_m2", "must satisfy rigid-body triangle inequalities")
	return true


func _validate_quality_flags(value: Variant) -> bool:
	if not value is Array:
		return _reject("quality_flags", "must be an array")
	var found: Array[String] = []
	for index in value.size():
		if not value[index] is String or String(value[index]).is_empty() or found.has(String(value[index])):
			return _reject("quality_flags[%d]" % index, "must be a unique non-empty string")
		found.append(String(value[index]))
	return true


func _vec3(value: Variant, path: String, positive := false) -> bool:
	if not value is Array or value.size() != 3:
		return _reject(path, "must contain three numbers")
	for index in 3:
		if not _finite_number(value[index]) or (positive and float(value[index]) <= 0.0):
			return _reject("%s[%d]" % [path, index], "must be finite%s" % (" and positive" if positive else ""))
	return true


func _transform_rows(value: Variant, path: String) -> bool:
	if not value is Array or value.size() != 4:
		return _reject(path, "must contain four rows")
	for row_index in 4:
		if not value[row_index] is Array or value[row_index].size() != 4:
			return _reject("%s[%d]" % [path, row_index], "must contain four numbers")
		for column_index in 4:
			if not _finite_number(value[row_index][column_index]):
				return _reject("%s[%d][%d]" % [path, row_index, column_index], "must be finite")
	var rows := value as Array
	if not (
		is_zero_approx(float(rows[3][0]))
		and is_zero_approx(float(rows[3][1]))
		and is_zero_approx(float(rows[3][2]))
		and is_equal_approx(float(rows[3][3]), 1.0)
	):
		return _reject("%s[3]" % path, "must be a homogeneous [0, 0, 0, 1] row")
	var basis := _rows_to_transform(rows).basis
	if (
		absf(basis.x.length() - 1.0) > 0.0001
		or absf(basis.y.length() - 1.0) > 0.0001
		or absf(basis.z.length() - 1.0) > 0.0001
		or absf(basis.x.dot(basis.y)) > 0.0001
		or absf(basis.x.dot(basis.z)) > 0.0001
		or absf(basis.y.dot(basis.z)) > 0.0001
		or absf(basis.determinant() - 1.0) > 0.0001
	):
		return _reject(path, "must encode a right-handed rigid transform")
	return true


func _rows_to_transform(value: Array) -> Transform3D:
	return Transform3D(
		Basis(
			Vector3(float(value[0][0]), float(value[1][0]), float(value[2][0])),
			Vector3(float(value[0][1]), float(value[1][1]), float(value[2][1])),
			Vector3(float(value[0][2]), float(value[1][2]), float(value[2][2])),
		),
		Vector3(float(value[0][3]), float(value[1][3]), float(value[2][3])),
	)


func _basis_max_abs_difference(first: Basis, second: Basis) -> float:
	var result := 0.0
	for axis in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
		var delta: Vector3 = first * axis - second * axis
		result = maxf(result, maxf(absf(delta.x), maxf(absf(delta.y), absf(delta.z))))
	return result


func _exact_fields(value: Dictionary, required: Array, path: String) -> bool:
	for field in required:
		if not value.has(field):
			return _reject("%s.%s" % [path, field], "is required")
	for field in value:
		if not required.has(field):
			return _reject("%s.%s" % [path, field], "is not allowed")
	return true


func _fields_with_optional(value: Dictionary, required: Array, optional: Array, path: String) -> bool:
	for field in required:
		if not value.has(field):
			return _reject("%s.%s" % [path, field], "is required")
	for field in value:
		if not required.has(field) and not optional.has(field):
			return _reject("%s.%s" % [path, field], "is not allowed")
	return true


func _finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


func _positive_number(value: Variant) -> bool:
	return _finite_number(value) and float(value) > 0.0


func _integer_in_range(value: Variant, minimum: int, maximum: int) -> bool:
	return (
		_finite_number(value)
		and float(value) == floorf(float(value))
		and float(value) >= minimum
		and float(value) <= maximum
	)


func _reject(path: String, reason: String) -> bool:
	_validation_error = "%s: %s" % [path, reason]
	return false


static func _load_json(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return (parsed as Dictionary).duplicate(true) if parsed is Dictionary else {}

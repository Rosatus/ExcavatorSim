class_name PhysicsRigDescriptor
extends RefCounted

const CATALOG_PATH := "res://resources/models/model_catalog.json"
const BODY_NAMES := ["chassis", "upper", "boom", "arm", "bucket"]
const JOINT_NAMES := ["swing_joint", "boom_joint", "arm_joint", "bucket_joint"]
const TOP_LEVEL_FIELDS := [
	"schema_version", "rig_id", "rig_version", "model_id", "model_version",
	"coordinate_basis", "provenance", "collision_layers", "bodies", "joints",
	"tracks", "quality_flags",
]
const BODY_FIELDS := ["name", "frame", "mass_kg", "center_of_mass_m", "inertia_diagonal_kg_m2", "shape"]
const SHAPE_FIELDS := ["kind", "center_m", "size_m"]
const JOINT_FIELDS := ["name", "type", "parent_body", "child_body", "frame", "axis", "limit_rad", "actuator"]
const ACTUATOR_FIELDS := ["mode", "max_force_n", "max_velocity_rad_s", "damping"]
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


static func load_for_model(model_id: String) -> PhysicsRigDescriptor:
	var catalog := _load_json(CATALOG_PATH)
	for candidate in catalog.get("models", []):
		if candidate is Dictionary and String(candidate.get("model_id", "")) == model_id:
			var descriptor := PhysicsRigDescriptor.new()
			descriptor._data = _load_json(String(candidate.get("physics_rig_path", "")))
			return descriptor
	return null


static func from_dictionary_for_test(data: Dictionary) -> PhysicsRigDescriptor:
	var descriptor := PhysicsRigDescriptor.new()
	descriptor._data = data.duplicate(true)
	return descriptor


func is_valid_for(model_id: String, model_version: String) -> bool:
	_validation_error = ""
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
	if not _validate_bodies(_data.get("bodies")):
		return false
	if not _validate_joints(_data.get("joints")):
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
		if not _vec3(joint.get("axis"), "%s.axis" % path):
			return false
		var axis_data := joint.get("axis") as Array
		var axis := Vector3(float(axis_data[0]), float(axis_data[1]), float(axis_data[2]))
		if not is_equal_approx(axis.length(), 1.0):
			return _reject("%s.axis" % path, "must be a unit vector")
		var limits: Variant = joint.get("limit_rad")
		if not limits is Array or limits.size() != 2:
			return _reject("%s.limit_rad" % path, "must contain lower and upper limits")
		if not _finite_number(limits[0]) or not _finite_number(limits[1]) or float(limits[0]) >= float(limits[1]):
			return _reject("%s.limit_rad" % path, "must be finite and strictly increasing")
		if not _validate_actuator(joint.get("actuator"), "%s.actuator" % path):
			return false
		found.append(name)
	return true


func _validate_actuator(value: Variant, path: String) -> bool:
	if not value is Dictionary:
		return _reject(path, "must be an object")
	var actuator := value as Dictionary
	if not _exact_fields(actuator, ACTUATOR_FIELDS, path):
		return false
	if actuator.get("mode") != "velocity_motor":
		return _reject("%s.mode" % path, "must equal velocity_motor")
	for field in ["max_force_n", "max_velocity_rad_s"]:
		if not _positive_number(actuator.get(field)):
			return _reject("%s.%s" % [path, field], "must be finite and positive")
	if not _finite_number(actuator.get("damping")) or float(actuator.get("damping")) < 0.0:
		return _reject("%s.damping" % path, "must be finite and non-negative")
	return true


func _validate_tracks(value: Variant) -> bool:
	if not value is Dictionary:
		return _reject("tracks", "must be an object")
	var tracks := value as Dictionary
	var fields := ["gauge_m", "contact_length_m", "contact_width_m", "traction_points_per_side", "friction", "max_drive_force_n"]
	if not _exact_fields(tracks, fields, "tracks"):
		return false
	for field in ["gauge_m", "contact_length_m", "contact_width_m", "max_drive_force_n"]:
		if not _positive_number(tracks.get(field)):
			return _reject("tracks.%s" % field, "must be finite and positive")
	var points: Variant = tracks.get("traction_points_per_side")
	if not _integer_in_range(points, 2, 16):
		return _reject("tracks.traction_points_per_side", "must be an integer from 2 to 16")
	if not _finite_number(tracks.get("friction")) or float(tracks.get("friction")) < 0.0 or float(tracks.get("friction")) > 4.0:
		return _reject("tracks.friction", "must be finite and between 0 and 4")
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


func _exact_fields(value: Dictionary, required: Array, path: String) -> bool:
	for field in required:
		if not value.has(field):
			return _reject("%s.%s" % [path, field], "is required")
	for field in value:
		if not required.has(field):
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

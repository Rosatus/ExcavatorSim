class_name EquipmentCommandMapper
extends RefCounted

const PROFILE_PATH := "res://resources/protocol/equipment-command-profile-v1.json"
const SCHEMA_VERSION := "equipment-command-profile-v1"
const AXIS_ORDER := ["swing", "boom", "arm", "bucket"]
const POSITIVE_SEMANTICS := ["right_rotation", "boom_raise", "arm_extend", "bucket_curl"]
const NEGATIVE_SEMANTICS := ["left_rotation", "boom_lower", "arm_retract", "bucket_dump"]
const MODEL_IDS := ["sy205", "sy135"]
const INPUT_ACTIONS := {
	"operator_swing_right": {"keys": [KEY_D], "joy_axis": JOY_AXIS_LEFT_X, "joy_sign": 1.0},
	"operator_swing_left": {"keys": [KEY_A], "joy_axis": JOY_AXIS_LEFT_X, "joy_sign": -1.0},
	# ISO pattern: right-stick down raises the boom; left-stick up extends the arm.
	"operator_boom_raise": {"keys": [KEY_K], "joy_axis": JOY_AXIS_RIGHT_Y, "joy_sign": 1.0},
	"operator_boom_lower": {"keys": [KEY_I], "joy_axis": JOY_AXIS_RIGHT_Y, "joy_sign": -1.0},
	"operator_arm_extend": {"keys": [KEY_W], "joy_axis": JOY_AXIS_LEFT_Y, "joy_sign": -1.0},
	"operator_arm_retract": {"keys": [KEY_S], "joy_axis": JOY_AXIS_LEFT_Y, "joy_sign": 1.0},
	"operator_bucket_curl": {"keys": [KEY_J], "joy_axis": JOY_AXIS_RIGHT_X, "joy_sign": -1.0},
	"operator_bucket_dump": {"keys": [KEY_L], "joy_axis": JOY_AXIS_RIGHT_X, "joy_sign": 1.0},
}

var _models: Dictionary = {}
var _model_id := ""
var _signs := Vector4.ZERO
var _last_error := ""


func _init(profile_path: String = PROFILE_PATH) -> void:
	_load_profile(profile_path)


func configure_model(model_id: String) -> bool:
	if not _models.has(model_id):
		if _models.is_empty() and not _last_error.is_empty():
			_model_id = ""
			_signs = Vector4.ZERO
			return false
		_last_error = "unknown or unavailable equipment command profile: %s" % model_id
		_model_id = ""
		_signs = Vector4.ZERO
		return false
	var entry := _models[model_id] as Dictionary
	var values := entry["semantic_to_joint_signs"] as Array
	_signs = Vector4(float(values[0]), float(values[1]), float(values[2]), float(values[3]))
	_model_id = model_id
	_last_error = ""
	return true


func read_operator_axes() -> Vector4:
	return Vector4(
		Input.get_axis("operator_swing_left", "operator_swing_right"),
		Input.get_axis("operator_boom_lower", "operator_boom_raise"),
		Input.get_axis("operator_arm_retract", "operator_arm_extend"),
		Input.get_axis("operator_bucket_dump", "operator_bucket_curl"),
	)


func to_joint_axes(operator_axes: Vector4) -> Vector4:
	if _model_id.is_empty() or not operator_axes.is_finite():
		return Vector4.ZERO
	return Vector4(
		clampf(operator_axes.x, -1.0, 1.0) * _signs.x,
		clampf(operator_axes.y, -1.0, 1.0) * _signs.y,
		clampf(operator_axes.z, -1.0, 1.0) * _signs.z,
		clampf(operator_axes.w, -1.0, 1.0) * _signs.w,
	)


func get_model_id() -> String:
	return _model_id


func get_last_error() -> String:
	return _last_error


func _load_profile(path: String) -> void:
	_models.clear()
	_model_id = ""
	_signs = Vector4.ZERO
	if not FileAccess.file_exists(path):
		_last_error = "equipment command profile is unavailable"
		return
	if FileAccess.get_sha256(path) != EquipmentCommandProfileHash.SHA256:
		_last_error = "equipment command profile SHA-256 mismatch"
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		_last_error = "equipment command profile must be a JSON object"
		return
	var payload := parsed as Dictionary
	if not _has_exact_keys(payload, ["schema_version", "axis_order", "positive_semantics", "negative_semantics", "models"]):
		_last_error = "equipment command profile fields are invalid"
		return
	if (
		String(payload["schema_version"]) != SCHEMA_VERSION
		or payload["axis_order"] != AXIS_ORDER
		or payload["positive_semantics"] != POSITIVE_SEMANTICS
		or payload["negative_semantics"] != NEGATIVE_SEMANTICS
		or not payload["models"] is Dictionary
	):
		_last_error = "equipment command profile semantics are invalid"
		return
	var models := payload["models"] as Dictionary
	if not _has_exact_keys(models, MODEL_IDS):
		_last_error = "equipment command profile model set is invalid"
		return
	for model_id in MODEL_IDS:
		var entry: Variant = models[model_id]
		if not entry is Dictionary or not _has_exact_keys(entry as Dictionary, ["semantic_to_joint_signs", "evidence"]):
			_last_error = "equipment command model fields are invalid: %s" % model_id
			return
		var signs: Variant = (entry as Dictionary)["semantic_to_joint_signs"]
		if not signs is Array or (signs as Array).size() != 4 or String((entry as Dictionary)["evidence"]).is_empty():
			_last_error = "equipment command model payload is invalid: %s" % model_id
			return
		for sign in signs as Array:
			if not (sign is int or sign is float) or not [ -1.0, 1.0 ].has(float(sign)):
				_last_error = "equipment command signs must be +/-1: %s" % model_id
				return
	_models = models.duplicate(true)
	_last_error = ""


func _has_exact_keys(value: Dictionary, expected: Array) -> bool:
	if value.size() != expected.size():
		return false
	for key in expected:
		if not value.has(key):
			return false
	return true

class_name WheeledMachineProfile
extends RefCounted
## Optional, separately versioned wheel adapter; legacy physics-rig-v1 remains
## the work-equipment and compatibility contract. No model IDs in the solver.
const PATH := "res://resources/physics/wheeled_machine_profiles.json"
var enabled := false
var error := ""
var data: Dictionary = {}
var stations: Array[Dictionary] = []

static func load_for_model(model_id: String) -> WheeledMachineProfile:
	var result := WheeledMachineProfile.new()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not parsed is Dictionary or parsed.get("schema_version") != 1 or not parsed.get("profiles") is Dictionary:
		result.error = "invalid wheeled profile registry"
		return result
	if not parsed.profiles.has(model_id):
		return result
	if not parsed.profiles[model_id] is Dictionary:
		result.error = "invalid wheeled profile: " + model_id
		return result
	result.data = parsed.profiles[model_id].duplicate(true)
	result._validate()
	return result

func _validate() -> void:
	if not data.get("parameters") is Dictionary or not data.get("wheels") is Array or not data.get("hulls") is Array or data.hulls.is_empty():
		error = "missing wheel parameters, stations or hulls"
		return
	for row in data.wheels:
		if not row is Dictionary or not _vec_valid(row.get("mount")) or not _vec_valid(row.get("rest_origin")):
			error = "invalid wheel mount"
			return
		for key in ["pivot_path", "roll_path"]:
			if not row.get(key) is String or String(row[key]).is_empty():
				error = "invalid wheel visual path"
				return
		if not _number(row.get("rest_suspension_length_m"), 0.0):
			error = "invalid rest suspension length"
			return
		if not row.get("rest_basis") is Array or row.rest_basis.size() != 3:
			error = "invalid wheel pivot basis"
			return
		for column in row.rest_basis:
			if not _vec_valid(column):
				error = "invalid wheel pivot basis"
				return
		var station: Dictionary = row.duplicate(true)
		station.mount = vec(row.mount)
		stations.append(station)
	for hull in data.hulls:
		if not hull is Dictionary or not _vec_valid(hull.get("center_m")) or not _vec_valid(hull.get("size_m")):
			error = "invalid wheel chassis hull"
			return
		var size := vec(hull.size_m)
		if minf(size.x, minf(size.y, size.z)) <= 0.0:
			error = "invalid wheel chassis hull size"
			return
	for key in ["linear_damp", "angular_damp", "collision_wheel_width_m"]:
		if not _number(data.get(key), 0.0):
			error = "invalid wheel chassis parameter: " + key
			return
	for key in ["roll_axis", "steer_axis"]:
		if not _vec_valid(data.get(key)) or not is_equal_approx(vec(data[key]).length(), 1.0):
			error = "invalid wheel axis: " + key
			return
	var solver := WheeledLocomotionState.new()
	if not solver.configure(data.parameters, stations):
		error = solver.last_error
		return
	var path := String(data.get("asset_path", ""))
	if path.is_empty() or not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != String(data.get("asset_sha256", "")):
		error = "wheel profile asset SHA-256 mismatch"
		return
	enabled = true

static func _number(value: Variant, minimum: float) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and float(value) >= minimum

static func _vec_valid(value: Variant) -> bool:
	if not value is Array or value.size() != 3:
		return false
	for component in value:
		if not (component is float or component is int) or not is_finite(float(component)):
			return false
	return true

static func vec(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))

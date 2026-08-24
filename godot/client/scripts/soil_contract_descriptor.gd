class_name SoilContractDescriptor
extends RefCounted

## Hash-bound owner for the complete per-model soil contract. Both presentation
## and Jolt load through this class so a malformed semantic tool cannot be
## accepted by one runtime and rejected by another.

const CATALOG_PATH := "res://resources/models/model_catalog.json"
const SCHEMA_VERSION := "excavator-soil-contract-v1"
const TOOL_SCHEMA_VERSION := "bucket-soil-tool-v1"
const TOP_LEVEL_FIELDS := [
	"schema_version", "model_id", "material_density_kg_m3",
	"nominal_capacity_m3", "heaped_capacity_m3", "cell_grid",
	"interaction", "proxies", "bucket_tool",
]
const INTERACTION_FIELDS := [
	"contact_tolerance_m", "maximum_cut_depth_m", "minimum_sweep_m",
	"cut_radius_m", "deposit_radius_m", "spill_opening_down_dot",
	"dump_opening_down_dot",
]
const PROXY_NAMES := ["cutting_edge", "top_edge", "opening", "cavity", "shell", "rear_support"]
const REGION_IDS := [
	"teeth_main_edge", "left_side_cutter", "right_side_cutter",
	"floor_wear_plate", "outer_back", "outer_left_side",
	"outer_right_side", "inner_shell", "opening",
]
const REGION_KINDS := {
	"teeth_main_edge": "teeth",
	"left_side_cutter": "side_cutter",
	"right_side_cutter": "side_cutter",
	"floor_wear_plate": "floor",
	"outer_back": "outer_shell",
	"outer_left_side": "outer_shell",
	"outer_right_side": "outer_shell",
	"inner_shell": "inner_shell",
	"opening": "opening",
}
const STABLE_ROLES := ["cut", "side_cut", "scrape", "push", "back_drag", "grade", "compact"]
const ACTIVE_ROLES := ["contain", "entry", "spill", "dump"]

var _data: Dictionary = {}
var _validation_error := ""
var _expected_sha256 := ""
var _actual_sha256 := ""


static func load_for_model(model_id: String) -> SoilContractDescriptor:
	var catalog := _load_json(CATALOG_PATH)
	for candidate_value in catalog.get("models", []):
		if not candidate_value is Dictionary:
			continue
		var candidate := candidate_value as Dictionary
		if String(candidate.get("model_id", "")) != model_id:
			continue
		var descriptor := SoilContractDescriptor.new()
		var path := String(candidate.get("soil_contract_path", ""))
		descriptor._data = _load_json(path)
		descriptor._expected_sha256 = String(candidate.get("soil_contract_sha256", ""))
		descriptor._actual_sha256 = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else ""
		return descriptor
	return null


static func from_dictionary_for_test(data: Dictionary) -> SoilContractDescriptor:
	var descriptor := SoilContractDescriptor.new()
	descriptor._data = data.duplicate(true)
	return descriptor


func is_valid_for(model_id: String) -> bool:
	_validation_error = ""
	if not _expected_sha256.is_empty() and _actual_sha256 != _expected_sha256:
		return _reject("soil_contract_sha256", "does not match model catalog")
	if not _exact_fields(_data, TOP_LEVEL_FIELDS, "descriptor"):
		return false
	if _data.get("schema_version") != SCHEMA_VERSION:
		return _reject("schema_version", "must equal %s" % SCHEMA_VERSION)
	if _data.get("model_id") != model_id or model_id.is_empty():
		return _reject("model_id", "does not match active model")
	for field in ["material_density_kg_m3", "nominal_capacity_m3", "heaped_capacity_m3"]:
		if not _positive_number(_data.get(field)):
			return _reject(field, "must be finite and positive")
	if float(_data["nominal_capacity_m3"]) > float(_data["heaped_capacity_m3"]):
		return _reject("heaped_capacity_m3", "must be at least nominal capacity")
	if not _validate_grid(_data.get("cell_grid")):
		return false
	if not _validate_interaction(_data.get("interaction")):
		return false
	if not _validate_proxies(_data.get("proxies")):
		return false
	return _validate_bucket_tool(_data.get("bucket_tool"))


func validation_error() -> String:
	return _validation_error


func to_dictionary() -> Dictionary:
	return _data.duplicate(true)


func tool_contract() -> Dictionary:
	return (_data.get("bucket_tool", {}) as Dictionary).duplicate(true)


func _validate_grid(value: Variant) -> bool:
	if not value is Array or value.size() != 3:
		return _reject("cell_grid", "must contain three dimensions")
	for index in 3:
		if not _integer_in_range(value[index], 2, 32):
			return _reject("cell_grid[%d]" % index, "must be an integer from 2 to 32")
	return true


func _validate_interaction(value: Variant) -> bool:
	if not value is Dictionary:
		return _reject("interaction", "must be an object")
	var interaction := value as Dictionary
	if not _exact_fields(interaction, INTERACTION_FIELDS, "interaction"):
		return false
	for field in ["contact_tolerance_m", "maximum_cut_depth_m", "minimum_sweep_m", "cut_radius_m", "deposit_radius_m"]:
		if not _positive_number(interaction.get(field)):
			return _reject("interaction.%s" % field, "must be finite and positive")
	var spill: Variant = interaction.get("spill_opening_down_dot")
	var dump: Variant = interaction.get("dump_opening_down_dot")
	if not _finite_number(spill) or not _finite_number(dump):
		return _reject("interaction.spill_opening_down_dot", "thresholds must be finite")
	if float(spill) < -1.0 or float(dump) > 1.0 or float(spill) >= float(dump):
		return _reject("interaction.spill_opening_down_dot", "must be below the bounded dump threshold")
	return true


func _validate_proxies(value: Variant) -> bool:
	if not value is Dictionary:
		return _reject("proxies", "must be an object")
	var proxies := value as Dictionary
	if not _exact_fields(proxies, PROXY_NAMES, "proxies"):
		return false
	var allowed_fields := {
		"cutting_edge": ["frame", "center_godot", "direction_godot", "half_width_m"],
		"top_edge": ["frame", "center_godot", "half_width_m"],
		"opening": ["frame", "center_godot", "normal_godot", "up_godot", "size_m"],
		"cavity": ["frame", "center_godot", "up_godot", "size_m"],
		"shell": ["frame", "center_godot", "up_godot", "size_m", "evidence"],
		"rear_support": ["frame", "center_godot", "radius_m"],
	}
	for name in PROXY_NAMES:
		var proxy_value: Variant = proxies.get(name)
		if not proxy_value is Dictionary:
			return _reject("proxies.%s" % name, "must be an object")
		var proxy := proxy_value as Dictionary
		if not _exact_fields(proxy, allowed_fields[name], "proxies.%s" % name):
			return false
		if proxy.get("frame") != "bucket_link":
			return _reject("proxies.%s.frame" % name, "must use the semantic bucket_link frame")
		if not _vec3(proxy.get("center_godot"), "proxies.%s.center_godot" % name):
			return false
	if not _unit_vec3((proxies["cutting_edge"] as Dictionary).get("direction_godot"), "proxies.cutting_edge.direction_godot"):
		return false
	if not _positive_number((proxies["cutting_edge"] as Dictionary).get("half_width_m")):
		return _reject("proxies.cutting_edge.half_width_m", "must be finite and positive")
	if not _positive_number((proxies["top_edge"] as Dictionary).get("half_width_m")):
		return _reject("proxies.top_edge.half_width_m", "must be finite and positive")
	for name in ["opening", "cavity", "shell"]:
		if not _unit_vec3((proxies[name] as Dictionary).get("up_godot"), "proxies.%s.up_godot" % name):
			return false
	if not _unit_vec3((proxies["opening"] as Dictionary).get("normal_godot"), "proxies.opening.normal_godot"):
		return false
	if not _positive_array((proxies["opening"] as Dictionary).get("size_m"), 2, "proxies.opening.size_m"):
		return false
	for name in ["cavity", "shell"]:
		if not _positive_array((proxies[name] as Dictionary).get("size_m"), 3, "proxies.%s.size_m" % name):
			return false
	if not _positive_number((proxies["rear_support"] as Dictionary).get("radius_m")):
		return _reject("proxies.rear_support.radius_m", "must be finite and positive")
	if String((proxies["shell"] as Dictionary).get("evidence", "")).is_empty():
		return _reject("proxies.shell.evidence", "must be a non-empty string")
	return true


func _validate_bucket_tool(value: Variant) -> bool:
	if not value is Dictionary:
		return _reject("bucket_tool", "must be an object")
	var tool := value as Dictionary
	if not _exact_fields(tool, ["schema_version", "frame", "capacity", "sweep", "regions"], "bucket_tool"):
		return false
	if tool.get("schema_version") != TOOL_SCHEMA_VERSION:
		return _reject("bucket_tool.schema_version", "must equal %s" % TOOL_SCHEMA_VERSION)
	if tool.get("frame") != "bucket_link":
		return _reject("bucket_tool.frame", "must equal bucket_link")
	if not _validate_capacity(tool.get("capacity")) or not _validate_sweep(tool.get("sweep")):
		return false
	var regions_value: Variant = tool.get("regions")
	if not regions_value is Array or regions_value.size() != REGION_IDS.size():
		return _reject("bucket_tool.regions", "must contain exactly the nine required semantic regions")
	var found: Array[String] = []
	var regions_by_id := {}
	for index in regions_value.size():
		if not regions_value[index] is Dictionary:
			return _reject("bucket_tool.regions[%d]" % index, "must be an object")
		var region := regions_value[index] as Dictionary
		var path := "bucket_tool.regions[%d]" % index
		if not _exact_fields(region, ["region_id", "kind", "center_godot", "outward_normal_godot", "shape", "stable_soil_roles", "active_soil_roles"], path):
			return false
		var region_id := String(region.get("region_id", ""))
		if not REGION_IDS.has(region_id) or found.has(region_id):
			return _reject("%s.region_id" % path, "must be a unique required region")
		if region_id != REGION_IDS[index]:
			return _reject("%s.region_id" % path, "must follow canonical region order")
		if region.get("kind") != REGION_KINDS[region_id]:
			return _reject("%s.kind" % path, "does not match region_id")
		if not _vec3(region.get("center_godot"), "%s.center_godot" % path):
			return false
		if not _unit_vec3(region.get("outward_normal_godot"), "%s.outward_normal_godot" % path):
			return false
		if not _validate_shape(region.get("shape"), "%s.shape" % path):
			return false
		if not _role_list(region.get("stable_soil_roles"), STABLE_ROLES, "%s.stable_soil_roles" % path):
			return false
		if not _role_list(region.get("active_soil_roles"), ACTIVE_ROLES, "%s.active_soil_roles" % path):
			return false
		found.append(region_id)
		regions_by_id[region_id] = region
	for region_id in REGION_IDS:
		if not found.has(region_id):
			return _reject("bucket_tool.regions", "is missing %s" % region_id)
	if not _validate_role_contract(regions_by_id):
		return false
	return _validate_geometry_consistency(regions_by_id)


func _validate_capacity(value: Variant) -> bool:
	if not value is Dictionary:
		return _reject("bucket_tool.capacity", "must be an object")
	var capacity := value as Dictionary
	if not _exact_fields(capacity, ["nominal_m3", "heaped_m3", "cavity_region"], "bucket_tool.capacity"):
		return false
	if capacity.get("cavity_region") != "inner_shell":
		return _reject("bucket_tool.capacity.cavity_region", "must equal inner_shell")
	if not _positive_number(capacity.get("nominal_m3")) or not _positive_number(capacity.get("heaped_m3")):
		return _reject("bucket_tool.capacity.nominal_m3", "capacities must be finite and positive")
	if not is_equal_approx(float(capacity["nominal_m3"]), float(_data["nominal_capacity_m3"])):
		return _reject("bucket_tool.capacity.nominal_m3", "must match nominal_capacity_m3")
	if not is_equal_approx(float(capacity["heaped_m3"]), float(_data["heaped_capacity_m3"])):
		return _reject("bucket_tool.capacity.heaped_m3", "must match heaped_capacity_m3")
	return true


func _validate_sweep(value: Variant) -> bool:
	if not value is Dictionary:
		return _reject("bucket_tool.sweep", "must be an object")
	var sweep := value as Dictionary
	if not _exact_fields(sweep, ["maximum_translation_step_m", "maximum_rotation_step_degrees", "maximum_samples"], "bucket_tool.sweep"):
		return false
	if not _positive_number(sweep.get("maximum_translation_step_m")) or float(sweep["maximum_translation_step_m"]) > 0.25:
		return _reject("bucket_tool.sweep.maximum_translation_step_m", "must be in (0, 0.25]")
	if not _positive_number(sweep.get("maximum_rotation_step_degrees")) or float(sweep["maximum_rotation_step_degrees"]) > 15.0:
		return _reject("bucket_tool.sweep.maximum_rotation_step_degrees", "must be in (0, 15]")
	if not _integer_in_range(sweep.get("maximum_samples"), 2, 24):
		return _reject("bucket_tool.sweep.maximum_samples", "must be an integer from 2 to 24")
	return true


func _validate_shape(value: Variant, path: String) -> bool:
	if not value is Dictionary:
		return _reject(path, "must be an object")
	var shape := value as Dictionary
	var kind := String(shape.get("kind", ""))
	if kind == "segment":
		if not _exact_fields(shape, ["kind", "axis_godot", "half_length_m", "radius_m"], path):
			return false
		return (
			_unit_vec3(shape.get("axis_godot"), "%s.axis_godot" % path)
			and _positive_number_or_reject(shape.get("half_length_m"), "%s.half_length_m" % path)
			and _positive_number_or_reject(shape.get("radius_m"), "%s.radius_m" % path)
		)
	if kind == "box":
		if not _exact_fields(shape, ["kind", "size_m"], path):
			return false
		return _positive_array(shape.get("size_m"), 3, "%s.size_m" % path)
	if kind == "plane":
		if not _exact_fields(shape, ["kind", "size_m", "width_axis_godot", "height_axis_godot"], path):
			return false
		if not _positive_array(shape.get("size_m"), 2, "%s.size_m" % path):
			return false
		if not _unit_vec3(shape.get("width_axis_godot"), "%s.width_axis_godot" % path):
			return false
		if not _unit_vec3(shape.get("height_axis_godot"), "%s.height_axis_godot" % path):
			return false
		var width := _vector3(shape["width_axis_godot"])
		var height := _vector3(shape["height_axis_godot"])
		if absf(width.dot(height)) > 0.001:
			return _reject("%s.height_axis_godot" % path, "must be orthogonal to width_axis_godot")
		return true
	return _reject("%s.kind" % path, "must be segment, box, or plane")


func _validate_role_contract(regions: Dictionary) -> bool:
	var required_stable := {
		"teeth_main_edge": ["cut"],
		"left_side_cutter": ["side_cut"],
		"right_side_cutter": ["side_cut"],
		"floor_wear_plate": ["scrape", "grade"],
		"outer_back": ["push", "back_drag", "grade", "compact"],
		"outer_left_side": ["side_cut", "push", "grade"],
		"outer_right_side": ["side_cut", "push", "grade"],
	}
	for region_id in required_stable:
		var roles := (regions[region_id] as Dictionary).get("stable_soil_roles", []) as Array
		for role in required_stable[region_id]:
			if not roles.has(role):
				return _reject("bucket_tool.regions.%s.stable_soil_roles" % region_id, "must contain %s" % role)
	for region_id in ["inner_shell", "opening"]:
		if not ((regions[region_id] as Dictionary).get("stable_soil_roles", []) as Array).is_empty():
			return _reject("bucket_tool.regions.%s.stable_soil_roles" % region_id, "inner/opening regions cannot erase stable terrain")
	var inner_roles := (regions["inner_shell"] as Dictionary).get("active_soil_roles", []) as Array
	if inner_roles != ["contain"]:
		return _reject("bucket_tool.regions.inner_shell.active_soil_roles", "must equal [contain]")
	var opening_roles := (regions["opening"] as Dictionary).get("active_soil_roles", []) as Array
	for role in ["entry", "spill", "dump"]:
		if not opening_roles.has(role):
			return _reject("bucket_tool.regions.opening.active_soil_roles", "must contain %s" % role)
	return true


func _validate_geometry_consistency(regions: Dictionary) -> bool:
	var proxies := _data["proxies"] as Dictionary
	var cavity_size := ((proxies["cavity"] as Dictionary)["size_m"] as Array)
	var inner_shape := (regions["inner_shell"] as Dictionary)["shape"] as Dictionary
	if String(inner_shape.get("kind", "")) != "box" or not _arrays_approx(inner_shape.get("size_m", []), cavity_size):
		return _reject("bucket_tool.regions.inner_shell.shape.size_m", "must match the authoritative cavity proxy")
	var opening_size := ((proxies["opening"] as Dictionary)["size_m"] as Array)
	var opening_shape := (regions["opening"] as Dictionary)["shape"] as Dictionary
	if String(opening_shape.get("kind", "")) != "plane" or not _arrays_approx(opening_shape.get("size_m", []), opening_size):
		return _reject("bucket_tool.regions.opening.shape.size_m", "must match the authoritative opening proxy")
	var opening_normal := _vector3((regions["opening"] as Dictionary)["outward_normal_godot"])
	var proxy_normal := _vector3((proxies["opening"] as Dictionary)["normal_godot"])
	if opening_normal.dot(proxy_normal) < 0.999:
		return _reject("bucket_tool.regions.opening.outward_normal_godot", "must match the opening proxy orientation")
	return true


func _role_list(value: Variant, allowed: Array, path: String) -> bool:
	if not value is Array:
		return _reject(path, "must be an array")
	var found: Array[String] = []
	for index in value.size():
		if not value[index] is String or not allowed.has(value[index]) or found.has(value[index]):
			return _reject("%s[%d]" % [path, index], "must be a unique supported role")
		found.append(String(value[index]))
	return true


func _vec3(value: Variant, path: String) -> bool:
	if not value is Array or value.size() != 3:
		return _reject(path, "must contain three numbers")
	for index in 3:
		if not _finite_number(value[index]):
			return _reject("%s[%d]" % [path, index], "must be finite")
	return true


func _unit_vec3(value: Variant, path: String) -> bool:
	if not _vec3(value, path):
		return false
	if absf(_vector3(value).length() - 1.0) > 0.001:
		return _reject(path, "must be a unit vector")
	return true


func _positive_array(value: Variant, expected_size: int, path: String) -> bool:
	if not value is Array or value.size() != expected_size:
		return _reject(path, "must contain %d numbers" % expected_size)
	for index in expected_size:
		if not _positive_number(value[index]):
			return _reject("%s[%d]" % [path, index], "must be finite and positive")
	return true


func _positive_number_or_reject(value: Variant, path: String) -> bool:
	return true if _positive_number(value) else _reject(path, "must be finite and positive")


func _positive_number(value: Variant) -> bool:
	return _finite_number(value) and float(value) > 0.0


func _finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


func _integer_in_range(value: Variant, minimum: int, maximum: int) -> bool:
	return _finite_number(value) and float(value) == floorf(float(value)) and int(value) >= minimum and int(value) <= maximum


func _arrays_approx(first: Variant, second: Variant) -> bool:
	if not first is Array or not second is Array or first.size() != second.size():
		return false
	for index in first.size():
		if not is_equal_approx(float(first[index]), float(second[index])):
			return false
	return true


func _vector3(value: Variant) -> Vector3:
	var data := value as Array
	return Vector3(float(data[0]), float(data[1]), float(data[2]))


func _exact_fields(value: Dictionary, required: Array, path: String) -> bool:
	for field in required:
		if not value.has(field):
			return _reject("%s.%s" % [path, field], "is required")
	for field in value:
		if not required.has(field):
			return _reject("%s.%s" % [path, field], "is not allowed")
	return true


func _reject(path: String, message: String) -> bool:
	_validation_error = "%s %s" % [path, message]
	return false


static func _load_json(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}

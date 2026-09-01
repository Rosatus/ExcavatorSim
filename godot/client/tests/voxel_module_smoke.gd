extends SceneTree

const EXPECTED_VERSION := {
	"major": 4,
	"minor": 7,
	"patch": 2,
	"status": "stable",
	"build": "custom_build",
	"hash_prefix": "ed1daf0bf",
}
const REQUIRED_CLASSES: Array[StringName] = [
	&"VoxelTerrain",
	&"VoxelLodTerrain",
	&"Terrain3D",
]


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures := validate()
	var version := Engine.get_version_info()
	if failures.is_empty():
		print(
			"voxel_module_smoke: PASS (%s; %s)"
			% [version.get("string", "unknown"), "VoxelTerrain, VoxelLodTerrain, Terrain3D"]
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


static func validate() -> Array[String]:
	var failures: Array[String] = []
	var version := Engine.get_version_info()
	for field in ["major", "minor", "patch", "status", "build"]:
		if version.get(field) != EXPECTED_VERSION[field]:
			failures.append(
				"engine %s expected %s, got %s"
				% [field, EXPECTED_VERSION[field], version.get(field)]
			)
	var engine_hash := String(version.get("hash", ""))
	if not engine_hash.begins_with(EXPECTED_VERSION.hash_prefix):
		failures.append(
			"engine hash expected prefix %s, got %s"
			% [EXPECTED_VERSION.hash_prefix, engine_hash]
		)

	for required_class in REQUIRED_CLASSES:
		if not ClassDB.class_exists(required_class):
			failures.append("ClassDB is missing %s" % required_class)
			continue
		var instance: Object = ClassDB.instantiate(required_class)
		if instance == null:
			failures.append("ClassDB could not instantiate %s" % required_class)
			continue
		instance.free()
	return failures


static func identity() -> Dictionary:
	var version := Engine.get_version_info()
	var class_names: Array[String] = []
	for required_class in REQUIRED_CLASSES:
		class_names.append(String(required_class))
	return {
		"engine_version": String(version.get("string", "unknown")),
		"engine_hash": String(version.get("hash", "")),
		"required_classes": class_names,
	}

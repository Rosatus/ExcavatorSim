extends Node

const VoxelModuleSmoke = preload("res://tests/voxel_module_smoke.gd")


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures: Array[String] = VoxelModuleSmoke.validate()
	if failures.is_empty():
		print("voxel_module_export_smoke: PASS %s" % JSON.stringify(VoxelModuleSmoke.identity()))
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)

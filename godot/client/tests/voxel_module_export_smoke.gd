extends Node

const VoxelModuleSmoke = preload("res://tests/voxel_module_smoke.gd")
const VoxelWorkZone = preload("res://scripts/voxel_work_zone.gd")
const MAX_READY_FRAMES := 1200


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures: Array[String] = VoxelModuleSmoke.validate()
	var zone := VoxelWorkZone.new()
	zone.name = "ReleaseTemplateVoxelWorkZone"
	add_child(zone)
	var ready := false
	for _frame in MAX_READY_FRAMES:
		if zone.is_support_ready_at(Vector3(0.0, 0.0, 16.0)):
			ready = true
			break
		await get_tree().physics_frame
	if not ready:
		failures.append("release template did not produce ready voxel collision")
	if failures.is_empty():
		print("voxel_module_export_smoke: PASS %s" % JSON.stringify(VoxelModuleSmoke.identity()))
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)

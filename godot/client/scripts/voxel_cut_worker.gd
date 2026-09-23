class_name VoxelCutWorker
extends Node

# Root-owned completion receipt. A retired world can discard its result without
# waiting or leaving an un-reaped WorkerThreadPool task behind. The task itself
# owns only a private RefCounted preparation, never this Node or a terrain.
var _task_id := -1
var _abandoned := false


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -100
	set_process(false)


func start(job: RefCounted) -> void:
	assert(_task_id == -1)
	_task_id = WorkerThreadPool.add_task(job.compute_snapshot, false, "Voxel cut preparation")
	set_process(true)


func completed() -> bool:
	if _task_id == -1:
		return true
	if not WorkerThreadPool.is_task_completed(_task_id):
		return false
	# Completion was observed before reaping; this never waits for live work.
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1
	set_process(false)
	return true


func abandon() -> void:
	_abandoned = true
	if completed():
		queue_free()


func _process(_delta: float) -> void:
	if completed() and _abandoned:
		queue_free()


func _exit_tree() -> void:
	# Only application shutdown removes a running root receipt. Private buffers
	# must finish before the engine tears down native voxel resources.
	if _task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1

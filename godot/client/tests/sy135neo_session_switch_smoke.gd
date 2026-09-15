extends SceneTree

## Session-level SY135-NEO switch smoke: exercises ProductSession.request_model_switch
## through the real main scene stack (presentation + chassis + equipment mapper).
## Soil-lifecycle assertions live in offline_product_test; this smoke only covers
## the model-switch contract.

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := load("res://scenes/main.tscn").instantiate() as Node3D
	if scene == null:
		_fail("main scene did not instantiate")
		return _finish()
	root.add_child(scene)
	await process_frame
	await physics_frame
	var session := scene.get_node_or_null("ProductSession") as ProductSession
	var chassis := scene.get_node_or_null("ChassisMotionRoot") as TrackedChassisController
	var presentation := scene.get_node_or_null("MotionPresentation") as MotionPresentation
	var client := scene.get_node_or_null("MotionClient") as MotionClient
	if session == null or chassis == null or presentation == null or client == null:
		_fail("main scene is missing a required product node")
		return _finish()
	if not bool(chassis.get_status_snapshot().get("configured", false)):
		_fail("Jolt chassis was not configured at startup")

	if not session.request_model_switch("sy135neo"):
		_fail("session rejected the SY135-NEO switch: %s" % JSON.stringify(session.last_error))
		return _finish()
	if session.active_model_id != "sy135neo":
		_fail("session did not select sy135neo")
	if presentation.get_active_model_id() != "sy135neo":
		_fail("presentation did not follow the SY135-NEO switch")
	if presentation.get_contract_error() != "":
		_fail("presentation contract error after SY135-NEO switch: %s" % presentation.get_contract_error())
	if client.get_equipment_model_id() != "sy135neo":
		_fail("equipment command profile did not follow the SY135-NEO switch")
	if not bool(chassis.get_status_snapshot().get("configured", false)):
		_fail("chassis lost its configuration after the SY135-NEO switch")
	var visible := 0
	var presentation_root := scene.get_node_or_null("ChassisMotionRoot/PresentationRoot") as Node3D
	if presentation_root == null:
		_fail("presentation root is missing")
	else:
		for child in presentation_root.get_children():
			if child is Node3D and (child as Node3D).visible:
				visible += 1
		if visible != 1:
			_fail("SY135-NEO switch was not singular (visible=%d)" % visible)
	if not session.request_model_switch("sy135"):
		_fail("session rejected the return switch to SY135: %s" % JSON.stringify(session.last_error))
	if session.active_model_id != "sy135" or presentation.get_active_model_id() != "sy135":
		_fail("return switch to SY135 did not complete")
	if not session.request_model_switch("sy135neo"):
		_fail("session rejected the second SY135-NEO switch")
	if presentation.get_active_model_id() != "sy135neo":
		_fail("second SY135-NEO activation did not complete")
	_finish()


func _fail(message: String) -> void:
	failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("SY135-NEO session switch smoke passed.")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)

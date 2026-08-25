extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"
const HELPER_SCRIPT := "res://tests/visual_evidence_capture.gd"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var helper = load(HELPER_SCRIPT).new()
	if helper.expected_matrix_capture_count() != 34:
		_fail("visual evidence matrix must contain 34 captures")
	_assert_checkpoints(helper, "low", ["carry", "dump", "terrain", "support"])
	_assert_checkpoints(
		helper,
		"balanced",
		[
			"startup", "controls-visible", "travel", "dig", "carry",
			"dump", "terrain", "support", "reset",
		],
	)
	_assert_artifact_validation(helper)
	await _assert_controls_status(helper)
	var scene := load(MAIN_SCENE).instantiate() as Node3D
	if scene == null:
		_fail("main scene did not instantiate")
		_finish()
		return
	root.add_child(scene)
	await process_frame
	await physics_frame
	var invalid: Dictionary = await helper.configure_product_for_capture(
		scene, "unknown", "balanced"
	)
	if bool(invalid.get("ok", true)) or String(invalid.get("reason", "")) != "unsupported_model_or_quality":
		_fail("invalid evidence configuration did not fail closed")
	var configured: Dictionary = await helper.configure_product_for_capture(scene, "sy135", "low")
	var session := scene.get_node("ProductSession") as ProductSession
	var client := scene.get_node("MotionClient") as MotionClient
	var presentation := scene.get_node("MotionPresentation") as MotionPresentation
	var quality := scene.get_node("VisualQualityController") as VisualQualityController
	if not bool(configured.get("ok", false)):
		_fail("offline evidence configuration failed: %s" % configured)
	if session.lifecycle != ProductSession.LIFECYCLE_STOPPED:
		_fail("evidence configuration did not leave the real product stopped")
	if session.active_model_id != "sy135" or presentation.get_active_model_id() != "sy135":
		_fail("evidence configuration did not switch the real product model")
	if client.connection_state != MotionClient.STATE_DISCONNECTED:
		_fail("evidence configuration started the optional transport")
	if String(quality.get_quality_snapshot().get("profile", "")) != "low":
		_fail("evidence configuration did not apply the requested quality")
	if not session.request_start() or session.lifecycle != ProductSession.LIFECYCLE_RUNNING:
		_fail("evidence configuration could not start the real product lifecycle")
	helper.release_product_after_capture(scene)
	await physics_frame
	if session.lifecycle != ProductSession.LIFECYCLE_STOPPED:
		_fail("evidence cleanup did not reset the real product lifecycle")
	scene.queue_free()
	await process_frame
	_finish()


func _assert_checkpoints(helper, quality_profile: String, expected: Array) -> void:
	var actual: Array = helper.expected_checkpoints(quality_profile)
	if actual != expected:
		_fail("%s checkpoint contract mismatch: %s" % [quality_profile, actual])


func _assert_artifact_validation(helper) -> void:
	var valid := {
		"saved": true,
		"width": 1920,
		"height": 1080,
		"sha256": "abc123",
		"visual_content": true,
	}
	if not helper.validate_artifact_metadata(valid).is_empty():
		_fail("valid artifact metadata was rejected")
	var invalid := valid.duplicate(true)
	invalid["width"] = 1280
	invalid["sha256"] = ""
	invalid["visual_content"] = false
	var errors: Array = helper.validate_artifact_metadata(invalid)
	for expected_error in ["width_mismatch", "sha256_missing", "blank_or_uniform_render"]:
		if not errors.has(expected_error):
			_fail("artifact validation missed %s" % expected_error)


func _assert_controls_status(helper) -> void:
	var scene := load(MAIN_SCENE).instantiate() as Node3D
	root.add_child(scene)
	await process_frame
	var status: Dictionary = await helper.controls_visible_status(scene)
	if not bool(status.get("achieved", false)):
		_fail("production controls are not discoverable: %s" % status)
	scene.queue_free()
	await process_frame


func _finish() -> void:
	if failures.is_empty():
		print("Visual evidence capture contract passed.")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _fail(message: String) -> void:
	failures.append(message)

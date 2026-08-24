extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"
const HELPER_SCRIPT := "res://tests/visual_evidence_capture.gd"
const SCHEMA_VERSION := "excavator-sim-visual-evidence-manifest-v1"

var _output_dir := "user://visual-evidence"
var _commit := "unrecorded"
var _capture_command := "unrecorded"
var _run_id := "unrecorded"
var _error_log_path := "unrecorded"
var _models: Array[String] = ["sy205", "sy135"]
var _quality_profiles: Array[String] = ["low", "balanced", "high"]
var _failures: Array[String] = []


func _init() -> void:
	if not _parse_arguments():
		quit(2)
		return
	call_deferred("_run")


func _run() -> void:
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		_finish([], "main_scene_unavailable")
		return
	var scene := packed.instantiate() as Node3D
	if scene == null:
		_finish([], "main_scene_instantiation_failed")
		return
	root.add_child(scene)
	DisplayServer.window_set_title("ExcavatorSim visual evidence baseline")
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	for _frame in 5:
		await process_frame
	var helper = load(HELPER_SCRIPT).new()
	var entries: Array[Dictionary] = []
	var run_context := {
		"commit": _commit,
		"capture_command": _capture_command,
		"run_id": _run_id,
		"error_log_path": _error_log_path,
	}
	for model_id in _models:
		for quality_profile in _quality_profiles:
			print("[visual-evidence] capture %s/%s" % [model_id, quality_profile])
			var result: Dictionary = await helper.capture(
				scene, model_id, quality_profile, _output_dir, run_context
			)
			entries.append(result)
			if not bool(result.get("ok", false)):
				_failures.append(
					"%s/%s: %s" % [model_id, quality_profile, result.get("reason", "unknown")]
				)
			if not _write_manifest(helper, entries):
				_failures.append("manifest_write_failed:%s/%s" % [model_id, quality_profile])
				helper.release_product_after_capture(scene)
				scene.queue_free()
				await process_frame
				_finish(entries)
				return
	helper.release_product_after_capture(scene)
	scene.queue_free()
	await process_frame
	_finish(entries)


func _write_manifest(helper, entries: Array[Dictionary]) -> bool:
	var expected_count := 0
	var actual_count := 0
	var scenario_failure_count := 0
	var artifact_integrity_errors: Array[String] = []
	for _model_id in _models:
		for quality_profile in _quality_profiles:
			expected_count += helper.expected_checkpoints(quality_profile).size()
	for entry in entries:
		actual_count += int(entry.get("artifact_count", 0))
		scenario_failure_count += (entry.get("scenario_findings", []) as Array).size()
		for checkpoint_value in entry.get("checkpoints", []):
			var checkpoint := checkpoint_value as Dictionary
			if not bool(checkpoint.get("ok", false)):
				artifact_integrity_errors.append(
					"%s/%s/%s" % [
						entry.get("model_id", "unknown"),
						entry.get("quality_profile", "unknown"),
						checkpoint.get("checkpoint", "unknown"),
					]
				)
	var partial := _models.size() != 2 or _quality_profiles.size() != 3
	var selection_complete := (
		entries.size() == _models.size() * _quality_profiles.size()
		and actual_count == expected_count
		and _failures.is_empty()
		and artifact_integrity_errors.is_empty()
	)
	var manifest := {
		"schema_version": SCHEMA_VERSION,
		"run_id": _run_id,
		"commit": _commit,
		"capture_command": _capture_command,
		"models": _models,
		"quality_profiles": _quality_profiles,
		"resolution": [1920, 1080],
		"core_checkpoints": ["carry", "dump", "terrain", "support"],
		"balanced_journey": [
			"startup", "controls-visible", "travel", "dig", "carry", "dump", "reset"
		],
		"support_case": "bucket-ground support/contact transfer",
		"expected_capture_count": expected_count,
		"actual_capture_count": actual_count,
		"partial": partial,
		"selection_complete": selection_complete,
		"complete": selection_complete and not partial,
		"all_scenarios_achieved": scenario_failure_count == 0,
		"scenario_failure_count": scenario_failure_count,
		"artifact_integrity_errors": artifact_integrity_errors,
		"failures": _failures,
		"entries": entries,
	}
	var path := "%s/manifest.json" % _output_dir
	return helper.write_json_file(path, manifest)


func _finish(entries: Array[Dictionary], fatal_reason := "") -> void:
	if not fatal_reason.is_empty():
		_failures.append(fatal_reason)
	if entries.is_empty() or not _write_manifest(load(HELPER_SCRIPT).new(), entries):
		if not _failures.has("manifest_write_failed"):
			_failures.append("manifest_write_failed")
	if _failures.is_empty():
		print("Visual evidence matrix complete: %s" % _output_dir)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _parse_arguments() -> bool:
	var arguments := OS.get_cmdline_user_args()
	var index := 0
	while index < arguments.size():
		if index + 1 >= arguments.size():
			push_error("missing value for %s" % arguments[index])
			return false
		var argument := String(arguments[index])
		var value := String(arguments[index + 1])
		match argument:
			"--evidence-output": _output_dir = value
			"--evidence-commit": _commit = value
			"--evidence-command": _capture_command = value
			"--evidence-run-id": _run_id = value
			"--evidence-error-log": _error_log_path = value
			"--evidence-models": _models = _parse_list(value, ["sy205", "sy135"])
			"--evidence-quality-profiles":
				_quality_profiles = _parse_list(value, ["low", "balanced", "high"])
			_:
				push_error("unknown visual evidence argument: %s" % argument)
				return false
		index += 2
	return (
		not _output_dir.is_empty()
		and not _models.is_empty()
		and not _quality_profiles.is_empty()
	)


func _parse_list(value: String, allowed: Array[String]) -> Array[String]:
	var result: Array[String] = []
	for item in value.split(",", false):
		var normalized := item.strip_edges()
		if allowed.has(normalized) and not result.has(normalized):
			result.append(normalized)
	return result

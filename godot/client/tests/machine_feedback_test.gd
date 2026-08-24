extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var feedback := MachineFeedback.new()
	root.add_child(feedback)
	await process_frame
	var session := {"generation": 1, "lifecycle": "running", "focused": true}
	var soil := {
		"interaction_batch_key": "1:10:cut",
		"interaction_penetration_m": 0.06,
		"last_transaction": {"transaction_id": "1:1", "kind": "cut", "accepted_volume_m3": 0.012},
		"digging_response": {"phase": "cut", "intensity": 0.82, "raw_commands": Vector4(0.0, -0.75, -0.4, 0.0)},
	}
	var chassis := {"left_speed_mps": 1.2, "right_speed_mps": 1.0, "left_slip_ratio": 0.2, "right_slip_ratio": 0.1}
	feedback.apply_snapshots_for_test(session, soil, chassis)
	var active := feedback.get_feedback_snapshot()
	if int(active["active_loop_count"]) != 3 or int(active["active_one_shots"]) != 2 or String(active["last_event"]) != "cut":
		_fail("running travel/work/cut state did not produce bounded layered feedback")
	for state_value in (active["active_loops"] as Dictionary).values():
		var state := state_value as Dictionary
		if float(state["pitch"]) < 0.62 or float(state["pitch"]) > 1.45 or float(state["gain_db"]) < -80.0 or float(state["gain_db"]) > -4.0:
			_fail("loop gain or pitch escaped clamps")
	var events_before := int(active["event_count"])
	feedback.apply_snapshots_for_test(session, soil, chassis)
	if int(feedback.get_feedback_snapshot()["event_count"]) != events_before:
		_fail("transaction/batch identity was not deduplicated")
	feedback.set_muted(true)
	if not bool(feedback.get_feedback_snapshot()["muted"]) or int(feedback.get_feedback_snapshot()["active_loop_count"]) != 3:
		_fail("mute changed feedback state instead of only the mix")
	if not feedback.set_quality_profile("low"):
		_fail("low feedback profile was rejected")
	feedback.apply_snapshots_for_test(session, soil, chassis, 0.2)
	var low := feedback.get_feedback_snapshot()
	if int(low["loop_cap"]) != 1 or int(low["voice_cap"]) != 2 or int(low["active_loop_count"]) != 1:
		_fail("low feedback profile did not enforce loop/voice caps")
	feedback.set_muted(false)
	feedback.apply_snapshots_for_test({"generation": 1, "lifecycle": "paused", "focused": true}, soil, chassis)
	var paused := feedback.get_feedback_snapshot()
	if int(paused["active_loop_count"]) != 0 or int(paused["active_one_shots"]) != 0:
		_fail("pause did not clear loops and voices")
	feedback.apply_snapshots_for_test({"generation": 2, "lifecycle": "running", "focused": false}, soil, chassis)
	var unfocused := feedback.get_feedback_snapshot()
	if int(unfocused["generation"]) != 2 or int(unfocused["active_loop_count"]) != 0:
		_fail("generation/focus boundary did not reset feedback")
	if not feedback.set_quality_profile("high") or int(feedback.get_feedback_snapshot()["voice_cap"]) != 6:
		_fail("high feedback voice budget was not applied")
	if AudioServer.get_bus_index("Machine") < 0 or AudioServer.get_bus_index("Effects") < 0:
		_fail("runtime feedback buses were not created")
	feedback.queue_free()
	await process_frame
	if failures.is_empty():
		print("Machine and soil feedback contract passed.")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _fail(message: String) -> void:
	failures.append(message)

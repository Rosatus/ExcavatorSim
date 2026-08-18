extends SceneTree

const STEP := 1.0 / 60.0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var result := _run_contracts()
	if result == 0:
		print("Bucket ground lift contracts passed.")
	quit(result)


func _run_contracts() -> int:
	var support := BucketGroundLiftReaction.classify_contact(
		0.18, 0.04, Vector3(0.0, -0.02, 0.0), Vector3.UP, Vector3.FORWARD, Vector3.UP, false
	)
	if not bool(support["eligible"]) or support["classification"] != "support":
		return _fail("rear/shell contact does not classify as support")
	var cutting := BucketGroundLiftReaction.classify_contact(
		0.18, 0.04, Vector3.FORWARD * 0.02, Vector3.UP, Vector3.FORWARD, Vector3.UP, false
	)
	if bool(cutting["eligible"]) or cutting["classification"] != "cutting_window":
		return _fail("cutting-edge motion triggered lift")
	var shallow := BucketGroundLiftReaction.classify_contact(
		0.01, 0.01, Vector3.DOWN, Vector3.UP, Vector3.FORWARD, Vector3.UP, false
	)
	if bool(shallow["eligible"]) or shallow["classification"] != "none":
		return _fail("support dead zone triggered lift")
	var host := Node3D.new()
	root.add_child(host)
	var chassis := TrackedChassisController.new()
	chassis.name = "ChassisMotionRoot"
	chassis.controller_enabled = true
	chassis.use_project_authority_profile = false
	chassis.authority_profile = AuthorityProfile.PYTHON_KINEMATIC
	host.add_child(chassis)
	for model_id in ["sy205", "sy135"]:
		if not chassis.configure_model_for_test(model_id):
			host.queue_free()
			return _fail("model configures: %s" % model_id)
		var lateral := -0.75 if model_id == "sy205" else 0.7
		var base_point := chassis.global_transform * Transform3D(Basis.IDENTITY, Vector3(lateral, 0.0, 1.0))
		var contact := {
			"eligible": true,
			"penetration_m": 0.24,
			"point_world": base_point.origin,
			"authority_generation": 7,
			"model_id": model_id,
			"reason": "rear_support",
		}
		chassis.submit_bucket_support_contact(contact)
		chassis.step_fixed_for_test(STEP, func(_point: Vector2) -> float: return 0.0)
		var first_step := chassis.get_status_snapshot()["ground_lift"] as Dictionary
		if float(first_step["heave_m"]) > BucketGroundLiftReaction.MAX_HEAVE_SPEED_MPS * STEP + 0.0001:
			host.queue_free()
			return _fail("heave velocity clamp failed for %s" % model_id)
		for _frame in 29:
			chassis.step_fixed_for_test(STEP, func(_point: Vector2) -> float: return 0.0)
		var lifted := chassis.get_status_snapshot()
		var lift := lifted["ground_lift"] as Dictionary
		if float(lift["heave_m"]) <= 0.0 or float(lift["heave_m"]) > BucketGroundLiftReaction.MAX_HEAVE_M + 0.001:
			host.queue_free()
			return _fail("bounded heave was not applied for %s" % model_id)
		if absf(float(lift["pitch_deg"])) > rad_to_deg(BucketGroundLiftReaction.MAX_PITCH_RAD) + 0.1:
			host.queue_free()
			return _fail("pitch clamp failed for %s" % model_id)
		if is_zero_approx(float(lift["roll_deg"])) or absf(float(lift["roll_deg"])) > rad_to_deg(BucketGroundLiftReaction.MAX_ROLL_RAD) + 0.1:
			host.queue_free()
			return _fail("bounded lateral roll was not applied for %s" % model_id)
		var yaw_before := chassis.locomotion_state.yaw_radians
		chassis.set_commands_for_test(-0.45, 0.7)
		for _frame in 20:
			chassis.step_fixed_for_test(STEP, func(point: Vector2) -> float: return point.x * 0.015)
		var composed := chassis.get_status_snapshot()
		if (
			is_equal_approx(chassis.locomotion_state.yaw_radians, yaw_before)
			or float((composed["ground_lift"] as Dictionary)["heave_m"]) <= 0.0
			or not chassis.transform.origin.is_finite()
		):
			host.queue_free()
			return _fail("lift did not compose with pivoting slope support for %s" % model_id)
		chassis.set_commands_for_test(0.0, 0.0)
		var effective_support := chassis.global_transform * Transform3D(Basis.IDENTITY, Vector3(lateral, 0.0, 1.0))
		var raw_support := chassis.raw_world_transform(effective_support)
		var expected_raw := host.global_transform * chassis.locomotion_state.chassis_transform * Vector3(lateral, 0.0, 1.0)
		if raw_support.origin.distance_to(expected_raw) > 0.001:
			host.queue_free()
			return _fail("raw contact sampling includes the applied reaction for %s" % model_id)
		chassis.submit_bucket_support_contact({
			"eligible": false,
			"authority_generation": 7,
			"model_id": model_id,
		})
		var before_release := float(lift["heave_m"])
		chassis.step_fixed_for_test(STEP, func(_point: Vector2) -> float: return 0.0)
		var after_release := float((chassis.get_status_snapshot()["ground_lift"] as Dictionary)["heave_m"])
		if after_release >= before_release or after_release < 0.0:
			host.queue_free()
			return _fail("support release was not smooth for %s" % model_id)
		chassis.submit_bucket_support_contact({
			"eligible": true,
			"penetration_m": 9.0,
			"point_world": base_point.origin,
			"authority_generation": 8,
			"model_id": model_id,
		})
		chassis.step_fixed_for_test(STEP, func(_point: Vector2) -> float: return 0.0)
		if float((chassis.get_status_snapshot()["ground_lift"] as Dictionary)["heave_m"]) > after_release + 0.1:
			host.queue_free()
			return _fail("stale generation was accepted")
	chassis.ground_lift_enabled = false
	for _frame in 60:
		chassis.step_fixed_for_test(STEP, func(_point: Vector2) -> float: return 0.0)
	if absf(float((chassis.get_status_snapshot()["ground_lift"] as Dictionary)["heave_m"])) > 0.001:
		host.queue_free()
		return _fail("feature disable did not release support offset")
	host.queue_free()
	return 0


func _fail(message: String) -> int:
	push_error("bucket ground lift check failed: %s" % message)
	return 1

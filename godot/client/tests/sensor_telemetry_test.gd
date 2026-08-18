extends SceneTree


func _init() -> void:
	var publisher := SimulationTruthPublisher.new()
	var snapshot := {
		"schema_version": "simulation-truth-v1",
		"authority_profile": "jolt_authoritative",
		"authority_epoch": "authority-1",
		"sequence": 7,
		"physics_tick": 42,
		"monotonic_time_ns": 420000000,
		"identity": {
			"session_id": "session",
			"simulation_epoch": "stream",
			"model_id": "sy205",
			"model_version": "sy205-glb-urdf-v4",
			"rig_id": "sy205-rig",
			"rig_version": "sy205-rig-v1",
			"calibration_version": "machine-calibration-v2",
		},
		"bodies": [{
			"name": "chassis",
			"transform": [[1.0, 0.0, 0.0, 1.0], [0.0, 1.0, 0.0, 2.0], [0.0, 0.0, 1.0, 3.0], [0.0, 0.0, 0.0, 1.0]],
			"linear_velocity_m_s": [0.1, 0.2, 0.3],
			"angular_velocity_rad_s": [0.01, 0.02, 0.03],
			"sleeping": false,
		}],
		"joints": [
			{"name": "swing_joint", "position_rad": 0.0, "velocity_rad_s": 0.0, "effort_n": 0.0},
			{"name": "boom_joint", "position_rad": 0.1, "velocity_rad_s": 0.2, "effort_n": 1.0},
			{"name": "arm_joint", "position_rad": 0.2, "velocity_rad_s": 0.3, "effort_n": 2.0},
			{"name": "bucket_joint", "position_rad": 0.3, "velocity_rad_s": 0.4, "effort_n": 3.0},
		],
		"tracks": {"left_speed_m_s": 0.0, "right_speed_m_s": 0.0, "left_slip_ratio": 0.0, "right_slip_ratio": 0.0, "left_contact_count": 1, "right_contact_count": 1},
		"payload": {"mass_kg": 100.0, "volume_m3": 0.08, "fill_ratio": 0.5, "motion_load_factor": 0.9},
	}
	var batch := publisher.build_sensor_batch(snapshot)
	_assert(batch["authority_profile"] == "jolt_authoritative", "profile")
	_assert(batch["physics_tick"] == 42, "physics tick")
	_assert((batch["samples"] as Array).size() == 11, "sensor sample count")
	_assert((batch["samples"] as Array)[0].has("raw_value"), "raw sensor value")
	var samples := batch["samples"] as Array
	var imu_ids := ["imu/swing_imu_link", "imu/boom_imu_link", "imu/arm_imu_link", "imu/bucket_imu_link"]
	for index in imu_ids.size():
		var imu := samples[4 + index] as Dictionary
		_assert(imu["sensor_id"] == imu_ids[index], "declared imu frame")
		_assert(imu["units"] == "rotation_matrix_3x3,rad_s,m_s2", "imu units")
		_assert((imu["value"] as Array).size() == 15, "imu layout")
		_assert(is_equal_approx(float((imu["value"] as Array)[14]), 9.80665), "stationary imu specific force")
	var gnss := samples[8] as Dictionary
	_assert(gnss["frame_id"] == "gnss_link", "gnss frame")
	_assert(gnss["units"] == "position_m,velocity_m_s", "gnss units")
	_assert((gnss["value"] as Array).size() == 6, "gnss layout")
	var wire := MotionProtocol.sensor_telemetry_batch_message(batch)
	_assert(wire["protocol_version"] == MotionProtocol.PROTOCOL_VERSION, "protocol version")
	_assert((wire["samples"] as Array)[0]["sample_sequence"] == 7, "sample sequence")
	print("Sensor telemetry producer contracts passed.")
	quit()


func _assert(condition: bool, label: String) -> void:
	if not condition:
		push_error("sensor telemetry assertion failed: %s" % label)
		quit(1)

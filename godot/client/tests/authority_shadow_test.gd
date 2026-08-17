extends SceneTree


class FakeTransport extends RefCounted:
	var sent: Array[String] = []

	func get_ready_state() -> int:
		return WebSocketPeer.STATE_OPEN

	func send_text(message: String) -> int:
		sent.append(message)
		return OK


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if not AuthorityProfile.publishes_shadow("jolt_shadow"):
		return _fail("jolt_shadow must publish")
	if AuthorityProfile.writes_product_pose("jolt_shadow"):
		return _fail("jolt_shadow must not write product pose")
	if not AuthorityProfile.writes_product_pose("jolt_authoritative"):
		return _fail("jolt_authoritative must own product pose")
	if not AuthorityProfile.produces_truth("jolt_authoritative"):
		return _fail("jolt_authoritative must produce local truth")
	for model_id in ["sy205", "sy135"]:
		var descriptor := PhysicsRigDescriptor.load_for_model(model_id)
		if descriptor == null:
			return _fail("missing descriptor for %s" % model_id)
		var catalog: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://resources/models/model_catalog.json"))
		var model_version := ""
		var catalog_entry := {}
		for candidate in catalog.get("models", []):
			if candidate.get("model_id") == model_id:
				catalog_entry = candidate
				model_version = String(candidate.get("model_version", ""))
		if not descriptor.is_valid_for(model_id, model_version):
			return _fail("invalid descriptor for %s: %s" % [model_id, descriptor.validation_error()])
		var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(String(catalog_entry.get("manifest_path", ""))))
		var manifest_rests: Dictionary = manifest.get("calibration", {}).get("rest_transforms_godot", {})
		for body in descriptor.bodies():
			var frame_name := String(body.get("frame", ""))
			if not _rows_are_close(body.get("rest_transform_godot", []), manifest_rests.get(frame_name, []), 0.000001):
				return _fail("%s descriptor rest transform drifted from %s manifest" % [model_id, frame_name])
	var valid_descriptor := PhysicsRigDescriptor.load_for_model("sy205")
	if valid_descriptor == null:
		return _fail("missing sy205 descriptor")
	var invalid_cases := [
		["provenance.notes", _without_nested_field(valid_descriptor.to_dictionary(), ["provenance", "notes"])],
		["bodies[0].shape.extra", _with_nested_value(valid_descriptor.to_dictionary(), ["bodies", 0, "shape", "extra"], true)],
		["bodies[0].shape.size_m[1]", _with_nested_value(valid_descriptor.to_dictionary(), ["bodies", 0, "shape", "size_m", 1], 0.0)],
		["bodies[0].rest_transform_godot[3]", _with_nested_value(valid_descriptor.to_dictionary(), ["bodies", 0, "rest_transform_godot", 3], [0.0, 0.0, 1.0, 1.0])],
		["bodies[1].rest_transform_godot", _with_nested_value(valid_descriptor.to_dictionary(), ["bodies", 1, "rest_transform_godot", 0, 0], 2.0)],
		["joints[0].actuator.max_torque_nm", _with_nested_value(valid_descriptor.to_dictionary(), ["joints", 0, "actuator", "max_torque_nm"], 0.0)],
		["joints[0].actuator.max_jerk_rad_s3", _with_nested_value(valid_descriptor.to_dictionary(), ["joints", 0, "actuator", "max_jerk_rad_s3"], 0.0)],
		["joints[0].axis_frame", _with_nested_value(valid_descriptor.to_dictionary(), ["joints", 0, "axis_frame"], "world")],
		["joints[0].collide_connected", _with_nested_value(valid_descriptor.to_dictionary(), ["joints", 0, "collide_connected"], 1)],
		["joints[1].parent_anchor_godot", _with_nested_value(valid_descriptor.to_dictionary(), ["joints", 1, "parent_anchor_godot", 0, 3], 2.0)],
		["self_collision_mode", _with_nested_value(valid_descriptor.to_dictionary(), ["self_collision_mode"], "implicit")],
		["tracks.traction_points_per_side", _with_nested_value(valid_descriptor.to_dictionary(), ["tracks", "traction_points_per_side"], 1)],
		["chassis_dynamics.inertia_diagonal_kg_m2", _with_nested_value(valid_descriptor.to_dictionary(), ["chassis_dynamics", "inertia_diagonal_kg_m2"], [1.0, 1.0, 3.0])],
		["tracks.probe_depth_m", _with_nested_value(valid_descriptor.to_dictionary(), ["tracks", "probe_depth_m"], 0.0)],
	]
	for invalid_case in invalid_cases:
		var invalid := PhysicsRigDescriptor.from_dictionary_for_test(invalid_case[1])
		if invalid.is_valid_for("sy205", "sy205-glb-urdf-v4"):
			return _fail("descriptor accepted invalid %s" % invalid_case[0])
		if not invalid.validation_error().begins_with(String(invalid_case[0])):
			return _fail("descriptor error did not identify %s: %s" % [invalid_case[0], invalid.validation_error()])
	var identity_cases: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/simulation_truth_identity_cases.json"))
	if (identity_cases.get("valid", []) as Array).size() != 2 or (identity_cases.get("invalid", []) as Array).size() != 2:
		return _fail("shared identity fixture is incomplete")
	var original := Transform3D(Basis(Vector3.UP, 0.4), Vector3(1.0, 2.0, 3.0))
	var rows := MotionProtocol.transform_to_canonical_rows(original)
	var round_trip := MotionProtocol.rows_to_transform(rows)
	if not round_trip.is_equal_approx(original):
		return _fail("coordinate transform did not round trip")
	if MotionProtocol.vector_to_canonical_array(Vector3(1.0, 2.0, 3.0)) != [1.0, -3.0, 2.0]:
		return _fail("vector conversion is wrong")
	var publisher := SimulationTruthPublisher.new()
	var pose_client := MotionClient.new()
	pose_client.session_id = "session-a"
	pose_client.simulation_epoch = "simulation-a"
	publisher._motion_client = pose_client
	if publisher._pose_matches_authority({}):
		return _fail("publisher accepted an empty pose")
	if publisher._pose_matches_authority({"session_id": "session-a", "simulation_epoch": "old"}):
		return _fail("publisher accepted an old simulation epoch")
	if not publisher._pose_matches_authority({"session_id": "session-a", "simulation_epoch": "simulation-a"}):
		return _fail("publisher rejected the current authority pose")
	publisher.free()
	pose_client.free()
	var source := {"nested": {"value": 1}}
	var snapshot := SimulationTruthSnapshot.from_dictionary(source)
	source["nested"]["value"] = 2
	if snapshot.to_dictionary()["nested"]["value"] != 1:
		return _fail("snapshot retained mutable input")
	var returned := snapshot.to_dictionary()
	returned["nested"]["value"] = 3
	if snapshot.to_dictionary()["nested"]["value"] != 1:
		return _fail("snapshot exposed mutable storage")
	var message := MotionProtocol.simulation_truth_shadow_message({"schema_version": "simulation-truth-v1"})
	if message.get("type") != "simulation_truth_shadow":
		return _fail("shadow envelope is wrong")
	var client := MotionClient.new()
	var transport := FakeTransport.new()
	client.connection_state = MotionClient.STATE_READY
	client.negotiated_optional_capabilities = ["simulation_truth_shadow_v1"]
	client._transport = transport
	if not client.queue_simulation_truth_shadow({"schema_version": "simulation-truth-v1", "sequence": 1}):
		return _fail("negotiated shadow queue rejected a valid envelope")
	client.queue_simulation_truth_shadow({"schema_version": "simulation-truth-v1", "sequence": 2})
	client._send_pending_shadow_truth()
	if transport.sent.size() != 1 or JSON.parse_string(transport.sent[0])["snapshot"]["sequence"] != 2:
		return _fail("shadow transport did not preserve latest-value semantics")
	client.free()
	print("authority_shadow_test: PASS")
	quit(0)


func _without_nested_field(data: Dictionary, path: Array) -> Dictionary:
	var cursor: Variant = data
	for index in path.size() - 1:
		cursor = cursor[path[index]]
	(cursor as Dictionary).erase(path.back())
	return data


func _with_nested_value(data: Dictionary, path: Array, value: Variant) -> Dictionary:
	var cursor: Variant = data
	for index in path.size() - 1:
		cursor = cursor[path[index]]
	cursor[path.back()] = value
	return data


func _rows_are_close(first: Array, second: Array, tolerance: float) -> bool:
	if first.size() != 4 or second.size() != 4:
		return false
	for row in 4:
		if first[row].size() != 4 or second[row].size() != 4:
			return false
		for column in 4:
			if absf(float(first[row][column]) - float(second[row][column])) > tolerance:
				return false
	return true


func _fail(message: String) -> void:
	push_error(message)
	quit(1)

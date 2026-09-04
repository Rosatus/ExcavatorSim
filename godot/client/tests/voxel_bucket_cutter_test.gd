extends SceneTree

const Cutter = preload("res://scripts/voxel_bucket_cutter.gd")
const WorkZoneConfig = preload("res://scripts/voxel_work_zone_config.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures: Array[String] = []
	for model_id in ["sy205", "sy135"]:
		_check_model(String(model_id), failures)
	_check_sy135_deep_insertion(failures)
	_check_negative_cases(failures)
	if failures.is_empty():
		print("Voxel bucket cutter contracts passed.")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _check_model(model_id: String, failures: Array[String]) -> void:
	var contract := _contract(model_id)
	var cutter := Cutter.new()
	_expect(cutter.configure(contract, WorkZoneConfig.DEFAULT_VOXEL_SCALE_M), "%s configures" % model_id, failures)
	var strokes := [
		{"name": "slow", "start": Vector3(0.0, _bucket_origin_y(contract, -0.02), 18.0), "motion": Vector3(0.0, -0.018, 0.025), "rotation": 0.0},
		{"name": "fast", "start": Vector3(-3.0, _bucket_origin_y(contract, -0.04), 22.0), "motion": Vector3(0.35, -0.16, 0.42), "rotation": 0.0},
		{"name": "translated", "start": Vector3(4.0, _bucket_origin_y(contract, -0.03), 30.0), "motion": Vector3(-0.12, -0.08, 0.20), "rotation": 0.0},
		{"name": "curling", "start": Vector3(1.0, _bucket_origin_y(contract, -0.03), 26.0), "motion": Vector3(0.0, -0.12, 0.08), "rotation": deg_to_rad(5.0)},
		{"name": "rotation_only", "start": Vector3(-1.0, _bucket_origin_y(contract, -0.20), 26.0), "motion": Vector3.ZERO, "rotation": deg_to_rad(-7.0)},
	]
	for stroke_value in strokes:
		var stroke := stroke_value as Dictionary
		var previous := Transform3D(Basis.IDENTITY, stroke["start"] as Vector3)
		var current_basis := Basis(Vector3.RIGHT, float(stroke["rotation"]))
		var current := Transform3D(current_basis, (stroke["start"] as Vector3) + (stroke["motion"] as Vector3))
		var pose := _pose(contract, previous, current, "%s:%s" % [model_id, stroke["name"]])
		var result := cutter.build_proposal(pose, 7, 10, 10, "epoch", false, _flat_sdf)
		_expect(bool(result.get("accepted", false)), "%s %s stroke accepted (%s)" % [model_id, stroke["name"], result.get("reason", "")], failures)
		if not bool(result.get("accepted", false)):
			continue
		var proposal := result.get("proposal") as VoxelCutProposal
		_expect(proposal != null and proposal.is_valid(), "%s %s typed proposal valid" % [model_id, stroke["name"]], failures)
		if proposal == null:
			continue
		_expect(_sources_are_canonical(proposal.capsules), "%s %s canonical region order" % [model_id, stroke["name"]], failures)
		_expect(_edge_sweep_is_covered(pose, proposal.capsules), "%s %s connected half-voxel coverage" % [model_id, stroke["name"]], failures)
		_expect(not proposal.clearance_capsules.is_empty(), "%s %s constrained clearance exists" % [model_id, stroke["name"]], failures)
		if model_id == "sy135":
			_expect(not proposal.native_paths.is_empty(), "%s %s native paths exist" % [model_id, stroke["name"]], failures)
			_expect(_has_role(proposal.native_paths, "bucket_occupancy"), "%s %s inner occupancy participates" % [model_id, stroke["name"]], failures)
			_expect(_has_role(proposal.native_paths, "bucket_floor"), "%s %s floor participates" % [model_id, stroke["name"]], failures)


func _check_sy135_deep_insertion(failures: Array[String]) -> void:
	var contract := _contract("sy135")
	var cutter := Cutter.new()
	_expect(cutter.configure(contract, WorkZoneConfig.DEFAULT_VOXEL_SCALE_M), "sy135 deep configures", failures)
	var start := Vector3(0.0, _bucket_origin_y(contract, -1.1), 24.0)
	var previous := Transform3D(Basis.IDENTITY, start)
	var current := Transform3D(Basis.IDENTITY, start + Vector3(0.08, -0.12, 0.18))
	var pose := _pose(contract, previous, current, "sy135:deep")
	var result := cutter.build_proposal(pose, 8, 20, 20, "epoch", false, _flat_sdf)
	_expect(bool(result.get("accepted", false)), "sy135 deep insertion accepted", failures)
	if not bool(result.get("accepted", false)):
		return
	var proposal := result.get("proposal") as VoxelCutProposal
	_expect(proposal != null and _has_role(proposal.native_paths, "overburden_cleanup"), "deep insertion clears unsupported overburden", failures)


func _has_role(paths: Array[Dictionary], role: String) -> bool:
	for path in paths:
		if String(path.get("role", "")) == role or (path.get("components", []) as Array).has(role):
			return true
	return false


func _check_negative_cases(failures: Array[String]) -> void:
	var contract := _contract("sy205")
	var cutter := Cutter.new()
	cutter.configure(contract, WorkZoneConfig.DEFAULT_VOXEL_SCALE_M)
	var origin_y := _bucket_origin_y(contract, -0.04)
	var base := Transform3D(Basis.IDENTITY, Vector3(0.0, origin_y, 20.0))
	var cases := [
		{"name": "stationary", "previous": base, "current": base},
		{"name": "above_ground", "previous": Transform3D(Basis.IDENTITY, base.origin + Vector3.UP * 3.0), "current": Transform3D(Basis.IDENTITY, base.origin + Vector3(0.0, 2.95, 0.05))},
		{"name": "separating", "previous": base, "current": Transform3D(Basis.IDENTITY, base.origin + Vector3(0.0, 0.08, 0.02))},
		{"name": "teleported", "previous": base, "current": Transform3D(Basis.IDENTITY, base.origin + Vector3(3.0, -0.1, 0.0))},
		{"name": "protected_boundary", "previous": Transform3D(Basis.IDENTITY, Vector3(15.6, origin_y, 20.0)), "current": Transform3D(Basis.IDENTITY, Vector3(15.55, origin_y - 0.08, 20.1))},
	]
	for case_value in cases:
		var case := case_value as Dictionary
		var pose := _pose(contract, case["previous"] as Transform3D, case["current"] as Transform3D, String(case["name"]))
		var result := cutter.build_proposal(pose, 1, 1, 1, "epoch", false, _flat_sdf)
		_expect(not bool(result.get("accepted", false)), "%s is rejected" % case["name"], failures)


func _pose(contract: Dictionary, previous: Transform3D, current: Transform3D, identity: String) -> Dictionary:
	var tool := BucketSoilTool.new()
	tool.configure(contract)
	var tool_snapshot := tool.compose_snapshot(previous, current, true, identity)
	return {
		"valid": true,
		"reason": "ok",
		"model_id": String(contract["model_id"]),
		"soil_tool": tool_snapshot,
		"contract": contract,
	}


func _flat_sdf(world_position: Vector3) -> Dictionary:
	return {
		"valid": true,
		"sdf": world_position.y / WorkZoneConfig.DEFAULT_VOXEL_SCALE_M,
		"gradient_world": Vector3.UP,
	}


func _edge_sweep_is_covered(pose: Dictionary, capsules: Array[Dictionary]) -> bool:
	var edge := {}
	for value in (pose.get("soil_tool", {}) as Dictionary).get("regions", []):
		if value is Dictionary and String((value as Dictionary).get("region_id", "")) == "teeth_main_edge":
			edge = value
			break
	if edge.is_empty():
		return false
	var previous := edge.get("previous_points", []) as Array
	var current := edge.get("current_points", []) as Array
	for step in 17:
		var alpha := float(step) / 16.0
		for point_index in previous.size():
			var world_point := (previous[point_index] as Vector3).lerp(current[point_index] as Vector3, alpha)
			var voxel_point := WorkZoneConfig.world_to_voxel(world_point)
			var covered := false
			for capsule in capsules:
				if not String(capsule.get("source", "")).begins_with("teeth_main_edge"):
					continue
				if _distance_to_segment(voxel_point, capsule["a_voxels"], capsule["b_voxels"]) <= float(capsule["radius_voxels"]) + 0.0001:
					covered = true
					break
			if not covered:
				return false
	return true


func _sources_are_canonical(capsules: Array[Dictionary]) -> bool:
	var last_order := -1
	var order := ["teeth_main_edge", "left_side_cutter", "right_side_cutter"]
	for capsule in capsules:
		var current_order := order.find(String(capsule.get("source", "")))
		if current_order < last_order:
			return false
		last_order = current_order
	return true


func _distance_to_segment(point: Vector3, a_value: Variant, b_value: Variant) -> float:
	var a := a_value as Vector3
	var b := b_value as Vector3
	var segment := b - a
	if segment.length_squared() <= 0.0000001:
		return point.distance_to(a)
	var alpha := clampf((point - a).dot(segment) / segment.length_squared(), 0.0, 1.0)
	return point.distance_to(a + segment * alpha)


func _bucket_origin_y(contract: Dictionary, desired_edge_y: float) -> float:
	var cutting := (contract.get("proxies", {}) as Dictionary).get("cutting_edge", {}) as Dictionary
	var center := cutting.get("center_godot", [0.0, 0.0, 0.0]) as Array
	return desired_edge_y - float(center[1])


func _contract(model_id: String) -> Dictionary:
	var descriptor := SoilContractDescriptor.load_for_model(model_id)
	return descriptor.to_dictionary() if descriptor != null and descriptor.is_valid_for(model_id) else {}


func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append("voxel bucket cutter: %s" % message)

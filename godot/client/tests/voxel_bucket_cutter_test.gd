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
	_check_sy135_lift_exit(failures)
	_check_occupancy_volume(failures)
	_check_tooth_lip_bridge(failures)
	_check_rotated_shallow_roof(failures)
	_check_negative_cases(failures)
	_check_sy135_unengaged_negative_cases(failures)
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


func _check_sy135_lift_exit(failures: Array[String]) -> void:
	var contract := _contract("sy135")
	var cutter := Cutter.new()
	cutter.configure(contract, WorkZoneConfig.DEFAULT_VOXEL_SCALE_M)
	var start := Vector3(0.0, _bucket_origin_y(contract, -0.45), 24.0)
	var previous := Transform3D(Basis.IDENTITY, start)
	var current := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(25.0)), start + Vector3(0.04, 0.08, 0.07))
	var pose := _pose(contract, previous, current, "sy135:lift-exit")
	var result := cutter.build_proposal(pose, 8, 21, 21, "epoch", true, _flat_sdf)
	var held_pose := _pose(contract, previous, previous, "engaged-hold")
	var held := cutter.build_proposal(held_pose, 8, 19, 19, "epoch", true, _flat_sdf)
	_expect(not bool(held["accepted"]) and bool(held["engaged"]), "engaged stationary hold retains contact without a cut", failures)
	var held_air := cutter.build_proposal(held_pose, 8, 19, 19, "epoch", true,
		func(_point: Vector3) -> Dictionary: return {"valid": true, "sdf": 1.0, "gradient_world": Vector3.UP})
	_expect(not bool(held_air["accepted"]) and bool(held_air["engaged"]), "pause in cleared cavity retains episode without a cut", failures)
	var fresh_air := cutter.build_proposal(held_pose, 8, 19, 19, "epoch", false,
		func(_point: Vector3) -> Dictionary: return {"valid": true, "sdf": 1.0, "gradient_world": Vector3.UP})
	_expect(not bool(fresh_air["engaged"]), "cleared cavity cannot initiate an episode", failures)
	var invalid_hold := cutter.build_proposal(held_pose, 8, 19, 19, "epoch", true,
		func(_point: Vector3) -> Dictionary: return {"valid": false})
	_expect(not bool(invalid_hold["engaged"]), "invalid SDF retires held episode", failures)
	var high := Transform3D(Basis.IDENTITY, start + Vector3.UP * 3)
	var exited_hold := cutter.build_proposal(_pose(contract, high, high, "exited"), 8, 19, 19, "epoch", true,
		func(_point: Vector3) -> Dictionary: return {"valid": true, "sdf": 1.0, "gradient_world": Vector3.UP})
	_expect(not bool(exited_hold["engaged"]), "fully exited stationary bucket retires episode", failures)
	var sideways := Transform3D(previous.basis, previous.origin + Vector3.RIGHT * 0.04)
	var departed := cutter.build_proposal(_pose(contract, previous, sideways, "sideways-clear"), 8, 19, 19, "epoch", true,
		func(_point: Vector3) -> Dictionary: return {"valid": true, "sdf": 2.0, "gradient_world": Vector3.UP})
	_expect(not bool(departed["accepted"]) and not bool(departed["engaged"]), "non-lifting traversal through air retires episode", failures)
	var buried := cutter.build_proposal(pose, 8, 20, 20, "epoch", true,
		func(point: Vector3) -> Dictionary: return {"valid": true, "sdf": -0.2 if point.y < -0.1 else 1.0, "gradient_world": Vector3.UP})
	_expect(bool(buried["accepted"]), "lift detects residual below a cleared original surface", failures)
	_expect(bool(result.get("accepted", false)), "engaged lifting finishes trailing surface sweep (%s)" % result.get("reason", ""), failures)
	if bool(result.get("accepted", false)):
		var proposal := result["proposal"] as VoxelCutProposal
		_expect(proposal.quality_flags.has("engaged_lift_exit"), "lift uses bounded continuation rather than new leading admission", failures)
		_expect(_has_role(proposal.native_paths, "overburden_cleanup"), "lift exit includes shallow roof cleanup", failures)
	var unengaged := cutter.build_proposal(pose, 8, 22, 22, "epoch", false, _flat_sdf)
	_expect(not bool(unengaged.get("accepted", false)), "same lift cannot initiate an unengaged cut", failures)
	var slope_contact := cutter.build_proposal(pose, 8, 24, 24, "epoch", true,
		func(point: Vector3) -> Dictionary: return {"valid": true, "sdf": minf(0.0, point.y / 0.125), "gradient_world": Vector3.FORWARD})
	_expect(bool(slope_contact.get("accepted", false)), "lift can remain in contact with an advancing front", failures)
	if bool(slope_contact.get("accepted", false)):
		_expect((slope_contact["proposal"] as VoxelCutProposal).quality_flags.has("engaged_lift_exit"),
			"lifting while leading gate still passes also receives shallow cleanup", failures)
	var air := cutter.build_proposal(pose, 8, 23, 23, "epoch", true,
		func(_point: Vector3) -> Dictionary: return {"valid": true, "sdf": 1.0, "gradient_world": Vector3.UP})
	_expect(not bool(air.get("accepted", false)), "continuation ends once residual surface is cleared", failures)
	# A shallow shell roof used to disappear from cleanup at 1.5 voxel depth.
	var shallow := {"shape": {"kind": "box", "size_m": [0.6, 0.1, 0.6]},
		"previous_transform": Transform3D(Basis.IDENTITY, Vector3(0, -0.12, 24)),
		"current_transform": Transform3D(Basis.IDENTITY, Vector3(0, -0.08, 24.04))}
	_expect(cutter._overburden_cleanup_paths(shallow).is_empty(), "ordinary shallow cut retains existing roof policy", failures)
	_expect(not cutter._overburden_cleanup_paths(shallow, true).is_empty(), "authorized shallow exit closes roof gap", failures)
	# Check between old depth strips, not just path centerlines.
	var exit_paths := cutter._overburden_cleanup_paths(shallow, true)
	for depth in [-0.72, -0.36, 0.0, 0.36, 0.72]:
		var point := WorkZoneConfig.world_to_voxel(Vector3(0.0, 0.0, 24.0 + 0.3 * float(depth)))
		var covered := false
		for path in exit_paths:
			var points := path["points_voxels"] as PackedVector3Array
			var radii := path["radii_voxels"] as PackedFloat32Array
			for index in range(points.size() - 1):
				if _distance_to_segment(point, points[index], points[index + 1]) <= radii[index]:
					covered = true
		_expect(covered, "lift cleanup covers surface between depth strips at %.2f" % depth, failures)
	var rotation := {"shape": {"kind": "box", "size_m": [1.0, 1.0, 1.0]},
		"previous_transform": Transform3D.IDENTITY,
		"current_transform": Transform3D(Basis(Vector3.RIGHT, deg_to_rad(25)), Vector3.ZERO)}
	_expect(cutter._sweep_transforms(rotation).size() > 2, "rotation-only sweep samples corner arc instead of origin distance", failures)


func _check_tooth_lip_bridge(failures: Array[String]) -> void:
	var contract := _contract("sy135")
	var cutter := Cutter.new()
	cutter.configure(contract, WorkZoneConfig.DEFAULT_VOXEL_SCALE_M)
	for yaw in [0.0, 0.8, 2.7]:
		var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.FORWARD, 0.15)
		var current := Transform3D(basis, Vector3(0, -1.5, 24))
		var previous := Transform3D(basis, current.origin - Vector3.UP * 0.01)
		var pose := _pose(contract, previous, current, "lip")
		var paths := cutter._build_sy135_native_paths(pose.soil_tool, true)
		var lip: Dictionary = {}
		for path in paths:
			if path.path_id == "floor:tooth_lip":
				lip = path
			var points: PackedVector3Array = path.points_voxels
			for i in range(points.size() - 1):
				_expect(points[i].distance_squared_to(points[i + 1]) > 0.00000001, "final lip proposal has no degenerate segments", failures)
		_expect(not lip.is_empty(), "lip retains separate native path boundary", failures)
		if lip.is_empty():
			continue
		var target := WorkZoneConfig.world_to_voxel(current * Vector3(0, 0.184, -1.104))
		var outside := WorkZoneConfig.world_to_voxel(current * Vector3(0.8, 0.184, -1.104))
		var covered := false
		var exterior_covered := false
		var points: PackedVector3Array = lip.points_voxels
		for i in range(points.size() - 1):
			covered = covered or _distance_to_segment(target, points[i], points[i + 1]) < lip.radii_voxels[i]
			exterior_covered = exterior_covered or _distance_to_segment(outside, points[i], points[i + 1]) < lip.radii_voxels[i]
		_expect(covered and not exterior_covered, "rotated lip covers working span and preserves exterior", failures)


func _check_occupancy_volume(failures: Array[String]) -> void:
	var cutter := Cutter.new()
	cutter.configure(_contract("sy135"), WorkZoneConfig.DEFAULT_VOXEL_SCALE_M)
	var region := {"region_id": "inner_shell", "shape": {"kind": "box", "size_m": [0.94, 0.64, 0.78]},
		"previous_transform": Transform3D(Basis.IDENTITY, Vector3(0, -1, 24)),
		"current_transform": Transform3D(Basis.IDENTITY, Vector3(0, -0.996, 24))}
	var paths := cutter._box_surface_paths(region, Cutter.OCCUPANCY_WIDTH_FRACTIONS,
		Cutter.OCCUPANCY_HEIGHT_FRACTIONS, "bucket_occupancy", Cutter.NATIVE_SURFACE_RADIUS_VOXELS)
	var missed := 0
	# Independent dense cross-section, including lane midpoints and box edges.
	for x in range(25):
		for y in range(19):
			for z in [-0.38, 0.0, 0.38]:
				var point := WorkZoneConfig.world_to_voxel(Vector3(lerpf(-0.46, 0.46, x / 24.0),
					-1.0 + lerpf(-0.31, 0.31, y / 18.0), 24.0 + float(z)))
				var covered := false
				for path in paths:
					var points := path["points_voxels"] as PackedVector3Array
					var radii := path["radii_voxels"] as PackedFloat32Array
					for index in range(points.size() - 1):
						if _distance_to_segment(point, points[index], points[index + 1]) < radii[index]:
							covered = true
				if not covered:
					missed += 1
	print("OCCUPANCY_VOLUME missed=%d/1425" % missed)
	_expect(missed == 0, "whole inner volume has no gaps between round brush lanes (%d missed)" % missed, failures)
	region["previous_transform"] = Transform3D(Basis.IDENTITY, Vector3(0, -0.3, 24))
	region["current_transform"] = Transform3D(Basis.IDENTITY, Vector3(0.02, -0.13, 24.08))
	var roof_paths := cutter._overburden_cleanup_paths(region, true)
	var degenerate := 0
	var last_crossing_covered := false
	# Independent intersection of the trailing lane with the world surface.
	# Inspect every segment too: a zero-length native capsule can corrupt SDF.
	var crossing := WorkZoneConfig.world_to_voxel(Vector3(0.01, 0.0, 24.39))
	for path in roof_paths:
		var points := path["points_voxels"] as PackedVector3Array
		var radii := path["radii_voxels"] as PackedFloat32Array
		for index in range(points.size() - 1):
			if points[index].distance_squared_to(points[index + 1]) < 0.00000001:
				degenerate += 1
			if _distance_to_segment(crossing, points[index], points[index + 1]) < radii[index]:
				last_crossing_covered = true
	_expect(degenerate == 0, "roof cutoff crossing emits no zero-length native segment", failures)
	_expect(last_crossing_covered, "trailing surface intersection is covered during exit", failures)


func _check_rotated_shallow_roof(failures: Array[String]) -> void:
	var cutter := Cutter.new()
	var contract := _contract("sy135")
	cutter.configure(contract, WorkZoneConfig.DEFAULT_VOXEL_SCALE_M)
	var previous := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(25)), Vector3(0, -0.12, 24))
	var current := Transform3D(previous.basis, previous.origin + Vector3(0, 0.025, 0.025))
	var pose := _pose(contract, previous, current, "shallow-rotated-roof")
	var result := cutter.build_proposal(pose, 1, 1, 1, "epoch", true, _flat_sdf)
	_expect(bool(result.get("accepted", false)), "shallow rotated inner bottom still authorizes engaged exit", failures)
	var inner := cutter._find_region(pose["soil_tool"], "inner_shell")
	var half := cutter._box_half_dimensions(inner)
	var transform := inner["current_transform"] as Transform3D
	var paths := cutter._overburden_cleanup_paths(inner, true)
	var missed := 0
	var checked := 0
	# Independently project the whole submerged volume, not the selected +Y face.
	for ix in range(9):
		for iy in range(9):
			for iz in range(9):
				var world := transform * (half * Vector3(lerpf(-0.95, 0.95, ix / 8.0), lerpf(-0.95, 0.95, iy / 8.0), lerpf(-0.95, 0.95, iz / 8.0)))
				if world.y > -0.01:
					continue
				checked += 1
				world.y = 0
				var point := WorkZoneConfig.world_to_voxel(world)
				var covered := false
				for path in paths:
					var points := path["points_voxels"] as PackedVector3Array
					var radii := path["radii_voxels"] as PackedFloat32Array
					for index in range(points.size() - 1):
						if _distance_to_segment(point, points[index], points[index + 1]) < radii[index]:
							covered = true
				if not covered:
					missed += 1
	print("ROTATED_ROOF checked=%d missed=%d" % [checked, missed])
	_expect(checked > 0 and missed == 0, "whole submerged volume projects to cleared roof (%d/%d missed)" % [missed, checked], failures)


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


func _check_sy135_unengaged_negative_cases(failures: Array[String]) -> void:
	var contract := _contract("sy135")
	var cutter := Cutter.new()
	_expect(cutter.configure(contract, WorkZoneConfig.DEFAULT_VOXEL_SCALE_M), "sy135 negative cases configure", failures)
	if not cutter.configured:
		return
	var origin_y := _bucket_origin_y(contract, -0.04)
	var base := Transform3D(Basis.IDENTITY, Vector3(-6.0, origin_y, 30.0))
	var withdrawal_pose := _pose(
		contract,
		base,
		Transform3D(Basis.IDENTITY, base.origin + Vector3(0.0, 0.08, -0.02)),
		"sy135:withdrawal-unengaged",
	)
	var withdrawal := cutter.build_proposal(withdrawal_pose, 9, 30, 30, "epoch", false, _flat_sdf)
	_expect(
		not bool(withdrawal.get("accepted", false)) and String(withdrawal.get("reason", "")) == "separating",
		"sy135 unengaged withdrawal cannot authorize occupancy deletion",
		failures,
	)

	var curl_current := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(5.0)), base.origin)
	var curl_pose := _pose(contract, base, curl_current, "sy135:curl-unengaged")
	var curl := cutter.build_proposal(curl_pose, 9, 31, 31, "epoch", false, _flat_sdf)
	_expect(
		not bool(curl.get("accepted", false)),
		"sy135 unengaged curl cannot authorize occupancy deletion (%s)" % curl.get("reason", ""),
		failures,
	)

	# With the bucket inverted, the outer back intersects the flat soil while the
	# leading teeth remain in air. Only the leading-front sampler is allowed to
	# authorize a cut, so moving the back shell tangentially must stay rejected.
	var inverted_basis := Basis(Vector3.RIGHT, PI)
	var back_previous := Transform3D(inverted_basis, Vector3(6.0, 0.2, 30.0))
	var back_current := Transform3D(inverted_basis, back_previous.origin + Vector3(0.0, 0.0, 0.08))
	var back_pose := _pose(contract, back_previous, back_current, "sy135:outer-back-brush")
	var back_region := _region(back_pose, "outer_back")
	var teeth_region := _region(back_pose, "teeth_main_edge")
	_expect(
		_minimum_current_y(back_region) < 0.0 and _minimum_current_y(teeth_region) > 0.0,
		"sy135 back-brush fixture contacts only the non-authorizing outer shell",
		failures,
	)
	var back_brush := cutter.build_proposal(back_pose, 9, 32, 32, "epoch", false, _flat_sdf)
	_expect(
		not bool(back_brush.get("accepted", false)) and String(back_brush.get("reason", "")) == "above_ground",
		"sy135 outer-back brush cannot authorize occupancy deletion",
		failures,
	)


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


func _region(pose: Dictionary, region_id: String) -> Dictionary:
	for value in (pose.get("soil_tool", {}) as Dictionary).get("regions", []):
		var candidate := value as Dictionary
		if String(candidate.get("region_id", "")) == region_id:
			return candidate
	return {}


func _minimum_current_y(region: Dictionary) -> float:
	var minimum_y := INF
	for value in region.get("current_points", []):
		minimum_y = minf(minimum_y, (value as Vector3).y)
	return minimum_y


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

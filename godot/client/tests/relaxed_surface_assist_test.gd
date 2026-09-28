extends "res://tests/assist_modes_test.gd"

const Profile = preload("res://scripts/slope_profile.gd")


func _run() -> void:
	var failures: Array[String] = []
	_check_relaxed_assist_contracts(failures)
	_check_relaxed_assist_at_bound(failures)
	_check_bounded_solver(failures)
	_check_actuator_inverse(failures)
	_check_geometry(failures)
	_check_exterior_geometry(failures)
	_check_profile_knee(failures)
	_drive_transport(failures)
	for angle in [0.0, 20.0, -20.0]:
		for direction in [-1.0, 1.0]:
			_drive_surface(angle, direction, failures)
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("relaxed_surface_assist_test: PASS")
	quit(0 if failures.is_empty() else 1)


func _check_bounded_solver(failures: Array[String]) -> void:
	# A saturated joint may remain fixed while the other two still supply
	# both surface tracking and travel. Scaling one unconstrained solution
	# would incorrectly stall every joint here.
	var rates := Solver.bounded_surface_rates(Vector3(1, 1, 0), Vector3(0, 1, 1), 0.0, 0.8,
		Vector3(-1, 0, -1), Vector3(1, 0, 1), Vector3.ZERO, 0.08)
	_expect(absf(rates.x) < 0.00001 and absf(rates.y) < 0.00001 and rates.z > 0.79,
		"bounded solve redistributes travel with a fixed joint: %s" % rates, failures)
	# Impossible tangential speed must not consume normal tracking authority.
	rates = Solver.bounded_surface_rates(Vector3(1, 1, 0), Vector3(0, 1, 1), 0.3, 100.0,
		Vector3(-0.2, -0.2, -0.2), Vector3(0.2, 0.2, 0.2), Vector3.ZERO, 0.08)
	_expect(absf(rates.x + rates.y - 0.3) < 0.00001 and rates.length() < 0.35,
		"normal task wins over unreachable travel: %s" % rates, failures)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4813
	for trial in 100:
		var normal := Vector3(rng.randf_range(-5, 5), rng.randf_range(-5, 5), rng.randf_range(-1, 1))
		var tangent := Vector3(rng.randf_range(-5, 5), rng.randf_range(-5, 5), rng.randf_range(-1, 1))
		var low := Vector3(-0.3, -0.4, -0.2)
		var high := Vector3(0.1, 0.5, 0.3)
		var witness := low.lerp(high, rng.randf())
		var desired := normal.dot(witness)
		rates = Solver.bounded_surface_rates(normal, tangent, desired, rng.randf_range(-1, 1), low, high, Vector3.ZERO, 0.08)
		_expect(absf(normal.dot(rates) - desired) < 0.00002 and rates == rates.clamp(low, high),
			"bounded normal equality trial %d" % trial, failures)


func _check_actuator_inverse(failures: Array[String]) -> void:
	var fixture := _standalone_fixture("sy135")
	var articulation := fixture.articulation as KinematicArticulationState
	var pipeline := fixture.pipeline as EquipmentAssistPipeline
	var chassis := Transform3D.IDENTITY
	articulation.set_commands(Vector4.ZERO)
	articulation.accept_step(articulation.propose_step(STAGE_DT, chassis, true), 1.0)
	articulation.set_cut_resistance(0.7)
	for tick in 180:
		var ctx := pipeline.build_context(articulation, chassis, STAGE_DT, {}) as KCtx
		var commands := Vector4.ZERO
		var predicted := Vector3.ZERO
		for index in 3:
			var joint: String = GuidedProfileStage.WORK_JOINTS[index]
			var low := ctx.velocity_for_command(joint, -1.0)
			var high := ctx.velocity_for_command(joint, 1.0)
			var fraction := 0.95 if (tick / 30) % 2 == 0 else 0.05
			predicted[index] = lerpf(low, high, fraction)
			commands[index + 1] = ctx.command_for_velocity(joint, predicted[index])
		articulation.set_commands(commands, tick)
		var proposal := articulation.propose_step(STAGE_DT, chassis, true)
		for index in 3:
			var actual := float(proposal.velocities[GuidedProfileStage.WORK_JOINTS[index]])
			_expect(absf(actual - predicted[index]) < 0.000002, "exact actuator inverse through acceleration reversal", failures)
		articulation.accept_step(proposal, 1.0)


func _check_geometry(failures: Array[String]) -> void:
	var fixture := _standalone_fixture("sy135")
	var pipeline := fixture.pipeline as EquipmentAssistPipeline
	var articulation := fixture.articulation as KinematicArticulationState
	pipeline.set_stage_params("bucket_level", {"relaxed_attitude": true})
	pipeline.set_stage_enabled("bucket_level", true)
	var contract := JSON.parse_string(FileAccess.get_file_as_string("res://resources/models/sy135_soil_contract.json")) as Dictionary
	pipeline.set_tool_geometry(contract)
	var mount := Transform3D(Basis(Vector3.UP, 0.2), Vector3(0.1, -0.3, -0.7))
	pipeline.set_tool_mount(mount)
	var chassis := Transform3D(Basis(Vector3.FORWARD, 0.1), Vector3(2, 3, 4))
	var ctx := pipeline.build_context(articulation, chassis, STAGE_DT, {}) as KCtx
	var frames := articulation.frames_at_chassis(chassis)
	var region := contract.bucket_tool.regions[0] as Dictionary
	var c := region.center_godot as Array
	var n := region.outward_normal_godot as Array
	var point := Vector3(c[0], c[1], c[2]) + Vector3(n[0], n[1], n[2]).normalized() * float(region.shape.radius_m)
	var expected: Vector3 = frames.bucket_link * mount * point
	_expect(ctx.bucket_ref_world.distance_to(expected) < 0.00001, "current chassis and mounted physical cutting edge geometry", failures)
	# Contact bypass clears solid sweep history every tick. Assist transport
	# still needs the previous accepted mount in that mode.
	var runtime := JoltChassisTrackRuntime.new()
	runtime._assist_pipeline = pipeline
	runtime.set_solid_tool_mount(mount)
	runtime._reset_support_response(true)
	var moved_mount := mount
	moved_mount.origin.y += 0.001
	runtime.set_solid_tool_mount(moved_mount)
	var moving_ctx := pipeline.build_context(articulation, chassis, STAGE_DT, {}) as KCtx
	_expect(moving_ctx.tool_point_velocity.length() > 0.05, "contact bypass retains attachment velocity feedforward", failures)
	runtime.free()
	pipeline.set_tool_mount(mount)
	var level := pipeline.get_stage("bucket_level") as BucketLevelAssist
	level.step(ctx, Vector4(0, 0, 0.8, 0))
	_expect(level.get_status_snapshot().edge_plane_span_m > 0.02, "rolled or tilted cutting edge reports line-plane mismatch", failures)
	var height := float(level.get_status_snapshot().height_ref_m)
	ctx.bucket_ref_world.y += 0.5
	level.step(ctx, Vector4(0, 0, 0.8, 0))
	_expect(is_equal_approx(float(level.get_status_snapshot().height_ref_m), height), "relaxed plane never follows tracking error", failures)
	pipeline.set_tool_geometry({})
	ctx = pipeline.build_context(articulation, chassis, STAGE_DT, {}) as KCtx
	var result := level.step(ctx, Vector4(0, 0.3, 0.8, 0.4))
	_expect(result.commands == Vector4.ZERO and result.flags.has("level_assist_no_cutting_edge"), "no tool cannot guide a hidden native bucket", failures)


func _drive_surface(angle: float, direction: float, failures: Array[String]) -> void:
	var fixture := _standalone_fixture("sy135")
	var pipeline := fixture.pipeline as EquipmentAssistPipeline
	var articulation := fixture.articulation as KinematicArticulationState
	var chassis := Transform3D(Basis.IDENTITY, Vector3(0, 1, 0))
	_teleport(articulation, chassis, {"swing_joint": 0.0, "boom_joint": 0.0, "arm_joint": -0.4, "bucket_joint": 0.0})
	articulation.set_commands(Vector4.ZERO)
	articulation.accept_step(articulation.propose_step(STAGE_DT, chassis, true), 1.0)
	var name := "bucket_level" if angle == 0.0 else "slope_grade"
	pipeline.set_stage_params(name, {"relaxed_attitude": true})
	# Enable geometry selection before recording the independent target.
	var profile: SlopeProfile
	if angle != 0.0:
		profile = Profile.create(Vector3.ZERO, Vector3.FORWARD, -10.0, angle, 0.0)
		pipeline.set_stage_params(name, {"profile": profile})
	pipeline.set_stage_enabled(name, true)
	var start := pipeline.build_context(articulation, chassis, STAGE_DT, {}) as KCtx
	if profile != null:
		var contact: Vector3 = start.surface_contact(Vector3.UP - tan(deg_to_rad(angle)) * start.horizontal).point
		profile = Profile.create(contact, start.horizontal, -10.0, angle,
			contact.y - tan(deg_to_rad(angle)) * 10.0)
		pipeline.set_stage_params(name, {"profile": profile})
	var initial_y: float = start.surface_contact(Vector3.UP).point.y
	var max_error := 0.0
	var min_gap := INF
	var max_gap := -INF
	var tooth_clearance := 0.0
	var max_step := 0.0
	var previous_attitude := start.bucket_attitude_rad()
	var travel := 0.0
	var reverse_start := 0.0
	var returned := 0.0
	for tick in 900:
		var intent := direction * 0.8 if tick < 600 else -direction * 0.8
		# Loaded cutting and reversal exercise asymmetric actuator ceilings.
		articulation.set_cut_resistance(0.7)
		var result := pipeline.step(Vector4(0, 0, intent, 0), articulation, chassis, STAGE_DT, {})
		var commands := result.commands as Vector4
		_expect(commands.is_finite() and absf(commands.y) <= 1.0 and absf(commands.z) <= 1.0 and absf(commands.w) <= 1.0,
			"finite bounded commands", failures)
		articulation.set_commands(commands, tick)
		articulation.accept_step(articulation.propose_step(STAGE_DT, chassis, true), 1.0)
		var ctx := pipeline.build_context(articulation, chassis, STAGE_DT, {}) as KCtx
		var lowest_gap := INF
		for endpoint in ctx.exterior_points:
			var height := initial_y if profile == null else profile.height_at(profile.along(endpoint))
			lowest_gap = minf(lowest_gap, endpoint.y - height)
		max_error = maxf(max_error, absf(lowest_gap))
		min_gap = minf(min_gap, lowest_gap)
		max_gap = maxf(max_gap, lowest_gap)
		var tooth_height := initial_y if profile == null else profile.height_at(profile.along(ctx.bucket_ref_world))
		tooth_clearance = maxf(tooth_clearance, ctx.bucket_ref_world.y - tooth_height)
		var along := (ctx.bucket_ref_world - start.bucket_ref_world).dot(start.horizontal) * direction
		if tick < 600:
			travel = maxf(travel, along)
			reverse_start = along
		else:
			returned = maxf(returned, reverse_start - along)
		max_step = maxf(max_step, absf(wrapf(ctx.bucket_attitude_rad() - previous_attitude, -PI, PI)))
		previous_attitude = ctx.bucket_attitude_rad()
	print("gap range %.5f .. %.5f" % [min_gap, max_gap])
	print("surface angle=%.0f dir=%.0f travel=%.3f return=%.3f max_error=%.5f max_pitch_step=%.5f" % [angle, direction, travel, returned, max_error, max_step])
	_expect(angle != 0.0 or tooth_clearance > 0.05, "body contact allows teeth to rise instead of pushing shell through surface", failures)
	_expect(max_error < 0.015, "lowest exterior stays within 1.5cm (angle=%s dir=%s error=%s)" % [angle, direction, max_error], failures)
	_expect(travel > 0.5 and returned > 0.25, "sustained pass and reversal progress (angle=%s dir=%s)" % [angle, direction], failures)
	_expect(max_step < 0.04, "pitch changes continuously", failures)


func _drive_transport(failures: Array[String]) -> void:
	var fixture := _standalone_fixture("sy135")
	var pipeline := fixture.pipeline as EquipmentAssistPipeline
	var articulation := fixture.articulation as KinematicArticulationState
	var chassis := Transform3D(Basis.IDENTITY, Vector3(0, 1, 0))
	_teleport(articulation, chassis, {"swing_joint": 0.0, "boom_joint": 0.0, "arm_joint": -0.4, "bucket_joint": 0.0})
	articulation.set_commands(Vector4.ZERO)
	articulation.accept_step(articulation.propose_step(STAGE_DT, chassis, true), 1.0)
	pipeline.set_stage_params("bucket_level", {"relaxed_attitude": true})
	pipeline.set_stage_enabled("bucket_level", true)
	var start := pipeline.build_context(articulation, chassis, STAGE_DT, {}) as KCtx
	var previous_mount := Transform3D.IDENTITY
	var max_error := 0.0
	for tick in 360:
		var t := tick * STAGE_DT
		var previous_chassis := chassis
		chassis.origin.y = 1.0 + 0.025 * sin(t * 2.0)
		var linear := (chassis.origin - previous_chassis.origin) / STAGE_DT
		var mount := Transform3D(Basis(Vector3.RIGHT, 0.08 * sin(t * 1.5)), Vector3.ZERO)
		pipeline.set_tool_mount(mount, previous_mount)
		previous_mount = mount
		var result := pipeline.step(Vector4(0, 0, 0.5, 0), articulation, chassis, STAGE_DT, {}, linear)
		articulation.set_commands(result.commands, tick)
		articulation.accept_step(articulation.propose_step(STAGE_DT, chassis, true), 1.0)
		var ctx := pipeline.build_context(articulation, chassis, STAGE_DT, {}) as KCtx
		max_error = maxf(max_error, absf(float(ctx.surface_contact(Vector3.UP).point.y) - float(start.surface_contact(Vector3.UP).point.y)))
	print("moving chassis and attachment max_error=%.5f" % max_error)
	_expect(max_error < 0.02, "moving chassis and attachment keep the original level plane", failures)


func _check_exterior_geometry(failures: Array[String]) -> void:
	for path in ["res://resources/models/sy135_soil_contract.json", "res://resources/models/sy80u_soil_contract.json", "res://resources/attachments/gb12_s50_soil_contract.json"]:
		var fixture := _standalone_fixture("sy135")
		var pipeline := fixture.pipeline as EquipmentAssistPipeline
		var articulation := fixture.articulation as KinematicArticulationState
		var contract := JSON.parse_string(FileAccess.get_file_as_string(path)) as Dictionary
		pipeline.set_tool_geometry(contract)
		pipeline.set_stage_params("bucket_level", {"relaxed_attitude": true})
		pipeline.set_stage_enabled("bucket_level", true)
		var mount := Transform3D(Basis(Vector3.FORWARD, 0.3), Vector3(0.1, -0.2, 0.3))
		pipeline.set_tool_mount(mount)
		var ctx := pipeline.build_context(articulation, Transform3D.IDENTITY, STAGE_DT, {}) as KCtx
		var tool := BucketSoilTool.new()
		_expect(tool.configure(contract), "exterior tool config " + path, failures)
		var snapshot := tool.compose_snapshot(ctx.bucket_link, ctx.bucket_link, true, "assist-test")
		var count := 0
		for region in snapshot.regions:
			if region.kind not in ["teeth", "side_cutter", "floor", "outer_shell"]:
				continue
			for point in region.current_points:
				var found := false
				for candidate in ctx.exterior_points:
					found = found or candidate.distance_to(point) < 0.00001
				_expect(found, "assist covers mounted exterior " + region.region_id + " " + path, failures)
				count += 1
		_expect(count == ctx.exterior_points.size() and count > 10, "no empty cavity/opening used as solid contact", failures)


func _check_profile_knee(failures: Array[String]) -> void:
	var fixture := _standalone_fixture("sy135")
	var pipeline := fixture.pipeline as EquipmentAssistPipeline
	var ctx := pipeline.build_context(fixture.articulation, Transform3D.IDENTITY, STAGE_DT, {}) as KCtx
	# Tooth on the descending slope while the back is still over the bench.
	# Extrapolating the tooth tangent misses the bench contact.
	ctx.horizontal = Vector3.RIGHT
	ctx.bucket_ref_world = Vector3(1, -0.5, 0)
	ctx.exterior_points = [Vector3(1, -0.5, 0), Vector3(-1, -0.1, 0)]
	ctx.exterior_mount_velocities = [Vector3.ZERO, Vector3.ZERO]
	var stage := pipeline.get_stage("slope_grade") as SlopeGradeAssist
	var profile := Profile.create(Vector3.ZERO, Vector3.RIGHT, 0, -30, 0)
	stage.apply_params({"profile": profile, "relaxed_attitude": true})
	var contact := stage._exterior_contact(ctx)
	_expect(contact.point == ctx.exterior_points[1] and is_zero_approx(float(contact.target.grade)), "knee checks each point against its actual bench/slope segment", failures)

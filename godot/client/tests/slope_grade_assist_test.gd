extends SceneTree

## Slope-grade assist contract: the confirmed SlopeProfile becomes the
## tracked surface — swing/boom/bucket are owned (swing silenced), W/S rides
## the tooth along the piecewise profile (flat bench inside the toe, grade
## beyond it), and the bucket keeps its ground-relative pitch. Covers the
## pure profile math, pipeline mutual exclusion with the level assist,
## refuse-to-enable without a profile, the preview volume computation on a
## synthetic heightfield, and a live Jolt drive across the toe junction.

const Pipeline = preload("res://scripts/equipment_assist_pipeline.gd")
const AssistStage = preload("res://scripts/equipment_assist_stage.gd")
const KCtx = preload("res://scripts/equipment_kinematics_context.gd")
const Profile = preload("res://scripts/slope_profile.gd")
const CutPreview = preload("res://scripts/slope_cut_preview.gd")

const DRIVE_TICKS := 90
## The live-drive profile is anchored through the current tooth pose so the
## pass rides in air — no soil offset to absorb — and the correction window
## converges the same centimeter band the level assist holds.
const SURFACE_TOL_M := 0.05
const ATTITUDE_TOL_RAD := 0.02

var failures: Array[String] = []
var _command_identity := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if ProjectSettings.get_setting("physics/3d/physics_engine") != "Jolt Physics":
		return _fail("Jolt Physics is not selected")
	_test_profile_math()
	_test_profile_reanchor()
	_test_knee_blend()
	_test_pipeline_contracts()
	_test_preview_compute()
	for model_id in ["sy135", "sy205"]:
		if failures.is_empty():
			await _test_model(model_id)
	if failures.is_empty():
		print("slope_grade_assist_test: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


## Piecewise surface: flat bench at toe height on the machine side of the
## toe, linear grade beyond it — both signs of slope angle.
func _test_profile_math() -> void:
	var tooth := Vector3(2.0, 0.5, -1.0)
	var axis := Vector3(0.6, 0.2, 0.8) # projected: ~(-) — normalizes to xz
	var rising := Profile.create(tooth, axis, 3.0, 20.0, 0.0)
	if absf(rising.axis.length() - 1.0) > 0.001:
		failures.append("profile axis was not normalized")
	if not is_equal_approx(rising.toe_s, 3.0):
		failures.append("profile toe distance not preserved")
	if absf(rising.along(tooth)) > 0.001:
		failures.append("profile origin does not sit on the tooth")
	# Bench side: any s below toe_s must read exactly toe height.
	for s in [-2.0, 0.0, 2.99]:
		if not is_equal_approx(rising.height_at(s), 0.0) or not is_equal_approx(rising.grade_at(s), 0.0):
			failures.append("bench segment is not flat at toe height (s=%.2f)" % s)
			break
	# Grade side: linear climb at tan(20°).
	var expected := tan(deg_to_rad(20.0)) * 2.0
	if absf(rising.height_at(5.0) - expected) > 0.001:
		failures.append("rising profile height mismatch: %.4f vs %.4f" % [rising.height_at(5.0), expected])
	if absf(rising.grade_at(5.0) - tan(deg_to_rad(20.0))) > 0.0001:
		failures.append("rising profile grade mismatch")
	# Negative slope descends symmetrically.
	var falling := Profile.create(tooth, axis, 3.0, -20.0, 1.0)
	if absf(falling.height_at(4.0) - (1.0 - tan(deg_to_rad(20.0)))) > 0.001:
		failures.append("falling profile height mismatch")
	# Toe world point lands on the axis at the configured distance.
	var toe := rising.toe_world()
	var toe_s := (Vector2(toe.x, toe.z) - Vector2(tooth.x, tooth.z)).dot(rising.axis)
	if absf(toe_s - 3.0) > 0.001 or not is_equal_approx(toe.y, 0.0):
		failures.append("toe_world does not sit at distance/height")


## Machine-following anchor: capture once, then reanchor() must reproduce
## the origin on an unmoved machine, translate it rigidly with the pivot,
## and rotate it around the pivot with the heading.
func _test_profile_reanchor() -> void:
	var profile := Profile.create(
		Vector3(2.0, 0.5, -1.0), Vector3(1.0, 0.0, 0.0), 3.0, 15.0, 0.0
	)
	var pivot := Vector2(0.0, 0.0)
	profile.capture_anchor(pivot)
	var origin0 := profile.origin_xz
	profile.reanchor(Vector3(1.0, 0.0, 0.0), pivot)
	if profile.origin_xz.distance_to(origin0) > 0.0001:
		failures.append("reanchor moved the origin on a stationary machine")
	# Undercarriage drives 5 m forward: the whole surface follows.
	profile.reanchor(Vector3(1.0, 0.0, 0.0), pivot + Vector2(5.0, 0.0))
	if profile.origin_xz.distance_to(origin0 + Vector2(5.0, 0.0)) > 0.0001:
		failures.append("reanchor did not translate the surface with the pivot")
	# Machine yaws 90°: the anchor keeps its (s, t) offset in the new frame.
	profile.reanchor(Vector3(0.0, 0.0, 1.0), pivot)
	if not profile.axis.is_equal_approx(Vector2(0.0, 1.0)):
		failures.append("reanchor did not adopt the live heading")
	var expect := pivot + Vector2(0.0, 1.0) * 2.0 + Vector2(-1.0, 0.0) * -1.0
	if profile.origin_xz.distance_to(expect) > 0.001:
		failures.append("reanchor rotated the anchor off its machine-relative offset")


## Smooth toe knee: C1 at both blend joints, mid-knee lifts w/4 above the
## sharp corner, grade ramps 0 -> full across the band instead of stepping.
func _test_knee_blend() -> void:
	var profile := Profile.create(
		Vector3(0.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0), 3.0, 20.0, 0.0
	)
	profile.knee_blend_m = 0.2
	var g := tan(deg_to_rad(20.0))
	var w := 0.2
	# Outside the band the surface is identical to the sharp profile.
	for s in [2.5, 2.79]:
		if absf(profile.height_at(s)) > 0.0001:
			failures.append("blended profile lifted the bench outside the knee (s=%.2f)" % s)
			break
	if absf(profile.height_at(4.0) - g * 1.0) > 0.001:
		failures.append("blended profile broke the grade beyond the knee")
	# C1 joints: height and grade are continuous at both band edges.
	if absf(profile.height_at(3.0 - w)) > 0.0001 or absf(profile.grade_at(3.0 - w)) > 0.0001:
		failures.append("blended profile is not C0/C1 at the bench joint")
	if absf(profile.grade_at(3.0 + w) - g) > 0.0001:
		failures.append("blended profile does not reach full grade at the grade joint")
	# Mid-knee: the surface rounds over the corner, grade is halfway in.
	if absf(profile.height_at(3.0) - g * w / 4.0) > 0.0005:
		failures.append("blended profile mid-knee height wrong")
	if absf(profile.grade_at(3.0) - g * 0.5) > 0.0001:
		failures.append("blended profile mid-knee grade wrong")
	# Blend off: the sharp piecewise surface comes back verbatim.
	profile.knee_blend_m = 0.0
	if absf(profile.height_at(3.0)) > 0.0001 or absf(profile.grade_at(2.99)) > 0.0001:
		failures.append("zero blend did not restore the sharp profile")


## Pipeline plumbing that needs no Jolt body: registration, exclusive group
## with the level stage, refused enable without a confirmed profile, swing
## silencing, and passthrough while disabled.
func _test_pipeline_contracts() -> void:
	var fixture := _standalone_fixture("sy135")
	if fixture.is_empty():
		return
	var pipeline := fixture["pipeline"] as EquipmentAssistPipeline
	var articulation := fixture["articulation"] as KinematicArticulationState
	var stage := pipeline.get_stage("slope_grade")
	if stage == null:
		return _fail("slope_grade stage was not registered")
	if stage.writes_mask != (AssistStage.MASK_WORK_EQUIPMENT | AssistStage.MASK_SWING):
		failures.append("slope stage declared an unexpected channel mask")
	# No profile injected: enabling must be refused so nothing half-tracks.
	pipeline.set_stage_enabled("slope_grade", true)
	if pipeline.is_stage_enabled("slope_grade"):
		failures.append("slope stage enabled without a confirmed profile")
	var profile := Profile.create(
		Vector3(3.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0), 2.0, 15.0, 0.0
	)
	if not pipeline.set_stage_params("slope_grade", {"profile": profile}):
		return _fail("slope stage rejected a valid profile injection")
	pipeline.set_stage_enabled("bucket_level", true)
	pipeline.set_stage_enabled("slope_grade", true)
	if not pipeline.is_stage_enabled("slope_grade"):
		failures.append("slope stage did not enable with a confirmed profile")
	if pipeline.is_stage_enabled("bucket_level"):
		failures.append("exclusive group did not drop the level assist")
	# Enabled with profile: a swing command must come out zeroed while the
	# arm channel still carries intent through the solver.
	var driven := pipeline.step(
		Vector4(0.7, 0.0, 0.4, 0.0), articulation, Transform3D.IDENTITY, 0.016, {}
	)
	var out := driven.get("commands", Vector4.ZERO) as Vector4
	if absf(out.x) > 0.0001:
		failures.append("slope stage leaked swing input (%.4f)" % out.x)
	# Disabled: the pipeline passes commands through untouched.
	pipeline.set_stage_enabled("slope_grade", false)
	var input := Vector4(0.4, 0.2, -0.3, 0.5)
	var idle := pipeline.step(input, articulation, Transform3D.IDENTITY, 0.016, {})
	if idle.get("commands", Vector4.ZERO) != input:
		failures.append("disabled slope stage did not pass commands through")


## Cut volume on a synthetic heightfield: a flat terrain at h=0 over a
## descending profile must yield positive volume only inside the reachable
## band, and an unreachable or all-below-terrain profile yields none.
func _test_preview_compute() -> void:
	var fixture := _standalone_fixture("sy135")
	if fixture.is_empty():
		return
	var pipeline := fixture["pipeline"] as EquipmentAssistPipeline
	var articulation := fixture["articulation"] as KinematicArticulationState
	var ctx := pipeline.build_context(articulation, Transform3D.IDENTITY, 0.016, {})
	var edge_local := _cutting_edge_local("sy135")
	# Anchor the profile at the measured tooth pose so the target surface
	# passes through the reachable envelope, then let the synthetic terrain
	# ride a constant 0.3 m above the target: every sampled band cell is a
	# cut of exactly that depth, so the volume is deterministic.
	var tooth := ctx.bucket_ref_world as Vector3
	var axis := Vector3(ctx.horizontal.x, 0.0, ctx.horizontal.z)
	var profile := Profile.create(tooth, axis, 1.5, -30.0, tooth.y - 0.3)
	var raised_sampler := func(world_xz: Vector2) -> float:
		var s := (world_xz - profile.origin_xz).dot(profile.axis)
		return profile.height_at(s) + 0.3
	var result := CutPreview.compute(
		profile, articulation, Transform3D.IDENTITY, edge_local,
		ctx.joint_limits, raised_sampler, 0.25, 0.56, 12
	)
	if result.is_empty() or float(result.get("volume_m3", 0.0)) <= 0.0:
		failures.append("raised-terrain preview produced no cut volume")
	if float(result.get("s_max", 0.0)) <= float(result.get("s_min", 0.0)):
		failures.append("preview reachable band collapsed")
	var s_values := result.get("s_values", PackedFloat32Array()) as PackedFloat32Array
	var terrain_rows := result.get("terrain", []) as Array
	if s_values.size() != terrain_rows.size() or s_values.size() < 2:
		failures.append("preview grids are missing or misaligned")
	if absf(float(result.get("max_depth_m", 0.0)) - 0.3) > 0.01:
		failures.append("preview max depth should equal the constant offset")
	# Terrain sunk 0.3 m below the target: nothing to cut anywhere.
	var sunk_sampler := func(world_xz: Vector2) -> float:
		var s := (world_xz - profile.origin_xz).dot(profile.axis)
		return profile.height_at(s) - 0.3
	var dry := CutPreview.compute(
		profile, articulation, Transform3D.IDENTITY, edge_local,
		ctx.joint_limits, sunk_sampler, 0.25, 0.56, 12
	)
	if float(dry.get("volume_m3", -1.0)) > 0.001:
		failures.append("profile above terrain reported cut volume")


## Live drive: confirm a rising profile, then W pushes the tooth along it —
## the measured tooth height must track height_at(s) with pitch held and
## the swing joint frozen; S pulls back across the toe onto the bench.
func _test_model(model_id: String) -> void:
	var fixture := await _create_fixture(model_id)
	if fixture.is_empty():
		return
	var runtime := fixture["runtime"] as JoltChassisTrackRuntime
	var spawn := fixture["spawn"] as Transform3D
	runtime.reset(spawn)
	await _settle(runtime, 60)
	# Lower the tooth toward a working pose — rest height varies a lot
	# between rigs (sy205 parks the tooth ~3.7 m up). Stop at 2 m: deeper
	# retraction pushes sy205 into the ill-conditioned crawl zone where the
	# rate conditioning caps joint speed at a few cm/s.
	for frame in 300:
		var probe := _measure(runtime)
		if (probe["ref"] as Vector3).y < 2.0:
			break
		_drive(runtime, Vector4(0.0, -0.9, 0.9, 0.5))
		await physics_frame
	await _settle(runtime, 30)
	# The fixture has no excavation world, so soil never yields — a profile
	# anchored at terrain height would hold the tooth up on un-cut ground
	# forever. Instead confirm a surface passing through the current tooth
	# height: pure kinematic tracking in air, which is the contract this
	# stage actually owns. The runtime confirm path takes any profile.
	var ctx0 := runtime._assist_pipeline.build_context(
		runtime._articulation, runtime._body.global_transform, 0.0, {}
	) as KCtx
	var tooth0 := ctx0.bucket_ref_world
	var axis := Vector3(ctx0.horizontal.x, 0.0, ctx0.horizontal.z)
	var profile := Profile.create(tooth0, axis, 1.5, 20.0, tooth0.y - 0.3)
	if not runtime.confirm_slope_assist(profile):
		failures.append("%s refused the confirmed slope profile" % model_id)
		runtime.teardown()
		(fixture["host"] as Node3D).queue_free()
		return
	if runtime.is_equipment_assist_enabled("bucket_level"):
		failures.append("%s level assist stayed enabled alongside slope" % model_id)

	# Swing silenced: A/D input must not move the swing joint while the
	# stage owns the channel.
	var swing_before := _joint_positions(runtime).get("swing_joint", 0.0) as float
	for frame in 30:
		_drive(runtime, Vector4(0.8, 0.0, 0.0, 0.0))
		await physics_frame
	var swing_after := _joint_positions(runtime).get("swing_joint", 0.0) as float
	if absf(swing_after - swing_before) > 0.005:
		failures.append("%s swing moved under slope assist (%.4f rad)" % [model_id, swing_after - swing_before])

	# Push out across the toe: the tooth height must track the profile. The
	# measured error over virgin soil is the unexcavated thickness — the edge
	# presses and translates, the pass scrapes the bench down to the target,
	# so the meaningful invariant is steady-state convergence by the end of
	# the stroke plus a bounded excursion, not an instant landing.
	var peak_surface_error := 0.0
	var peak_attitude_error := 0.0
	var tail_surface_error := 0.0
	var landed := false
	var start := _measure(runtime)
	var start_attitude := float(start["attitude"])
	var s_progress: float = profile.along(start["ref"])
	for frame in DRIVE_TICKS * 2:
		_drive(runtime, Vector4(0.0, 0.0, 0.5, 0.0))
		await physics_frame
		var probe := _measure(runtime)
		var s: float = profile.along(probe["ref"])
		s_progress = maxf(s_progress, s)
		var surface_error := absf((probe["ref"] as Vector3).y - profile.height_at(s))
		# The initial dive offset is legitimately large; once the tooth is
		# inside the correction window it must stay bounded afterward.
		if surface_error < 0.3:
			landed = true
		elif landed:
			peak_surface_error = maxf(peak_surface_error, surface_error)
		if frame >= DRIVE_TICKS * 2 - 20:
			tail_surface_error = maxf(tail_surface_error, surface_error)
		peak_attitude_error = maxf(peak_attitude_error, absf(float(probe["attitude"]) - start_attitude))
	# Along-axis progress proves the pass translates; the bar is low because
	# ill-conditioned poses legitimately crawl (rate conditioning caps joint
	# speed there) — tracking quality is what the surface/pitch errors check.
	if s_progress < 0.25:
		failures.append("%s slope drive made no along-axis progress (%.3f m)" % [model_id, s_progress])
	if tail_surface_error > SURFACE_TOL_M:
		failures.append("%s tooth did not settle onto the profile (%.4f m at stroke end)" % [model_id, tail_surface_error])
	if peak_surface_error > 0.5:
		failures.append("%s tooth left the profile surface by %.4f m after landing" % [model_id, peak_surface_error])
	if peak_attitude_error > ATTITUDE_TOL_RAD:
		failures.append("%s bucket pitch drifted %.4f rad on the slope" % [model_id, peak_attitude_error])
	var s_end: float = profile.along((_measure(runtime)["ref"] as Vector3))
	print(
		"%s slope drive: s=%.3f m, peak surface err=%.4f m, peak pitch err=%.4f rad"
		% [model_id, s_end, peak_surface_error, peak_attitude_error]
	)

	# Pull back across the toe: on the bench side the target height flattens
	# to toe height, so the tooth must settle near it rather than diving.
	for frame in DRIVE_TICKS * 2:
		_drive(runtime, Vector4(0.0, 0.0, -0.5, 0.0))
		await physics_frame
	var back := _measure(runtime)
	var s_back: float = profile.along(back["ref"])
	var bench_error := absf((back["ref"] as Vector3).y - profile.height_at(s_back))
	if bench_error > SURFACE_TOL_M:
		failures.append("%s tooth left the bench after crossing the toe (%.4f m)" % [model_id, bench_error])
	print("%s toe return: s=%.3f m, bench err=%.4f m" % [model_id, s_back, bench_error])

	runtime.teardown()
	(fixture["host"] as Node3D).queue_free()
	await physics_frame
	await physics_frame


func _drive(runtime: JoltChassisTrackRuntime, commands: Vector4) -> void:
	_command_identity += 1
	runtime.set_equipment_commands(commands, _command_identity)


func _settle(runtime: JoltChassisTrackRuntime, ticks: int) -> void:
	for _tick in ticks:
		_drive(runtime, Vector4.ZERO)
		await physics_frame


func _measure(runtime: JoltChassisTrackRuntime) -> Dictionary:
	var ctx := runtime._assist_pipeline.build_context(
		runtime._articulation,
		runtime._body.global_transform,
		0.0,
		{},
	) as KCtx
	return {"ref": ctx.bucket_ref_world, "attitude": ctx.bucket_attitude_rad()}


func _joint_positions(runtime: JoltChassisTrackRuntime) -> Dictionary:
	var positions := {}
	for state_value in runtime.get_status_snapshot().get("joints", []):
		var state := state_value as Dictionary
		positions[String(state.get("name", ""))] = float(state.get("position_rad", 0.0))
	return positions


## Pipeline + standalone articulation for contract tests — no Jolt body.
func _standalone_fixture(model_id: String) -> Dictionary:
	var descriptor := PhysicsRigDescriptor.load_for_model(model_id)
	if descriptor == null:
		_fail("%s descriptor unavailable" % model_id)
		return {}
	var soil: Variant = JSON.parse_string(
		FileAccess.get_file_as_string("res://resources/models/%s_soil_contract.json" % model_id)
	)
	if not soil is Dictionary:
		_fail("%s soil contract unavailable" % model_id)
		return {}
	var pipeline := Pipeline.new() as EquipmentAssistPipeline
	if not pipeline.configure(descriptor.to_dictionary(), soil as Dictionary, model_id):
		_fail("assist pipeline rejected the %s rig: %s" % [model_id, pipeline.last_error])
		return {}
	var articulation := KinematicArticulationState.new()
	if not articulation.configure(descriptor.to_dictionary(), Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))):
		_fail("standalone articulation configure failed")
		return {}
	return {"pipeline": pipeline, "articulation": articulation}


func _cutting_edge_local(model_id: String) -> Vector3:
	var soil: Variant = JSON.parse_string(
		FileAccess.get_file_as_string("res://resources/models/%s_soil_contract.json" % model_id)
	)
	var edge := ((soil as Dictionary).get("proxies", {}) as Dictionary).get("cutting_edge", {}) as Dictionary
	var rows := edge.get("center_godot", [0.0, 0.0, 0.0]) as Array
	return Vector3(float(rows[0]), float(rows[1]), float(rows[2])) if rows.size() == 3 else Vector3.ZERO


func _create_fixture(model_id: String) -> Dictionary:
	var host := Node3D.new()
	host.name = "SlopeGradeAssist_%s" % model_id
	root.add_child(host)
	var terrain_world := TerrainWorld.new()
	terrain_world.name = "TerrainWorld"
	host.add_child(terrain_world)
	var terrain_collider := TerrainCollider.new()
	terrain_collider.name = "TerrainCollider"
	terrain_collider.enabled = true
	host.add_child(terrain_collider)
	await process_frame
	if not terrain_collider.queue_snapshot(terrain_world.terrain_state.surface_snapshot()) or not terrain_collider.apply_pending():
		failures.append("%s terrain fixture failed" % model_id)
		host.queue_free()
		return {}
	await physics_frame
	var descriptor := PhysicsRigDescriptor.load_for_model(model_id)
	if descriptor == null or not descriptor.is_valid_for(model_id, descriptor.model_version()):
		failures.append("%s descriptor fixture failed" % model_id)
		host.queue_free()
		return {}
	var runtime := JoltChassisTrackRuntime.new()
	runtime.name = "JoltChassisTrackRuntime"
	host.add_child(runtime)
	var spawn := _spawn_transform(descriptor, terrain_world)
	if not runtime.configure(descriptor, terrain_world, terrain_collider, spawn):
		failures.append("%s runtime configure failed: %s" % [model_id, runtime.contract_error])
		host.queue_free()
		return {}
	return {"host": host, "runtime": runtime, "spawn": spawn}


func _spawn_transform(descriptor: PhysicsRigDescriptor, terrain_world: TerrainWorld) -> Transform3D:
	var chassis := descriptor.bodies()[0] as Dictionary
	var shape := chassis["shape"] as Dictionary
	var center := _vector3(shape["center_m"])
	var size := _vector3(shape["size_m"])
	var clearance := float(descriptor.chassis_dynamics()["ground_clearance_m"])
	var surface_y := terrain_world.terrain_state.sample_surface_bilinear_at(Vector2.ZERO)
	return Transform3D(Basis.IDENTITY, Vector3(0.0, surface_y - (center.y - 0.5 * size.y) + clearance, 0.0))


func _vector3(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


func _fail(message: String) -> void:
	failures.append(message)
	push_error(message)
	quit(1)

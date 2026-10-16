extends SceneTree

var failures: Array[String] = []

class RowSampler extends DtmSurfaceSampler:
	var shoulder := -1.0
	func height_at(p: Vector2) -> float:
		return shoulder if p.x > 0.3 else -1.0

func check_finished_rows() -> void:
	var job := SurfaceJobExecutor.new()
	var measurement := RowSampler.new()
	job.sampler = measurement
	job.station_index = 0
	job.clearance = 1.0
	job.stations = [{"axis": Vector3.BACK, "complete": false, "vertices": [
		{"target": Vector3(0, -1, 0.4), "lane_width": 1.0},
		{"target": Vector3(0, -1, 0.2), "lane_width": 1.0},
		{"target": Vector3(0, -1, 0), "lane_width": 1.0}]}]
	job.verification = PackedVector3Array([Vector3(0.4, -1, 0.4), Vector3(0.4, -1, 0.2), Vector3(0.4, -1, 0)])
	measurement.shoulder = -0.8
	job._begin_vertex(null)
	check(job.state == "approach" and job.vertex_index == 0, "finished center cannot skip residual shoulder")
	measurement.shoulder = NAN
	job._begin_vertex(null)
	check(job.state == "failed" and job.vertex_index == 0, "missing shoulder cannot skip row")
	measurement.shoulder = -0.98
	job._begin_vertex(null)
	check(job.state == "select" and job.skipped_vertices == 3 and job.completed_stations == 1, "long sweep skips all measured finished rows without lowering")
	check(job.stations[0].complete, "finished station advances through ordinary selection")

func _init() -> void:
	call_deferred("run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)

func run() -> void:
	var reference_rig := PhysicsRigDescriptor.load_for_model("sy135")
	var neo_rig := PhysicsRigDescriptor.load_for_model("sy135neo")
	check(reference_rig.is_valid_for("sy135", reference_rig.model_version()), "SY135 reference hash and contract valid")
	check(neo_rig.is_valid_for("sy135neo", neo_rig.model_version()), "NEO shared reference hash and contract valid")
	var reference_data := reference_rig.to_dictionary()
	var neo_data := neo_rig.to_dictionary()
	check(reference_data.bodies == neo_data.bodies and reference_data.joints == neo_data.joints, "NEO bodies and joints match SY135 reference exactly")
	check_finished_rows()
	var parsed := LandXmlSurface.parse(DtmModel.demo_xml("trench", Vector3.ZERO, 1.0))
	var surface: LandXmlSurface = parsed.surfaces[0]
	surface.translation = Vector3(surface.source_origin.e, surface.source_origin.h, surface.source_origin.n)
	var planner := SurfaceJobPlanner
	var plan := planner.build(surface, func(_p: Vector2) -> float: return 0.0, Vector3.ZERO, Vector3.BACK, 1.0, 4.0)
	check(plan.error.is_empty() and plan.stations.size() == 12, "partition full cut into stations")
	var moved := planner.build(surface, func(_p: Vector2) -> float: return 0.0, Vector3(0.12, 0, 0.3), Vector3(0.002, 0, 1).normalized(), 1.0, 4.0)
	check(moved.error.is_empty() and moved.stations.size() == 12, "translation and small yaw preserve design lanes")
	check(plan.verification.size() >= 600, "verify full bucket width")
	var fill := planner.build(surface, func(_p: Vector2) -> float: return -2.0, Vector3.ZERO, Vector3.BACK, 1.0, 4.0)
	check(fill.error.is_empty() and fill.stations.is_empty(), "fill never generates cut")
	check(planner.grade_accepted(-1, -2, -2), "existing fill deficit accepted")
	check(not planner.grade_accepted(-1, -2, -2.2), "additional excavation in fill area rejected")
	check(not planner.grade_accepted(-1, 0, -1.2), "new overcut rejected")
	check(not planner.grade_accepted(-1, 0, -0.8), "remaining cut rejected")
	var mixed := planner.build(surface, func(p: Vector2) -> float: return -2.0 if p.y < 0 else 0.0, Vector3.ZERO, Vector3.BACK, 1.0, 4.0)
	check(mixed.error.is_empty() and mixed.stations.size() == 6 and mixed.initial_heights.size() == mixed.verification.size(), "mixed cut/fill preserves baseline")
	var unknown := planner.build(surface, func(p: Vector2) -> float: return NAN if p.x > 0.3 else 0.0, Vector3.ZERO, Vector3.BACK, 1.0, 4.0)
	check(not unknown.error.is_empty(), "unknown shoulder rejects plan")
	var stations := [{"position": Vector3(3,0,0), "complete": false}, {"position": Vector3(1,0,0), "complete": false}]
	check(planner.nearest(stations, Vector3.ZERO) == 1, "nearest greedy point")
	stations[1].complete = true
	check(planner.nearest(stations, Vector3.ZERO) == 0, "skip completed station")
	var driver := WaypointDriver.new()
	var physics := {"configured": true, "body_transform": Transform3D.IDENTITY, "linear_velocity": Vector3.ZERO,
		"angular_velocity": Vector3.ZERO, "vehicle_forward_world": Vector3.FORWARD,
		"authority_epoch": "test", "physics_tick": 1, "grounded": true, "locomotion_mode": "tracked"}
	check(driver.start(PackedVector3Array([Vector3.BACK]), physics, {"reverse": true}), "start reverse")
	var command := Vector3.ZERO
	for i in 60:
		physics.physics_tick += 1
		command = driver.step(1.0 / 60, physics)
	check(command.x < 0 and command.y < 0 and absf(command.x - command.y) < 0.0001, "reverse without pivot")
	driver.pause("menu")
	check(driver.step(1.0 / 60, physics) == Vector3.ZERO, "paused reverse neutral")
	var job := SurfaceJobExecutor.new()
	var empty_payload := {"bucket_capacity_m3": 0.6, "bucket_volume_m3": 0.0}
	var loaded_payload := {"bucket_capacity_m3": 0.6, "bucket_volume_m3": 0.3}
	check(job.capacity_distance(empty_payload, 1.0, 0.3) > job.capacity_distance(loaded_payload, 1.0, 0.3), "remaining capacity reduces cut distance")
	check(job.capacity_distance(empty_payload, 1.0, 0.6) < job.capacity_distance(empty_payload, 1.0, 0.3), "deeper bite shortens capacity distance")
	for direction in [-1.0, 1.0]:
		var ctx := EquipmentKinematicsContext.new()
		ctx.delta = 1.0 / 60.0
		ctx.joint_positions = {"swing_joint": 0.0}
		ctx.joint_velocities = {"swing_joint": 0.0}
		ctx.joint_accelerations = {"swing_joint": 0.0}
		ctx.joint_accel_limits = {"swing_joint": Vector2(0.9, 3.6)}
		ctx.joint_ceiling = {"swing_joint": 1.0}
		var target: float = direction * PI / 2.0
		var overshoot := 0.0
		for tick in 1200:
			var cmd := job._joint_command(ctx, "swing_joint", target)
			var velocity := ctx.velocity_for_command("swing_joint", cmd)
			ctx.joint_accelerations.swing_joint = move_toward(float(ctx.joint_accelerations.swing_joint), clampf((cmd * ctx.effective_ceiling("swing_joint", cmd) - float(ctx.joint_velocities.swing_joint)) / ctx.delta, -0.9, 0.9), 3.6 * ctx.delta)
			ctx.joint_velocities.swing_joint = velocity
			ctx.joint_positions.swing_joint += velocity * ctx.delta
			overshoot = maxf(overshoot, direction * (float(ctx.joint_positions.swing_joint) - target))
		check(overshoot < deg_to_rad(0.1) and job._joint_reached(ctx, "swing_joint", target), "slew settles without overshoot in both directions")
	job.state = "cut"
	job.pause("focus")
	check(job.state == "paused" and not job.active(), "job pause latched")
	check(job.resume() and job.state == "cut", "explicit job resume")
	job.cancel("manual")
	check(not job.active() and not job.resume(), "cancel cannot resume")
	var chassis := TrackedChassisController.new()
	chassis.surface_job.state = "cut"
	chassis.set_product_session_state(true, false)
	check(chassis.surface_job.state == "cut", "focus loss preserves automatic work")
	chassis._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	check(chassis.surface_job.state == "cut", "application focus notification preserves automatic work")
	chassis.set_product_session_state(false, false)
	check(chassis.surface_job.state == "paused", "explicit session pause still pauses automatic work")
	chassis.surface_job.state = "cut"
	chassis.set_race_mode(true)
	check(chassis.surface_job.state == "cancelled", "race cancels active job")
	chassis.surface_job.state = "paused"
	chassis.controller_enabled = true
	check(not chassis.resume_surface_job(), "race blocks job resume")
	chassis.free()
	for failure in failures:
		push_error(failure)
	print("SURFACE_JOB_CONTRACT ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

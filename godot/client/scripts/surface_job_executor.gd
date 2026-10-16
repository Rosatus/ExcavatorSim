class_name SurfaceJobExecutor
extends RefCounted

const Planner := preload("res://scripts/surface_job_planner.gd")
const Solver := preload("res://scripts/assist_rate_solver.gd")
const JOINTS := ["boom_joint", "arm_joint", "bucket_joint"]
var state := "idle"
var reason := ""
var stations: Array = []
var station_index := -1
var vertex_index := 0
var completed_stations := 0
var sampler: DtmSurfaceSampler
var target_surface: LandXmlSurface
var clearance := 0.0
var goal := Vector3.ZERO
var _epoch := ""
var _tick := -1
var _elapsed := 0.0
var _settled := 0.0
var _resume_state := ""
var _identity := ""
var _pass := 0
var _recut := false
var _finish_offset := 0.0
var cutting_tool := BucketSoilTool.new()
var cutting_envelope := VoxelBucketCutter.new()
var envelope_debug := {}
var _envelope_points: Array[Vector3] = []
var verification := PackedVector3Array()
var initial_heights := PackedFloat32Array()
var verification_result := {}
var drive_command := Vector2.ZERO
var _stale := 0.0
var _zone_generation := -1
var _heading := Vector3.ZERO
var simple_mode := false
var dump_right := true
var soil_payload := Callable()
var soil_visual := Callable()
var dump_cycles := 0
var _swing_home := 0.0
var _carry_bucket := 0.0
var _after_dump := "approach"
var _pre_dump_goal := Vector3.ZERO
var _dump_release_id := ""

func _joint_command(ctx: EquipmentKinematicsContext, joint: String, target: float) -> float:
	var error := target - float(ctx.joint_positions.get(joint, 0.0))
	return ctx.command_for_velocity(joint, clampf(error * 2.0, -0.6, 0.6))

func _joint_reached(ctx: EquipmentKinematicsContext, joint: String, target: float) -> bool:
	return absf(target - float(ctx.joint_positions.get(joint, 0.0))) < 0.001 and absf(float(ctx.joint_velocities.get(joint, 0.0))) < 0.003

func _begin_dump(ctx: EquipmentKinematicsContext, next: String) -> void:
	_after_dump = next
	_pre_dump_goal = goal
	_carry_bucket = float(ctx.joint_positions.bucket_joint)
	goal = ctx.bucket_ref_world
	goal.y = clearance + 0.5
	transition("dump_lift")

func configure_tool(contract: Dictionary, zone: VoxelWorkZone) -> bool:
	return cutting_tool.configure(contract) and cutting_envelope.configure(contract, zone.voxel_scale_m, zone.layout)

## Use the exact cutter brush geometry, including its voxel-radius dilation.
## This is a read-only envelope query; only the ordinary soil authority cuts.
func _cut_contact(ctx: EquipmentKinematicsContext) -> Vector3:
	var pose := cutting_tool.compose_snapshot(ctx.bucket_link, ctx.bucket_link, true, "envelope")
	var paths := cutting_envelope._build_sy135_native_paths(pose)
	var lowest := ctx.bucket_ref_world
	envelope_debug = {}
	_envelope_points.clear()
	for path in paths:
		var points: PackedVector3Array = path.points_voxels
		var radii: PackedFloat32Array = path.radii_voxels
		var path_low := INF
		for i in points.size():
			var p: Vector3 = cutting_envelope.layout.voxel_to_world(points[i], cutting_envelope.voxel_scale_m)
			p.y -= radii[i] * cutting_envelope.voxel_scale_m
			_envelope_points.append(p)
			path_low = minf(path_low, p.y)
			if p.y < lowest.y:
				lowest = p
		envelope_debug[path.path_id] = path_low
	envelope_debug["point"] = lowest
	return lowest

func active() -> bool:
	return state in ["select", "lift", "navigate", "orient", "approach", "cut", "sweep", "verify", "finish_lift", "dump_lift", "dump_swing", "dump_open", "dump_close", "dump_return"]

func start(plan: Dictionary, surface: LandXmlSurface, measurement: DtmSurfaceSampler,
		snapshot: Dictionary, ctx: EquipmentKinematicsContext, identity: String) -> bool:
	if ctx == null or not String(plan.get("error", "")).is_empty():
		reason = String(plan.get("error", "运动学不可用"))
		return false
	stations = plan.stations.duplicate(true)
	verification = plan.get("verification", PackedVector3Array()).duplicate()
	initial_heights = plan.get("initial_heights", PackedFloat32Array()).duplicate()
	verification_result = {}
	target_surface = surface
	sampler = measurement
	_zone_generation = sampler.zone.readiness.generation
	_heading = snapshot.vehicle_forward_world
	_swing_home = float(ctx.joint_positions.get("swing_joint", 0.0))
	dump_cycles = 0
	_stale = 0
	_recut = false
	_finish_offset = 0.0
	drive_command = Vector2.ZERO
	_epoch = String(snapshot.get("authority_epoch", ""))
	_identity = identity
	_tick = -1
	completed_stations = 0
	station_index = -1
	clearance = ctx.bucket_ref_world.y
	for station in stations:
		for vertex in station.vertices:
			clearance = maxf(clearance, float(vertex.initial_height) + 0.65)
	reason = ""
	transition("select")
	return true

func transition(next: String) -> void:
	state = next
	_elapsed = 0
	_settled = 0

func cancel(why := "operator_cancelled") -> void:
	drive_command = Vector2.ZERO
	state = "cancelled"
	reason = why

func fail(why: String) -> void:
	drive_command = Vector2.ZERO
	state = "failed"
	reason = why

func pause(why: String) -> void:
	drive_command = Vector2.ZERO
	if active():
		_resume_state = state
		state = "paused"
		reason = why

func resume() -> bool:
	if state != "paused":
		return false
	transition(_resume_state)
	reason = ""
	return true

func snapshot() -> Dictionary:
	return {"state": state, "reason": reason, "station": station_index,
		"count": stations.size(), "completed": completed_stations, "vertex": vertex_index,
		"verification": verification_result, "dump_cycles": dump_cycles, "simple_mode": simple_mode}

func verify_surface() -> bool:
	if verification.is_empty() or initial_heights.size() != verification.size():
		fail("复测计划不完整")
		return false
	var points := PackedVector2Array()
	for p in verification:
		points.append(Vector2(p.x, p.z))
	var heights := sampler.heights_at(points)
	var low := INF
	var high := -INF
	var accepted := true
	for i in heights.size():
		if not is_finite(heights[i]):
			fail("最终复测缺失")
			return false
		var error := heights[i] - verification[i].y
		accepted = accepted and Planner.grade_accepted(verification[i].y, initial_heights[i], heights[i])
		low = minf(low, error)
		high = maxf(high, error)
	verification_result = {"samples": heights.size(), "minimum_error_m": low, "maximum_error_m": high}
	if not accepted:
		fail("整面复测未达标：%+.3f ～ %+.3f m" % [low, high])
		return false
	return true

## Returns logical joint commands; the host owns drive/equipment arbitration.
func step(delta: float, physics: Dictionary, ctx: EquipmentKinematicsContext,
		identity: String, navigation: WaypointDriver) -> Vector4:
	if not active():
		return Vector4.ZERO
	drive_command = Vector2.ZERO
	if ctx == null or String(physics.get("authority_epoch", "")) != _epoch or identity != _identity:
		fail("设备或世界已改变")
		return Vector4.ZERO
	if not is_instance_valid(sampler.zone) or sampler.zone.readiness.generation != _zone_generation:
		fail("地形已重置")
		return Vector4.ZERO
	_elapsed += delta
	if _elapsed > 60:
		fail("作业阶段无进展：" + state)
		return Vector4.ZERO
	var tick := int(physics.get("physics_tick", -1))
	if tick <= _tick:
		_stale += delta
		if _stale > 0.25:
			fail("物理状态过期")
		return Vector4.ZERO
	_stale = 0
	_tick = tick
	var payload: Dictionary = soil_payload.call() if soil_payload.is_valid() else {}
	if not simple_mode and state in ["cut", "sweep", "verify"] and float(payload.get("fill_ratio", 0.0)) >= 0.65:
		_begin_dump(ctx, "approach")
	if state == "dump_lift" and reached(ctx, delta):
		transition("dump_swing")
	if state in ["dump_swing", "dump_return"]:
		var target := _swing_home + (-PI / 2.0 if dump_right else PI / 2.0) if state == "dump_swing" else _swing_home
		if _joint_reached(ctx, "swing_joint", target):
			if state == "dump_swing":
				transition("dump_open")
			else:
				dump_cycles += 1
				if _after_dump == "approach":
					_begin_vertex(ctx)
				elif _after_dump == "verify":
					goal = _pre_dump_goal
					transition("verify")
				else:
					goal = ctx.bucket_ref_world
					goal.y = clearance
					transition(_after_dump)
			return Vector4.ZERO
		return Vector4(_joint_command(ctx, "swing_joint", target), 0, 0, 0)
	if state == "dump_open":
		var visual: Dictionary = soil_visual.call() if soil_visual.is_valid() else {}
		var event_id := String(visual.get("accepted_dump_event_id", ""))
		if not event_id.is_empty() and event_id != _dump_release_id:
			_dump_release_id = event_id
		# Off-zone exports drain the authoritative bucket without a terrain
		# deposit event. Actual remaining payload also covers that valid unload.
		if _elapsed > 0.5 and float(payload.get("bucket_volume_m3", INF)) < 0.003:
			transition("dump_close")
			return Vector4.ZERO
		var gate := float(visual.get("opening_down_dot", -1.0)) >= float(visual.get("effective_dump_threshold", 0.5)) + 0.1
		return Vector4(0, 0, 0, 0 if gate else 0.65)
	if state == "dump_close":
		if _joint_reached(ctx, "bucket_joint", _carry_bucket):
			transition("dump_return")
		return Vector4(0, 0, 0, _joint_command(ctx, "bucket_joint", _carry_bucket))
	if state == "select":
		var next := Planner.nearest(stations, ctx.chassis_transform.origin)
		if next < 0:
			if station_index < 0:
				transition("completed")
				return Vector4.ZERO
			goal = ctx.bucket_ref_world
			goal.y = clearance
			transition("finish_lift")
		else:
			station_index = next
	if state == "select":
		vertex_index = 0
		_pass = 0
		goal = ctx.bucket_ref_world
		goal.y = clearance
		transition("lift")
	if state == "finish_lift" and reached(ctx, delta):
		if not simple_mode and float(payload.get("bucket_volume_m3", 0.0)) >= 0.003:
			_begin_dump(ctx, "finish_lift")
			return Vector4.ZERO
		if verify_surface():
			transition("completed")
		return Vector4.ZERO
	if state == "lift":
		if reached(ctx, delta):
			var position: Vector3 = stations[station_index].position
			var offset := position - ctx.chassis_transform.origin
			offset.y = 0
			if offset.length() < 0.05:
				transition("orient")
			else:
				var reverse := offset.dot(physics.vehicle_forward_world) < 0
				if not navigation.start(PackedVector3Array([position]), physics, {"reverse": reverse}):
					fail("转场路线不可用")
				else:
					transition("navigate")
			return Vector4.ZERO
	if state == "navigate":
		if navigation.state == "completed":
			transition("orient")
		elif navigation.state in ["failed", "cancelled"]:
			fail("转场失败：" + navigation.reason)
		return Vector4.ZERO
	if state == "orient":
		var forward: Vector3 = physics.vehicle_forward_world
		var f := Vector2(forward.x, forward.z).normalized()
		var right := Vector2(-f.y, f.x)
		var work_point: Vector3 = stations[station_index].vertices[0].target
		var direction := work_point - ctx.chassis_transform.origin
		var desired := Vector2(direction.x, direction.z).normalized()
		var error := atan2(right.dot(desired), f.dot(desired))
		var velocity: Vector3 = physics.linear_velocity
		var yaw := -Vector3(physics.angular_velocity).y
		if Vector2(velocity.x, velocity.z).length() > 0.025:
			return Vector4.ZERO
		if absf(error) < deg_to_rad(0.1) and absf(yaw) < 0.005:
			_settled += delta
			if _settled > 0.3:
				_begin_vertex(ctx)
		else:
			_settled = 0
			var turn := clampf((1.8 * error - 0.6 * yaw) / 3.1, -0.2, 0.2)
			drive_command = Vector2(turn, -turn)
		return Vector4.ZERO
	if state == "approach":
		if reached(ctx, delta):
			var point: Vector3 = stations[station_index].vertices[vertex_index].target
			var actual := sampler.height_at(Vector2(point.x, point.z))
			if not is_finite(actual):
				fail("切削点实测缺失")
				return Vector4.ZERO
			goal = point
			goal += stations[station_index].axis * _finish_offset
			# Simple digging has no bucket-capacity cycle: descend directly to
			# design grade. Normal digging takes a substantial bite, then unloads.
			goal.y = point.y - Planner.TOLERANCE * 0.5 if _recut else (point.y if simple_mode else maxf(point.y, actual - 0.6))
			_recut = false
			transition("cut")
	if state == "cut" and reached(ctx, delta):
		transition("sweep")
	if state == "sweep" and _elapsed >= 1.0 and absf((_cut_contact(ctx) - goal).y) < 0.005:
		if not simple_mode and float(payload.get("bucket_volume_m3", 0.0)) >= 0.003:
			_begin_dump(ctx, "verify")
			return Vector4.ZERO
		transition("verify")
		return Vector4.ZERO
	if state == "verify":
		if _elapsed < 0.3:
			return Vector4.ZERO
		var point: Vector3 = stations[station_index].vertices[vertex_index].target
		var actual := sampler.height_at(Vector2(point.x, point.z))
		# Certify the entire planned row before advancing; a center sample can
		# miss shoulders after a loaded bucket has returned from unloading.
		var row_axis: Vector3 = stations[station_index].axis
		var half_width := float(stations[station_index].vertices[vertex_index].get("lane_width", 1.0)) * 0.5
		for sample in verification:
			if absf((sample - point).dot(row_axis)) < 0.01 and absf((sample - point).dot(Vector3(-row_axis.z, 0, row_axis.x))) < half_width:
				var measured := sampler.height_at(Vector2(sample.x, sample.z))
				if not is_finite(measured):
					actual = NAN
					break
				actual = maxf(actual, measured)
		if not is_finite(actual):
			fail("复测缺失")
		elif actual <= point.y + Planner.TOLERANCE:
			vertex_index += 1
			_pass = 0
			_finish_offset = 0.0
			if vertex_index == stations[station_index].vertices.size():
				stations[station_index].complete = true
				completed_stations += 1
				transition("select")
			else:
				_begin_vertex(ctx)
		else:
			_pass += 1
			if _pass > 25:
				fail("切削未达到设计面")
			else:
				var next_height := point.y - Planner.TOLERANCE * 0.5 if simple_mode else minf(goal.y - 0.08, actual - 0.6)
				if goal.y <= point.y - Planner.TOLERANCE * 0.49:
					# Re-enter from clear air when the cutter has lost engagement;
					# oscillating inside its own cleared cavity cannot admit a cut.
					_recut = true
					# Change the entry footprint instead of repeating an identical
					# sweep inside an already cleared cavity. Grade stays bounded.
					_finish_offset = 0.12 if _pass % 2 == 0 else -0.12
					_begin_vertex(ctx)
					return Vector4.ZERO
				goal = point
				goal += stations[station_index].axis * _finish_offset
				# SDF interpolation and brush admission need a measured finish
				# correction. Bound it inside half the accepted grade tolerance.
				goal.y = maxf(point.y - Planner.TOLERANCE * 0.5, next_height)
				if not simple_mode:
					# Re-enter after unloading instead of traversing to the next
					# bite directly from the raised transport pose.
					_begin_vertex(ctx)
				else:
					transition("cut")
		return Vector4.ZERO
	if state not in ["lift", "approach", "cut", "sweep", "finish_lift", "dump_lift"]:
		return Vector4.ZERO
	var offset := goal - ctx.bucket_ref_world
	var axis: Vector3 = stations[station_index].axis
	if absf(offset.dot(Vector3(-axis.z, 0, axis.x))) > 0.12:
		fail("目标超出当前作业平面")
		return Vector4.ZERO
	var contact := _cut_contact(ctx) if state in ["cut", "sweep"] else ctx.bucket_ref_world
	if state in ["cut", "sweep"]:
		offset = goal - contact
	var columns := ctx.rate_columns(contact, JOINTS)
	var tooth_columns := ctx.rate_columns(ctx.bucket_ref_world, JOINTS)
	var normal := Vector3.ZERO
	var tangent := Vector3.ZERO
	for i in 3:
		normal[i] = Vector3(columns[JOINTS[i]]).y
		tangent[i] = Vector3(tooth_columns[JOINTS[i]]).dot(axis)
	var transport := ctx.chassis_point_velocity(ctx.bucket_ref_world) + ctx.tool_point_velocity
	var cutting := state in ["cut", "sweep"]
	# Enter outboard, then pull the teeth towards the machine as depth grows.
	# The complete brush envelope still limits vertical depth; a switching
	# lowest brush must not drag the axial control reference around the bucket.
	var axial_goal := goal
	if state == "cut":
		axial_goal += axis * 0.45 * clampf((contact.y - goal.y) / maxf(clearance - goal.y, 0.1), 0.0, 1.0)
	var axial_error := (axial_goal - ctx.bucket_ref_world).dot(axis)
	var solved := Solver.solve_surface(normal, tangent,
		clampf(offset.y * 2.0, -0.3 if cutting else -0.65, 0.65) - transport.y,
		(-0.18 if state == "sweep" else clampf(axial_error * 2.0, -0.65, 0.65)) - transport.dot(axis), 0.04, ctx, JOINTS,
		ctx.tooth_contact_preference(_envelope_points, Vector3.UP) if cutting else Vector3.ZERO)
	var command: Vector3 = solved.commands
	return Vector4(0, command.x, command.y, command.z)

func reached(ctx: EquipmentKinematicsContext, delta: float) -> bool:
	var error := ctx.bucket_ref_world - goal
	if state == "cut":
		var contact_error := _cut_contact(ctx) - goal
		var axis: Vector3 = stations[station_index].axis
		if absf(contact_error.y) < 0.005 and absf(error.dot(axis)) < 0.015:
			_settled += delta
		else:
			_settled = 0
		return _settled > 0.2
	if error.length() < 0.035:
		_settled += delta
	else:
		_settled = 0
	return _settled > 0.2

func _begin_vertex(_ctx: EquipmentKinematicsContext) -> void:
	goal = stations[station_index].vertices[vertex_index].target
	goal += stations[station_index].axis * _finish_offset
	goal += stations[station_index].axis * 0.45
	goal.y = clearance
	transition("approach")

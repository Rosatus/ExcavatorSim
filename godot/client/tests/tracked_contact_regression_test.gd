extends SceneTree
## Actual Jolt obstacle/edge regressions. Penetration checks use known fixture
## geometry, not the support solver's reported (previously always zero) depth.

var failures: Array[String] = []
var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("_run")

func _box(parent: Node3D, label: String, pos: Vector3, size: Vector3, angle := 0.0) -> void:
	var body := StaticBody3D.new()
	body.name = label
	body.collision_layer = 1
	body.collision_mask = 0
	parent.add_child(body)
	body.position = pos
	body.rotation.x = angle
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)

func _run() -> void:
	var cases := ["flat", "wall", "step", "narrow", "crest", "ditch", "pivot"]
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		cases = Array(args)
	for scenario in cases:
		await _scenario(scenario)
	print("TRACK_CONTACT_RESULTS ", JSON.stringify(results))
	for failure in failures:
		push_error(failure)
	print("tracked_contact_regression_test: %s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)

func _scenario(scenario: String) -> void:
	var host := Node3D.new()
	root.add_child(host)
	var map := Node3D.new()
	host.add_child(map)
	if scenario == "ditch":
		_box(map, "NearBank", Vector3(0,-0.5,8.0), Vector3(30,1,20))
		_box(map, "FarBank", Vector3(0,-0.5,-13.0), Vector3(30,1,20))
		_box(map, "DitchFloor", Vector3(0,-0.85,-2.5), Vector3(30,1,1))
	else:
		_box(map, "Ground", Vector3(0,-0.5,0), Vector3(30,1,30))
	if scenario == "wall":
		_box(map, "Wall", Vector3(0,1.5,-3), Vector3(10,3,0.2))
	elif scenario == "step":
		_box(map, "LeftStep", Vector3(-0.98,0.15,-3), Vector3(1.3,0.3,2))
	elif scenario == "narrow":
		_box(map, "NarrowRidge", Vector3(0,0.1,-3), Vector3(6,0.2,0.2))
	elif scenario == "crest":
		_box(map, "Uphill", Vector3(0,0.04,-3), Vector3(10,0.2,4), -0.15)
		_box(map, "Downhill", Vector3(0,0.04,-7), Vector3(10,0.2,4), 0.15)
	var runtime := JoltChassisTrackRuntime.new()
	host.add_child(runtime)
	await physics_frame
	var descriptor := PhysicsRigDescriptor.load_for_model("sy135")
	if not runtime.configure(descriptor, null, null, Transform3D(Basis.IDENTITY,Vector3(0,0.13,0)), map):
		failures.append("%s configure: %s" % [scenario,runtime.contract_error])
		host.queue_free()
		return
	runtime.set_commands(0,0)
	for i in 150:
		await physics_frame
	var start := runtime.get_body_global_transform()
	runtime.set_commands(1,-1 if scenario == "pivot" else 1)
	var max_vy := 0.0
	var max_tilt := 0.0
	var min_y := INF
	var max_y := -INF
	var guard_ticks := 0
	var disabled_ticks := 0
	var max_wall_penetration := 0.0
	for i in 420:
		await physics_frame
		var state := runtime.get_status_snapshot()
		var transform := runtime.get_body_global_transform()
		var velocity: Vector3 = state["linear_velocity"]
		var angular: Vector3 = state["angular_velocity"]
		max_vy = maxf(max_vy,absf(velocity.y))
		max_tilt = maxf(max_tilt,Vector2(angular.x,angular.z).length())
		min_y = minf(min_y,transform.origin.y)
		max_y = maxf(max_y,transform.origin.y)
		if runtime._body.collision_mask == 0:
			disabled_ticks += 1
		for flag in state["quality_flags"]:
			if String(flag).ends_with("clamped") or String(flag).begins_with("invalid_"):
				guard_ticks += 1
		if scenario == "wall":
			# Both imported SY135 track ends extend to local z=+-1.82085.
			for x in [-1.20, 1.20]:
				var front := transform * Vector3(x,0.45,-1.80)
				max_wall_penetration = maxf(max_wall_penetration,-2.90-front.z)
	runtime.set_commands(0,0)
	var heave_sq := 0.0
	var tilt_sq := 0.0
	var settle_low := INF
	var settle_high := -INF
	for i in 180:
		await physics_frame
		if i < 120:
			continue
		var state := runtime.get_status_snapshot()
		var velocity: Vector3 = state["linear_velocity"]
		var angular: Vector3 = state["angular_velocity"]
		heave_sq += velocity.y*velocity.y
		tilt_sq += angular.x*angular.x+angular.z*angular.z
		settle_low = minf(settle_low,runtime._body.global_position.y)
		settle_high = maxf(settle_high,runtime._body.global_position.y)
	var finish := runtime.get_body_global_transform()
	var row := {"case":scenario,"z":finish.origin.z,"travel":start.origin.distance_to(finish.origin),"max_vy":max_vy,"max_tilt":max_tilt,"min_y":min_y,"max_y":max_y,"settle_heave_rms":sqrt(heave_sq/60),"settle_tilt_rms":sqrt(tilt_sq/60),"settle_span":settle_high-settle_low,"guard_ticks":guard_ticks,"disabled_ticks":disabled_ticks,"wall_penetration":max_wall_penetration}
	results.append(row)
	print("TRACK_CASE ",JSON.stringify(row))
	if disabled_ticks > 0:
		failures.append("%s lost physical obstacle protection for %d ticks" % [scenario,disabled_ticks])
	if max_wall_penetration > 0.02:
		failures.append("wall penetrated by %.3fm" % max_wall_penetration)
	if guard_ticks > 0:
		failures.append("%s required velocity/invalid-state emergency guard" % scenario)
	if min_y < -0.4 or max_vy > 1.0 or max_tilt > 0.8:
		failures.append("%s uncontrolled edge response: %s" % [scenario,row])
	if float(row["settle_heave_rms"]) > 0.01 or float(row["settle_tilt_rms"]) > 0.02 or float(row["settle_span"]) > 0.01:
		failures.append("%s did not settle after releasing travel" % scenario)
	if scenario == "flat" and finish.origin.z > -5.0:
		failures.append("flat travel regressed")
	runtime.teardown()
	host.queue_free()
	await process_frame

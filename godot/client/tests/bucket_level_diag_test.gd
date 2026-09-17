extends SceneTree

## Temporary diagnostic for the reported sudden height/attitude jump near
## joint limits. Drives the arm channel to both extremes under assist and
## logs the per-tick signals that could produce a discontinuity: attitude
## measurement basis flips (horizontal), infeasible flags, uniform scale,
## joint positions, and the resulting measured pose.

const KCtx = preload("res://scripts/equipment_kinematics_context.gd")

var _command_identity := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	for model_id in ["sy135", "sy205"]:
		await _probe(model_id)
	print("diag done")
	quit(0)


func _probe(model_id: String) -> void:
	var fixture := await _create_fixture(model_id)
	if fixture.is_empty():
		print("%s: fixture failed" % model_id)
		return
	var runtime := fixture["runtime"] as JoltChassisTrackRuntime
	var spawn := fixture["spawn"] as Transform3D
	if not runtime.set_equipment_assist_enabled("bucket_level", true):
		print("%s: assist rejected" % model_id)
		runtime.teardown()
		return
	_command_identity = 0

	for direction in [-1.0, 1.0]:
		runtime.reset(spawn)
		await _settle(runtime, 60)
		var prev := _measure(runtime)
		var prev_horizontal := prev["horizontal"] as Vector3
		print("%s drive dir=%+.1f start h=%.4f att=%.4f" % [model_id, direction, (prev["ref"] as Vector3).y, prev["attitude"]])
		var last_flags := ""
		for frame in 400:
			_drive(runtime, Vector4(0.0, 0.0, 0.8 * direction, 0.0))
			await physics_frame
			var cur := _measure(runtime)
			var stage := runtime._assist_pipeline.get_stage("bucket_level")
			var snap := stage.get_status_snapshot()
			var dh := absf((cur["ref"] as Vector3).y - (prev["ref"] as Vector3).y)
			var da := absf(float(cur["attitude"]) - float(prev["attitude"]))
			var h_flip := (cur["horizontal"] as Vector3).dot(prev_horizontal) < 0.0
			var flag_str := str(snap.get("flags", []))
			var flags_new := flag_str != last_flags
			last_flags = flag_str
			if dh > 0.003 or da > 0.003 or h_flip or flags_new:
				var jp := _joint_positions(runtime)
				var jv := _joint_velocities(runtime)
				print(
					"  f%d dh=%.4f da=%.4f hflip=%s scale=%.3f flags=%s herr=%.4f aerr=%.4f j=(%.3f,%.3f,%.3f) v=(%.4f,%.4f,%.4f) out=%.3f att=%.4f href=%.4f aref=%.4f blk=%s r=(%.3f,%.3f,%.3f) lo=(%.3f,%.3f,%.3f) hi=(%.3f,%.3f,%.3f)" % [
						frame, dh, da, h_flip,
						float(snap.get("feasible_scale", 0.0)),
						flag_str,
						float(snap.get("height_error_m", 0.0)),
						float(snap.get("attitude_error_rad", 0.0)),
						float(jp.get("boom_joint", 0.0)),
						float(jp.get("arm_joint", 0.0)),
						float(jp.get("bucket_joint", 0.0)),
						float(jv.get("boom_joint", 0.0)),
						float(jv.get("arm_joint", 0.0)),
						float(jv.get("bucket_joint", 0.0)),
						float((cur["outward"] as Vector3).length()),
						float(cur["attitude"]),
						float(snap.get("height_ref_m", 0.0)),
						float(snap.get("attitude_ref_rad", 0.0)),
						String(stage._debug_blocked),
						stage._debug_rates.x, stage._debug_rates.y, stage._debug_rates.z,
						stage._debug_lo.x, stage._debug_lo.y, stage._debug_lo.z,
						stage._debug_hi.x, stage._debug_hi.y, stage._debug_hi.z,
					]
				)
			prev = cur
			prev_horizontal = cur["horizontal"] as Vector3
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
		1.0 / 60.0,
		{},
		runtime._body.linear_velocity,
		runtime._body.angular_velocity,
	) as KCtx
	var outward := ctx.bucket_ref_world - Vector3(
		ctx.joint_pivot_world.get("swing_joint", ctx.chassis_transform.origin)
	)
	outward.y = 0.0
	return {
		"ref": ctx.bucket_ref_world,
		"attitude": ctx.bucket_attitude_rad(),
		"horizontal": ctx.horizontal,
		"outward": outward,
	}


func _joint_positions(runtime: JoltChassisTrackRuntime) -> Dictionary:
	var positions := {}
	for state_value in runtime.get_status_snapshot().get("joints", []):
		var state := state_value as Dictionary
		positions[String(state.get("name", ""))] = float(state.get("position_rad", 0.0))
	return positions


func _joint_velocities(runtime: JoltChassisTrackRuntime) -> Dictionary:
	var velocities := {}
	for state_value in runtime.get_status_snapshot().get("joints", []):
		var state := state_value as Dictionary
		velocities[String(state.get("name", ""))] = float(state.get("velocity_rad_s", 0.0))
	return velocities


func _create_fixture(model_id: String) -> Dictionary:
	var host := Node3D.new()
	host.name = "Diag_%s" % model_id
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
		host.queue_free()
		return {}
	await physics_frame
	var descriptor := PhysicsRigDescriptor.load_for_model(model_id)
	if descriptor == null:
		host.queue_free()
		return {}
	var runtime := JoltChassisTrackRuntime.new()
	runtime.name = "JoltChassisTrackRuntime"
	host.add_child(runtime)
	var spawn := _spawn_transform(descriptor, terrain_world)
	if not runtime.configure(descriptor, terrain_world, terrain_collider, spawn):
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

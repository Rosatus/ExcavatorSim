extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")

const MAX_READY_FRAMES := 1200


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures: Array[String] = []
	var scene := MAIN_SCENE.instantiate()
	var excavation := scene.get_node("TerrainRoot/ExcavationWorld") as ExcavationWorld
	excavation.soil_material_lifecycle_mode = "voxel"
	excavation.soil_surface_solver_mode = "voxel_bucket_v1"
	excavation.voxel_unlimited_bucket_for_testing = true
	root.add_child(scene)
	for _frame in MAX_READY_FRAMES:
		var status := excavation.get_status_snapshot()
		var voxel := status.get("voxel_excavation", {}) as Dictionary
		if String(status.get("soil_material_lifecycle_mode", "")) == "voxel" and bool(voxel.get("configured", false)):
			break
		await physics_frame
	var selected := excavation.get_status_snapshot()
	_expect(String(selected.get("soil_material_lifecycle_mode", "")) == "voxel", "voxel mode owns the generation", failures)
	_expect(String(selected.get("soil_surface_solver_mode", "")) == "voxel_bucket_v1", "voxel solver identity is selected", failures)
	_expect(String((selected.get("soil_authority_selection", {}) as Dictionary).get("product_owner", "")) == "voxel", "mode controller exposes voxel as sole owner", failures)
	_expect(not bool(selected.get("legacy_runtime_constructed", true)), "legacy terrain and bucket runtime stay unconstructed", failures)
	_expect(not bool(selected.get("parcel_runtime_constructed", true)), "legacy parcel runtime stays unconstructed", failures)
	_expect(String((selected.get("selected_soil_payload", {}) as Dictionary).get("source", "")) == "voxel_bucket_v1", "selected payload comes from voxel ledger", failures)
	var voxel_status := selected.get("voxel_excavation", {}) as Dictionary
	_expect(bool(voxel_status.get("bucket_capacity_overridden", false)), "world enables the dedicated test bucket mode", failures)
	_expect(is_equal_approx(float(voxel_status.get("bucket_capacity_m3", 0.0)), ExcavationWorld.TEST_BUCKET_CAPACITY_M3), "world applies the large finite test capacity", failures)
	_expect(float(voxel_status.get("contract_bucket_capacity_m3", 0.0)) < float(voxel_status.get("bucket_capacity_m3", 0.0)), "test capacity preserves the smaller model contract capacity", failures)
	var zone := scene.get_node("TerrainRoot/VoxelWorkZone") as VoxelWorkZone
	for _frame in MAX_READY_FRAMES:
		if zone.readiness.is_ready(zone.initial_ticket):
			break
		await physics_frame
	_expect(zone.readiness.is_ready(zone.initial_ticket), "voxel terrain is loaded and collision-ready", failures)
	var voxel_tool := zone.get_voxel_tool()
	for depth_y in [-1.0, -5.5]:
		var voxel_position := VoxelWorkZoneConfig.world_to_voxel(Vector3(0.0, depth_y, 18.0), zone.voxel_scale_m)
		var voxel_coordinate := Vector3i(roundi(voxel_position.x), roundi(voxel_position.y), roundi(voxel_position.z))
		_expect(voxel_tool.get_voxel_f(voxel_coordinate) < -0.001, "voxel soil remains solid at %.1f m depth" % depth_y, failures)

	var presentation := scene.get_node("MotionPresentation") as MotionPresentation
	var contract := presentation.get_soil_contract()
	excavation.set("_tracked_chassis_controller", null)
	var start := Vector3(0.0, _bucket_origin_y(contract, -0.03), 18.0)
	var result := excavation.step_automatic_snapshot_for_test(
		_pose(contract, start, Vector3(0.0, -0.04, 0.06), "world-integration"),
		0.05,
	)
	var transaction := ((result.get("voxel_excavation", {}) as Dictionary).get("last_transaction", {}) as Dictionary)
	_expect(bool(result.get("changed", false)), "fixed snapshot reaches the voxel commit scheduler (%s; %s; %s)" % [
		JSON.stringify(result.get("terrain_commit_result", {})),
		String(result.get("interaction_state", "")),
		JSON.stringify((result.get("voxel_excavation", {}) as Dictionary).get("last_cutter_result", {})),
	], failures)
	_expect(int(transaction.get("accepted_mass_q", 0)) > 0, "world integration commits positive cut mass", failures)
	var post_status := excavation.get_status_snapshot()
	var ground_status := post_status.get("bucket_ground_interaction", {}) as Dictionary
	_expect(int(ground_status.get("terrain_commits_executed", -1)) == 0, "legacy heightfield commits never step", failures)
	_expect(int(ground_status.get("parcel_steps_executed", -1)) == 0, "legacy parcel simulation never steps", failures)
	var generation_before_reset := int(post_status.get("world_generation", -1))
	excavation.reset_for_test()
	await physics_frame
	var reset_status := excavation.get_status_snapshot()
	_expect(int(reset_status.get("world_generation", -1)) > generation_before_reset, "world reset advances voxel authority generation", failures)
	_expect(is_zero_approx(float((reset_status.get("selected_soil_payload", {}) as Dictionary).get("payload_mass_kg", -1.0))), "world reset clears voxel bucket inventory", failures)
	_expect(not bool(reset_status.get("legacy_runtime_constructed", true)), "voxel reset does not revive legacy runtime", failures)

	scene.queue_free()
	await process_frame
	if failures.is_empty():
		print("Voxel excavation world integration passed.")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _pose(contract: Dictionary, start: Vector3, motion: Vector3, identity: String) -> Dictionary:
	var tool := BucketSoilTool.new()
	if not tool.configure(contract):
		return {}
	return {
		"valid": true,
		"reason": "ok",
		"model_id": String(contract.get("model_id", "")),
		"identity": identity,
		"soil_tool": tool.compose_snapshot(
			Transform3D(Basis.IDENTITY, start),
			Transform3D(Basis.IDENTITY, start + motion),
			true,
			identity,
		),
		"contract": contract,
	}


func _bucket_origin_y(contract: Dictionary, desired_edge_y: float) -> float:
	var cutting := (contract.get("proxies", {}) as Dictionary).get("cutting_edge", {}) as Dictionary
	var center := cutting.get("center_godot", [0.0, 0.0, 0.0]) as Array
	return desired_edge_y - float(center[1])


func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append("voxel excavation world: %s" % message)

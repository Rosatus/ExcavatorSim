extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"
const SY205_SOIL_CONTRACT := "res://resources/models/sy205_soil_contract.json"
const SY135_SOIL_CONTRACT := "res://resources/models/sy135_soil_contract.json"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var result := _test_batched_repeatability_and_occupancy()
	if result == 0:
		result = _test_rejections_and_capacity()
	if result == 0:
		result = _test_model_contract_grid_switching()
	if result == 0:
		result = _test_scheduler_cadence_and_generation()
	if result == 0:
		result = await _test_scene_nodes_and_production_controls()
	if result == 0:
		print("Automatic excavation gameplay contracts passed.")
	quit(result)


func _test_batched_repeatability_and_occupancy() -> int:
	var contract := _read_json(SY205_SOIL_CONTRACT)
	var first_terrain := TerrainState.new(77)
	var second_terrain := TerrainState.new(77)
	var first_scheduler := TerrainCommitScheduler.new(first_terrain)
	var second_scheduler := TerrainCommitScheduler.new(second_terrain)
	var first := BucketSoilState.new(first_terrain, contract, first_scheduler)
	var second := BucketSoilState.new(second_terrain, contract, second_scheduler)
	var first_height := first_terrain.sample_surface_at(Vector2.ZERO)
	var second_height := second_terrain.sample_surface_at(Vector2.ZERO)
	var baseline := first_terrain.surface_snapshot()["surface_bytes"] as PackedByteArray
	if not first.queue_cut(1, Vector3(0.0, first_height, 0.0), Vector3(0.0, first_height - 0.2, 0.0)):
		return _fail("first cut queues")
	if not second.queue_cut(1, Vector3(0.0, second_height, 0.0), Vector3(0.0, second_height - 0.2, 0.0)):
		return _fail("second cut queues")
	var first_cut := first.step_fixed()
	var second_cut := second.step_fixed()
	if not first_cut.get("changed", false) or not second_cut.get("changed", false):
		return _fail("same contact accepts a cellular intake")
	if first.bucket_volume_m3 != 0.0 or first.get_status_snapshot()["transfer_states"] != {"bucket_pending_terrain": 1}:
		return _fail("cut remains pending until the coarse terrain commit succeeds")
	if first_terrain.surface_snapshot()["surface_bytes"] != baseline:
		return _fail("soil producer does not bypass the terrain scheduler")
	var first_cut_commit := first_scheduler.step_fixed(0.0, true)
	var second_cut_commit := second_scheduler.step_fixed(0.0, true)
	if not first_cut_commit.get("changed", false):
		return _fail("first terrain batch commits")
	if not second_cut_commit.get("changed", false):
		return _fail("second terrain batch commits")
	first.reconcile_transfers(first_cut_commit.get("committed_transfer_ids", []), first_cut_commit.get("rejected_transfer_ids", []))
	second.reconcile_transfers(second_cut_commit.get("committed_transfer_ids", []), second_cut_commit.get("rejected_transfer_ids", []))
	# Digging is decoupled from bucket capacity: committed cuts retire their
	# transfers and become particles directly without ever occupying the bucket.
	if first.bucket_volume_m3 != 0.0 or second.bucket_volume_m3 != 0.0:
		return _fail("cut soil does not occupy the bucket")
	if int(first.get_status_snapshot()["occupied_cells"]) != 0:
		return _fail("cut leaves no bucket payload cells")
	if int(first.get_status_snapshot()["active_transfers"]) != 0:
		return _fail("committed cut retires transfer ownership")
	var first_surface := first_terrain.sample_surface_at(Vector2.ZERO)
	if first.queue_deposit(2, Vector3(0.0, first_surface + 0.2, 0.0)):
		return _fail("empty-bucket deposit is rejected")
	var first_snapshot := first_terrain.surface_snapshot()
	var second_snapshot := second_terrain.surface_snapshot()
	if first_snapshot["surface_bytes"] != second_snapshot["surface_bytes"] or first_snapshot["snapshot_sha256"] != second_snapshot["snapshot_sha256"]:
		return _fail("same transfer batches reproduce coarse terrain")
	return 0


func _test_rejections_and_capacity() -> int:
	var terrain := TerrainState.new(99)
	var scheduler := TerrainCommitScheduler.new(terrain)
	var soil := BucketSoilState.new(terrain, _read_json(SY205_SOIL_CONTRACT), scheduler)
	var surface := terrain.sample_surface_at(Vector2.ZERO)
	if not soil.queue_cut(1, Vector3(0.0, surface + 1.0, 0.0), Vector3(0.0, surface + 1.0, 0.0)):
		return _fail("non-contact command queues for fixed-step rejection")
	var before: PackedByteArray = terrain.surface_snapshot()["surface_bytes"]
	var rejected := soil.step_fixed()
	if rejected.get("changed", false) or terrain.surface_snapshot()["surface_bytes"] != before or soil.bucket_volume_m3 != 0.0:
		return _fail("non-contact command is mutation-free")
	if soil.queue_cut(1, Vector3.ZERO, Vector3.ZERO):
		return _fail("duplicate sequence is rejected")
	if soil.queue_deposit(2, Vector3(0.0, surface + 1.0, 0.0)):
		return _fail("empty deposit is rejected before entering the transfer ledger")
	return 0


func _test_model_contract_grid_switching() -> int:
	var state := BucketSoilState.new(TerrainState.new(91), _read_json(SY205_SOIL_CONTRACT))
	for contract_path in [SY135_SOIL_CONTRACT, SY205_SOIL_CONTRACT, SY135_SOIL_CONTRACT]:
		var contract := _read_json(contract_path)
		if not state.configure_contract(contract):
			return _fail("model switch accepts bucket soil contract: %s" % contract_path)
		var status := state.get_status_snapshot()
		var grid := status.get("cell_grid", []) as Array
		if (
			grid.size() != 3
			or int(status.get("cell_count", -1)) != int(grid[0]) * int(grid[1]) * int(grid[2])
			or (status.get("fill_profile", PackedFloat32Array()) as PackedFloat32Array).size() != int(grid[0]) * int(grid[2])
		):
			return _fail("model switch replaces bucket cell grid atomically: %s" % contract_path)
	state._grid_dimensions = Vector3i(8, 5, 6)
	state._cell_fill.resize(175)
	if not (state.get_status_snapshot().get("fill_profile", PackedFloat32Array()) as PackedFloat32Array).is_empty():
		return _fail("transient bucket cell-grid mismatch fails closed")
	if not state.configure_contract(_read_json(SY135_SOIL_CONTRACT)):
		return _fail("bucket cell grid recovers after a transient mismatch")
	return 0


func _test_scheduler_cadence_and_generation() -> int:
	var terrain := TerrainState.new(123)
	var scheduler := TerrainCommitScheduler.new(terrain)
	if not scheduler.queue_brush(1, Vector2.ZERO, 0.2, -0.02, terrain.world_generation, "0:1:test"):
		return _fail("scheduler accepts immutable brush")
	if scheduler.step_fixed(0.01).get("changed", false):
		return _fail("small brush remains batched before cadence")
	if not scheduler.step_fixed(0.2).get("changed", false):
		return _fail("maximum latency flushes the brush")
	var old_generation := terrain.world_generation
	if not scheduler.queue_brush(2, Vector2.ZERO, 0.2, -0.02, old_generation, "0:2:test"):
		return _fail("pre-reset brush queues")
	terrain.reset()
	var generation_result := scheduler.step_fixed(0.01, true)
	if generation_result.get("reason", "") != "generation_changed" or int(scheduler.get_status_snapshot()["pending_brushes"]) != 0:
		return _fail("generation change discards pending terrain work")
	return 0


func _test_scene_nodes_and_production_controls() -> int:
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		return _fail("main scene loads")
	var scene := packed.instantiate()
	(scene.get_node("TerrainRoot/ExcavationWorld") as ExcavationWorld).soil_material_lifecycle_mode = "voxel"
	root.add_child(scene)
	var excavation := scene.get_node_or_null("TerrainRoot/ExcavationWorld") as ExcavationWorld
	if excavation == null:
		scene.queue_free()
		return _fail("excavation world node exists")
	for _frame in 600:
		var voxel := excavation.get_status_snapshot().get("voxel_excavation", {}) as Dictionary
		if bool(voxel.get("configured", false)):
			break
		await physics_frame
	if excavation._voxel_authority == null or not excavation._voxel_authority.configured:
		scene.queue_free()
		return _fail("voxel authority configures as the product soil owner")
	if not excavation.automatic_soil_enabled or excavation.debug_manual_controls:
		scene.queue_free()
		return _fail("automatic soil is production default and manual controls are debug-only")
	if scene.get_node_or_null("OperatorUI/StatusPanel/Margin/VBox/Buttons/Dig") != null or scene.get_node_or_null("OperatorUI/StatusPanel/Margin/VBox/Buttons/Deposit") != null:
		scene.queue_free()
		return _fail("production scene omits Dig and Deposit controls")
	if excavation.request_dig() or excavation.request_deposit():
		scene.queue_free()
		return _fail("manual requests are disabled without the debug flag")
	if excavation.process_physics_priority <= (scene.get_node("ChassisMotionRoot") as TrackedChassisController).process_physics_priority:
		scene.queue_free()
		return _fail("chassis composition runs before fixed-step bucket sampling")
	for action in InputMap.get_actions():
		for event in InputMap.action_get_events(action):
			if event is InputEventKey and [KEY_F9, KEY_F10].has((event as InputEventKey).physical_keycode):
				scene.queue_free()
				return _fail("production input map omits legacy F9/F10 soil controls")
	scene.queue_free()
	await process_frame
	return 0


func _read_json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}


func _fail(message: String) -> int:
	push_error("automatic soil check failed: %s" % message)
	return 1

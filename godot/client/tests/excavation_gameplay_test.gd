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
		result = _test_scheduler_cadence_and_generation()
	if result == 0:
		result = await _test_scene_nodes_and_production_controls()
	if result == 0:
		result = await _test_automatic_motion_for_both_models()
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
	var cut_volume := float(first_cut["cut_volume_m3"])
	if cut_volume <= 0.0 or not is_equal_approx(first.bucket_volume_m3, cut_volume):
		return _fail("cut volume occupies bucket cells")
	if int(first.get_status_snapshot()["occupied_cells"]) <= 0:
		return _fail("bucket payload has occupied cells")
	var first_surface := first_terrain.sample_surface_at(Vector2.ZERO)
	var second_surface := second_terrain.sample_surface_at(Vector2.ZERO)
	if not first.queue_deposit(2, Vector3(0.0, first_surface + 0.2, 0.0)):
		return _fail("first deposit queues")
	if not second.queue_deposit(2, Vector3(0.0, second_surface + 0.2, 0.0)):
		return _fail("second deposit queues")
	first.step_fixed()
	second.step_fixed()
	var first_deposit_commit := first_scheduler.step_fixed(0.0, true)
	var second_deposit_commit := second_scheduler.step_fixed(0.0, true)
	first.reconcile_transfers(first_deposit_commit.get("committed_transfer_ids", []), first_deposit_commit.get("rejected_transfer_ids", []))
	second.reconcile_transfers(second_deposit_commit.get("committed_transfer_ids", []), second_deposit_commit.get("rejected_transfer_ids", []))
	var first_snapshot := first_terrain.surface_snapshot()
	var second_snapshot := second_terrain.surface_snapshot()
	if first_snapshot["surface_bytes"] != second_snapshot["surface_bytes"] or first_snapshot["snapshot_sha256"] != second_snapshot["snapshot_sha256"]:
		return _fail("same transfer batches reproduce coarse terrain")
	if not is_equal_approx(first.bucket_volume_m3, second.bucket_volume_m3):
		return _fail("same transfers reproduce bucket occupancy aggregate")
	if int(first.get_status_snapshot()["active_transfers"]) != 0:
		return _fail("committed dump retires transfer ownership")
	if first.bucket_volume_m3 < -BucketSoilState.EPSILON_M3 or first.bucket_volume_m3 > first.bucket_capacity_m3 + BucketSoilState.EPSILON_M3:
		return _fail("bucket occupancy remains inside model capacity")
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
	root.add_child(scene)
	await process_frame
	await process_frame
	var excavation := scene.get_node_or_null("TerrainRoot/ExcavationWorld") as ExcavationWorld
	if excavation == null or excavation.terrain_scheduler == null or excavation.soil_state == null:
		scene.queue_free()
		return _fail("terrain, automatic excavation and scheduler initialize")
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


func _test_automatic_motion_for_both_models() -> int:
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		return _fail("main scene loads for automatic soil scenarios")
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	var excavation := scene.get_node("TerrainRoot/ExcavationWorld") as ExcavationWorld
	for contract_path in [SY205_SOIL_CONTRACT, SY135_SOIL_CONTRACT]:
		var contract := _read_json(contract_path)
		excavation.terrain_scheduler.reset_world()
		if not excavation.soil_state.configure_contract(contract):
			scene.queue_free()
			return _fail("model soil contract configures: %s" % contract_path)
		var direction := _vector3((contract["proxies"] as Dictionary)["cutting_edge"].get("direction_godot", []))
		var current_cut := Vector3(0.0, -0.02, 0.0)
		var previous_cut := current_cut - direction * 0.12
		var cut := excavation.step_automatic_snapshot_for_test(_soil_snapshot(contract, previous_cut, current_cut, Vector3.UP))
		if (
			cut.get("interaction_state", "") != "cut"
			or float(cut.get("bucket_volume_m3", 0.0)) <= 0.0
			or float(cut.get("flow_volume_m3", 0.0)) <= 0.0
		):
			scene.queue_free()
			return _fail("bucket motion alone cuts and retains soil for %s" % contract.get("model_id", ""))
		var carry := excavation.step_automatic_snapshot_for_test(_soil_snapshot(contract, current_cut, current_cut, Vector3.UP))
		if (
			carry.get("interaction_state", "") != "carry"
			or int(carry.get("occupied_cells", 0)) <= 0
			or float(carry.get("flow_volume_m3", -1.0)) != 0.0
		):
			scene.queue_free()
			return _fail("retained occupancy carries with the bucket for %s" % contract.get("model_id", ""))
		var volume_before_invalid := float(carry.get("bucket_volume_m3", 0.0))
		var revision_before_invalid := int(carry.get("terrain_revision", -1))
		var transfers_before_invalid := int(carry.get("active_transfers", 0))
		var invalid := excavation.step_automatic_snapshot_for_test({"valid": false, "reason": "stale_identity"})
		if (
			invalid.get("interaction_state", "") != "no_pose"
			or not is_equal_approx(float(invalid.get("bucket_volume_m3", 0.0)), volume_before_invalid)
			or int(invalid.get("terrain_revision", -1)) != revision_before_invalid
			or int(invalid.get("active_transfers", 0)) != transfers_before_invalid
		):
			scene.queue_free()
			return _fail("invalid fixed-step snapshots cannot create or remove material")
		# Fill through the same motion path before exposing the opening. This keeps
		# the spill assertion tied to automatic contact rather than a fixed grant.
		for attempt in 200:
			var x := float(attempt % 20) * 0.7 - 6.65
			var z := float(attempt / 20) * 0.7 - 3.45
			var surface_at_fill := excavation.terrain_world.terrain_state.sample_surface_at(Vector2(x, z))
			if is_nan(surface_at_fill):
				continue
			var fill_point := Vector3(x, surface_at_fill - 0.02, z)
			var fill_cut := excavation.step_automatic_snapshot_for_test(
				_soil_snapshot(contract, fill_point - direction * 0.12, fill_point, Vector3.UP)
			)
			if float(fill_cut.get("bucket_volume_m3", 0.0)) >= float(contract.get("nominal_capacity_m3", 0.0)) * 0.46:
				break
		var fill_ratio := excavation.soil_state.bucket_volume_m3 / maxf(float(contract.get("nominal_capacity_m3", 0.0)), BucketSoilState.EPSILON_M3)
		if fill_ratio <= 0.45:
			scene.queue_free()
			return _fail("automatic cuts fill the bucket before spill for %s" % contract.get("model_id", ""))
		var spill_normal := Vector3.RIGHT if contract.get("model_id", "") == "sy205" else Vector3(0.0, 0.3, 0.953939)
		var volume_before_spill := excavation.soil_state.bucket_volume_m3
		var spill := excavation.step_automatic_snapshot_for_test(_soil_snapshot(contract, current_cut, current_cut, spill_normal))
		if spill.get("interaction_state", "") != "spill" or float(spill.get("flow_volume_m3", 0.0)) <= 0.0 or float(spill.get("bucket_volume_m3", 0.0)) >= volume_before_spill:
			scene.queue_free()
			return _fail("partially open bucket spills retained soil for %s" % contract.get("model_id", ""))
		var dump_pose := Vector3(current_cut.x, 1.0, current_cut.z)
		for attempt in 12:
			var dump := excavation.step_automatic_snapshot_for_test(_soil_snapshot(contract, dump_pose, dump_pose, Vector3.DOWN), 0.15)
			if dump.get("interaction_state", "") != "dump" and float(dump.get("bucket_volume_m3", 0.0)) > BucketSoilState.EPSILON_M3:
				scene.queue_free()
				return _fail("opening exposure enters dump for %s" % contract.get("model_id", ""))
			if float(dump.get("bucket_volume_m3", 0.0)) <= BucketSoilState.EPSILON_M3:
				break
		if excavation.soil_state.bucket_volume_m3 > BucketSoilState.EPSILON_M3 or int(excavation.soil_state.get_status_snapshot()["active_transfers"]) != 0:
			scene.queue_free()
			return _fail("dump retires payload ownership for %s" % contract.get("model_id", ""))
		# A 30-second fixed-step idle/carry window must not accumulate transfers.
		for _frame in 1800:
			var sustained := excavation.step_automatic_snapshot_for_test(_soil_snapshot(contract, current_cut, current_cut, Vector3.UP))
			if int(sustained.get("active_transfers", 0)) > BucketSoilState.MAX_ACTIVE_TRANSFERS:
				scene.queue_free()
				return _fail("sustained automatic interaction remains bounded for %s" % contract.get("model_id", ""))
	scene.queue_free()
	await process_frame
	return 0


func _soil_snapshot(contract: Dictionary, previous_cut: Vector3, current_cut: Vector3, opening_normal: Vector3) -> Dictionary:
	var previous := {}
	var current := {}
	for proxy_name in ["cutting_edge", "top_edge", "opening", "cavity", "rear_support"]:
		var previous_origin := previous_cut
		var current_origin := current_cut
		if proxy_name == "opening" or proxy_name == "cavity":
			previous_origin.y += 0.42
			current_origin.y += 0.42
		elif proxy_name == "rear_support":
			previous_origin.y = 1.0
			current_origin.y = 1.0
		previous[proxy_name] = Transform3D(Basis.IDENTITY, previous_origin)
		current[proxy_name] = Transform3D(Basis.IDENTITY, current_origin)
	return {
		"valid": true,
		"reason": "test",
		"previous": previous,
		"current": current,
		"cutting_direction_world": _vector3((contract["proxies"] as Dictionary)["cutting_edge"].get("direction_godot", [])),
		"opening_normal_world": opening_normal,
		"contract": contract,
	}


func _vector3(value: Variant) -> Vector3:
	if not value is Array or (value as Array).size() != 3:
		return Vector3.ZERO
	return Vector3(float(value[0]), float(value[1]), float(value[2])).normalized()


func _read_json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}


func _fail(message: String) -> int:
	push_error("automatic soil check failed: %s" % message)
	return 1

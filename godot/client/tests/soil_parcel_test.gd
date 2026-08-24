extends SceneTree

## Focused contract for the bounded soil parcel transport loop: accepted cuts
## spawn bounded volume carriers at the tooth, capture credits the occupancy
## ledger up to capacity, poured material cannot be instantly re-swallowed,
## settled parcels ride the deposit pipeline back into the heightfield, and
## the pool never exceeds its budget or survives a generation clear.

const MAIN_SCENE := "res://scenes/main.tscn"
const SOIL_CONTRACT := "res://resources/models/sy205_soil_contract.json"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: " + label)
	else:
		failures.append(label)
		print("FAIL: " + label)


func _fail(message: String) -> int:
	failures.append(message)
	print("FAIL: " + message)
	return _finish()


func _finish() -> int:
	if failures.is_empty():
		print("soil_parcel_test: PASS")
		return 0
	print("soil_parcel_test: FAIL (%d)" % failures.size())
	return 1


func _run() -> void:
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		return _fail("main scene loads")
	var scene := packed.instantiate()
	(scene.get_node("TerrainRoot/ExcavationWorld") as ExcavationWorld).soil_material_lifecycle_mode = "legacy"
	root.add_child(scene)
	await process_frame
	await process_frame
	var excavation := scene.get_node("TerrainRoot/ExcavationWorld") as ExcavationWorld
	if excavation == null:
		return _fail("excavation world resolves")
	var contract := _read_json(SOIL_CONTRACT)
	if contract.is_empty():
		return _fail("soil contract loads")
	excavation.terrain_scheduler.reset_world()
	excavation.soil_state.configure_contract(contract)
	var pool := excavation._parcel_pool
	if pool == null:
		return _fail("parcel pool created")
	# Drive this focused pool deterministically; the production fixed loop would
	# otherwise overwrite the barrier pose between manual physics frames.
	excavation.set_physics_process(false)
	pool.clear_all()
	await process_frame

	await _test_barrier_first_pose(pool)
	await _test_spawn_bounds_and_velocity(pool)
	await _test_budget_steal(pool)
	await _test_full_pool_pour_preserves_ledger(excavation, pool)
	await _test_capture_and_overflow(excavation, pool)
	await _test_pour_guard(excavation, pool)
	await _test_settle_pipeline(excavation, pool)
	await _test_conservation(excavation, pool)
	await _test_partial_and_rejected_settle(pool)
	await _test_delayed_settle_identity(pool)
	await _test_clear(pool)

	_finish()
	quit(1 if not failures.is_empty() else 0)


func _test_spawn_bounds_and_velocity(pool: SoilParcelPool) -> void:
	pool.clear_all()
	var before := pool.active_count()
	var tooth_velocity := Vector3(1.0, 0.0, 0.0)
	pool.spawn_from_cut(Vector3.ZERO, 0.002, tooth_velocity)
	_check(pool.active_count() == before + 1, "spawn creates one parcel for small volume")
	var index := _first_active(pool)
	var body := pool.get_body(index)
	if body == null:
		_check(false, "spawned body resolves")
		return
	_check(body.linear_velocity.y >= SoilParcelPool.SPAWN_SPREAD_MPS * 0.3, "cut spray has a deterministic upward bias")
	_check(body.linear_velocity.dot(tooth_velocity) > 0.0, "cut spray keeps the tooth stroke direction")
	var snapshot := pool.get_pool_snapshot()
	_check(float(snapshot["volume_m3"]) > 0.0019 and float(snapshot["volume_m3"]) <= 0.0021, "spawn preserves volume")
	pool.clear_all()


func _test_budget_steal(pool: SoilParcelPool) -> void:
	pool.clear_all()
	var original_budget := pool.budget
	pool.budget = 4
	var total_cut := 0.0
	for i in 7:
		total_cut += 0.001
		pool.spawn_from_cut(Vector3(float(i), 0.0, 0.0), 0.001, Vector3.ZERO)
	_check(pool.active_count() == 4, "budget caps active parcel bodies")
	var snapshot := pool.get_pool_snapshot()
	_check(pool.pending_cut_volume_m3() > 0.0, "budget overflow enters a bounded aggregate backlog")
	_check(absf(float(snapshot["volume_m3"]) - total_cut) < 0.00001, "full cut pool preserves active plus pending material")
	pool._deactivate(0)
	pool.step_pool(1.0 / 60.0, Transform3D.IDENTITY, Vector3(0.25, 0.25, 0.35))
	_check(pool.active_count() == 4, "pending cut material occupies the next free carrier")
	_check(pool.pending_cut_volume_m3() < 0.003, "pending cut backlog drains when capacity returns")
	pool.budget = original_budget
	pool.clear_all()
	await process_frame


func _test_full_pool_pour_preserves_ledger(excavation: ExcavationWorld, pool: SoilParcelPool) -> void:
	pool.clear_all()
	excavation.soil_state.reset_for_generation()
	var original_budget := pool.budget
	pool.budget = 1
	pool.spawn_from_cut(Vector3.ZERO, 0.001, Vector3.ZERO)
	excavation.soil_state.credit_captured_volume(0.004)
	var ledger_before := excavation.soil_state.bucket_volume_m3
	var blocked_release := pool.release_volume(0.002, Vector3.ZERO, Vector3.DOWN)
	_check(blocked_release <= SoilParcelPool.EPSILON_M3, "full pool defers pour instead of stealing a carrier")
	_check(is_equal_approx(excavation.soil_state.bucket_volume_m3, ledger_before), "full pool leaves unrepresented pour volume in the ledger")
	pool.clear_all()
	var bounded_release := pool.release_volume(0.01, Vector3.ZERO, Vector3.DOWN)
	_check(bounded_release > 0.0 and bounded_release <= SoilParcelPool._volume_for_radius(SoilParcelPool.MAX_RADIUS_M) + SoilParcelPool.EPSILON_M3, "pour is bounded by available carrier capacity")
	_check(absf(ledger_before - bounded_release - excavation.soil_state.bucket_volume_m3) < 0.00001, "bounded pour debits exactly represented parcel volume")
	_check(absf(float(pool.get_pool_snapshot().get("volume_m3", 0.0)) - bounded_release) < 0.00001, "represented pour volume exists in the physical pool")
	pool.budget = original_budget
	excavation.soil_state.reset_for_generation()
	pool.clear_all()


func _test_capture_and_overflow(excavation: ExcavationWorld, pool: SoilParcelPool) -> void:
	pool.clear_all()
	excavation.soil_state.reset_for_generation()
	var cavity := Transform3D(Basis.IDENTITY, Vector3.ZERO)
	pool.spawn_from_cut(Vector3(0.0, 0.05, 0.0), 0.002, Vector3.ZERO)
	var volume_before := excavation.soil_state.bucket_volume_m3
	var capture_index := _first_active(pool)
	var capture_body := pool.get_body(capture_index)
	var initial_radius := ((capture_body.get_child(1) as CollisionShape3D).shape as SphereShape3D).radius
	pool.step_pool(1.0 / 60.0, cavity, Vector3(0.25, 0.25, 0.35))
	pool.step_pool(1.0 / 60.0, cavity, Vector3(0.25, 0.25, 0.35))
	var partial_credit := excavation.soil_state.bucket_volume_m3 - volume_before
	var partial_record := pool._records[capture_index]
	var partial_radius := ((capture_body.get_child(1) as CollisionShape3D).shape as SphereShape3D).radius
	_check(pool.active_count() == 1 and bool(partial_record.get("absorbing", false)), "capture remains visible during progressive absorption")
	_check(partial_credit > 0.0 and partial_credit < 0.002, "capture credits only a partial volume per fixed tick")
	_check(partial_radius < initial_radius, "progressive absorption shrinks the parcel collider")
	_check(absf(partial_credit + float(partial_record.get("volume_m3", 0.0)) - 0.002) < 0.00001, "partial absorption conserves ledger plus visible remainder")
	var absorbed := false
	for tick in 30:
		pool.step_pool(1.0 / 60.0, cavity, Vector3(0.25, 0.25, 0.35))
		if pool.active_count() == 0:
			absorbed = true
			break
	var captured := excavation.soil_state.bucket_volume_m3 - volume_before
	_check(captured > 0.0015, "capture credits ledger with parcel volume")
	_check(absorbed, "fully absorbed parcel recycles")

	excavation.soil_state.bucket_volume_m3 = excavation.soil_state.bucket_capacity_m3
	pool.spawn_from_cut(Vector3(0.0, 0.05, 0.0), 0.002, Vector3.ZERO)
	for tick in 8:
		pool.step_pool(1.0 / 60.0, cavity, Vector3(0.25, 0.25, 0.35))
	_check(excavation.soil_state.bucket_volume_m3 >= excavation.soil_state.bucket_capacity_m3 - 0.000001, "overflow parcel does not exceed capacity")
	_check(pool.active_count() == 1, "capacity-stalled parcel stays physical as heap")
	var overflow_index := _first_active(pool)
	_check(not bool(pool._records[overflow_index].get("absorbing", false)), "capacity-stalled heap leaves the absorption state")
	_check(pool.get_body(overflow_index).visible and not pool.get_body(overflow_index).freeze, "overflow heap remains a physical visible body")
	excavation.soil_state.reset_for_generation()
	pool.clear_all()


func _test_pour_guard(excavation: ExcavationWorld, pool: SoilParcelPool) -> void:
	pool.clear_all()
	excavation.soil_state.reset_for_generation()
	excavation.soil_state.credit_captured_volume(0.004)
	var released := pool.release_volume(0.002, Vector3(0.0, 0.1, 0.0), Vector3.DOWN)
	_check(released > 0.0015, "pour releases requested ledger volume")
	_check(absf(excavation.soil_state.bucket_volume_m3 - 0.002) < 0.0005, "pour removes ledger occupancy")
	var cavity := Transform3D(Basis.IDENTITY, Vector3.ZERO)
	pool.step_pool(1.0 / 60.0, cavity, Vector3(0.25, 0.25, 0.35))
	_check(pool.active_count() == 1, "guard blocks instant recapture inside cavity")
	for record in pool._records:
		record["guarded"] = false
	var recaptured := false
	for tick in 30:
		pool.step_pool(1.0 / 60.0, cavity, Vector3(0.25, 0.25, 0.35))
		if pool.active_count() == 0:
			recaptured = true
			break
	_check(recaptured, "unguarded parcel inside cavity absorbs gradually")
	excavation.soil_state.reset_for_generation()
	pool.clear_all()


func _test_settle_pipeline(excavation: ExcavationWorld, pool: SoilParcelPool) -> void:
	pool.clear_all()
	excavation.soil_state.reset_for_generation()
	pool.ground_probe = func(_body: RigidBody3D) -> bool: return true
	var state := excavation.terrain_world.terrain_state
	state.enqueue_brush(state.next_brush_sequence(), Vector2(2.0, 2.0), 0.5, 0.5)
	state.step_fixed()
	pool.spawn_from_cut(Vector3(2.0, 1.02, 2.0), 0.003, Vector3.ZERO)
	var index := _first_active(pool)
	pool.get_body(index).linear_velocity = Vector3.ZERO
	var settled := false
	for tick in 40:
		pool.step_pool(1.0 / 60.0, Transform3D(Basis.IDENTITY, Vector3(100.0, 0.0, 100.0)), Vector3(0.25, 0.25, 0.35))
		var result := excavation.soil_state.step_fixed()
		pool.notify_deposit_results(result.get("parcel_deposit_results", []))
		var commit := excavation.terrain_scheduler.step_fixed(1.0 / 60.0, true)
		excavation.soil_state.reconcile_transfers(
			commit.get("committed_transfer_ids", []),
			commit.get("rejected_transfer_ids", [])
		)
		pool.notify_deposit_commits(
			commit.get("committed_transfer_ids", []),
			commit.get("rejected_transfer_ids", [])
		)
		if pool.active_count() == 0 and pool.pending_settle_volume_m3() <= 0.0:
			settled = true
			break
	_check(settled, "grounded dwelling parcel queues settle and recycles")
	_check(excavation.soil_state.bucket_volume_m3 <= BucketSoilState.EPSILON_M3, "cut parcel settles without consuming bucket occupancy")
	_check(not is_nan(state.sample_surface_bilinear_at(Vector2(2.0, 2.0))), "settled region stays sampleable")
	pool.ground_probe = Callable()
	pool.clear_all()


func _test_barrier_first_pose(pool: SoilParcelPool) -> void:
	var barrier := pool.get_barrier()
	_check(barrier != null, "bucket barrier built")
	if barrier == null:
		return
	_check(barrier.collision_layer != 0, "barrier active on machine layer")
	var pose := Transform3D(Basis.IDENTITY, Vector3(3.0, 2.0, 4.0))
	pool.step_pool(1.0 / 60.0, pose, Vector3(0.25, 0.25, 0.35))
	await physics_frame
	pool.step_pool(1.0 / 60.0, pose, Vector3(0.25, 0.25, 0.35))
	await physics_frame
	_check(barrier.global_transform.origin.is_equal_approx(Vector3(3.0, 2.0, 4.0)), "barrier mirrors cavity pose (origin=%s)" % barrier.global_transform.origin)
	_check(barrier.get_child_count() == 4, "barrier has floor/back/side plates with open mouth")
	_check(barrier.collision_mask == 0 and barrier.collision_layer != 0, "barrier collides parcels one-way")
	var cavity := Transform3D(Basis.IDENTITY, Vector3(0.0, 3.0, 0.0))
	var extents := Vector3(
		absf((barrier.get_child(2) as CollisionShape3D).position.x),
		absf((barrier.get_child(0) as CollisionShape3D).position.y),
		absf((barrier.get_child(1) as CollisionShape3D).position.z),
	)
	var floor_result := await _throw_in_cavity(pool, cavity, extents, Vector3(0.0, -4.0, 0.0))
	_check(floor_result.y >= -extents.y - 0.14, "floor plate stops a downward parcel (y=%.3f)" % floor_result.y)
	var back_result := await _throw_in_cavity(pool, cavity, extents, Vector3(0.0, 0.0, 4.0))
	_check(back_result.z <= extents.z + 0.14, "back plate stops a rearward parcel (z=%.3f)" % back_result.z)
	var left_result := await _throw_in_cavity(pool, cavity, extents, Vector3(-4.0, 0.0, 0.0))
	_check(left_result.x >= -extents.x - 0.14, "left plate stops a sideward parcel (x=%.3f)" % left_result.x)
	var right_result := await _throw_in_cavity(pool, cavity, extents, Vector3(4.0, 0.0, 0.0))
	_check(right_result.x <= extents.x + 0.14, "right plate stops a sideward parcel (x=%.3f)" % right_result.x)
	var mouth_result := await _throw_in_cavity(pool, cavity, extents, Vector3(0.0, 5.0, 0.0))
	_check(mouth_result.y > extents.y + 0.2, "open mouth lets an outward parcel pass")
	var alternate_extents := Vector3(0.31, 0.19, 0.42)
	_check(pool.configure_barrier_extents(alternate_extents), "barrier accepts model-specific cavity extents")
	_check(
		is_equal_approx(absf((barrier.get_child(2) as CollisionShape3D).position.x), alternate_extents.x)
		and is_equal_approx(absf((barrier.get_child(0) as CollisionShape3D).position.y), alternate_extents.y)
		and is_equal_approx(absf((barrier.get_child(1) as CollisionShape3D).position.z), alternate_extents.z),
		"model switch retargets all closed barrier planes",
	)
	pool.configure_barrier_extents(extents)
	pool.clear_all()


func _test_conservation(excavation: ExcavationWorld, pool: SoilParcelPool) -> void:
	pool.clear_all()
	excavation.soil_state.reset_for_generation()
	excavation.soil_state.credit_captured_volume(0.0015)
	var ledger_before := excavation.soil_state.bucket_volume_m3
	var released := pool.release_volume(0.0015, Vector3(4.0, 1.05, 4.0), Vector3.DOWN)
	_check(absf(ledger_before - released - excavation.soil_state.bucket_volume_m3) < 0.000001, "occupancy decreases exactly once per pour")
	_check(excavation.soil_state.bucket_volume_m3 <= BucketSoilState.EPSILON_M3, "full pour may empty the bucket before parcels settle")
	pool.ground_probe = func(_body: RigidBody3D) -> bool: return true
	for index in range(pool._records.size()):
		if bool(pool._records[index].get("active", false)):
			pool.get_body(index).linear_velocity = Vector3.ZERO
	var accepted_total := 0.0
	var ledger_stayed_empty := true
	for tick in 60:
		pool.step_pool(1.0 / 60.0, Transform3D(Basis.IDENTITY, Vector3(100.0, 0.0, 100.0)), Vector3(0.25, 0.25, 0.35))
		var result := excavation.soil_state.step_fixed()
		pool.notify_deposit_results(result.get("parcel_deposit_results", []))
		accepted_total += float(result.get("deposit_volume_m3", 0.0))
		var commit := excavation.terrain_scheduler.step_fixed(1.0 / 60.0, true)
		excavation.soil_state.reconcile_transfers(
			commit.get("committed_transfer_ids", []),
			commit.get("rejected_transfer_ids", [])
		)
		pool.notify_deposit_commits(
			commit.get("committed_transfer_ids", []),
			commit.get("rejected_transfer_ids", [])
		)
		ledger_stayed_empty = ledger_stayed_empty and excavation.soil_state.bucket_volume_m3 <= BucketSoilState.EPSILON_M3
		if pool.active_count() == 0:
			break
	_check(pool.active_count() == 0 and pool.pending_settle_volume_m3() <= 0.0, "all poured parcels settle")
	_check(absf(accepted_total - released) < 0.0005, "settled deposit volume equals poured volume")
	_check(ledger_stayed_empty, "parcel settlement never debits bucket occupancy a second time")
	pool.ground_probe = Callable()
	pool.clear_all()


func _test_partial_and_rejected_settle(pool: SoilParcelPool) -> void:
	pool.clear_all()
	pool.spawn_from_cut(Vector3.ZERO, 0.002, Vector3.ZERO)
	var partial_index := _first_active(pool)
	var partial_record := pool._records[partial_index]
	partial_record["settling"] = true
	partial_record["settle_sequence"] = 7001
	partial_record["settled_ticks"] = 0
	pool.get_body(partial_index).freeze = true
	pool._pending_settle_volume_m3 = 0.002
	pool.notify_deposit_results([{
		"sequence": 7001,
		"accepted": true,
		"volume_m3": 0.00075,
		"transfer_id": "partial-transfer",
		"reason": "",
	}])
	pool.notify_deposit_commits(["partial-transfer"], [])
	_check(pool.active_count() == 1, "partial terrain commit keeps a physical parcel remainder")
	_check(absf(float(pool._records[partial_index].get("volume_m3", 0.0)) - 0.00125) < 0.00001, "partial terrain commit consumes only accepted parcel volume")
	_check(not bool(pool._records[partial_index].get("settling", false)) and not pool.get_body(partial_index).freeze, "partial parcel remainder returns to the retry state")

	pool.clear_all()
	pool.spawn_from_cut(Vector3.ZERO, 0.002, Vector3.ZERO)
	var rejected_index := _first_active(pool)
	var rejected_record := pool._records[rejected_index]
	rejected_record["settling"] = true
	rejected_record["settle_sequence"] = 7002
	rejected_record["settled_ticks"] = 0
	pool.get_body(rejected_index).freeze = true
	pool._pending_settle_volume_m3 = 0.002
	pool.notify_deposit_results([{
		"sequence": 7002,
		"accepted": true,
		"volume_m3": 0.002,
		"transfer_id": "rejected-transfer",
		"reason": "",
	}])
	pool.notify_deposit_commits([], ["rejected-transfer"])
	_check(pool.active_count() == 1, "rejected terrain transfer preserves the physical parcel")
	_check(absf(float(pool._records[rejected_index].get("volume_m3", 0.0)) - 0.002) < 0.00001, "rejected terrain transfer preserves full parcel volume")
	_check(not bool(pool._records[rejected_index].get("settling", false)) and not pool.get_body(rejected_index).freeze, "rejected parcel returns to the retry state")
	pool.clear_all()


func _test_delayed_settle_identity(pool: SoilParcelPool) -> void:
	pool.clear_all()
	pool.spawn_from_cut(Vector3.ZERO, 0.002, Vector3.ZERO)
	var index := _first_active(pool)
	var record := pool._records[index]
	record["settling"] = true
	record["settle_sequence"] = 7101
	pool.get_body(index).freeze = true
	pool._pending_settle_volume_m3 = 0.002
	for tick in 30:
		pool.step_pool(1.0 / 60.0, Transform3D.IDENTITY, Vector3(0.25, 0.25, 0.35))
	_check(bool(record.get("settling", false)), "delayed settle result keeps the parcel frozen in-flight")
	_check(int(record.get("settle_sequence", -1)) == 7101, "delayed settle result preserves exact sequence identity")
	pool.notify_deposit_results([{
		"sequence": 7101,
		"accepted": true,
		"volume_m3": 0.002,
		"transfer_id": "delayed-transfer",
		"reason": "",
	}])
	pool.notify_deposit_commits(["delayed-transfer"], [])
	_check(pool.active_count() == 0, "one delayed commit consumes the parcel exactly once")
	_check(pool.pending_settle_volume_m3() <= SoilParcelPool.EPSILON_M3, "delayed commit clears pending settle volume")
	pool.clear_all()


func _test_clear(pool: SoilParcelPool) -> void:
	pool.clear_all()
	pool.spawn_from_cut(Vector3(1.0, 0.5, 1.0), 0.004, Vector3.ZERO)
	pool.clear_all()
	_check(pool.active_count() == 0, "clear empties the pool")
	_check(float(pool.get_pool_snapshot()["volume_m3"]) == 0.0, "clear reports zero carried volume")


func _first_active(pool: SoilParcelPool) -> int:
	for index in pool._records.size():
		if bool(pool._records[index].get("active", false)):
			return index
	return -1


func _throw_in_cavity(
	pool: SoilParcelPool,
	cavity: Transform3D,
	extents: Vector3,
	velocity: Vector3,
) -> Vector3:
	pool.clear_all()
	pool.step_pool(1.0 / 60.0, cavity, extents)
	await physics_frame
	pool.step_pool(1.0 / 60.0, cavity, extents)
	await physics_frame
	pool.spawn_from_cut(cavity.origin, 0.002, Vector3.ZERO)
	var index := _first_active(pool)
	var body := pool.get_body(index)
	pool._records[index]["guarded"] = true
	pool._records[index]["guard_left_s"] = 10.0
	body.linear_velocity = velocity
	for _tick in 30:
		pool.step_pool(1.0 / 60.0, cavity, extents)
		await physics_frame
	return cavity.affine_inverse() * body.global_position


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed as Dictionary if parsed is Dictionary else {}

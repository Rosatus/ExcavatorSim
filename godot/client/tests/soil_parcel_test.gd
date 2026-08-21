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
	pool.clear_all()
	await process_frame

	await _test_spawn_bounds_and_velocity(pool)
	await _test_budget_steal(pool)
	await _test_capture_and_overflow(excavation, pool)
	await _test_pour_guard(excavation, pool)
	await _test_settle_pipeline(excavation, pool)
	await _test_clear(pool)

	_finish()
	quit(1 if not failures.is_empty() else 0)


func _test_spawn_bounds_and_velocity(pool: SoilParcelPool) -> void:
	pool.clear_all()
	var before := pool.active_count()
	pool.spawn_from_cut(Vector3.ZERO, 0.002, Vector3(0.5, -0.2, 0.0))
	_check(pool.active_count() == before + 1, "spawn creates one parcel for small volume")
	var index := _first_active(pool)
	var body := pool.get_body(index)
	if body == null:
		_check(false, "spawned body resolves")
		return
	_check(body.linear_velocity.length() > 0.2, "spawn inherits velocity plus spread")
	var snapshot := pool.get_pool_snapshot()
	_check(float(snapshot["volume_m3"]) > 0.0019 and float(snapshot["volume_m3"]) <= 0.0021, "spawn preserves volume")
	pool.clear_all()


func _test_budget_steal(pool: SoilParcelPool) -> void:
	pool.clear_all()
	var original_budget := pool.budget
	pool.budget = 4
	for i in 7:
		pool.spawn_from_cut(Vector3(float(i), 0.0, 0.0), 0.001, Vector3.ZERO)
	_check(pool.active_count() == 4, "budget caps active parcels (steal oldest)")
	var snapshot := pool.get_pool_snapshot()
	_check(int(snapshot["flying"]) == 4 and int(snapshot["settling"]) == 0, "stolen parcels recycle cleanly")
	pool.budget = original_budget
	pool.clear_all()
	await process_frame


func _test_capture_and_overflow(excavation: ExcavationWorld, pool: SoilParcelPool) -> void:
	pool.clear_all()
	excavation.soil_state.reset_for_generation()
	var cavity := Transform3D(Basis.IDENTITY, Vector3.ZERO)
	pool.spawn_from_cut(Vector3(0.0, 0.05, 0.0), 0.002, Vector3.ZERO)
	var volume_before := excavation.soil_state.bucket_volume_m3
	pool.step_pool(1.0 / 60.0, cavity, Vector3(0.25, 0.25, 0.35))
	var captured := excavation.soil_state.bucket_volume_m3 - volume_before
	_check(captured > 0.0015, "capture credits ledger with parcel volume")
	_check(pool.active_count() == 0, "fully captured parcel recycles")

	excavation.soil_state.bucket_volume_m3 = excavation.soil_state.bucket_capacity_m3
	pool.spawn_from_cut(Vector3(0.0, 0.05, 0.0), 0.002, Vector3.ZERO)
	pool.step_pool(1.0 / 60.0, cavity, Vector3(0.25, 0.25, 0.35))
	_check(excavation.soil_state.bucket_volume_m3 >= excavation.soil_state.bucket_capacity_m3 - 0.000001, "overflow parcel does not exceed capacity")
	_check(pool.active_count() == 1, "uncapturable overflow parcel keeps flying")
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
	pool.step_pool(1.0 / 60.0, cavity, Vector3(0.25, 0.25, 0.35))
	_check(pool.active_count() == 0, "unguarded parcel inside cavity captures")
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
		excavation.soil_state.step_fixed()
		var commit := excavation.terrain_scheduler.step_fixed(1.0 / 60.0, true)
		excavation.soil_state.reconcile_transfers(
			commit.get("committed_transfer_ids", []),
			commit.get("rejected_transfer_ids", [])
		)
		pool.notify_deposit_accepted(0.0)
		if pool.active_count() == 0 and pool.pending_settle_volume_m3() <= 0.0:
			settled = true
			break
	_check(settled, "grounded dwelling parcel queues settle and recycles")
	_check(not is_nan(state.sample_surface_bilinear_at(Vector2(2.0, 2.0))), "settled region stays sampleable")
	pool.ground_probe = Callable()
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


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	return parsed as Dictionary if parsed is Dictionary else {}

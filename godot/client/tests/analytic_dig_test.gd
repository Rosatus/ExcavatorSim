extends SceneTree

## Focused contract for the analytic soil cutting loop: penetration sampled
## straight from the authoritative heightfield drives cuts every commanded
## tick regardless of query validity, terrain yields with the press so
## penetration stays bounded, resting buckets erode nothing, and stale
## collider identity blocks support but never cutting.

const MAIN_SCENE := "res://scenes/main.tscn"
const SOIL_CONTRACT := "res://resources/models/sy205_soil_contract.json"
const EPOCH := "analytic-test"

var failures: Array[String] = []


class AnalyticStatusController:
	extends TrackedChassisController

	var test_status: Dictionary = {}

	func get_status_snapshot() -> Dictionary:
		return test_status.duplicate(true)

	func raw_world_transform(world_transform: Transform3D) -> Transform3D:
		return world_transform

	func submit_bucket_support_contact(_contact: Dictionary) -> void:
		pass

	func clear_bucket_support_contact() -> void:
		pass


func _init() -> void:
	call_deferred("_run")


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
	var fake := AnalyticStatusController.new()
	excavation._tracked_chassis_controller = fake
	var state := excavation.terrain_world.terrain_state
	var surface_h0 := state.sample_surface_bilinear_at(Vector2.ZERO)
	var dig_joints := [{"name": "boom_joint", "target_velocity_rad_s": -0.4}]

	# A: sustained slow press 鈥?cuts fire every commanded tick, surface follows
	# the edge down, penetration never escapes the working band.
	var queued_press := 0
	var worst_penetration := 0.0
	for i in 12:
		var depth := 0.02 + 0.004 * float(i)
		fake.test_status = _status(state, 200 + i, dig_joints, 0)
		var result := excavation.step_automatic_snapshot_for_test(
			_pose_snapshot(contract, surface_h0 - depth + 0.001, surface_h0 - depth, 0.0, 0.0)
		)
		var batch := result.get("soil_interaction_batch", {}) as Dictionary
		if bool(batch.get("transaction_queued", false)):
			queued_press += 1
		worst_penetration = maxf(worst_penetration, float(batch.get("analytic_penetration_m", 0.0)))
	if queued_press < 10:
		failures.append("sustained press queues cuts every tick (%d/12)" % queued_press)
	if worst_penetration > 0.08 + 0.12:
		failures.append("press penetration stays bounded: %.3f" % worst_penetration)
	var pressed_surface := state.sample_surface_bilinear_at(Vector2.ZERO)
	if pressed_surface >= surface_h0 - 0.01:
		failures.append("terrain yields under sustained press (%.3f -> %.3f)" % [surface_h0, pressed_surface])
	if excavation.soil_state.bucket_volume_m3 > 0.0:
		failures.append("digging must stay decoupled from bucket capacity")

	# B: swing drag 鈥?horizontal slew with an engaged edge keeps cutting along
	# the path even though movement never aligns with the cutting direction.
	excavation.terrain_scheduler.reset_world()
	excavation.soil_state.configure_contract(contract)
	var swing_joints := [{"name": "swing_joint", "target_velocity_rad_s": -0.3}]
	var drag_surface := state.sample_surface_bilinear_at(Vector2.ZERO)
	var queued_drag := 0
	for i in 8:
		fake.test_status = _status(state, 300 + i, swing_joints, 0)
		var result := excavation.step_automatic_snapshot_for_test(
			_pose_snapshot(contract, drag_surface - 0.04, drag_surface - 0.04, 0.05 * float(i), 0.05 * float(i - 1))
		)
		if bool((result.get("soil_interaction_batch", {}) as Dictionary).get("transaction_queued", false)):
			queued_drag += 1
	if queued_drag < 6:
		failures.append("swing drag cuts along the path (%d/8)" % queued_drag)

	# C: resting bucket 鈥?contact without commands or movement erodes nothing.
	excavation.terrain_scheduler.reset_world()
	excavation.soil_state.configure_contract(contract)
	var rest_surface := state.sample_surface_bilinear_at(Vector2.ZERO)
	var volume_before := excavation.soil_state.bucket_volume_m3
	var rested_transactions := 0
	for i in 6:
		fake.test_status = _status(state, 400 + i, [], 0)
		var result := excavation.step_automatic_snapshot_for_test(
			_pose_snapshot(contract, rest_surface - 0.03, rest_surface - 0.03, 0.0, 0.0)
		)
		if bool((result.get("soil_interaction_batch", {}) as Dictionary).get("transaction_queued", false)):
			rested_transactions += 1
	if rested_transactions != 0:
		failures.append("resting bucket must not erode (%d transactions)" % rested_transactions)
	if not is_equal_approx(excavation.soil_state.bucket_volume_m3, volume_before):
		failures.append("resting bucket volume unchanged")

	# D: stale collider identity 鈥?analytic cutting continues, support would
	# not be eligible, and the batch reports the split honestly.
	fake.test_status = _status(state, 500, dig_joints, 999)
	var stale := excavation.step_automatic_snapshot_for_test(
		_pose_snapshot(contract, rest_surface - 0.05, rest_surface - 0.06, 0.0, 0.0)
	)
	var stale_batch := stale.get("soil_interaction_batch", {}) as Dictionary
	if not bool(stale_batch.get("transaction_queued", false)):
		failures.append("stale collider identity must not stop analytic cutting")
	if bool(stale_batch.get("query_identity_valid", true)):
		failures.append("stale identity is reported honestly")

	if failures.is_empty():
		print("analytic_dig_test: PASS")
		scene.queue_free()
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		scene.queue_free()
		quit(1)


func _status(state: TerrainState, tick: int, joints: Array, revision_delta: int) -> Dictionary:
	var query := {
		"valid": true,
		"authority_epoch": EPOCH,
		"physics_tick": tick,
		"motion_sequence": tick,
		"terrain_generation": state.world_generation,
		"terrain_revision": state.terrain_revision + revision_delta,
		"contacts": [],
	}
	return {
		"authority_profile": AuthorityProfile.JOLT_AUTHORITATIVE,
		"authority_epoch": EPOCH,
		"physics_tick": tick,
		"bucket_motion_sequence": tick,
		"bucket_query": query,
		"joints": joints,
	}


func _pose_snapshot(contract: Dictionary, previous_y: float, current_y: float, current_x: float, previous_x: float) -> Dictionary:
	var previous := {}
	var current := {}
	for proxy_name in ["cutting_edge", "top_edge", "opening", "cavity", "rear_support"]:
		var py := previous_y
		var cy := current_y
		var px := previous_x
		var cx := current_x
		if proxy_name == "opening" or proxy_name == "cavity":
			py += 0.42
			cy += 0.42
		elif proxy_name == "rear_support":
			py = 1.0
			cy = 1.0
		previous[proxy_name] = Transform3D(Basis.IDENTITY, Vector3(px, py, 0.0))
		current[proxy_name] = Transform3D(Basis.IDENTITY, Vector3(cx, cy, 0.0))
	return {
		"valid": true,
		"reason": "test",
		"previous": previous,
		"current": current,
		"cutting_direction_world": Vector3(0.0, -0.35, -0.93675).normalized(),
		"opening_normal_world": Vector3.UP,
		"contract": contract,
	}


func _read_json(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	return parsed as Dictionary if parsed is Dictionary else {}


func _fail(message: String) -> void:
	push_error("analytic_dig_test failed: %s" % message)
	quit(1)

class_name SoilParcelPool
extends Node3D

# Authoritative transport stage for excavated soil. Parcels are coarse volume
# carriers spawned from accepted analytic cuts: they fly with inherited
# velocity, can be captured into the bucket cavity (crediting the occupancy
# ledger), pour out on dump/spill under a recapture guard, and settle back
# into the loose heightfield through the existing deposit pipeline.
# Parcels never gate, veto, or modify cutting decisions.

const DEFAULT_BUDGET := 48
const MIN_RADIUS_M := 0.03
const MAX_RADIUS_M := 0.09
const CAPTURE_SPEED_MAX_MPS := 2.0
const CAPTURE_MARGIN_M := 0.04
const SETTLE_DWELL_S := 0.35
const SETTLE_SPEED_MAX_MPS := 0.4
const SETTLE_HEIGHT_M := 0.06
const SETTLE_RETRIES_MAX := 3
const RECATURE_GUARD_S := 1.0
const ABSORB_TIME_S := 0.18
const BARRIER_THICKNESS_M := 0.03
const SPAWN_SPREAD_MPS := 0.6
const EPSILON_M3 := 0.000001

var budget := DEFAULT_BUDGET
var soil_density_kg_m3 := 1600.0
var collision_layer := 1 << 6
var collision_mask := 1
var soil_state: BucketSoilState
var deposit_sequencer: Callable = Callable()
var ground_probe: Callable = Callable()

var _bodies: Array[RigidBody3D] = []
var _records: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()
var _previous_cavity_origin := Vector3.ZERO
var _has_previous_cavity := false
var _bucket_velocity := Vector3.ZERO
var _pending_settle_volume_m3 := 0.0
var _pending_cut_volume_m3 := 0.0
var _pending_cut_origin := Vector3.ZERO
var _pending_cut_velocity := Vector3.ZERO
var _barrier: AnimatableBody3D
var _barrier_layer := 2
var _pending_barrier_extents := Vector3.ZERO


func _ready() -> void:
	_rng.randomize()
	_build_pool()
	if _pending_barrier_extents != Vector3.ZERO:
		_build_barrier(_pending_barrier_extents)


func setup(config: Dictionary) -> void:
	budget = int(config.get("budget", DEFAULT_BUDGET))
	soil_density_kg_m3 = float(config.get("density_kg_m3", 1600.0))
	collision_layer = int(config.get("collision_layer", collision_layer))
	collision_mask = int(config.get("collision_mask", collision_mask))
	_barrier_layer = int(config.get("barrier_layer", collision_mask))
	soil_state = config.get("soil_state", null) as BucketSoilState
	deposit_sequencer = config.get("deposit_sequencer", Callable()) as Callable
	if not is_inside_tree():
		_pending_barrier_extents = Vector3(config.get("barrier_extents", Vector3(0.25, 0.25, 0.35)))
		return
	_build_pool()
	_apply_collision_config()
	configure_barrier_extents(Vector3(config.get("barrier_extents", Vector3(0.25, 0.25, 0.35))))


func configure_barrier_extents(extents: Vector3) -> bool:
	if not extents.is_finite() or extents.x <= 0.0 or extents.y <= 0.0 or extents.z <= 0.0:
		return false
	_pending_barrier_extents = extents
	if is_inside_tree():
		_build_barrier(extents)
	return true


func spawn_from_cut(tooth_world: Vector3, volume_m3: float, inherit_velocity: Vector3) -> void:
	var remaining := maxf(volume_m3, 0.0)
	while remaining > EPSILON_M3:
		var parcel_volume := minf(remaining, _volume_for_radius(MAX_RADIUS_M))
		if not _activate_parcel(parcel_volume, tooth_world, inherit_velocity, false):
			_queue_pending_cut(remaining, tooth_world, inherit_velocity)
			break
		remaining -= parcel_volume


func release_volume(volume_m3: float, origin: Vector3, hint_direction: Vector3) -> float:
	if soil_state == null:
		return 0.0
	# Never debit more ledger volume than the pool can represent. Poured soil
	# cannot consume the bounded cut backlog because every released unit must keep
	# a physical carrier until its terrain transfer commits.
	var representable := float(_available_slot_count()) * _volume_for_radius(MAX_RADIUS_M)
	var released := soil_state.release_poured_volume(minf(volume_m3, representable))
	if released <= EPSILON_M3:
		return 0.0
	var remaining := released
	var activated := 0.0
	while remaining > EPSILON_M3:
		var parcel_volume := minf(remaining, _volume_for_radius(MAX_RADIUS_M))
		if not _activate_parcel(
			parcel_volume,
			origin + Vector3(_rng.randf_range(-0.05, 0.05), 0.0, _rng.randf_range(-0.05, 0.05)),
			hint_direction * 0.5,
			true,
		):
			break
		remaining -= parcel_volume
		activated += parcel_volume
	if remaining > EPSILON_M3:
		# Defensive rollback for an unexpected slot race or activation failure.
		soil_state.credit_captured_volume(remaining)
	return activated


func step_pool(delta: float, cavity_transform: Transform3D, cavity_extents: Vector3) -> void:
	if _barrier != null:
		_barrier.global_transform = cavity_transform
	_update_bucket_velocity(cavity_transform)
	_flush_pending_cut()
	var inverse := cavity_transform.affine_inverse()
	for index in _bodies.size():
		var record := _records[index]
		if not bool(record.get("active", false)):
			continue
		var body := _bodies[index]
		var local := inverse * body.global_position
		var inside := _is_inside_cavity(local, cavity_extents)
		if bool(record.get("guarded", false)):
			record["guard_left_s"] = maxf(float(record.get("guard_left_s", 0.0)) - delta, 0.0)
			if inside:
				record["exited_cavity"] = false
			elif float(record.get("guard_left_s", 0.0)) <= 0.0:
				record["guarded"] = false
				record["exited_cavity"] = true
		if bool(record.get("absorbing", false)):
			var pinned_local := record.get("absorb_local_position", local) as Vector3
			body.global_position = cavity_transform * pinned_local
			_absorb(index, delta)
			continue
		if bool(record.get("settling", false)):
			# Once queued, the parcel keeps its exact sequence/transfer identity
			# until an explicit result or terrain commit rejects it. A local timer
			# cannot safely infer cancellation because a late commit would duplicate
			# the same physical material on the next retry.
			continue
		if _try_capture(index, local, inside):
			continue
		_update_settle(index, body, delta)


func clear_all() -> void:
	for index in _bodies.size():
		_deactivate(index)
	_pending_settle_volume_m3 = 0.0
	_pending_cut_volume_m3 = 0.0
	_has_previous_cavity = false


func active_count() -> int:
	var count := 0
	for record in _records:
		if bool(record.get("active", false)):
			count += 1
	return count


func pending_settle_volume_m3() -> float:
	return _pending_settle_volume_m3


func pending_cut_volume_m3() -> float:
	return _pending_cut_volume_m3


func get_body(index: int) -> RigidBody3D:
	return _bodies[index] if index >= 0 and index < _bodies.size() else null


func get_barrier() -> AnimatableBody3D:
	return _barrier


func notify_deposit_results(results: Variant) -> void:
	if not results is Array:
		return
	for result_value in results:
		if not result_value is Dictionary:
			continue
		var result := result_value as Dictionary
		var sequence := int(result.get("sequence", -1))
		var index := _find_settling_sequence(sequence)
		if index < 0:
			continue
		if not bool(result.get("accepted", false)):
			_reset_settle_for_retry(index, true)
			continue
		var transfer_id := String(result.get("transfer_id", ""))
		var accepted_volume := float(result.get("volume_m3", 0.0))
		if transfer_id.is_empty() or accepted_volume <= EPSILON_M3:
			_reset_settle_for_retry(index, true)
			continue
		var record := _records[index]
		record["deposit_transfer_id"] = transfer_id
		record["accepted_settle_volume_m3"] = accepted_volume


func notify_deposit_commits(committed_ids: Variant, rejected_ids: Variant) -> void:
	var committed: Array = committed_ids if committed_ids is Array else []
	var rejected: Array = rejected_ids if rejected_ids is Array else []
	for index in _records.size():
		var record := _records[index]
		if not bool(record.get("settling", false)):
			continue
		var transfer_id := String(record.get("deposit_transfer_id", ""))
		if transfer_id.is_empty():
			continue
		if rejected.has(transfer_id):
			_reset_settle_for_retry(index, true)
		elif committed.has(transfer_id):
			_commit_settled_volume(index, float(record.get("accepted_settle_volume_m3", 0.0)))


func get_pool_snapshot() -> Dictionary:
	var flying := 0
	var settling := 0
	var guarded := 0
	var volume := 0.0
	for index in _bodies.size():
		var record := _records[index]
		if not bool(record.get("active", false)):
			continue
		volume += float(record.get("volume_m3", 0.0))
		if bool(record.get("settling", false)):
			settling += 1
		else:
			flying += 1
		if bool(record.get("guarded", false)):
			guarded += 1
	return {
		"budget": budget,
		"active": flying + settling,
		"flying": flying,
		"settling": settling,
		"guarded": guarded,
		"volume_m3": volume + _pending_cut_volume_m3,
		"active_volume_m3": volume,
		"pending_cut_volume_m3": _pending_cut_volume_m3,
		"pending_settle_volume_m3": _pending_settle_volume_m3,
	}


func _build_pool() -> void:
	if not _bodies.is_empty():
		return
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 8
	mesh.rings = 4
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#59402e")
	material.roughness = 1.0
	mesh.material = material
	for index in budget:
		var body := RigidBody3D.new()
		body.name = "SoilParcel%02d" % index
		body.collision_layer = collision_layer
		body.collision_mask = collision_mask
		body.continuous_cd = true
		body.freeze = true
		body.visible = false
		body.can_sleep = true
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = mesh
		body.add_child(mesh_instance)
		var collider := CollisionShape3D.new()
		var shape := SphereShape3D.new()
		collider.shape = shape
		body.add_child(collider)
		add_child(body)
		_bodies.append(body)
		_records.append({"active": false})


func _apply_collision_config() -> void:
	# The production owner adds this node to the tree before calling setup(),
	# so _ready() may have built the pool with defaults already. Always retarget
	# existing bodies to the selected model layers after configuration.
	for body in _bodies:
		body.collision_layer = collision_layer
		body.collision_mask = collision_mask


func _build_barrier(extents: Vector3) -> void:
	var t := BARRIER_THICKNESS_M
	if _barrier == null:
		_barrier = AnimatableBody3D.new()
		_barrier.name = "BucketSoilBarrier"
		# Open-mouthed shell approximation in cavity-local space: floor at -Y,
		# back plate on the +Z (rear-support) side, side plates at ±X, mouth (+Y)
		# left open so dump/spill pours through freely. Machine layer only: no
		# other system masks machine, so support probes and sweeper queries are
		# unaffected.
		_barrier.collision_layer = _barrier_layer
		_barrier.collision_mask = 0
		_barrier.sync_to_physics = true
		add_child(_barrier)
		# Parked far below the world until the first cavity pose arrives; an
		# invisible box at the origin would otherwise block settling parcels.
		_barrier.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, -10000.0, 0.0))
	var wall_height := 2.0 * extents.y + 2.0 * (t + MAX_RADIUS_M)
	var plates := [
		# Adjacent plates overlap by one thickness at every closed seam. Exact
		# edge-to-edge boxes let small fast spheres escape through a solver seam
		# where gravity presses them into the floor/wall corner.
		{"pos": Vector3(0.0, -extents.y, 0.0), "size": Vector3(2.0 * extents.x + 2.0 * t, t, 2.0 * extents.z + 2.0 * t)},
		{"pos": Vector3(0.0, 0.0, extents.z), "size": Vector3(2.0 * extents.x + 2.0 * t, wall_height, t)},
		{"pos": Vector3(-extents.x, 0.0, 0.0), "size": Vector3(t, wall_height, 2.0 * extents.z + 2.0 * t)},
		{"pos": Vector3(extents.x, 0.0, 0.0), "size": Vector3(t, wall_height, 2.0 * extents.z + 2.0 * t)},
	]
	while _barrier.get_child_count() < plates.size():
		var collider := CollisionShape3D.new()
		var box := BoxShape3D.new()
		collider.shape = box
		_barrier.add_child(collider)
	for index in plates.size():
		var plate := plates[index] as Dictionary
		var collider := _barrier.get_child(index) as CollisionShape3D
		(collider.shape as BoxShape3D).size = plate["size"] as Vector3
		collider.position = plate["pos"] as Vector3


func _activate_parcel(
	volume_m3: float,
	position: Vector3,
	velocity: Vector3,
	guarded: bool,
) -> bool:
	var index := _acquire_index()
	if index < 0:
		return false
	var radius := _radius_for_volume(volume_m3)
	var body := _bodies[index]
	var scale_factor := radius
	body.global_position = position
	body.scale = Vector3.ONE
	body.mass = maxf(volume_m3 * soil_density_kg_m3, 0.01)
	var spread := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(0.3, 1.2), _rng.randf_range(-1.0, 1.0)) * SPAWN_SPREAD_MPS
	body.linear_velocity = velocity + spread
	body.freeze = false
	body.visible = true
	var mesh_instance := body.get_child(0) as MeshInstance3D
	var collider := body.get_child(1) as CollisionShape3D
	mesh_instance.scale = Vector3.ONE * scale_factor
	(collider.shape as SphereShape3D).radius = scale_factor
	_records[index] = {
		"active": true,
		"volume_m3": volume_m3,
		"radius_m": scale_factor,
		"dwell_s": 0.0,
		"settling": false,
		"retries": 0,
		"guarded": guarded,
		"guard_left_s": RECATURE_GUARD_S if guarded else 0.0,
		"exited_cavity": false,
	}
	return true


func _available_slot_count() -> int:
	var available := 0
	var cap := mini(budget, _records.size())
	for index in cap:
		if not bool(_records[index].get("active", false)):
			available += 1
	return available


func _queue_pending_cut(volume_m3: float, origin: Vector3, velocity: Vector3) -> void:
	var added := maxf(volume_m3, 0.0)
	if added <= EPSILON_M3:
		return
	var combined := _pending_cut_volume_m3 + added
	if _pending_cut_volume_m3 <= EPSILON_M3:
		_pending_cut_origin = origin
		_pending_cut_velocity = velocity
	else:
		_pending_cut_origin = (
			_pending_cut_origin * _pending_cut_volume_m3 + origin * added
		) / combined
		_pending_cut_velocity = (
			_pending_cut_velocity * _pending_cut_volume_m3 + velocity * added
		) / combined
	_pending_cut_volume_m3 = combined


func _flush_pending_cut() -> void:
	while _pending_cut_volume_m3 > EPSILON_M3:
		var parcel_volume := minf(_pending_cut_volume_m3, _volume_for_radius(MAX_RADIUS_M))
		if not _activate_parcel(
			parcel_volume,
			_pending_cut_origin,
			_pending_cut_velocity,
			false,
		):
			return
		_pending_cut_volume_m3 = maxf(_pending_cut_volume_m3 - parcel_volume, 0.0)


func _acquire_index() -> int:
	var cap := mini(budget, _bodies.size())
	for index in cap:
		if not bool(_records[index].get("active", false)):
			return index
	return -1


func _deactivate(index: int) -> void:
	var body := _bodies[index]
	body.freeze = true
	body.visible = false
	body.linear_velocity = Vector3.ZERO
	_records[index] = {"active": false}


func _try_capture(index: int, local_position: Vector3, inside: bool) -> bool:
	if not inside or soil_state == null:
		return false
	var record := _records[index]
	if bool(record.get("guarded", false)):
		return false
	if bool(record.get("capture_blocked", false)):
		if soil_state.free_capacity_m3() <= EPSILON_M3:
			return false
		record["capture_blocked"] = false
	var body := _bodies[index]
	if (body.linear_velocity - _bucket_velocity).length() > CAPTURE_SPEED_MAX_MPS:
		return false
	# Capture starts a progressive absorption instead of teleporting the
	# volume: the chunk visibly melts into the load while the ledger fills.
	# If capacity stalls mid-absorption the remainder stays physical.
	record["absorbing"] = true
	record["volume_initial"] = float(record.get("volume_m3", 0.0))
	record["absorb_left"] = float(record["volume_initial"])
	record["absorb_local_position"] = local_position
	body.freeze = true
	body.linear_velocity = Vector3.ZERO
	return true


func _absorb(index: int, delta: float) -> void:
	var record := _records[index]
	var initial := maxf(float(record.get("volume_initial", 0.0)), EPSILON_M3)
	var left := float(record.get("absorb_left", 0.0))
	var chunk := minf(left, initial * delta / ABSORB_TIME_S)
	var credited := soil_state.credit_captured_volume(chunk)
	left -= credited
	record["absorb_left"] = left
	record["volume_m3"] = left
	_bodies[index].mass = maxf(left * soil_density_kg_m3, 0.01)
	if credited <= EPSILON_M3 and chunk > EPSILON_M3:
		# Capacity stalled: stop absorbing, keep the remainder as visible heap.
		record["absorbing"] = false
		record["capture_blocked"] = true
		record.erase("absorb_local_position")
		_set_parcel_scale(index, float(record.get("radius_m", MIN_RADIUS_M)), pow(maxf(left / initial, 0.001), 1.0 / 3.0))
		_bodies[index].freeze = false
		_bodies[index].linear_velocity = _bucket_velocity
		return
	if left <= EPSILON_M3:
		_deactivate(index)
		return
	_set_parcel_scale(index, float(record.get("radius_m", MIN_RADIUS_M)), pow(maxf(left / initial, 0.05), 1.0 / 3.0))


func _set_parcel_scale(index: int, base_radius: float, factor: float) -> void:
	var body := _bodies[index]
	var mesh_instance := body.get_child(0) as MeshInstance3D
	var collider := body.get_child(1) as CollisionShape3D
	mesh_instance.scale = Vector3.ONE * base_radius * factor
	(collider.shape as SphereShape3D).radius = maxf(base_radius * factor, 0.01)


func _update_settle(index: int, body: RigidBody3D, delta: float) -> void:
	var record := _records[index]
	if body.linear_velocity.length() > SETTLE_SPEED_MAX_MPS or not _is_grounded(body):
		record["dwell_s"] = 0.0
		return
	record["dwell_s"] = float(record.get("dwell_s", 0.0)) + delta
	if float(record["dwell_s"]) < SETTLE_DWELL_S:
		return
	if _queue_settle_deposit(index, body):
		return
	var retries := int(record.get("retries", 0)) + 1
	record["retries"] = mini(retries, SETTLE_RETRIES_MAX)
	record["dwell_s"] = 0.0


func _queue_settle_deposit(index: int, body: RigidBody3D) -> bool:
	if soil_state == null or not deposit_sequencer.is_valid():
		return false
	var record := _records[index]
	var center := Vector2(body.global_position.x, body.global_position.z)
	var sequence := int(deposit_sequencer.call())
	if not soil_state.queue_parcel_deposit_volume(sequence, Vector3(center.x, body.global_position.y, center.y), float(record.get("volume_m3", 0.0))):
		return false
	record["settling"] = true
	record["settle_sequence"] = sequence
	record["settled_ticks"] = 0
	body.freeze = true
	_pending_settle_volume_m3 += float(record["volume_m3"])
	return true


func _find_settling_sequence(sequence: int) -> int:
	for index in _records.size():
		var record := _records[index]
		if bool(record.get("settling", false)) and int(record.get("settle_sequence", -1)) == sequence:
			return index
	return -1


func _reset_settle_for_retry(index: int, count_retry: bool) -> void:
	var record := _records[index]
	var volume := float(record.get("volume_m3", 0.0))
	_pending_settle_volume_m3 = maxf(_pending_settle_volume_m3 - volume, 0.0)
	record["settling"] = false
	record["settled_ticks"] = 0
	record["dwell_s"] = 0.0
	record.erase("settle_sequence")
	record.erase("deposit_transfer_id")
	record.erase("accepted_settle_volume_m3")
	if count_retry:
		record["retries"] = int(record.get("retries", 0)) + 1
	_bodies[index].freeze = false
	_bodies[index].linear_velocity = Vector3.ZERO


func _commit_settled_volume(index: int, accepted_volume_m3: float) -> void:
	var record := _records[index]
	var original_volume := float(record.get("volume_m3", 0.0))
	_pending_settle_volume_m3 = maxf(_pending_settle_volume_m3 - original_volume, 0.0)
	var remaining := maxf(original_volume - maxf(accepted_volume_m3, 0.0), 0.0)
	if remaining <= EPSILON_M3:
		_deactivate(index)
		return
	record["volume_m3"] = remaining
	record["radius_m"] = _radius_for_volume(remaining)
	record["settling"] = false
	record["settled_ticks"] = 0
	record["dwell_s"] = 0.0
	record.erase("settle_sequence")
	record.erase("deposit_transfer_id")
	record.erase("accepted_settle_volume_m3")
	_set_parcel_scale(index, float(record["radius_m"]), 1.0)
	_bodies[index].mass = maxf(remaining * soil_density_kg_m3, 0.01)
	_bodies[index].freeze = false
	_bodies[index].linear_velocity = Vector3.ZERO


func _is_grounded(body: RigidBody3D) -> bool:
	if ground_probe.is_valid():
		return bool(ground_probe.call(body))
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var query := PhysicsRayQueryParameters3D.create(
		body.global_position,
		body.global_position + Vector3.DOWN * (SETTLE_HEIGHT_M),
		1
	)
	return not space.intersect_ray(query).is_empty()


func _is_inside_cavity(local: Vector3, extents: Vector3) -> bool:
	return (
		absf(local.x) <= extents.x + CAPTURE_MARGIN_M
		and absf(local.y) <= extents.y + CAPTURE_MARGIN_M
		and absf(local.z) <= extents.z + CAPTURE_MARGIN_M
	)


func _update_bucket_velocity(cavity_transform: Transform3D) -> void:
	var origin := cavity_transform.origin
	if _has_previous_cavity:
		_bucket_velocity = (origin - _previous_cavity_origin) / maxf(get_physics_process_delta_time(), 0.0001)
	else:
		_bucket_velocity = Vector3.ZERO
	_previous_cavity_origin = origin
	_has_previous_cavity = true


static func _radius_for_volume(volume_m3: float) -> float:
	var clamped := clampf(volume_m3, EPSILON_M3, _volume_for_radius(MAX_RADIUS_M))
	return clampf(pow(clamped * 3.0 / (4.0 * PI), 1.0 / 3.0), MIN_RADIUS_M, MAX_RADIUS_M)


static func _volume_for_radius(radius_m: float) -> float:
	return (4.0 / 3.0) * PI * pow(radius_m, 3.0)

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
const SETTLE_STALE_TICKS := 12
const RECATURE_GUARD_S := 1.0
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

func _ready() -> void:
	_rng.randomize()
	_build_pool()


func setup(config: Dictionary) -> void:
	budget = int(config.get("budget", DEFAULT_BUDGET))
	soil_density_kg_m3 = float(config.get("density_kg_m3", 1600.0))
	collision_layer = int(config.get("collision_layer", collision_layer))
	collision_mask = int(config.get("collision_mask", collision_mask))
	soil_state = config.get("soil_state", null) as BucketSoilState
	deposit_sequencer = config.get("deposit_sequencer", Callable()) as Callable
	if not is_inside_tree():
		return
	_build_pool()


func spawn_from_cut(tooth_world: Vector3, volume_m3: float, inherit_velocity: Vector3) -> void:
	var remaining := maxf(volume_m3, 0.0)
	while remaining > EPSILON_M3:
		var parcel_volume := minf(remaining, _volume_for_radius(MAX_RADIUS_M))
		remaining -= parcel_volume
		_activate_parcel(parcel_volume, tooth_world, inherit_velocity, false)


func release_volume(volume_m3: float, origin: Vector3, hint_direction: Vector3) -> float:
	if soil_state == null:
		return 0.0
	var released := soil_state.release_poured_volume(volume_m3)
	if released <= EPSILON_M3:
		return 0.0
	var remaining := released
	while remaining > EPSILON_M3:
		var parcel_volume := minf(remaining, _volume_for_radius(MAX_RADIUS_M))
		remaining -= parcel_volume
		_activate_parcel(parcel_volume, origin + Vector3(_rng.randf_range(-0.05, 0.05), 0.0, _rng.randf_range(-0.05, 0.05)), hint_direction * 0.5, true)
	return released


func step_pool(delta: float, cavity_transform: Transform3D, cavity_extents: Vector3) -> void:
	_update_bucket_velocity(cavity_transform)
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
		if bool(record.get("settling", false)):
			record["settled_ticks"] = int(record.get("settled_ticks", 0)) + 1
			if int(record["settled_ticks"]) > SETTLE_STALE_TICKS:
				# Aggregate deposit volume may have been consumed by another
				# source; force-recycle so a parcel can never wedge the pool.
				_pending_settle_volume_m3 = maxf(_pending_settle_volume_m3 - float(record.get("volume_m3", 0.0)), 0.0)
				_deactivate(index)
			continue
		if _try_capture(index, local, inside):
			continue
		_update_settle(index, body, delta)


func clear_all() -> void:
	for index in _bodies.size():
		_deactivate(index)
	_pending_settle_volume_m3 = 0.0
	_has_previous_cavity = false


func active_count() -> int:
	var count := 0
	for record in _records:
		if bool(record.get("active", false)):
			count += 1
	return count


func pending_settle_volume_m3() -> float:
	return _pending_settle_volume_m3


func get_body(index: int) -> RigidBody3D:
	return _bodies[index] if index >= 0 and index < _bodies.size() else null


func notify_deposit_accepted(volume_m3: float) -> void:
	# The ledger reports accepted deposit volume per tick; consume it against
	# pending settle requests in spawn order and recycle satisfied parcels.
	var remaining := maxf(volume_m3, 0.0)
	if remaining <= EPSILON_M3:
		return
	for index in _bodies.size():
		if remaining <= EPSILON_M3:
			return
		var record := _records[index]
		if not bool(record.get("settling", false)):
			continue
		var volume := float(record.get("volume_m3", 0.0))
		remaining -= volume
		_pending_settle_volume_m3 = maxf(_pending_settle_volume_m3 - volume, 0.0)
		_deactivate(index)


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
		"volume_m3": volume,
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


func _activate_parcel(volume_m3: float, position: Vector3, velocity: Vector3, guarded: bool) -> void:
	var index := _acquire_index()
	if index < 0:
		return
	var radius := _radius_for_volume(volume_m3)
	var body := _bodies[index]
	var scale_factor := radius
	body.global_position = position
	body.scale = Vector3.ONE
	body.mass = maxf(volume_m3 * soil_density_kg_m3, 0.01)
	var spread := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-0.2, 0.6), _rng.randf_range(-1.0, 1.0)) * SPAWN_SPREAD_MPS
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
		"dwell_s": 0.0,
		"settling": false,
		"retries": 0,
		"guarded": guarded,
		"guard_left_s": RECATURE_GUARD_S if guarded else 0.0,
		"exited_cavity": false,
	}


func _acquire_index() -> int:
	var cap := mini(budget, _bodies.size())
	var active := 0
	for index in _records.size():
		if bool(_records[index].get("active", false)):
			active += 1
	if active >= cap:
		# Budget exhausted: steal the oldest settling parcel, else the oldest
		# flying one, so repeated digging never grows the pool.
		for index in _records.size():
			if bool(_records[index].get("settling", false)):
				_deactivate(index)
				return index
		if _records.is_empty():
			return -1
		_deactivate(0)
		return 0
	for index in _records.size():
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
	var body := _bodies[index]
	if (body.linear_velocity - _bucket_velocity).length() > CAPTURE_SPEED_MAX_MPS:
		return false
	var volume := float(record.get("volume_m3", 0.0))
	var credited := soil_state.credit_captured_volume(volume)
	if credited <= EPSILON_M3:
		return false
	if credited >= volume - EPSILON_M3:
		_deactivate(index)
	else:
		record["volume_m3"] = volume - credited
	return true


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
	record["retries"] = retries
	record["dwell_s"] = 0.0
	if retries >= SETTLE_RETRIES_MAX:
		_deactivate(index)


func _queue_settle_deposit(index: int, body: RigidBody3D) -> bool:
	if soil_state == null or not deposit_sequencer.is_valid():
		return false
	var record := _records[index]
	var center := Vector2(body.global_position.x, body.global_position.z)
	var sequence := int(deposit_sequencer.call())
	if not soil_state.queue_deposit_volume(sequence, Vector3(center.x, body.global_position.y, center.y), float(record.get("volume_m3", 0.0))):
		return false
	record["settling"] = true
	_pending_settle_volume_m3 += float(record["volume_m3"])
	return true


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

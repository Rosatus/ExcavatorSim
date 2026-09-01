class_name ActiveSoilPatch
extends RefCounted

## Deterministic bounded CPU reference for visually active soil. Representative
## count is a quality choice; aggregate volume remains exact and is settled
## through ActiveSoilPersistentField's selected shadow or product scheduler.

const SCHEMA_VERSION := "active-soil-patch-v1"
const MIN_VOLUME_M3 := 0.000001
const GRAVITY_M_S2 := 9.81
const MAX_TICK_SAMPLES := 240
const MAX_LOGICAL_AGGREGATES := 256
const QUALITY_PROFILES := {
	"low": {
		"window_m": 3.0,
		"max_representatives": 320,
		"target_volume_m3": 0.0025,
		"substeps": 1,
		"max_neighbors": 6,
		"max_settlements": 6,
		"spatial_cell_m": 0.22,
	},
	"balanced": {
		"window_m": 4.0,
		"max_representatives": 800,
		"target_volume_m3": 0.0014,
		"substeps": 1,
		"max_neighbors": 10,
		"max_settlements": 12,
		"spatial_cell_m": 0.18,
	},
	"high": {
		"window_m": 5.0,
		"max_representatives": 1600,
		"target_volume_m3": 0.0008,
		"substeps": 1,
		"max_neighbors": 14,
		"max_settlements": 18,
		"spatial_cell_m": 0.15,
	},
}
const MATERIAL_RESPONSE := {
	"loose": {
		"friction": 0.42,
		"restitution": 0.05,
		"linear_damping": 0.14,
		"cohesion": 0.05,
		"neighbor_stiffness": 0.48,
		"sleep_speed": 0.12,
		"settle_delay_s": 0.85,
		"angle_of_repose_degrees": 34.0,
	},
	"compact": {
		"friction": 0.68,
		"restitution": 0.02,
		"linear_damping": 0.32,
		"cohesion": 0.18,
		"neighbor_stiffness": 0.65,
		"sleep_speed": 0.10,
		"settle_delay_s": 0.55,
		"angle_of_repose_degrees": 40.0,
	},
	"sand": {
		"friction": 0.30,
		"restitution": 0.03,
		"linear_damping": 0.08,
		"cohesion": 0.0,
		"neighbor_stiffness": 0.40,
		"sleep_speed": 0.15,
		"settle_delay_s": 0.7,
		"angle_of_repose_degrees": 30.0,
	},
	"damp": {
		"friction": 0.58,
		"restitution": 0.01,
		"linear_damping": 0.38,
		"cohesion": 0.42,
		"neighbor_stiffness": 0.58,
		"sleep_speed": 0.09,
		"settle_delay_s": 1.1,
		"angle_of_repose_degrees": 43.0,
	},
}

var persistent_field := ActiveSoilPersistentField.new()
var quality_profile := "balanced"
var material_preset := "loose"
var generation := -1

var _profile: Dictionary = QUALITY_PROFILES["balanced"]
var _material: Dictionary = MATERIAL_RESPONSE["loose"]
## Authoritative, quality-independent mobile soil aggregates. Their volume,
## compartment and trajectory are material truth.
var _representatives: Array[Dictionary] = []
## Disposable visual samples derived from logical aggregates. Quality changes
## may rebuild or remove these without changing any material volume.
var _visual_representatives: Array[Dictionary] = []
var _aggregate_volume: Dictionary = {}
var _aggregate_sequence := 0
var _representative_sequence := 0
var _focus_world := Vector3.ZERO
var _last_tick_us := 0
var _tick_samples_us := PackedInt64Array()
var _injected_volume_m3 := 0.0
var _received_released_volume_m3 := 0.0
var _exported_bucket_volume_m3 := 0.0
var _settled_volume_m3 := 0.0
var _rejected_volume_m3 := 0.0
var _evicted_representatives := 0
var _settlement_events: Array[Dictionary] = []
var _predebited_reservations: Dictionary = {}


func configure(source_snapshot: Dictionary, requested_quality: String = "balanced", requested_material: String = "loose") -> bool:
	clear(false)
	if not QUALITY_PROFILES.has(requested_quality) or not MATERIAL_RESPONSE.has(requested_material):
		return false
	if not persistent_field.configure(source_snapshot, requested_material):
		return false
	quality_profile = requested_quality
	material_preset = requested_material
	_profile = (QUALITY_PROFILES[quality_profile] as Dictionary).duplicate(true)
	_material = (MATERIAL_RESPONSE[material_preset] as Dictionary).duplicate(true)
	generation = int(source_snapshot.get("world_generation", -1))
	return generation >= 0


func configure_product(
	state: TerrainState,
	product_scheduler: TerrainCommitScheduler,
	requested_quality: String = "balanced",
	requested_material: String = "loose"
) -> bool:
	clear(false)
	if not QUALITY_PROFILES.has(requested_quality) or not MATERIAL_RESPONSE.has(requested_material):
		return false
	if not persistent_field.configure_product(state, product_scheduler, requested_material):
		return false
	quality_profile = requested_quality
	material_preset = requested_material
	_profile = (QUALITY_PROFILES[quality_profile] as Dictionary).duplicate(true)
	_material = (MATERIAL_RESPONSE[material_preset] as Dictionary).duplicate(true)
	generation = state.world_generation
	return generation >= 0


func clear(settle_active: bool = false) -> void:
	if settle_active and persistent_field.terrain_state != null:
		flush_all()
	_representatives.clear()
	_visual_representatives.clear()
	_aggregate_volume.clear()
	_aggregate_sequence = 0
	_representative_sequence = 0
	_focus_world = Vector3.ZERO
	_last_tick_us = 0
	_tick_samples_us = PackedInt64Array()
	_injected_volume_m3 = 0.0
	_received_released_volume_m3 = 0.0
	_exported_bucket_volume_m3 = 0.0
	_settled_volume_m3 = 0.0
	_rejected_volume_m3 = 0.0
	_evicted_representatives = 0
	_settlement_events.clear()
	_predebited_reservations.clear()
	generation = -1
	persistent_field.clear()


func set_quality_profile(requested_quality: String) -> bool:
	if not QUALITY_PROFILES.has(requested_quality):
		return false
	quality_profile = requested_quality
	_profile = (QUALITY_PROFILES[quality_profile] as Dictionary).duplicate(true)
	_rebuild_visual_representatives()
	return true


func inject_cut_event(event: Dictionary, aggregate_hint: String = "") -> Dictionary:
	return inject_tool_volume(event, aggregate_hint)


func inject_tool_volume(event: Dictionary, aggregate_hint: String = "") -> Dictionary:
	return _inject_volume(event, aggregate_hint, true, "active")


func inject_released_volume(event: Dictionary, aggregate_hint: String = "") -> Dictionary:
	return _inject_volume(event, aggregate_hint, false, "released")


## Reserves logical aggregate capacity before the source authority is debited.
## The reservation owns no soil volume and can be cancelled without rollback.
func reserve_predebited_volume(event: Dictionary, aggregate_hint: String, compartment: String = "active") -> Dictionary:
	var requested_volume := float(event.get("volume_m3", 0.0))
	var tooth_world := event.get("tooth_world", Vector3.ZERO) as Vector3
	if (
		generation < 0
		or aggregate_hint.is_empty()
		or compartment not in ["active", "released"]
		or requested_volume <= MIN_VOLUME_M3
		or not tooth_world.is_finite()
		or _aggregate_volume.has(aggregate_hint)
		or _predebited_reservations.has(aggregate_hint)
		or not can_accept_volume(requested_volume)
	):
		return {"accepted": false, "reason": "reservation_rejected"}
	_predebited_reservations[aggregate_hint] = {
		"event": event.duplicate(true),
		"compartment": compartment,
	}
	return {"accepted": true, "reason": "reserved", "reservation_id": aggregate_hint, "volume_m3": requested_volume}


func reserve_predebited_tool_volume(event: Dictionary, aggregate_hint: String) -> Dictionary:
	return reserve_predebited_volume(event, aggregate_hint, "active")


func cancel_predebited_volume(reservation_id: String) -> bool:
	return _predebited_reservations.erase(reservation_id)


func cancel_predebited_tool_volume(reservation_id: String) -> bool:
	return cancel_predebited_volume(reservation_id)


func commit_predebited_volume(reservation_id: String) -> Dictionary:
	if not _predebited_reservations.has(reservation_id):
		return {"accepted": false, "volume_m3": 0.0, "reason": "reservation_missing"}
	var reservation := (_predebited_reservations[reservation_id] as Dictionary).duplicate(true)
	_predebited_reservations.erase(reservation_id)
	var event := (reservation.get("event", {}) as Dictionary).duplicate(true)
	var compartment := String(reservation.get("compartment", "active"))
	var result := _inject_volume(event, reservation_id, false, compartment, true)
	if bool(result.get("accepted", false)) and compartment == "active":
		var committed := float(result.get("volume_m3", 0.0))
		_received_released_volume_m3 = maxf(0.0, _received_released_volume_m3 - committed)
		_injected_volume_m3 += committed
		result["reason"] = "predebited_activated"
	return result


func commit_predebited_tool_volume(reservation_id: String) -> Dictionary:
	return commit_predebited_volume(reservation_id)


func can_accept_volume(requested_volume_m3: float) -> bool:
	return (
		generation >= 0
		and requested_volume_m3 > MIN_VOLUME_M3
		and _representatives.size() + _predebited_reservations.size() < MAX_LOGICAL_AGGREGATES
	)


func extract_contained_volume(maximum_volume_m3: float) -> Dictionary:
	var remaining := maxf(maximum_volume_m3, 0.0)
	var extracted := 0.0
	var weighted_position := Vector3.ZERO
	var weighted_velocity := Vector3.ZERO
	for index in range(_representatives.size() - 1, -1, -1):
		if remaining <= MIN_VOLUME_M3:
			break
		var rep := _representatives[index]
		if not bool(rep["contained"]):
			continue
		var available := float(rep["volume_m3"])
		var moved := minf(available, remaining)
		weighted_position += (rep["position"] as Vector3) * moved
		weighted_velocity += (rep["velocity"] as Vector3) * moved
		extracted += moved
		remaining -= moved
		if moved >= available - MIN_VOLUME_M3:
			_remove_representative(index)
		else:
			rep["volume_m3"] = available - moved
			rep["radius_m"] = _radius_for_volume(float(rep["volume_m3"]))
			_representatives[index] = rep
			var aggregate_id := String(rep["aggregate_id"])
			_aggregate_volume[aggregate_id] = maxf(0.0, float(_aggregate_volume.get(aggregate_id, available)) - moved)
	_exported_bucket_volume_m3 += extracted
	_rebuild_visual_representatives()
	return {
		"accepted": extracted > MIN_VOLUME_M3,
		"volume_m3": extracted,
		"origin_world": weighted_position / extracted if extracted > MIN_VOLUME_M3 else Vector3.ZERO,
		"velocity_world": weighted_velocity / extracted if extracted > MIN_VOLUME_M3 else Vector3.ZERO,
		"reason": "extracted" if extracted > MIN_VOLUME_M3 else "no_contained_volume",
	}


func extract_scoop_volume(
	maximum_volume_m3: float,
	intake_regions: Array,
	intake_margin_m: float = 0.18,
) -> Dictionary:
	var requested := maxf(maximum_volume_m3, 0.0)
	var extracted := 0.0
	var weighted_position := Vector3.ZERO
	var weighted_velocity := Vector3.ZERO
	for index in range(_representatives.size() - 1, -1, -1):
		if extracted >= requested - MIN_VOLUME_M3:
			break
		var rep := _representatives[index]
		if String(rep.get("compartment", "active")) != "active":
			continue
		var near_intake := false
		for region_value in intake_regions:
			var region := region_value as Dictionary
			if String(region.get("region_id", "")) not in [
				"teeth_main_edge", "inner_shell", "opening",
			]:
				continue
			if _point_inside_region(
				rep["position"] as Vector3,
				float(rep["radius_m"]) + maxf(intake_margin_m, 0.0),
				region,
			):
				near_intake = true
				break
		if not near_intake:
			continue
		var available := float(rep["volume_m3"])
		var moved := minf(available, requested - extracted)
		if moved <= MIN_VOLUME_M3:
			continue
		extracted += moved
		weighted_position += (rep["position"] as Vector3) * moved
		weighted_velocity += (rep["velocity"] as Vector3) * moved
		if moved >= available - MIN_VOLUME_M3:
			_remove_representative(index)
		else:
			rep["volume_m3"] = available - moved
			rep["radius_m"] = _radius_for_volume(float(rep["volume_m3"]))
			_aggregate_volume[String(rep["aggregate_id"])] = maxf(
				0.0,
				float(_aggregate_volume.get(String(rep["aggregate_id"]), 0.0)) - moved,
			)
			_representatives[index] = rep
	_exported_bucket_volume_m3 += extracted
	_rebuild_visual_representatives()
	return {
		"accepted": extracted > MIN_VOLUME_M3,
		"volume_m3": extracted,
		"origin_world": weighted_position / extracted if extracted > MIN_VOLUME_M3 else Vector3.ZERO,
		"velocity_world": weighted_velocity / extracted if extracted > MIN_VOLUME_M3 else Vector3.ZERO,
		"reason": "scoop_flux" if extracted > MIN_VOLUME_M3 else "no_local_active_volume",
	}


## Failure-only compensation for a bucket destination that accepted less than
## its preflight amount. It restores exact logical volume without touching the
## persistent heightfield or producing a visual authority event.
func restore_extracted_volume(extraction: Dictionary, restored_volume_m3: float, aggregate_hint: String) -> bool:
	var restored := maxf(restored_volume_m3, 0.0)
	if restored <= MIN_VOLUME_M3:
		return true
	var origin := extraction.get("origin_world", Vector3.ZERO) as Vector3
	var velocity := extraction.get("velocity_world", Vector3.ZERO) as Vector3
	var injection := _inject_volume({
		"center": Vector2(origin.x, origin.z),
		"tooth_world": origin,
		"tooth_velocity": velocity,
		"volume_m3": restored,
	}, aggregate_hint, false, "active")
	if bool(injection.get("accepted", false)):
		var committed := float(injection.get("volume_m3", 0.0))
		_received_released_volume_m3 = maxf(0.0, _received_released_volume_m3 - committed)
		_exported_bucket_volume_m3 = maxf(0.0, _exported_bucket_volume_m3 - committed)
		return absf(committed - restored) <= MIN_VOLUME_M3
	# A partial extraction can leave the logical store at its hard count limit.
	# Merge back into an existing active aggregate in that exceptional case.
	for index in range(_representatives.size() - 1, -1, -1):
		var rep := _representatives[index]
		if String(rep.get("compartment", "active")) != "active":
			continue
		var aggregate_id := String(rep["aggregate_id"])
		rep["volume_m3"] = float(rep["volume_m3"]) + restored
		rep["radius_m"] = _radius_for_volume(float(rep["volume_m3"]))
		_representatives[index] = rep
		_aggregate_volume[aggregate_id] = float(_aggregate_volume.get(aggregate_id, 0.0)) + restored
		_exported_bucket_volume_m3 = maxf(0.0, _exported_bucket_volume_m3 - restored)
		_rebuild_visual_representatives()
		return true
	return false


func consume_settlement_events() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event in _settlement_events:
		result.append(event.duplicate(true))
	_settlement_events.clear()
	return result


func _inject_volume(event: Dictionary, aggregate_hint: String, debit_persistent: bool, compartment: String, reserved_slot: bool = false) -> Dictionary:
	var requested_volume := float(event.get("volume_m3", 0.0))
	var tooth_world := event.get("tooth_world", Vector3.ZERO) as Vector3
	var center_xz_value: Variant = event.get("center", Vector2(tooth_world.x, tooth_world.z))
	var center_xz := center_xz_value as Vector2 if center_xz_value is Vector2 else Vector2(tooth_world.x, tooth_world.z)
	var rejected := {"accepted": false, "volume_m3": 0.0, "reason": "invalid_event"}
	if generation < 0 or requested_volume <= MIN_VOLUME_M3 or not tooth_world.is_finite():
		_rejected_volume_m3 += maxf(requested_volume, 0.0)
		return rejected
	if not reserved_slot and _representatives.size() >= MAX_LOGICAL_AGGREGATES:
		rejected["reason"] = "logical_aggregate_budget"
		_rejected_volume_m3 += requested_volume
		return rejected
	var aggregate_id := aggregate_hint
	if aggregate_id.is_empty():
		aggregate_id = "%d:%d" % [generation, _aggregate_sequence]
	_aggregate_sequence += 1
	if _aggregate_volume.has(aggregate_id):
		rejected["reason"] = "duplicate_aggregate"
		_rejected_volume_m3 += requested_volume
		return rejected
	var activation_radius := clampf(sqrt(requested_volume / PI) * 1.9, 0.22, 0.58)
	var committed_volume := requested_volume
	var stable_source_volume := 0.0
	var loose_source_volume := 0.0
	if debit_persistent:
		var activation := persistent_field.activate_volume(center_xz, requested_volume, activation_radius, aggregate_id)
		if not bool(activation.get("accepted", false)):
			rejected["reason"] = String(activation.get("reason", "activation_rejected"))
			_rejected_volume_m3 += requested_volume
			return rejected
		committed_volume = float(activation.get("committed_volume_m3", 0.0))
		stable_source_volume = float(activation.get("stable_volume_m3", 0.0))
		loose_source_volume = float(activation.get("loose_volume_m3", 0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s|%s|%d" % [aggregate_id, material_preset, generation])
	var base_radius := _radius_for_volume(committed_volume)
	var surface := persistent_field.sample_surface_at(center_xz)
	var start_y := maxf(tooth_world.y, surface + base_radius) if not is_nan(surface) else tooth_world.y
	var source_velocity := event.get("tooth_velocity", Vector3.ZERO) as Vector3
	if source_velocity.length() > 4.0:
		source_velocity = source_velocity.normalized() * 4.0
	_representatives.append({
		"id": _representative_sequence,
		"aggregate_id": aggregate_id,
		"position": Vector3(center_xz.x, start_y, center_xz.y),
		"velocity": source_velocity * 0.28 + Vector3(rng.randf_range(-0.12, 0.12), rng.randf_range(0.02, 0.18), rng.randf_range(-0.12, 0.12)),
		"volume_m3": committed_volume,
		"radius_m": base_radius,
		"sleep_s": 0.0,
		"sleeping": false,
		"contained": false,
		"compartment": compartment,
		"age_s": 0.0,
	})
	_representative_sequence += 1
	_aggregate_volume[aggregate_id] = committed_volume
	_rebuild_visual_representatives()
	var representative_count := _visual_count_for_aggregate(aggregate_id)
	if debit_persistent:
		_injected_volume_m3 += committed_volume
	else:
		_received_released_volume_m3 += committed_volume
	return {
		"accepted": true,
		"aggregate_id": aggregate_id,
		"volume_m3": committed_volume,
		"stable_source_volume_m3": stable_source_volume,
		"loose_source_volume_m3": loose_source_volume,
		"representative_count": representative_count,
		"reason": "activated",
	}


func step_fixed(delta: float, focus_world: Vector3, soil_tool_snapshot: Dictionary = {}) -> Dictionary:
	if generation < 0:
		return {"changed": false, "reason": "unconfigured"}
	var started_us := Time.get_ticks_usec()
	persistent_field.step_pending_flux()
	_focus_world = focus_world
	var bounded_delta := clampf(delta, 0.0, 0.05)
	var substeps := maxi(1, int(_profile["substeps"]))
	var sub_delta := bounded_delta / float(substeps)
	for _substep in substeps:
		_integrate_representatives(sub_delta, soil_tool_snapshot)
		_resolve_neighbors(sub_delta)
	_settle_ready_representatives()
	_rebuild_visual_representatives()
	_last_tick_us = Time.get_ticks_usec() - started_us
	_tick_samples_us.append(_last_tick_us)
	if _tick_samples_us.size() > MAX_TICK_SAMPLES:
		_tick_samples_us.remove_at(0)
	return {"changed": not _representatives.is_empty(), "reason": "stepped", "tick_us": _last_tick_us}


func schedule_loose_flux(dirty_rect_cells: Rect2i, horizontal_impulse_xz: Vector2) -> bool:
	return persistent_field.schedule_tool_flux(dirty_rect_cells, horizontal_impulse_xz)


func flush_all() -> Dictionary:
	var settled := 0.0
	for index in range(_representatives.size() - 1, -1, -1):
		var rep := _representatives[index]
		var position := rep["position"] as Vector3
		var result := persistent_field.settle_volume(
			_clamp_to_field(Vector2(position.x, position.z)),
			float(rep["volume_m3"]),
			maxf(0.20, float(rep["radius_m"]) * 2.8),
			"flush:%s" % str(rep["id"]),
		)
		if bool(result.get("accepted", false)):
			var committed := float(result.get("committed_volume_m3", 0.0))
			settled += committed
			_settlement_events.append({
				"compartment": String(rep.get("compartment", "active")),
				"volume_m3": committed,
				"origin_world": position,
				"velocity_world": rep.get("velocity", Vector3.ZERO),
				"aggregate_id": String(rep.get("aggregate_id", "")),
			})
			_debit_representative(index, committed)
	_settled_volume_m3 += settled
	_rebuild_visual_representatives()
	return {"settled_volume_m3": settled, "remaining_representatives": _representatives.size()}


func get_visual_snapshot() -> Dictionary:
	_rebuild_visual_representatives()
	var positions := PackedVector3Array()
	var radii := PackedFloat32Array()
	var states := PackedByteArray()
	positions.resize(_visual_representatives.size())
	radii.resize(_visual_representatives.size())
	states.resize(_visual_representatives.size())
	for index in _visual_representatives.size():
		var rep := _visual_representatives[index]
		positions[index] = rep["position"] as Vector3
		radii[index] = float(rep["radius_m"])
		states[index] = 2 if bool(rep["contained"]) else (1 if bool(rep["sleeping"]) else 0)
	return {
		"schema_version": SCHEMA_VERSION,
		"generation": generation,
		"material_preset": material_preset,
		"angle_of_repose_degrees": float(_material["angle_of_repose_degrees"]),
		"positions": positions,
		"radii": radii,
		"states": states,
	}


func get_status_snapshot() -> Dictionary:
	_rebuild_visual_representatives()
	var active_volume := 0.0
	var displaced_active_volume := 0.0
	var released_volume := 0.0
	var sleeping_count := 0
	var contained_count := 0
	var contained_volume := 0.0
	for rep in _representatives:
		var rep_volume := float(rep["volume_m3"])
		active_volume += rep_volume
		if String(rep.get("compartment", "active")) == "released":
			released_volume += rep_volume
		else:
			displaced_active_volume += rep_volume
		sleeping_count += 1 if bool(rep["sleeping"]) else 0
		contained_count += 1 if bool(rep["contained"]) else 0
		contained_volume += rep_volume if bool(rep["contained"]) else 0.0
	var sorted_ticks := Array(_tick_samples_us)
	sorted_ticks.sort()
	var p95_us := 0
	if not sorted_ticks.is_empty():
		p95_us = int(sorted_ticks[clampi(ceili(float(sorted_ticks.size()) * 0.95) - 1, 0, sorted_ticks.size() - 1)])
	var field_status := persistent_field.get_status_snapshot()
	var estimated_memory := int(field_status.get("estimated_memory_bytes", 0)) + _representatives.size() * 192 + _visual_representatives.size() * 96
	return {
		"schema_version": SCHEMA_VERSION,
		"configured": generation >= 0,
		"generation": generation,
		"quality_profile": quality_profile,
		"material_preset": material_preset,
		"angle_of_repose_degrees": float(_material["angle_of_repose_degrees"]),
		"focus_world": _focus_world,
		"window_m": float(_profile["window_m"]),
		"representative_count": _visual_representatives.size(),
		"max_representatives": int(_profile["max_representatives"]),
		"logical_aggregate_count": _representatives.size(),
		"max_logical_aggregates": MAX_LOGICAL_AGGREGATES,
		"sleeping_count": sleeping_count,
		"contained_count": contained_count,
		"contained_volume_m3": contained_volume,
		"aggregate_count": _aggregate_volume.size(),
		"injected_volume_m3": _injected_volume_m3,
		"received_released_volume_m3": _received_released_volume_m3,
		"exported_bucket_volume_m3": _exported_bucket_volume_m3,
		"active_volume_m3": active_volume,
		"displaced_active_volume_m3": displaced_active_volume,
		"released_volume_m3": released_volume,
		"settled_volume_m3": _settled_volume_m3,
		"rejected_volume_m3": _rejected_volume_m3,
		"conservation_error_m3": _injected_volume_m3 + _received_released_volume_m3 - active_volume - _settled_volume_m3 - _exported_bucket_volume_m3,
		"evicted_representatives": _evicted_representatives,
		"predebited_reservation_count": _predebited_reservations.size(),
		"last_tick_ms": float(_last_tick_us) / 1000.0,
		"p95_tick_ms": float(p95_us) / 1000.0,
		"estimated_memory_bytes": estimated_memory,
		"persistent_field": field_status,
	}


func _integrate_representatives(delta: float, soil_tool_snapshot: Dictionary) -> void:
	var regions := soil_tool_snapshot.get("regions", []) as Array if bool(soil_tool_snapshot.get("valid", false)) else []
	var damping := exp(-float(_material["linear_damping"]) * delta)
	var half_window := float(_profile["window_m"]) * 0.5
	for index in _representatives.size():
		var rep := _representatives[index]
		var position := rep["position"] as Vector3
		var velocity := rep["velocity"] as Vector3
		var radius := float(rep["radius_m"])
		var was_contained := bool(rep["contained"])
		if was_contained:
			var contained_result := _resolve_containment(position, velocity, radius, regions, delta)
			position = contained_result["position"] as Vector3
			velocity = contained_result["velocity"] as Vector3
			rep["contained"] = bool(contained_result["contained"])
		if not bool(rep["contained"]):
			velocity.y -= GRAVITY_M_S2 * delta
			velocity *= damping
			position += velocity * delta
			if String(rep.get("compartment", "active")) == "active":
				var bucket_result := _resolve_bucket_solids(position, velocity, radius, regions)
				position = bucket_result["position"] as Vector3
				velocity = bucket_result["velocity"] as Vector3
				if bool(bucket_result["entered_cavity"]):
					rep["contained"] = true
		var on_floor := false
		if not bool(rep["contained"]):
			var surface := persistent_field.sample_surface_at(Vector2(position.x, position.z))
			if not is_nan(surface) and position.y < surface + radius:
				position.y = surface + radius
				if velocity.y < 0.0:
					velocity.y = -velocity.y * float(_material["restitution"])
				var floor_friction := maxf(0.0, 1.0 - float(_material["friction"]) * delta * 6.0)
				velocity.x *= floor_friction
				velocity.z *= floor_friction
				on_floor = true
		var horizontal_offset := Vector2(position.x - _focus_world.x, position.z - _focus_world.z)
		var outside_window := absf(horizontal_offset.x) > half_window or absf(horizontal_offset.y) > half_window
		if outside_window and not bool(rep["contained"]):
			rep["sleep_s"] = float(_material["settle_delay_s"]) + 1.0
			rep["sleeping"] = true
			_evicted_representatives += 1
		elif on_floor and velocity.length() <= float(_material["sleep_speed"]):
			rep["sleep_s"] = float(rep["sleep_s"]) + delta
			rep["sleeping"] = true
		else:
			rep["sleep_s"] = 0.0
			rep["sleeping"] = false
		rep["position"] = position
		rep["velocity"] = velocity
		rep["age_s"] = float(rep["age_s"]) + delta
		_representatives[index] = rep


func _resolve_neighbors(delta: float) -> void:
	if _representatives.size() < 2:
		return
	var cell_size := float(_profile["spatial_cell_m"])
	var spatial := {}
	for index in _representatives.size():
		var position := _representatives[index]["position"] as Vector3
		var key := Vector3i(floori(position.x / cell_size), floori(position.y / cell_size), floori(position.z / cell_size))
		if not spatial.has(key):
			spatial[key] = []
		(spatial[key] as Array).append(index)
	var max_neighbors := int(_profile["max_neighbors"])
	var stiffness := float(_material["neighbor_stiffness"])
	var cohesion := float(_material["cohesion"])
	for first_index in _representatives.size():
		var first := _representatives[first_index]
		var first_position := first["position"] as Vector3
		var first_key := Vector3i(floori(first_position.x / cell_size), floori(first_position.y / cell_size), floori(first_position.z / cell_size))
		var visited := 0
		for x_offset in range(-1, 2):
			for y_offset in range(-1, 2):
				for z_offset in range(-1, 2):
					var key := first_key + Vector3i(x_offset, y_offset, z_offset)
					if not spatial.has(key):
						continue
					var cell_indices := spatial[key] as Array
					for second_value in cell_indices:
						var second_index := int(second_value)
						if second_index <= first_index:
							continue
						var second := _representatives[second_index]
						var second_position := second["position"] as Vector3
						var offset := second_position - first_position
						var distance := offset.length()
						var target := float(first["radius_m"]) + float(second["radius_m"])
						if distance < target and distance > 0.00001:
							var normal := offset / distance
							var correction := normal * (target - distance) * 0.5 * stiffness
							first_position -= correction
							second_position += correction
							var relative_speed := ((second["velocity"] as Vector3) - (first["velocity"] as Vector3)).dot(normal)
							if relative_speed < 0.0:
								var impulse := normal * relative_speed * 0.22
								first["velocity"] = (first["velocity"] as Vector3) + impulse
								second["velocity"] = (second["velocity"] as Vector3) - impulse
							first["sleeping"] = false
							second["sleeping"] = false
						elif cohesion > 0.0 and distance < target * 1.45 and distance > target:
							var attraction := offset.normalized() * cohesion * delta * 0.08
							first["velocity"] = (first["velocity"] as Vector3) + attraction
							second["velocity"] = (second["velocity"] as Vector3) - attraction
						first["position"] = first_position
						second["position"] = second_position
						_representatives[second_index] = second
						visited += 1
						if visited >= max_neighbors:
							break
					if visited >= max_neighbors:
						break
				if visited >= max_neighbors:
					break
			if visited >= max_neighbors:
				break
		_representatives[first_index] = first


func _settle_ready_representatives() -> void:
	var settled_this_tick := 0
	var maximum := int(_profile["max_settlements"])
	for index in range(_representatives.size() - 1, -1, -1):
		if settled_this_tick >= maximum:
			break
		var rep := _representatives[index]
		if bool(rep["contained"]) or float(rep["sleep_s"]) < float(_material["settle_delay_s"]):
			continue
		var position := rep["position"] as Vector3
		var result := persistent_field.settle_volume(
			_clamp_to_field(Vector2(position.x, position.z)),
			float(rep["volume_m3"]),
			maxf(0.20, float(rep["radius_m"]) * 2.8),
			"sleep:%s" % str(rep["id"]),
		)
		if not bool(result.get("accepted", false)):
			continue
		var committed := float(result.get("committed_volume_m3", 0.0))
		_settled_volume_m3 += committed
		_settlement_events.append({
			"compartment": String(rep.get("compartment", "active")),
			"volume_m3": committed,
			"origin_world": position,
			"velocity_world": rep.get("velocity", Vector3.ZERO),
			"aggregate_id": String(rep.get("aggregate_id", "")),
		})
		_debit_representative(index, committed)
		settled_this_tick += 1


func _resolve_containment(position: Vector3, velocity: Vector3, radius: float, regions: Array, delta: float) -> Dictionary:
	var inner := _find_region(regions, "inner_shell")
	var opening := _find_region(regions, "opening")
	if inner.is_empty():
		return {"position": position, "velocity": velocity, "contained": false}
	var opening_down := (opening.get("outward_normal_world", Vector3.UP) as Vector3).dot(Vector3.DOWN) if not opening.is_empty() else -1.0
	if opening_down > 0.3:
		return {"position": position, "velocity": velocity, "contained": false}
	var previous := inner.get("previous_transform", inner.get("current_transform", Transform3D.IDENTITY)) as Transform3D
	var current := inner.get("current_transform", Transform3D.IDENTITY) as Transform3D
	position = current * (previous.affine_inverse() * position)
	velocity += (inner.get("motion_world", Vector3.ZERO) as Vector3) / maxf(delta, 0.0001) * 0.35
	var size := _shape_size(inner.get("shape", {}) as Dictionary)
	var local := current.affine_inverse() * position
	var half := size * 0.5 - Vector3.ONE * radius * 0.35
	local = local.clamp(-half, half)
	return {"position": current * local, "velocity": velocity * 0.82, "contained": true}


func _resolve_bucket_solids(position: Vector3, velocity: Vector3, radius: float, regions: Array) -> Dictionary:
	var entered_cavity := false
	var inner := _find_region(regions, "inner_shell")
	var opening := _find_region(regions, "opening")
	var opening_down_dot := (opening.get("outward_normal_world", Vector3.UP) as Vector3).dot(Vector3.DOWN) if not opening.is_empty() else -1.0
	if (
		not inner.is_empty()
		and opening_down_dot <= 0.3
		and _point_inside_region(position, radius * 0.25, inner)
	):
		entered_cavity = true
		return {"position": position, "velocity": velocity * 0.75, "entered_cavity": true}
	for region_value in regions:
		var region := region_value as Dictionary
		if String(region.get("region_id", "")) in ["inner_shell", "opening"]:
			continue
		var transform := region.get("current_transform", Transform3D.IDENTITY) as Transform3D
		var half := _shape_size(region.get("shape", {}) as Dictionary) * 0.5 + Vector3.ONE * radius
		var local := transform.affine_inverse() * position
		if absf(local.x) > half.x or absf(local.y) > half.y or absf(local.z) > half.z:
			continue
		var penetration := Vector3(half.x - absf(local.x), half.y - absf(local.y), half.z - absf(local.z))
		var axis := 0
		if penetration.y < penetration.x:
			axis = 1
		if penetration.z < penetration[axis]:
			axis = 2
		var direction := 1.0 if local[axis] >= 0.0 else -1.0
		local[axis] = half[axis] * direction
		position = transform * local
		var normal := transform.basis[axis].normalized() * direction
		var inward_speed := velocity.dot(normal)
		if inward_speed < 0.0:
			velocity -= normal * inward_speed * 1.15
		velocity += region.get("motion_world", Vector3.ZERO) as Vector3 * 18.0
	return {"position": position, "velocity": velocity, "entered_cavity": entered_cavity}


func _point_inside_region(point: Vector3, margin: float, region: Dictionary) -> bool:
	var transform := region.get("current_transform", Transform3D.IDENTITY) as Transform3D
	var half := _shape_size(region.get("shape", {}) as Dictionary) * 0.5 + Vector3.ONE * margin
	var local := transform.affine_inverse() * point
	return absf(local.x) <= half.x and absf(local.y) <= half.y and absf(local.z) <= half.z


func _find_region(regions: Array, region_id: String) -> Dictionary:
	for value in regions:
		var region := value as Dictionary
		if String(region.get("region_id", "")) == region_id:
			return region
	return {}


func _shape_size(shape: Dictionary) -> Vector3:
	match String(shape.get("kind", "")):
		"box":
			var size := shape.get("size_m", [0.1, 0.1, 0.1]) as Array
			return Vector3(float(size[0]), float(size[1]), float(size[2]))
		"segment":
			var radius := float(shape.get("radius_m", 0.04))
			return Vector3(radius * 2.0, radius * 2.0, float(shape.get("half_length_m", 0.1)) * 2.0)
		"plane":
			var plane_size := shape.get("size_m", [0.1, 0.1]) as Array
			return Vector3(float(plane_size[0]), 0.02, float(plane_size[1]))
	return Vector3.ONE * 0.1


func _remove_representative(index: int) -> void:
	var rep := _representatives[index]
	var aggregate_id := String(rep["aggregate_id"])
	var remaining := maxf(0.0, float(_aggregate_volume.get(aggregate_id, 0.0)) - float(rep["volume_m3"]))
	if remaining <= MIN_VOLUME_M3:
		_aggregate_volume.erase(aggregate_id)
	else:
		_aggregate_volume[aggregate_id] = remaining
	_representatives.remove_at(index)


func _debit_representative(index: int, amount_m3: float) -> void:
	if index < 0 or index >= _representatives.size() or amount_m3 <= MIN_VOLUME_M3:
		return
	var rep := _representatives[index]
	var available := float(rep.get("volume_m3", 0.0))
	var debited := minf(available, amount_m3)
	if debited >= available - MIN_VOLUME_M3:
		_remove_representative(index)
		return
	var aggregate_id := String(rep.get("aggregate_id", ""))
	rep["volume_m3"] = available - debited
	rep["radius_m"] = _radius_for_volume(float(rep["volume_m3"]))
	_representatives[index] = rep
	_aggregate_volume[aggregate_id] = maxf(0.0, float(_aggregate_volume.get(aggregate_id, available)) - debited)


func _rebuild_visual_representatives() -> void:
	_visual_representatives.clear()
	if _representatives.is_empty():
		return
	var remaining_budget := int(_profile["max_representatives"])
	for logical_value in _representatives:
		if remaining_budget <= 0:
			break
		var logical := logical_value as Dictionary
		var aggregate_id := String(logical.get("aggregate_id", ""))
		var volume := float(logical.get("volume_m3", 0.0))
		if aggregate_id.is_empty() or volume <= MIN_VOLUME_M3:
			continue
		var desired := maxi(1, ceili(volume / float(_profile["target_volume_m3"])))
		var count := mini(desired, remaining_budget)
		var sample_volume := volume / float(count)
		var sample_radius := _radius_for_volume(sample_volume)
		var logical_radius := float(logical.get("radius_m", sample_radius))
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("visual|%s|%s|%d" % [aggregate_id, material_preset, generation])
		for sample_index in count:
			var angle := rng.randf_range(0.0, TAU)
			var radial := sqrt(rng.randf()) * logical_radius * 0.55
			var jitter := Vector3(cos(angle) * radial, rng.randf_range(0.0, sample_radius * 0.7), sin(angle) * radial)
			_visual_representatives.append({
				"id": "%s:%d" % [aggregate_id, sample_index],
				"aggregate_id": aggregate_id,
				"position": (logical.get("position", Vector3.ZERO) as Vector3) + jitter,
				"velocity": logical.get("velocity", Vector3.ZERO),
				"radius_m": sample_radius * rng.randf_range(0.88, 1.12),
				"sleeping": bool(logical.get("sleeping", false)),
				"contained": bool(logical.get("contained", false)),
			})
		remaining_budget -= count


func _visual_count_for_aggregate(aggregate_id: String) -> int:
	var count := 0
	for visual in _visual_representatives:
		if String(visual.get("aggregate_id", "")) == aggregate_id:
			count += 1
	return count


func _clamp_to_field(world_xz: Vector2) -> Vector2:
	if persistent_field.terrain_state == null:
		return world_xz
	var state := persistent_field.terrain_state
	return Vector2(
		clampf(world_xz.x, state.origin_xz.x, state.origin_xz.x + float(state.columns - 1) * state.spacing_m),
		clampf(world_xz.y, state.origin_xz.y, state.origin_xz.y + float(state.rows - 1) * state.spacing_m),
	)


func _radius_for_volume(volume_m3: float) -> float:
	return clampf(pow(3.0 * volume_m3 / (4.0 * PI), 1.0 / 3.0), 0.025, 0.22)

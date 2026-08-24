class_name ActiveSoilPatch
extends RefCounted

## Deterministic bounded CPU reference for visually active soil. Representative
## count is a quality choice; aggregate volume remains exact and is settled
## through ActiveSoilPersistentField's shadow scheduler.

const SCHEMA_VERSION := "active-soil-patch-v1"
const MIN_VOLUME_M3 := 0.000001
const GRAVITY_M_S2 := 9.81
const MAX_TICK_SAMPLES := 240
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
var _representatives: Array[Dictionary] = []
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


func clear(settle_active: bool = true) -> void:
	if settle_active and persistent_field.terrain_state != null:
		flush_all()
	_representatives.clear()
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
	generation = -1
	persistent_field.clear()


func set_quality_profile(requested_quality: String) -> bool:
	if not QUALITY_PROFILES.has(requested_quality):
		return false
	quality_profile = requested_quality
	_profile = (QUALITY_PROFILES[quality_profile] as Dictionary).duplicate(true)
	# Quality may reduce visual representatives, but never discards material.
	while _representatives.size() > int(_profile["max_representatives"]):
		if not _merge_last_representative():
			break
	return true


func inject_cut_event(event: Dictionary, aggregate_hint: String = "") -> Dictionary:
	return inject_tool_volume(event, aggregate_hint)


func inject_tool_volume(event: Dictionary, aggregate_hint: String = "") -> Dictionary:
	return _inject_volume(event, aggregate_hint, true, "active")


func inject_released_volume(event: Dictionary, aggregate_hint: String = "") -> Dictionary:
	return _inject_volume(event, aggregate_hint, false, "released")


func can_accept_volume(requested_volume_m3: float) -> bool:
	return (
		generation >= 0
		and requested_volume_m3 > MIN_VOLUME_M3
		and (
			_representatives.size() < int(_profile["max_representatives"])
			or _representatives.size() >= 2
		)
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
	return {
		"accepted": extracted > MIN_VOLUME_M3,
		"volume_m3": extracted,
		"origin_world": weighted_position / extracted if extracted > MIN_VOLUME_M3 else Vector3.ZERO,
		"velocity_world": weighted_velocity / extracted if extracted > MIN_VOLUME_M3 else Vector3.ZERO,
		"reason": "extracted" if extracted > MIN_VOLUME_M3 else "no_contained_volume",
	}


func consume_settlement_events() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event in _settlement_events:
		result.append(event.duplicate(true))
	_settlement_events.clear()
	return result


func _inject_volume(event: Dictionary, aggregate_hint: String, debit_persistent: bool, compartment: String) -> Dictionary:
	var requested_volume := float(event.get("volume_m3", 0.0))
	var tooth_world := event.get("tooth_world", Vector3.ZERO) as Vector3
	var center_xz_value: Variant = event.get("center", Vector2(tooth_world.x, tooth_world.z))
	var center_xz := center_xz_value as Vector2 if center_xz_value is Vector2 else Vector2(tooth_world.x, tooth_world.z)
	var rejected := {"accepted": false, "volume_m3": 0.0, "reason": "invalid_event"}
	if generation < 0 or requested_volume <= MIN_VOLUME_M3 or not tooth_world.is_finite():
		_rejected_volume_m3 += maxf(requested_volume, 0.0)
		return rejected
	var available := int(_profile["max_representatives"]) - _representatives.size()
	if available <= 0 and _representatives.size() >= 2:
		_merge_last_representative()
		available = int(_profile["max_representatives"]) - _representatives.size()
	if available <= 0:
		rejected["reason"] = "representative_budget"
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
	var desired_count := maxi(1, ceili(committed_volume / float(_profile["target_volume_m3"])))
	var representative_count := mini(available, desired_count)
	var volume_per_rep := committed_volume / float(representative_count)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s|%s|%d" % [aggregate_id, material_preset, generation])
	var base_radius := _radius_for_volume(volume_per_rep)
	var surface := persistent_field.sample_surface_at(center_xz)
	var start_y := maxf(tooth_world.y, surface + base_radius) if not is_nan(surface) else tooth_world.y
	var source_velocity := event.get("tooth_velocity", Vector3.ZERO) as Vector3
	if source_velocity.length() > 4.0:
		source_velocity = source_velocity.normalized() * 4.0
	for index in representative_count:
		var angle := rng.randf_range(0.0, TAU)
		var radial := sqrt(rng.randf()) * activation_radius * 0.42
		var jitter := Vector3(cos(angle) * radial, rng.randf_range(0.0, base_radius * 1.7), sin(angle) * radial)
		_representatives.append({
			"id": _representative_sequence,
			"aggregate_id": aggregate_id,
			"position": Vector3(center_xz.x, start_y, center_xz.y) + jitter,
			"velocity": source_velocity * 0.28 + Vector3(rng.randf_range(-0.12, 0.12), rng.randf_range(0.02, 0.18), rng.randf_range(-0.12, 0.12)),
			"volume_m3": volume_per_rep,
			"radius_m": base_radius * rng.randf_range(0.88, 1.12),
			"sleep_s": 0.0,
			"sleeping": false,
			"contained": false,
			"compartment": compartment,
			"age_s": 0.0,
		})
		_representative_sequence += 1
	_aggregate_volume[aggregate_id] = committed_volume
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
	_focus_world = focus_world
	var bounded_delta := clampf(delta, 0.0, 0.05)
	var substeps := maxi(1, int(_profile["substeps"]))
	var sub_delta := bounded_delta / float(substeps)
	for _substep in substeps:
		_integrate_representatives(sub_delta, soil_tool_snapshot)
		_resolve_neighbors(sub_delta)
	_settle_ready_representatives()
	_last_tick_us = Time.get_ticks_usec() - started_us
	_tick_samples_us.append(_last_tick_us)
	if _tick_samples_us.size() > MAX_TICK_SAMPLES:
		_tick_samples_us.remove_at(0)
	return {"changed": not _representatives.is_empty(), "reason": "stepped", "tick_us": _last_tick_us}


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
			_remove_representative(index)
	_settled_volume_m3 += settled
	return {"settled_volume_m3": settled, "remaining_representatives": _representatives.size()}


func get_visual_snapshot() -> Dictionary:
	var positions := PackedVector3Array()
	var radii := PackedFloat32Array()
	var states := PackedByteArray()
	positions.resize(_representatives.size())
	radii.resize(_representatives.size())
	states.resize(_representatives.size())
	for index in _representatives.size():
		var rep := _representatives[index]
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
	var estimated_memory := int(field_status.get("estimated_memory_bytes", 0)) + _representatives.size() * 160
	return {
		"schema_version": SCHEMA_VERSION,
		"configured": generation >= 0,
		"generation": generation,
		"quality_profile": quality_profile,
		"material_preset": material_preset,
		"angle_of_repose_degrees": float(_material["angle_of_repose_degrees"]),
		"focus_world": _focus_world,
		"window_m": float(_profile["window_m"]),
		"representative_count": _representatives.size(),
		"max_representatives": int(_profile["max_representatives"]),
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
		_remove_representative(index)
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
	if not inner.is_empty() and opening_down_dot <= 0.3 and _point_inside_region(position, radius * 0.25, inner):
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


func _merge_last_representative() -> bool:
	if _representatives.size() < 2:
		return false
	var last_index := _representatives.size() - 1
	var last := _representatives[last_index] as Dictionary
	var target_index := -1
	for candidate_index in range(last_index - 1, -1, -1):
		var candidate := _representatives[candidate_index] as Dictionary
		if String(candidate.get("compartment", "active")) == String(last.get("compartment", "active")):
			target_index = candidate_index
			break
	if target_index < 0:
		return false
	_representatives.remove_at(last_index)
	var target := _representatives[target_index]
	var last_aggregate := String(last["aggregate_id"])
	var target_aggregate := String(target["aggregate_id"])
	var target_volume := float(target["volume_m3"])
	var last_volume := float(last["volume_m3"])
	var combined := target_volume + last_volume
	if last_aggregate != target_aggregate:
		var last_remaining := maxf(0.0, float(_aggregate_volume.get(last_aggregate, 0.0)) - last_volume)
		if last_remaining <= MIN_VOLUME_M3:
			_aggregate_volume.erase(last_aggregate)
		else:
			_aggregate_volume[last_aggregate] = last_remaining
		_aggregate_volume[target_aggregate] = float(_aggregate_volume.get(target_aggregate, target_volume)) + last_volume
	target["position"] = ((target["position"] as Vector3) * target_volume + (last["position"] as Vector3) * last_volume) / combined
	target["velocity"] = ((target["velocity"] as Vector3) * target_volume + (last["velocity"] as Vector3) * last_volume) / combined
	target["volume_m3"] = combined
	target["radius_m"] = _radius_for_volume(combined)
	_representatives[target_index] = target
	return true


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

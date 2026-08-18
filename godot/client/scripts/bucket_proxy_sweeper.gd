class_name BucketProxySweeper
extends RefCounted

const PROXY_ORDER := ["cutting_edge", "opening", "cavity", "shell", "rear_support"]
const BLOCKING_PROXIES := ["cutting_edge", "shell", "rear_support"]
const MAX_SEGMENTS := 12
const MAX_ROTATION_PER_SEGMENT_RAD := deg_to_rad(4.0)
const MAX_TRANSLATION_PER_SEGMENT_M := 0.08
const QUERY_MARGIN_M := 0.005

var configured := false
var model_id := ""
var proxy_version := ""

var _terrain_collider: TerrainCollider
var _terrain_mask := 1
var _proxy_contracts: Dictionary = {}
var _shapes: Dictionary = {}


func configure(
	model: String,
	soil_contract: Dictionary,
	terrain_collider: TerrainCollider,
	terrain_collision_mask: int
) -> bool:
	reset()
	if model.is_empty() or terrain_collider == null or terrain_collision_mask <= 0:
		return false
	var proxies := soil_contract.get("proxies", {}) as Dictionary
	for proxy_name in PROXY_ORDER:
		var proxy := proxies.get(proxy_name, {}) as Dictionary
		var shape := _build_shape(proxy_name, proxy)
		if proxy.is_empty() or shape == null:
			reset()
			return false
		_proxy_contracts[proxy_name] = proxy.duplicate(true)
		_shapes[proxy_name] = shape
	model_id = model
	proxy_version = "%s:%s" % [String(soil_contract.get("schema_version", "")), model]
	_terrain_collider = terrain_collider
	_terrain_mask = terrain_collision_mask
	configured = true
	return true


func reset() -> void:
	configured = false
	model_id = ""
	proxy_version = ""
	_terrain_collider = null
	_terrain_mask = 1
	_proxy_contracts.clear()
	_shapes.clear()


func sweep(
	world: World3D,
	previous_bucket_frame: Transform3D,
	candidate_bucket_frame: Transform3D,
	terrain_identity: Vector2i,
	physics_tick: int,
	authority_epoch: String,
	motion_sequence: int
) -> Dictionary:
	var base := {
		"valid": false,
		"accepted_fraction": 1.0,
		"contacts": [],
		"model_id": model_id,
		"proxy_version": proxy_version,
		"terrain_generation": terrain_identity.x,
		"terrain_revision": terrain_identity.y,
		"physics_tick": physics_tick,
		"authority_epoch": authority_epoch,
		"motion_sequence": motion_sequence,
		"quality_flags": [],
	}
	if (
		not configured or world == null or not previous_bucket_frame.is_finite()
		or not candidate_bucket_frame.is_finite() or authority_epoch.is_empty()
	):
		base["quality_flags"] = ["bucket_query_unavailable"]
		return base
	if (
		_terrain_collider == null or not _terrain_collider.available
		or _terrain_collider.get_applied_identity() != terrain_identity
	):
		base["quality_flags"] = ["bucket_query_terrain_identity_mismatch"]
		return base
	var segment_count := _segment_count(previous_bucket_frame, candidate_bucket_frame)
	var records: Array[Dictionary] = []
	var accepted_fraction := 1.0
	var saw_initial_overlap := false
	for proxy_name in PROXY_ORDER:
		var local_transform := _proxy_local_transform(_proxy_contracts[proxy_name] as Dictionary)
		var proxy_start := previous_bucket_frame * local_transform
		var proxy_end := candidate_bucket_frame * local_transform
		var proxy_result := _sweep_proxy(
			world.direct_space_state,
			proxy_name,
			_shapes[proxy_name] as Shape3D,
			proxy_start,
			proxy_end,
			segment_count,
			physics_tick,
			motion_sequence,
		)
		for record_value in proxy_result.get("contacts", []):
			records.append((record_value as Dictionary).duplicate(true))
		saw_initial_overlap = saw_initial_overlap or bool(proxy_result.get("initial_overlap", false))
		if BLOCKING_PROXIES.has(proxy_name):
			accepted_fraction = minf(accepted_fraction, float(proxy_result.get("accepted_fraction", 1.0)))
	records.sort_custom(_contact_less)
	base["valid"] = not saw_initial_overlap
	base["accepted_fraction"] = clampf(accepted_fraction, 0.0, 1.0)
	base["contacts"] = records
	base["quality_flags"] = ["bucket_query_initial_overlap"] if saw_initial_overlap else []
	return base


func _sweep_proxy(
	space_state: PhysicsDirectSpaceState3D,
	proxy_name: String,
	shape: Shape3D,
	start: Transform3D,
	finish: Transform3D,
	segment_count: int,
	physics_tick: int,
	motion_sequence: int
) -> Dictionary:
	var result := {"accepted_fraction": 1.0, "initial_overlap": false, "contacts": []}
	var initial_query := _query(shape, start, Vector3.ZERO)
	# The sweep margin is a conservative cast safety band, not penetration.
	# Reusing it for the zero-motion overlap probe turns a valid resting contact
	# into an endless recovery state and prevents support force application.
	initial_query.margin = 0.0
	var initial_hits := space_state.intersect_shape(initial_query, 8)
	if not initial_hits.is_empty():
		var initial_hit := _first_terrain_hit(initial_hits)
		if not initial_hit.is_empty():
			result["initial_overlap"] = true
			var initial_rest := space_state.get_rest_info(initial_query)
			(result["contacts"] as Array[Dictionary]).append(
				_contact_record(proxy_name, 0.0, initial_hit, initial_rest, true, physics_tick, motion_sequence)
			)
			# Initial-overlap queries remain invalid evidence, but the kinematic
			# work-equipment proxy must be allowed one bounded fixed-step to
			# recover. Soil stays disarmed; support still requires separate,
			# non-initial shell/rear evidence from the same segmented sweep.
			result["accepted_fraction"] = 1.0
			return result
	for segment_index in segment_count:
		var alpha_start := float(segment_index) / float(segment_count)
		var alpha_end := float(segment_index + 1) / float(segment_count)
		var segment_start := start.interpolate_with(finish, alpha_start)
		var segment_end := start.interpolate_with(finish, alpha_end)
		var query := _query(shape, segment_start, segment_end.origin - segment_start.origin)
		var fractions: PackedFloat32Array = space_state.cast_motion(query)
		var safe_fraction := 1.0
		var unsafe_fraction := 1.0
		if fractions.size() >= 2:
			safe_fraction = clampf(float(fractions[0]), 0.0, 1.0)
			unsafe_fraction = clampf(float(fractions[1]), safe_fraction, 1.0)
		var segment_hit := safe_fraction < 0.999999
		var endpoint_query := _query(shape, segment_end, Vector3.ZERO)
		var endpoint_hits := space_state.intersect_shape(endpoint_query, 8)
		var hit := _first_terrain_hit(endpoint_hits)
		if not segment_hit and hit.is_empty():
			continue
		var local_fraction := safe_fraction if segment_hit else 1.0
		var global_fraction := lerpf(alpha_start, alpha_end, local_fraction)
		var contact_transform := segment_start.interpolate_with(segment_end, unsafe_fraction if segment_hit else 1.0)
		var rest_query := _query(shape, contact_transform, Vector3.ZERO)
		var rest := space_state.get_rest_info(rest_query)
		if hit.is_empty():
			hit = _first_terrain_hit(space_state.intersect_shape(rest_query, 8))
		if hit.is_empty():
			continue
		(result["contacts"] as Array[Dictionary]).append(
			_contact_record(proxy_name, global_fraction, hit, rest, false, physics_tick, motion_sequence)
		)
		result["accepted_fraction"] = maxf(0.0, global_fraction - 0.002)
		break
	return result


func _contact_record(
	proxy_name: String,
	travel_fraction: float,
	hit: Dictionary,
	rest: Dictionary,
	initial_overlap: bool,
	physics_tick: int,
	motion_sequence: int
) -> Dictionary:
	var collider := hit.get("collider") as Node
	var point := rest.get("point", Vector3.ZERO) as Vector3
	var normal := rest.get("normal", Vector3.UP) as Vector3
	var point_valid := rest.has("point") and point.is_finite()
	if not point_valid:
		point = Vector3.ZERO
	if not normal.is_finite() or normal.length_squared() < 0.5:
		normal = Vector3.UP
	return {
		"contact_id": "%d:%d:%s:%d" % [physics_tick, motion_sequence, proxy_name, int(hit.get("shape", -1))],
		"proxy_role": proxy_name,
		"travel_fraction": clampf(travel_fraction, 0.0, 1.0),
		"point_world": point,
		"point_valid": point_valid,
		"normal_world": normal.normalized(),
		"collider_id": collider.get_instance_id() if collider != null else 0,
		"collider_name": String(collider.name) if collider != null else "terrain",
		"initial_overlap": initial_overlap,
		"quality": "initial_overlap" if initial_overlap else "shape_query",
	}


func _query(shape: Shape3D, transform: Transform3D, motion: Vector3) -> PhysicsShapeQueryParameters3D:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = transform
	query.motion = motion
	query.margin = QUERY_MARGIN_M
	query.collision_mask = _terrain_mask
	query.collide_with_bodies = true
	query.collide_with_areas = false
	return query


func _first_terrain_hit(hits: Array[Dictionary]) -> Dictionary:
	for hit_value in hits:
		var hit := hit_value as Dictionary
		var collider := hit.get("collider") as Node
		if collider != null and _terrain_collider != null and _terrain_collider.is_ancestor_of(collider):
			return hit
	return {}


func _build_shape(proxy_name: String, proxy: Dictionary) -> Shape3D:
	if proxy_name == "rear_support":
		var sphere := SphereShape3D.new()
		sphere.radius = float(proxy.get("radius_m", 0.0))
		return sphere if sphere.radius > 0.0 else null
	var box := BoxShape3D.new()
	if proxy_name == "cutting_edge":
		var half_width := float(proxy.get("half_width_m", 0.0))
		box.size = Vector3(2.0 * half_width, 0.06, 0.08)
	elif proxy_name == "opening":
		var opening_size := proxy.get("size_m", []) as Array
		if opening_size.size() != 2:
			return null
		box.size = Vector3(float(opening_size[0]), 0.04, float(opening_size[1]))
	else:
		var size := proxy.get("size_m", []) as Array
		if size.size() != 3:
			return null
		box.size = _vector3(size)
	return box if box.size.x > 0.0 and box.size.y > 0.0 and box.size.z > 0.0 else null


func _proxy_local_transform(proxy: Dictionary) -> Transform3D:
	var basis := Basis.IDENTITY
	if proxy.has("up_godot"):
		var up := _vector3(proxy["up_godot"]).normalized()
		var width := Vector3.RIGHT
		basis = Basis(width, up, width.cross(up).normalized()).orthonormalized()
	return Transform3D(basis, _vector3(proxy["center_godot"]))


func _segment_count(start: Transform3D, finish: Transform3D) -> int:
	var distance_segments := ceili(start.origin.distance_to(finish.origin) / MAX_TRANSLATION_PER_SEGMENT_M)
	var rotation := start.basis.get_rotation_quaternion().angle_to(finish.basis.get_rotation_quaternion())
	var rotation_segments := ceili(rotation / MAX_ROTATION_PER_SEGMENT_RAD)
	return clampi(maxi(1, maxi(distance_segments, rotation_segments)), 1, MAX_SEGMENTS)


func _contact_less(first: Dictionary, second: Dictionary) -> bool:
	var first_fraction := float(first.get("travel_fraction", 1.0))
	var second_fraction := float(second.get("travel_fraction", 1.0))
	if not is_equal_approx(first_fraction, second_fraction):
		return first_fraction < second_fraction
	var first_role := PROXY_ORDER.find(String(first.get("proxy_role", "")))
	var second_role := PROXY_ORDER.find(String(second.get("proxy_role", "")))
	if first_role != second_role:
		return first_role < second_role
	return String(first.get("contact_id", "")) < String(second.get("contact_id", ""))


func _vector3(value: Variant) -> Vector3:
	var data := value as Array
	return Vector3(float(data[0]), float(data[1]), float(data[2]))

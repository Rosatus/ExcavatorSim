class_name TrackContactSolver
extends RefCounted
## Virtual wheel stations sample a finite track footprint. Jolt's permanent
## convex hull handles walls, side impacts and bottoming; support never disables it.
## Descriptor v1 force coefficients are per original station, so changing query
## density preserves total suspension stiffness, damping and maximum load.

const MIN_SUPPORT_UP_DOT := 0.45
const QUERY_SKIN_M := 0.002
const REFERENCE_TICK_HZ := 60.0

var _tracks: Dictionary
var _dynamics: Dictionary
var _sphere := SphereShape3D.new()
var _station_count := 0
var _half_length := 0.0
var _bottom_y := 0.0
var _force_scale := 1.0
var _effort := Vector2.ZERO

func configure(tracks: Dictionary, dynamics: Dictionary) -> void:
	_tracks = tracks.duplicate(true)
	_dynamics = dynamics.duplicate(true)
	var lower: Dictionary = dynamics["compound_shapes"][0]
	var size := _vec3(lower["size_m"])
	_bottom_y = _vec3(lower["center_m"]).y - 0.5 * size.y
	# contact_width_m describes BOTH tracks; it is not one belt's width.
	_sphere.radius = clampf(0.5 * (float(tracks["contact_width_m"]) - float(tracks["gauge_m"])), 0.15, 0.45)
	_half_length = 0.5 * size.z - _sphere.radius
	_station_count = clampi(ceili(2.0 * _half_length / (1.8 * _sphere.radius)) + 1, 4, 12)
	_force_scale = float(tracks["traction_points_per_side"]) / float(_station_count)
	reset()

func reset() -> void:
	_effort = Vector2.ZERO

func add_collision_shapes(body: RigidBody3D) -> void:
	var lower: Dictionary = _dynamics["compound_shapes"][0]
	var size := _vec3(lower["size_m"])
	var center := _vec3(lower["center_m"])
	var radius := 0.5 * size.y
	var width := 2.0 * _sphere.radius
	var half_length := 0.5 * size.z
	for side in [-1.0, 1.0]:
		var vertices := PackedVector3Array()
		# Rounded leading/trailing lower edges instead of a full-width flat box.
		for x in [-0.5 * width, 0.5 * width]:
			for end in [-1.0, 1.0]:
				for segment in 7:
					var angle := -PI * 0.5 + float(segment) * PI / 6.0
					vertices.append(Vector3(x, _bottom_y + radius + sin(angle) * radius, end * (half_length - radius + cos(angle) * radius)))
		var shape := ConvexPolygonShape3D.new()
		shape.points = vertices
		shape.margin = 0.01
		_add_shape(body, shape, Vector3(side * float(_tracks["gauge_m"]) * 0.5, 0.0, center.z), "TrackHull")
	# Belly protects the space between belts without filling their ground gap.
	var belly := BoxShape3D.new()
	belly.size = Vector3(maxf(0.2, float(_tracks["gauge_m"]) - width), size.y * 0.55, maxf(0.4, size.z - 2.0 * radius))
	_add_shape(body, belly, Vector3(center.x, _bottom_y + size.y - 0.5 * belly.size.y, center.z), "BellyHull")
	for index in range(1, (_dynamics["compound_shapes"] as Array).size()):
		var item: Dictionary = _dynamics["compound_shapes"][index]
		var shape := BoxShape3D.new()
		shape.size = _vec3(item["size_m"])
		_add_shape(body, shape, _vec3(item["center_m"]), "UpperHull")

func step(body: RigidBody3D, commands: Vector2, delta: float, terrain_mask: int, accept_hit: Callable) -> Dictionary:
	var output := {"left": {}, "right": {}, "contacts": [], "sources": {}, "probes": [], "rejections": {}}
	var sign_forward := 1.0 if _tracks.get("local_forward_axis", "-Z") == "+Z" else -1.0
	var forward := body.global_basis.z.normalized() * sign_forward
	var up := body.global_basis.y.normalized()
	# An overturned machine is supported by its real hull, not upside-down rays.
	var can_support := up.dot(Vector3.UP) > MIN_SUPPORT_UP_DOT
	var hull_contacts := _loaded_hull_contacts(body, delta, accept_hit)
	for side in 2:
		var side_name := "left" if side == 0 else "right"
		var local_x := (1.0 if side == 0 else -1.0) * sign_forward * float(_tracks["gauge_m"]) * 0.5
		var samples: Array[Dictionary] = []
		var speed_sum := 0.0
		var load_sum := 0.0
		for index in _station_count:
			if not can_support:
				break
			var z := lerpf(-_half_length, _half_length, float(index) / float(_station_count - 1))
			var hit := _sweep(body, Vector3(local_x, _bottom_y, z), up, terrain_mask)
			if hit.is_empty():
				_record_rejection(output, "no_surface")
				continue
			hit = accept_hit.call(hit)
			if hit.is_empty():
				_record_rejection(output, "surface_not_ready_or_owned")
				continue
			var normal: Vector3 = hit["normal"]
			if normal.dot(Vector3.UP) < MIN_SUPPORT_UP_DOT or normal.dot(up) < MIN_SUPPORT_UP_DOT:
				_record_rejection(output, "steep_obstacle")
				continue
			var compression := clampf(float(_tracks["support_rest_length_m"]) - float(hit["travel"]), 0.0, float(_tracks["support_rest_length_m"]))
			# A ray/sweep within range is not necessarily carrying load.
			if compression <= 0.0:
				continue
			var point: Vector3 = hit["position"]
			var com := body.global_transform * body.center_of_mass
			var velocity := body.linear_velocity + body.angular_velocity.cross(point - com)
			var normal_speed := velocity.dot(normal)
			var spring := float(_tracks["support_stiffness_n_per_m"]) * _force_scale
			var damper := float(_tracks["support_damping_n_s_per_m"]) * _force_scale
			# No filtered spring-force memory: it keeps pushing after a crest and
			# adds a phase lag to the damper. Finite travel cannot pull the ground.
			var load := clampf(spring * compression - damper * normal_speed, 0.0, float(_tracks["max_support_force_n"]) * _force_scale)
			var tangent := forward.slide(normal).normalized()
			var lateral := tangent.cross(normal).normalized()
			var speed := velocity.dot(tangent)
			samples.append({"point":point,"normal":normal,"velocity":velocity,"forward":tangent,"lateral":lateral,"speed":speed,"load":load,"traction_load":load,"hull_load":0.0,"source":hit["support_source"],"collider":hit["collider"],"compression":compression,"station":index})
		# The collision solver may carry most of the weight at a pit lip or when
		# a station bottoms out. That load provides grip but must NOT be added
		# again as a spring force. Attribute each physical contact once.
		for contact in hull_contacts:
			if int(contact["side"]) != side:
				continue
			var nearest := -1
			var nearest_distance := INF
			for index in samples.size():
				if samples[index]["collider"] != contact["collider"]:
					continue
				if (samples[index]["normal"] as Vector3).dot(contact["normal"]) < 0.85:
					continue
				var distance := (samples[index]["point"] as Vector3).distance_squared_to(contact["point"])
				if distance < nearest_distance:
					nearest = index
					nearest_distance = distance
			if nearest >= 0:
				samples[nearest]["hull_load"] += float(contact["load"])
				samples[nearest]["traction_load"] += float(contact["load"])
			else:
				var point: Vector3 = contact["point"]
				var normal: Vector3 = contact["normal"]
				var tangent := forward.slide(normal).normalized()
				var velocity := body.linear_velocity + body.angular_velocity.cross(point - body.global_transform * body.center_of_mass)
				samples.append({"point":point,"normal":normal,"velocity":velocity,"forward":tangent,"lateral":tangent.cross(normal).normalized(),"speed":velocity.dot(tangent),"load":0.0,"traction_load":contact["load"],"hull_load":contact["load"],"source":contact["support_source"],"collider":contact["collider"],"compression":0.0,"station":-1})
		var loaded_samples: Array[Dictionary] = []
		for sample in samples:
			if float(sample["traction_load"]) <= 0.01:
				continue
			loaded_samples.append(sample)
			load_sum += float(sample["traction_load"])
			speed_sum += float(sample["speed"]) * float(sample["traction_load"])
		samples = loaded_samples
		var speed := speed_sum / load_sum if load_sum > 0.01 else 0.0
		_effort[side] = _drive_effort(commands[side], speed, _effort[side], delta, not samples.is_empty())
		# Keep normal Coulomb traction for loaded contact, but provide a small,
		# bounded recovery floor when only a corner or one station still touches
		# the ground. This avoids a soft-lock without making an airborne track
		# powered: the floor exists only after the same valid-contact filters above.
		var minimum_ratio := clampf(float(_tracks.get("minimum_traction_ratio", 0.0)), 0.0, 0.5)
		var recovery_speed := maxf(0.05, float(_tracks.get("recovery_speed_m_s", 0.22)))
		# Do not inject recovery force while the operator is braking through a
		# non-zero velocity. The normal effort must cross zero first so reversal
		# remains smooth and predictable.
		var same_direction := speed * commands[side] >= -0.02
		var recovery_active := not samples.is_empty() and absf(commands[side]) > 0.01 and absf(speed) < recovery_speed and same_direction
		var contact_quality := 0.0
		for sample in samples:
			contact_quality = maxf(contact_quality, clampf((sample["normal"] as Vector3).dot(Vector3.UP), 0.0, 1.0))
		var minimum_side_force := float(_tracks["max_drive_force_n"]) * minimum_ratio * contact_quality if recovery_active else 0.0
		var saturated := false
		var slip := 0.0
		for sample in samples:
			var load := float(sample["load"])
			var normal: Vector3 = sample["normal"]
			var point: Vector3 = sample["point"]
			var tangent: Vector3 = sample["forward"]
			var lateral: Vector3 = sample["lateral"]
			var weight := float(sample["traction_load"]) / maxf(load_sum, 0.001)
			var drive := _effort[side] * weight
			if minimum_side_force > 0.0:
				drive = signf(commands[side]) * maxf(absf(drive), minimum_side_force * weight)
			var pivot := clampf(sqrt(maxf(0.0,-commands.x*commands.y)),0.0,1.0)
			var lateral_scale := lerpf(1.0,float(_tracks["pivot_lateral_resistance_scale"]),pivot)
			var side_force := -(sample["velocity"] as Vector3).dot(lateral) * float(_tracks["lateral_resistance_n_per_m_s"]) * lateral_scale * weight
			var force := tangent * drive + lateral * side_force
			# A neutral brake can hold a slope within the same Coulomb budget.
			if absf(commands[side]) < 0.001:
				force += Vector3.UP.slide(normal) * (float(_dynamics["mass_kg"]) * 9.80665 * 0.5 * weight)
			var cap := maxf(
				float(_tracks["friction"]) * float(sample["traction_load"]),
				minimum_side_force * weight
			)
			if force.length() > cap:
				force = force.limit_length(cap)
				saturated = true
			body.apply_force(normal * load, point - body.global_position)
			# Gameplay traction acts at COM height, avoiding artificial high-COM
			# pitching. Keep the full fore/aft lever for distributed yaw damping.
			var lever := (point - body.global_transform * body.center_of_mass).slide(up)
			body.apply_central_force(force)
			body.apply_torque(lever.cross(force))
			var target := commands[side] * float(_tracks["max_belt_speed_m_s"])
			slip += clampf((target-float(sample["speed"]))/maxf(absf(target),0.25),-4.0,4.0)
			var source := String(sample["source"])
			output["sources"][source] = int(output["sources"].get(source,0)) + 1
			output["contacts"].append({"body":"chassis","other":String((sample["collider"] as Node).name),"point":point,"normal":normal,"impulse_n_s":load*delta,"penetration_m":0.0,"track_side":side_name,"support_source":source})
			output["probes"].append({"side":side_name,"station":sample["station"],"point":point,"normal":normal,"compression_m":sample["compression"],"load_n":load,"hull_load_n":sample["hull_load"],"traction_load_n":sample["traction_load"],"source":source})
		output[side_name] = {"contact_count":samples.size(),"speed_m_s":speed,"slip_ratio":slip/float(samples.size()) if not samples.is_empty() else 0.0,"support_load_n":load_sum,"effort_n":_effort[side],"saturated":saturated,"recovery_active":recovery_active,"traction_floor_n":minimum_side_force}
	return output

func _sweep(body: RigidBody3D, local_point: Vector3, up: Vector3, mask: int) -> Dictionary:
	var travel := float(_tracks["probe_height_m"]) + float(_tracks["probe_depth_m"])
	var start := body.global_transform * local_point + up * (float(_tracks["probe_height_m"]) + _sphere.radius)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _sphere
	query.transform = Transform3D(Basis.IDENTITY,start)
	query.motion = -up * travel
	query.margin = QUERY_SKIN_M
	query.collision_mask = mask
	query.exclude = [body.get_rid()]
	var space := body.get_world_3d().direct_space_state
	# cast_motion ignores shapes already overlapping at the sweep origin.
	# A steep lip can reach the start sphere while the real hull still blocks it.
	var motion := query.motion
	query.motion = Vector3.ZERO
	var initial := space.get_rest_info(query)
	if not initial.is_empty():
		return _support_hit(initial, 0.0, start - up * _sphere.radius)
	query.motion = motion
	var fractions := space.cast_motion(query)
	if fractions.size() < 2 or fractions[0] >= 1.0:
		return {}
	var distance := float(fractions[1]) * travel
	query.transform.origin = start - up * (distance + QUERY_SKIN_M)
	query.motion = Vector3.ZERO
	var hit := space.get_rest_info(query)
	if hit.is_empty():
		return {}
	return _support_hit(hit, distance, start - up * _sphere.radius)

func _support_hit(hit: Dictionary, distance: float, start: Vector3) -> Dictionary:
	var owner := instance_from_id(int(hit.get("collider_id", 0))) as Node
	return {"position":hit["point"],"normal":hit["normal"],"rid":hit["rid"],"collider":owner,"travel":distance,"ray_start":start}

func _loaded_hull_contacts(body: RigidBody3D, delta: float, accept_hit: Callable) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var state := PhysicsServer3D.body_get_direct_state(body.get_rid())
	if state == null:
		return result
	var forward_sign := 1.0 if _tracks.get("local_forward_axis", "-Z") == "+Z" else -1.0
	var budget := float(_dynamics["mass_kg"]) * 9.80665 * 2.0
	for index in state.get_contact_count():
		var shape_index := state.get_contact_local_shape(index)
		if shape_index < 0:
			continue
		var shape_owner := body.shape_find_owner(shape_index)
		var shape_node := body.shape_owner_get_owner(shape_owner) as CollisionShape3D
		# Belly/upper-body grounding is not a powered belt. Nor is a vertical
		# wall: contact impulse alone must never grant wall-climbing traction.
		if shape_node == null or not shape_node.has_meta("track_side_sign"):
			continue
		# "local" identifies this body's contact, not its coordinate space;
		# the Jolt backend reports the world-space manifold normal.
		var normal := state.get_contact_local_normal(index).normalized()
		if normal.dot(Vector3.UP) < MIN_SUPPORT_UP_DOT or normal.dot(body.global_basis.y) < MIN_SUPPORT_UP_DOT:
			continue
		var load := minf(absf(state.get_contact_impulse(index).dot(normal)) / maxf(delta, 0.001), budget)
		if load <= 0.01:
			continue
		var point := state.get_contact_collider_position(index)
		var hit: Dictionary = accept_hit.call({"position":point,"normal":normal,"rid":state.get_contact_collider(index),"collider":state.get_contact_collider_object(index)})
		if hit.is_empty():
			continue
		budget -= load
		hit["point"] = point
		hit["load"] = load
		hit["side"] = 0 if float(shape_node.get_meta("track_side_sign")) == forward_sign else 1
		result.append(hit)
		if budget <= 0.0:
			break
	return result

func _drive_effort(command: float, speed: float, current: float, delta: float, supported: bool) -> float:
	var maximum := float(_tracks["max_drive_force_n"])
	# A held direction must develop tractive effort even while gravity causes
	# rollback. Neutral alone uses the no-crossing brake; a reverse command
	# naturally brakes and then drives through zero via its bounded target.
	var braking := absf(command) < 0.001
	var slew := float(_tracks.get("brake_effort_slew_n_per_tick" if braking else "drive_effort_slew_n_per_tick",maximum)) * REFERENCE_TICK_HZ * delta
	if not supported:
		return move_toward(current,0.0,slew)
	var target := command * float(_tracks["max_belt_speed_m_s"])
	var effort := (target-speed)*float(_tracks["traction_response_n_per_m_s"])
	if braking:
		effort = -speed * float(_tracks["brake_force_n"])
		var momentum_budget := float(_dynamics["mass_kg"])*absf(speed)/maxf(delta,0.001)*0.45
		effort = clampf(effort,-momentum_budget,momentum_budget)
		if current*speed > 0.0:
			current = 0.0
		current = clampf(current,-momentum_budget,momentum_budget)
	return move_toward(current,clampf(effort,-maximum,maximum),slew)

func _record_rejection(output: Dictionary, reason: String) -> void:
	output["rejections"][reason] = int(output["rejections"].get(reason,0))+1

func _add_shape(body: RigidBody3D, shape: Shape3D, position: Vector3, label: String) -> void:
	var collision := CollisionShape3D.new()
	collision.name = label
	collision.shape = shape
	collision.position = position
	if label == "TrackHull":
		collision.set_meta("track_side_sign", signf(position.x))
	body.add_child(collision)

func _vec3(value: Array) -> Vector3:
	return Vector3(float(value[0]),float(value[1]),float(value[2]))

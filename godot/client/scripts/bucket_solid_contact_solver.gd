extends RefCounted

## Query-only physical plates + a unilateral compliant contact constraint.
## No angle/cutting classification, chassis pose writes, or retained world anchors.
## Fresh witnesses each tick naturally release on separation and follow objects.
const SKIN_M := 0.004
const MAX_COMPRESSION_M := 0.06
const FREQUENCY_HZ := 12.0
const DAMPING_RATIO := 1.0
const MAX_FORCE_N := 180000.0
const MAX_TORQUE_NM := 320000.0
const MAX_CONTACTS := 4
const MAX_FILTERED_HITS := 16

var parts: Array[Dictionary] = []
var collision_mask := 1


func configure(contract: Dictionary, mask: int) -> bool:
	parts.clear()
	collision_mask = mask
	var tool := BucketSoilTool.new()
	if not tool.configure(contract):
		return false
	for value in contract.get("bucket_tool", {}).get("regions", []):
		var region := value as Dictionary
		var kind := String(region.get("kind", ""))
		if not ["teeth", "side_cutter", "floor", "outer_shell"].has(kind):
			continue
		var geometry := region["shape"] as Dictionary
		var shape: Shape3D
		var local := tool.region_local_transform(region)
		if geometry["kind"] == "segment":
			var capsule := CapsuleShape3D.new()
			capsule.radius = float(geometry["radius_m"])
			capsule.height = 2.0 * (float(geometry["half_length_m"]) + capsule.radius)
			# Semantic segments use local Z; Godot capsules use local Y.
			local.basis = local.basis * Basis(Vector3.RIGHT, PI * 0.5)
			shape = capsule
		else:
			var box := BoxShape3D.new()
			var size := geometry["size_m"] as Array
			box.size = Vector3(float(size[0]), float(size[1]), float(size[2]))
			shape = box
		parts.append({"shape": shape, "local": local, "region_id": region["region_id"],
			"proxy_role": "cutting_edge" if kind == "teeth" else "shell"})
	return not parts.is_empty()


func query_contacts(
	space: PhysicsDirectSpaceState3D, current: Transform3D, candidate: Transform3D,
	chassis: RigidBody3D, accept_hit: Callable, previous_world := Transform3D.IDENTITY
) -> Dictionary:
	var contacts: Array[Dictionary] = []
	var fraction := 1.0
	for part in parts:
		var sweep_start := current if previous_world == Transform3D.IDENTITY else previous_world
		var start := sweep_start * (part["local"] as Transform3D)
		var finish := candidate * (part["local"] as Transform3D)
		var shape := part["shape"] as Shape3D
		var records := _overlaps(space, shape, finish, chassis.get_rid(), accept_hit)
		# Translation casts supplement overlap contacts for thin obstacles. Rotation
		# is covered by bounded intermediate poses, rather than a translation-only cast.
		var angle := start.basis.get_rotation_quaternion().angle_to(finish.basis.get_rotation_quaternion())
		var segments := clampi(maxi(ceili(angle / deg_to_rad(3.0)),
			ceili(start.origin.distance_to(finish.origin) / 0.06)), 1, 12)
		if start.origin.distance_to(finish.origin) > 0.001 or angle > 0.001:
			for index in segments:
				var a := start.interpolate_with(finish, float(index) / segments)
				var b := start.interpolate_with(finish, float(index + 1) / segments)
				var swept := _cast_contact(space, shape, a, b, chassis.get_rid(), accept_hit)
				if swept.is_empty():
					swept = _overlaps(space, shape, b, chassis.get_rid(), accept_hit)
				if swept.is_empty():
					continue
				for hit in swept:
					var witness := b.affine_inverse() * (hit["query_point"] as Vector3)
					var end_point := finish * witness
					hit["query_point"] = end_point
					hit["penetration_m"] = maxf(0.0, ((hit["point_world"] as Vector3) - end_point).dot(hit["normal_world"]))
				records.append_array(swept)
				break
		for contact in records:
			var local_point := candidate.affine_inverse() * (contact["query_point"] as Vector3)
			var motion := candidate * local_point - current * local_point
			var inward := -motion.dot(contact["normal_world"])
			var depth := float(contact["penetration_m"])
			if inward > 0.000001 and depth > MAX_COMPRESSION_M:
				fraction = minf(fraction, clampf(1.0 - (depth - MAX_COMPRESSION_M) / inward, 0.0, 1.0))
			contact["local_point"] = local_point
			contact["region_id"] = part["region_id"]
			contact["proxy_role"] = part["proxy_role"]
			_merge_contact(contacts, contact)
	return {"contacts": contacts, "accepted_fraction": fraction}


func solve(contacts: Array, current: Transform3D, accepted: Transform3D, chassis: RigidBody3D, delta: float) -> Dictionary:
	var forces: Array[Dictionary] = []
	var total_force := Vector3.ZERO
	var total_torque := Vector3.ZERO
	var com := center_of_mass_world(chassis)
	var inverse_inertia := _inverse_inertia(chassis)
	var virtual_linear := chassis.linear_velocity
	var virtual_angular := chassis.angular_velocity
	var dt := maxf(delta, 0.001)
	for contact_value in contacts:
		var contact := contact_value as Dictionary
		var normal := contact["normal_world"] as Vector3
		var local_point := contact["local_point"] as Vector3
		var point := contact["point_world"] as Vector3
		var accepted_point := accepted * local_point
		var depth := clampf((point - accepted_point).dot(normal), 0.0, MAX_COMPRESSION_M)
		var lever := point - com
		var angular_axis := lever.cross(normal)
		var inverse_mass := 1.0 / chassis.mass + angular_axis.dot(inverse_inertia * angular_axis)
		var other := instance_from_id(int(contact["collider_id"])) as RigidBody3D
		var other_velocity := contact.get("surface_velocity", Vector3.ZERO) as Vector3
		if other != null and not other.freeze:
			var other_lever := point - center_of_mass_world(other)
			var other_axis := other_lever.cross(normal)
			inverse_mass += 1.0 / other.mass + other_axis.dot(_inverse_inertia(other) * other_axis)
			other_velocity = other.linear_velocity + other.angular_velocity.cross(other_lever)
		var articulation_velocity := (accepted_point - current * local_point) / dt
		var relative_velocity := (virtual_linear + virtual_angular.cross(lever) + articulation_velocity - other_velocity).dot(normal)
		# Backward-Euler spring/damper, expressed through contact effective mass.
		# Compression is in metres, not per-tick command travel; neutral holds load.
		var omega := TAU * FREQUENCY_HZ
		var stiffness := omega * omega / inverse_mass
		var damping := 2.0 * DAMPING_RATIO * omega / inverse_mass
		var magnitude := maxf(0.0, (stiffness * depth - (damping + stiffness * dt) * relative_velocity)
			/ (1.0 + (damping * dt + stiffness * dt * dt) * inverse_mass))
		magnitude = minf(magnitude, maxf(0.0, MAX_FORCE_N - total_force.length()))
		var torque_per_newton := lever.cross(normal)
		if torque_per_newton.length() > 0.001:
			magnitude = minf(magnitude, maxf(0.0, MAX_TORQUE_NM - total_torque.length()) / torque_per_newton.length())
		var force := normal * magnitude
		var torque := lever.cross(force)
		forces.append({"force": force, "torque": torque, "point": point,
			"collider_id": contact["collider_id"], "rid": contact["rid"]})
		total_force += force
		total_torque += torque
		virtual_linear += force * dt / chassis.mass
		virtual_angular += inverse_inertia * torque * dt
	return {"forces": forces, "force": total_force, "torque": total_torque}


func _overlaps(space: PhysicsDirectSpaceState3D, shape: Shape3D, pose: Transform3D, self_rid: RID, accept_hit: Callable) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var query := _query(shape, pose, self_rid)
	for _attempt in MAX_FILTERED_HITS:
		var rest := space.get_rest_info(query)
		if rest.is_empty():
			break
		var rid: RID = rest["rid"]
		if accept_hit.call(rest):
			# collide_shape pairs have no collider identity. Isolate the selected RID
			# first so a voxel/other obstacle cannot lend its normal to this contact.
			var isolated := _query(shape, pose, self_rid)
			var isolated_exclusions: Array[RID] = query.exclude.duplicate()
			for hit in space.intersect_shape(query, 32):
				if hit["rid"] != rid:
					isolated_exclusions.append(hit["rid"])
			isolated.exclude = isolated_exclusions
			var pairs := space.collide_shape(isolated, 16)
			var best_depth := 0.0
			var normal: Vector3 = rest["normal"]
			var point: Vector3 = rest["point"]
			var query_point := point
			for index in range(0, pairs.size() - 1, 2):
				var difference := pairs[index + 1] - pairs[index]
				if difference.dot(normal) > best_depth:
					best_depth = difference.dot(normal)
					query_point = pairs[index]
					point = pairs[index + 1]
			# A flat tooth line/plate bears across its width. Averaging equally
			# deep witnesses avoids arbitrary left/right torque from Jolt ordering.
			var point_sum := Vector3.ZERO
			var query_sum := Vector3.ZERO
			var count := 0
			for index in range(0, pairs.size() - 1, 2):
				if (pairs[index + 1] - pairs[index]).dot(normal) >= best_depth - 0.001:
					query_sum += pairs[index]
					point_sum += pairs[index + 1]
					count += 1
			if count > 0:
				query_point = query_sum / count
				point = point_sum / count
			if normal.is_finite() and normal.length_squared() > 0.5 and point.is_finite():
				result.append({"point_world": point, "query_point": query_point,
					"normal_world": normal.normalized(), "penetration_m": best_depth,
					"collider_id": int(rest.get("collider_id", 0)), "rid": rid,
					"surface_velocity": rest.get("linear_velocity", Vector3.ZERO)})
			if result.size() >= 2:
				break
		var exclusions: Array[RID] = query.exclude
		exclusions.append(rid)
		query.exclude = exclusions
	return result


func _cast_contact(space: PhysicsDirectSpaceState3D, shape: Shape3D, start: Transform3D, finish: Transform3D, self_rid: RID, accept_hit: Callable) -> Array[Dictionary]:
	var query := _query(shape, start, self_rid)
	query.motion = finish.origin - start.origin
	for _attempt in MAX_FILTERED_HITS:
		var fractions := space.cast_motion(query)
		if fractions.size() < 2 or fractions[0] >= 1.0:
			break
		var pose := start.interpolate_with(finish, minf(1.0, fractions[1] + 0.001))
		var rest_query := _query(shape, pose, self_rid)
		rest_query.exclude = query.exclude.duplicate()
		var rest := space.get_rest_info(rest_query)
		if rest.is_empty():
			break
		if accept_hit.call(rest):
			var point: Vector3 = rest["point"]
			# Reproject the witness to the segment endpoint for remaining travel.
			return [{"point_world": point, "query_point": finish * (pose.affine_inverse() * point),
				"normal_world": rest["normal"], "penetration_m": 0.0,
				"collider_id": int(rest.get("collider_id", 0)), "rid": rest["rid"],
				"surface_velocity": rest.get("linear_velocity", Vector3.ZERO)}]
		var exclusions: Array[RID] = query.exclude
		exclusions.append(rest["rid"])
		query.exclude = exclusions
	return []


func _merge_contact(contacts: Array[Dictionary], contact: Dictionary) -> void:
	for index in contacts.size():
		var existing := contacts[index]
		if existing["rid"] == contact["rid"] and (existing["normal_world"] as Vector3).dot(contact["normal_world"]) > 0.95:
			if float(contact["penetration_m"]) > float(existing["penetration_m"]):
				contacts[index] = contact
			return
	if contacts.size() < MAX_CONTACTS:
		contacts.append(contact)


func _query(shape: Shape3D, pose: Transform3D, self_rid: RID) -> PhysicsShapeQueryParameters3D:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = pose
	query.margin = SKIN_M
	query.collision_mask = collision_mask
	query.exclude = [self_rid]
	return query


func _inverse_inertia(body: RigidBody3D) -> Basis:
	var state := PhysicsServer3D.body_get_direct_state(body.get_rid())
	return state.inverse_inertia_tensor if state != null else Basis.IDENTITY


func center_of_mass_world(body: RigidBody3D) -> Vector3:
	var state := PhysicsServer3D.body_get_direct_state(body.get_rid())
	# Direct-state COM is a world-oriented offset from body origin (including
	# automatic COM from offset shapes); the Node property is custom-mode only.
	return body.global_position + state.center_of_mass if state != null else body.global_transform * body.center_of_mass

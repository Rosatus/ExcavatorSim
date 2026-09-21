class_name PassiveHydraulics
extends RefCounted

## Presentation-only pin followers. No AnimationPlayer, operator inputs or
## authority writes. Source geometry remains rigid; rods translate into barrels.
var error := ""
var _root: Node3D
var _cylinders: Array[Dictionary] = []
var _hoses: Array[Dictionary] = []
var _bar: Dictionary = {}
var _rest: Dictionary = {}
var _previous_a := Vector2.ZERO


func configure(asset: Node3D, contract: Dictionary) -> bool:
	_root = asset
	_cylinders.clear()
	_hoses.clear()
	_bar.clear()
	_rest.clear()
	error = ""
	if contract.is_empty():
		return true
	for value in contract.get("cylinders", []):
		var spec: Dictionary = value
		var entry := {"id": String(spec.get("id", ""))}
		for key in ["barrel", "rod", "a_node", "b_node"]:
			var node := asset.get_node_or_null(NodePath(String(spec.get(key, "")))) as Node3D
			if node == null:
				return _reject("missing_cylinder_node:%s:%s" % [entry.id, key])
			entry[key] = node
		entry["a_point"] = _vector(spec.get("a_point", []))
		entry["b_point"] = _vector(spec.get("b_point", []))
		var barrel := entry.barrel as Node3D
		var rod := entry.rod as Node3D
		if barrel.get_parent() != rod.get_parent():
			return _reject("cylinder_parent_mismatch:%s" % entry.id)
		var parent := barrel.get_parent() as Node3D
		var direction := parent.to_local(_pin(entry, "b")) - parent.to_local(_pin(entry, "a"))
		if not direction.is_finite() or direction.length() < 0.000001:
			return _reject("degenerate_cylinder:%s" % entry.id)
		entry["rest_direction"] = direction.normalized()
		_rest[barrel] = barrel.transform
		_rest[rod] = rod.transform
		_cylinders.append(entry)
	var bar_spec: Dictionary = contract.get("four_bar", {})
	if not bar_spec.is_empty():
		for key in ["arm", "bucket", "rocker", "coupler"]:
			var node := asset.get_node_or_null(NodePath(String(bar_spec.get(key, "")))) as Node3D
			if node == null:
				return _reject("missing_four_bar_node:%s" % key)
			_bar[key] = node
		_bar["bucket_pin"] = _vector(bar_spec.get("bucket_pin", []))
		_bar["rocker_tip"] = _vector(bar_spec.get("rocker_tip", []))
		_bar["r"] = float(bar_spec.get("rocker_length_m", 0.0))
		_bar["l"] = float(bar_spec.get("coupler_length_m", 0.0))
		var rocker := _bar.rocker as Node3D
		var coupler := _bar.coupler as Node3D
		if rocker.get_parent() != _bar.arm or coupler.get_parent() != _bar.arm or _bar.r <= 0.0 or _bar.l <= 0.0:
			return _reject("invalid_four_bar_topology")
		_rest[rocker] = rocker.transform
		_rest[coupler] = coupler.transform
		_bar["rest_a"] = rocker.transform * (_bar.rocker_tip as Vector3)
		_bar["rest_c"] = (_bar.arm as Node3D).to_local((_bar.bucket as Node3D).to_global(_bar.bucket_pin))
		_previous_a = _yz(_bar.rest_a)
	for value in contract.get("hoses", []):
		var spec: Dictionary = value
		var mesh := asset.get_node_or_null(NodePath(String(spec.get("mesh", "")))) as MeshInstance3D
		var joint := asset.get_node_or_null(NodePath(String(spec.get("joint", "")))) as Node3D
		var count := int(spec.get("target_count", 0))
		if mesh == null or mesh.mesh == null or joint == null or count < 2 or mesh.mesh.get_blend_shape_count() != count:
			return _reject("invalid_hose:%s" % spec.get("mesh", ""))
		if float(spec.get("max_degrees", 0)) <= float(spec.get("min_degrees", 0)):
			return _reject("invalid_hose_range")
		var entry := spec.duplicate()
		entry["mesh"] = mesh
		entry["joint"] = joint
		entry["rest_basis"] = joint.basis
		_hoses.append(entry)
	return update()


func restore() -> void:
	for node: Node3D in _rest:
		if is_instance_valid(node):
			node.transform = _rest[node]
	if not _bar.is_empty():
		_previous_a = _yz(_bar.rest_a)
	update()


func update() -> bool:
	if _cylinders.is_empty():
		return true
	# Stage every passive transform; restore all of them on invalid input.
	var previous := {}
	for node: Node3D in _rest:
		previous[node] = node.transform
	var previous_a := _previous_a
	if not _solve_four_bar() or not _solve_cylinders():
		for node: Node3D in previous:
			node.transform = previous[node]
		_previous_a = previous_a
		return false
	for entry in _hoses:
		var joint := entry.joint as Node3D
		var delta := (entry.rest_basis as Basis).inverse() * joint.basis
		if not delta.is_finite():
			for node: Node3D in previous:
				node.transform = previous[node]
			_previous_a = previous_a
			return _reject("non_finite_hose_joint")
	# Validate all joint inputs before changing any shape weights.
	for entry in _hoses:
		var delta := (entry.rest_basis as Basis).inverse() * (entry.joint as Node3D).basis
		var degrees := float(entry.rest_degrees) + rad_to_deg(atan2(delta.y.z, delta.y.y))
		var count := int(entry.target_count)
		var key := clampf((degrees - float(entry.min_degrees)) / (float(entry.max_degrees) - float(entry.min_degrees)) * (count - 1), 0, count - 1)
		var low := mini(int(key), count - 2)
		for index in count:
			var weight := 1.0 - (key - low) if index == low else (key - low) if index == low + 1 else 0.0
			(entry.mesh as MeshInstance3D).set_blend_shape_value(index, weight)
	error = ""
	return true


func _solve_four_bar() -> bool:
	if _bar.is_empty():
		return true
	var arm := _bar.arm as Node3D
	var rocker := _bar.rocker as Node3D
	var coupler := _bar.coupler as Node3D
	var b := (_rest[rocker] as Transform3D).origin
	var c := arm.to_local((_bar.bucket as Node3D).to_global(_bar.bucket_pin))
	if not b.is_finite() or not c.is_finite() or absf(b.x - c.x) > 0.0001:
		return _reject("non_planar_four_bar")
	var difference := _yz(c) - _yz(b)
	var distance := difference.length()
	var r := float(_bar.r)
	var length := float(_bar.l)
	if distance < 0.000001 or distance > r + length + 0.000001 or distance < absf(r - length) - 0.000001:
		return _reject("unreachable_four_bar")
	var along := (r * r - length * length + distance * distance) / (2.0 * distance)
	var height := sqrt(maxf(0, r * r - along * along))
	var direction := difference / distance
	var middle := _yz(b) + along * direction
	var perpendicular := Vector2(-direction.y, direction.x) * height
	var a1 := middle + perpendicular
	var a2 := middle - perpendicular
	var a := a1 if a1.distance_squared_to(_previous_a) <= a2.distance_squared_to(_previous_a) else a2
	var rest_a := _yz(_bar.rest_a)
	var rocker_rest := _rest[rocker] as Transform3D
	var coupler_rest := _rest[coupler] as Transform3D
	var rocker_delta := (rest_a - _yz(b)).angle_to(a - _yz(b))
	var coupler_delta := (_yz(_bar.rest_c) - rest_a).angle_to(_yz(c) - a)
	rocker.transform = Transform3D(Basis(Vector3.RIGHT, rocker_delta) * rocker_rest.basis, rocker_rest.origin)
	coupler.transform = Transform3D(Basis(Vector3.RIGHT, coupler_delta) * coupler_rest.basis, Vector3(b.x, a.x, a.y))
	_previous_a = a
	return true


func _solve_cylinders() -> bool:
	for entry in _cylinders:
		var barrel := entry.barrel as Node3D
		var rod := entry.rod as Node3D
		var parent := barrel.get_parent() as Node3D
		var a := parent.to_local(_pin(entry, "a"))
		var b := parent.to_local(_pin(entry, "b"))
		var direction := b - a
		if not a.is_finite() or not b.is_finite() or direction.length() < 0.000001 or absf(direction.x) > 0.0001:
			return _reject("invalid_cylinder_pins:%s" % entry.id)
		var angle := (entry.rest_direction as Vector3).signed_angle_to(direction.normalized(), Vector3.RIGHT)
		var rotation := Basis(Vector3.RIGHT, angle)
		barrel.transform = Transform3D(rotation * (_rest[barrel] as Transform3D).basis, a)
		rod.transform = Transform3D(rotation * (_rest[rod] as Transform3D).basis, b)
	return true


func snapshot() -> Dictionary:
	var pairs := []
	for entry in _cylinders:
		pairs.append({"id": entry.id,
			"barrel_error_m": (entry.barrel as Node3D).global_position.distance_to(_pin(entry, "a")),
			"rod_error_m": (entry.rod as Node3D).global_position.distance_to(_pin(entry, "b"))})
	return {"error": error, "cylinder_count": _cylinders.size(), "hose_count": _hoses.size(), "pins": pairs}


func _pin(entry: Dictionary, end: String) -> Vector3:
	return (entry[end + "_node"] as Node3D).to_global(entry[end + "_point"])


func _reject(reason: String) -> bool:
	error = reason
	return false


static func _vector(value: Array) -> Vector3:
	if value.size() != 3:
		return Vector3(INF, INF, INF)
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


static func _yz(value: Vector3) -> Vector2:
	return Vector2(value.y, value.z)

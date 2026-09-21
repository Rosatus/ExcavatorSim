class_name WheelVisualAnimator
extends Node3D
## Visual-only, one mount -> steer pivot -> rolling mesh per station.
## Paths are relative to this node. Pivots must be distinct nodes, in wheel order.
@export var wheel_paths: Array[NodePath] = []
@export var steering_pivot_paths: Array[NodePath] = []
@export var roll_axis := Vector3.RIGHT
@export var steer_axis := Vector3.UP
@export var rest_suspension_lengths_m: Array[float] = []
var _wheels: Array[Node3D] = []
var _pivots: Array[Node3D] = []
var _rest: Array[Transform3D] = []
var _pivot_rest: Array[Transform3D] = []
var _bound := false

func _ready() -> void:
	bind_wheels(wheel_paths, steering_pivot_paths)

func bind_wheels(paths: Array[NodePath], pivots: Array[NodePath]) -> bool:
	reset_animation()
	_bound = false
	_wheels.clear()
	_pivots.clear()
	_rest.clear()
	_pivot_rest.clear()
	if paths.is_empty() or paths.size() != pivots.size() or not roll_axis.is_finite() or roll_axis.length_squared() < 0.5 or not steer_axis.is_finite() or steer_axis.length_squared() < 0.5:
		return false
	var seen: Array[Node] = []
	for index in paths.size():
		var wheel := get_node_or_null(paths[index]) as Node3D
		var pivot := get_node_or_null(pivots[index]) as Node3D
		if wheel == null or pivot == null or wheel == pivot or seen.has(wheel) or seen.has(pivot) or wheel.get_parent() != pivot:
			_wheels.clear()
			_pivots.clear()
			return false
		seen.append(wheel)
		seen.append(pivot)
		_wheels.append(wheel)
		_pivots.append(pivot)
		_rest.append(wheel.transform)
		_pivot_rest.append(pivot.transform)
	_bound = true
	return true

func apply_physics_snapshot(snapshot: Dictionary, _delta: float = 0.0) -> void:
	var samples: Array = snapshot.get("wheels", [])
	if not _bound or samples.size() != _wheels.size():
		return
	for index in samples.size():
		var row: Dictionary = samples[index]
		var roll := float(row.get("roll_angle_rad", NAN))
		var steer := float(row.get("steer_angle_rad", NAN))
		var length := float(row.get("suspension_length_m", NAN))
		if not is_finite(roll) or not is_finite(steer) or not is_finite(length):
			return
	for index in samples.size():
		if not is_instance_valid(_wheels[index]) or not is_instance_valid(_pivots[index]):
			continue
		var row: Dictionary = samples[index]
		var pose := _pivot_rest[index]
		var rest_length := rest_suspension_lengths_m[index] if rest_suspension_lengths_m.size() == samples.size() else 0.0
		pose.origin -= Vector3.UP * (float(row.suspension_length_m) - rest_length)
		pose.basis = pose.basis * Basis(steer_axis.normalized(), -float(row.steer_angle_rad))
		_pivots[index].transform = pose
		pose = _rest[index]
		pose.basis *= Basis(roll_axis.normalized(), -float(row.roll_angle_rad))
		_wheels[index].transform = pose

func reset_animation() -> void:
	for index in _wheels.size():
		if is_instance_valid(_wheels[index]):
			_wheels[index].transform = _rest[index]
	for index in _pivots.size():
		if is_instance_valid(_pivots[index]):
			_pivots[index].transform = _pivot_rest[index]

## Import-specific rest validation precedes binding. This never reparents or
## re-exports a GLB and never changes vertices or the work-equipment chain.
func configure_imported(asset: Node3D, profile: WheeledMachineProfile) -> bool:
	var paths: Array[NodePath] = []
	var pivots: Array[NodePath] = []
	var lengths: Array[float] = []
	for row: Dictionary in profile.data.wheels:
		var pivot := asset.get_node_or_null(row.pivot_path) as Node3D
		var wheel := asset.get_node_or_null(row.roll_path) as Node3D
		if pivot == null or wheel == null or wheel.get_parent() != pivot:
			return false
		var expected := Transform3D(Basis(WheeledMachineProfile.vec(row.rest_basis[0]), WheeledMachineProfile.vec(row.rest_basis[1]), WheeledMachineProfile.vec(row.rest_basis[2])), WheeledMachineProfile.vec(row.rest_origin))
		if pivot.position.distance_to(expected.origin) > 0.001 or not pivot.basis.is_equal_approx(expected.basis) or not wheel.transform.is_equal_approx(Transform3D.IDENTITY):
			return false
		paths.append(get_path_to(wheel))
		pivots.append(get_path_to(pivot))
		lengths.append(float(row.rest_suspension_length_m))
	roll_axis = WheeledMachineProfile.vec(profile.data.roll_axis)
	steer_axis = WheeledMachineProfile.vec(profile.data.steer_axis)
	rest_suspension_lengths_m = lengths
	return bind_wheels(paths, pivots)

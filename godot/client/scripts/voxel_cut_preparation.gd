class_name VoxelCutPreparation
extends RefCounted

# Private preparation only: never owns a terrain, material field or scene node.
# The authority keeps one job and publishes its SDF and ledger together.
const MAX_PROBES := 16384
const COVERAGE_STEP := 1.5
const OFFSETS: Array[Vector3i] = [Vector3i.ZERO, Vector3i.RIGHT, Vector3i.UP]
const EDIT_SEGMENTS_PER_SLICE := 8

var paths: Array[Dictionary] = []
var unique: Dictionary = {}
var geometry_candidates: Dictionary = {}
var coordinates: Array[Vector3i] = []
var coverage_done := false
var edit_done := false
var buffer: VoxelBuffer
var buffer_origin := Vector3i.ZERO
var coverage_usec := 0
var edit_usec := 0
var bounds_min := Vector3i.ZERO
var bounds_max := Vector3i.ZERO
var coverage_size := Vector3i.ZERO
var x_ranks := PackedInt32Array()
var y_ranks := PackedInt32Array()
var z_ranks := PackedInt32Array()
var _path_index := 0
var _segment_index := 0
var _edit_path_index := 0
var _edit_point_index := 0
var accounting_origin := Vector3i.ZERO
var accounting_size := Vector3i.ZERO
var _buffer_tool: VoxelTool
var _solid_y_min := 0
var _solid_y_max := -1
var _bounded_coverage := false
var _solid_mask := PackedByteArray()
var _snapshot_size := Vector3i.ZERO
var occupancy_usec := 0
var skipped_coverage_steps := 0


func configure(edit_paths: Array[Dictionary], minimum: Vector3i, size: Vector3i, ranks: Array[PackedInt32Array]) -> void:
	paths = edit_paths
	bounds_min = minimum
	bounds_max = minimum + size - Vector3i.ONE
	coverage_size = size
	x_ranks = ranks[0]
	y_ranks = ranks[1]
	z_ranks = ranks[2]


func advance_coverage(deadline_usec: int) -> void:
	var started := Time.get_ticks_usec()
	while not coverage_done and Time.get_ticks_usec() < deadline_usec:
		if _path_index >= paths.size():
			coverage_done = true
			break
		var path := paths[_path_index]
		var points := path.get("points_voxels", PackedVector3Array()) as PackedVector3Array
		var radii := path.get("radii_voxels", PackedFloat32Array()) as PackedFloat32Array
		if _segment_index >= points.size() - 1:
			_path_index += 1
			_segment_index = 0
			continue
		_add_segment(points[_segment_index], points[_segment_index + 1], radii[_segment_index], radii[_segment_index + 1])
		_segment_index += 1
	coverage_usec += Time.get_ticks_usec() - started


func begin_edit(snapshot: VoxelBuffer, origin: Vector3i, sdf_scale: float, sdf_strength: float) -> void:
	buffer = snapshot
	buffer_origin = origin
	_buffer_tool = buffer.get_voxel_tool()
	_buffer_tool.channel = VoxelBuffer.CHANNEL_SDF
	_buffer_tool.mode = VoxelTool.MODE_REMOVE
	_buffer_tool.sdf_scale = sdf_scale
	_buffer_tool.sdf_strength = sdf_strength


func advance_edit(deadline_usec: int) -> void:
	var started := Time.get_ticks_usec()
	while not edit_done and Time.get_ticks_usec() < deadline_usec:
		if _edit_path_index >= paths.size():
			edit_done = true
			break
		var path := paths[_edit_path_index]
		var points := path.get("points_voxels", PackedVector3Array()) as PackedVector3Array
		var radii := path.get("radii_voxels", PackedFloat32Array()) as PackedFloat32Array
		if _edit_point_index >= points.size() - 1:
			_edit_path_index += 1
			_edit_point_index = 0
			continue
		var end := mini(points.size(), _edit_point_index + EDIT_SEGMENTS_PER_SLICE + 1)
		var local_points := points.slice(_edit_point_index, end)
		for index in local_points.size():
			local_points[index] -= Vector3(buffer_origin)
		_buffer_tool.do_path(local_points, radii.slice(_edit_point_index, end))
		_edit_point_index = end - 1
	edit_usec += Time.get_ticks_usec() - started


func _add_segment(a: Vector3, b: Vector3, radius_a: float, radius_b: float) -> void:
	var direction := b - a
	var distance_squared := direction.length_squared()
	var distance := sqrt(distance_squared)
	var steps := maxi(1, ceili(distance / COVERAGE_STEP))
	var first_step := 0
	var last_step := steps
	if _bounded_coverage:
		# Keep the original sample lattice (including endpoint rounding). Only
		# exclude samples that cannot reach any solid row, even with OFFSETS.
		var low := float(_solid_y_min) - 2.0
		var high := float(_solid_y_max) + 1.0
		if _solid_y_max < _solid_y_min or (absf(direction.y) < 0.000001 and (a.y < low or a.y > high)):
			skipped_coverage_steps += steps + 1
			return
		if absf(direction.y) >= 0.000001:
			var alpha_a := (low - a.y) / direction.y
			var alpha_b := (high - a.y) / direction.y
			first_step = maxi(0, ceili(minf(alpha_a, alpha_b) * steps) - 1)
			last_step = mini(steps, floori(maxf(alpha_a, alpha_b) * steps) + 1)
			skipped_coverage_steps += steps + 1 - maxi(0, last_step - first_step + 1)
	for step_index in range(first_step, last_step + 1):
		var alpha := float(step_index) / float(steps)
		var sample := a.lerp(b, alpha)
		var radius := lerpf(radius_a, radius_b, alpha)
		var center := Vector3i(roundi(sample.x), roundi(sample.y), roundi(sample.z))
		for offset in OFFSETS:
			var coordinate := center + offset
			# A strict candidate was already inserted into unique on its first
			# visit. Later samples cannot change either membership or ordering.
			if geometry_candidates.has(coordinate):
				continue
			if coordinate.x < bounds_min.x or coordinate.y < bounds_min.y or coordinate.z < bounds_min.z \
					or coordinate.x > bounds_max.x or coordinate.y > bounds_max.y or coordinate.z > bounds_max.z:
				continue
			var dx := float(coordinate.x) - sample.x
			var dy := float(coordinate.y) - sample.y
			var dz := float(coordinate.z) - sample.z
			var reach := radius + 0.55
			if dx * dx + dy * dy + dz * dz > reach * reach:
				continue
			# Credit's broad stencil can reach outside the brush. Track strict
			# geometric inclusion separately. A prior failed check cannot skip
			# this segment, whose radius may include the same coordinate.
			# Leave a small SDF quantization margin.
			if distance_squared > 0.00000001:
				var ax := float(coordinate.x) - a.x
				var ay := float(coordinate.y) - a.y
				var az := float(coordinate.z) - a.z
				var closest_alpha := clampf((ax * direction.x + ay * direction.y + az * direction.z) / distance_squared, 0.0, 1.0)
				var exact_radius := lerpf(radius_a, radius_b, closest_alpha) - 0.02
				var ex := ax - direction.x * closest_alpha
				var ey := ay - direction.y * closest_alpha
				var ez := az - direction.z * closest_alpha
				if exact_radius > 0.0 and ex * ex + ey * ey + ez * ez < exact_radius * exact_radius:
					geometry_candidates[coordinate] = true
			# Integer keys retain the old decimal-string lexical order so
			# the capped sample subset and transaction digests stay identical.
			var key := (x_ranks[coordinate.x - bounds_min.x] * coverage_size.y \
				+ y_ranks[coordinate.y - bounds_min.y]) * coverage_size.z \
				+ z_ranks[coordinate.z - bounds_min.z]
			if unique.has(key):
				continue
			unique[key] = coordinate
			if unique.size() >= MAX_PROBES:
				coverage_done = true
				return


func compute_snapshot() -> void:
	# Worker owns all mutable job state until its completion receipt is reaped.
	var index_started := Time.get_ticks_usec()
	_snapshot_size = buffer.get_size()
	# Omitting air candidates is equivalent only when the legacy MAX_PROBES
	# cutoff cannot be reached. Large snapshots retain the complete walker.
	_bounded_coverage = _snapshot_size.x * _snapshot_size.y * _snapshot_size.z < MAX_PROBES
	if _bounded_coverage:
		var occupancy := _row_bounds_below(0.000001)
		_solid_y_min = buffer_origin.y + occupancy.x
		_solid_y_max = buffer_origin.y + occupancy.y
	occupancy_usec = Time.get_ticks_usec() - index_started
	advance_coverage(0x7FFFFFFFFFFFFFFF)
	var started := Time.get_ticks_usec()
	var keys := unique.keys()
	keys.sort()
	var raw := buffer.get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF)
	var size := buffer.get_size()
	for key in keys:
		var coordinate := unique[key] as Vector3i
		var local := coordinate - accounting_origin
		if local.x < 0 or local.y < 0 or local.z < 0 \
				or local.x >= accounting_size.x or local.y >= accounting_size.y or local.z >= accounting_size.z:
			continue
		var read_local := coordinate - buffer_origin
		var byte_index := ((read_local.z * size.x + read_local.x) * size.y + read_local.y) * 2
		var hi := raw[byte_index + 1]
		if hi < 0x80 and (hi != 0 or raw[byte_index] != 0):
			continue
		coordinates.append(coordinate)
		if coordinates.size() >= 4096:
			break
	coverage_usec += Time.get_ticks_usec() - started
	if not coordinates.is_empty():
		advance_edit(0x7FFFFFFFFFFFFFFF)
	_solid_mask.clear()


func _row_bounds_below(threshold: float) -> Vector2i:
	# Native vector operation + native byte searches avoid a GDScript walk
	# through the full depth of every column. This index belongs to a single
	# immutable snapshot, so refill, reset and revision changes cannot stale it.
	var mask := VoxelBuffer.new()
	mask.set_channel_depth(VoxelBuffer.CHANNEL_TYPE, VoxelBuffer.DEPTH_8_BIT)
	mask.create(_snapshot_size.x, _snapshot_size.y, _snapshot_size.z)
	mask.op_select_less_src_f_dst_i_values(buffer, VoxelBuffer.CHANNEL_SDF, threshold, 1, 0, VoxelBuffer.CHANNEL_TYPE)
	_solid_mask = mask.get_channel_as_byte_array(VoxelBuffer.CHANNEL_TYPE)
	var low := _snapshot_size.y
	var high := -1
	for column in _snapshot_size.x * _snapshot_size.z:
		var begin := column * _snapshot_size.y
		var bytes := _solid_mask.slice(begin, begin + _snapshot_size.y)
		var first := bytes.find(1)
		if first >= 0:
			low = mini(low, first)
			high = maxi(high, bytes.rfind(1))
	return Vector2i(low, high)

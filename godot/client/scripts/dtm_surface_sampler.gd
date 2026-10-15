class_name DtmSurfaceSampler
extends RefCounted

## Read-only first air-to-solid crossing of the CURRENT voxel SDF.
## Never fall back to TerrainState (the pre-excavation heightfield).
var zone: VoxelWorkZone
var _buffer := VoxelBuffer.new()
var _buffer_height := 0

var _batch := VoxelBuffer.new()
var _batch_size := Vector3i.ZERO

## Batched equivalent of height_at. Nearby points (a grid row, a section run)
## share one VoxelTool.copy of their covering box instead of one copy per point;
## columns are decoded from the raw ZXY bytes. Points are grouped greedily so a
## diagonal run never copies a large mostly-unused box. Heights match the
## scalar path to float rounding; non-editable boxes fall back per point.
func heights_at(points: PackedVector2Array) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(points.size())
	result.fill(NAN)
	if points.is_empty() or not is_instance_valid(zone) or zone.terrain == null or zone.get_voxel_tool() == null:
		return result
	var scale_m := zone.voxel_scale_m
	var voxels := PackedVector2Array()
	voxels.resize(points.size())
	for i in points.size():
		if zone.layout.owns_world_xz(points[i]):
			var v: Vector3 = zone.layout.world_to_voxel(Vector3(points[i].x, 0, points[i].y), scale_m)
			voxels[i] = Vector2(v.x, v.z)
		else:
			voxels[i] = Vector2(NAN, NAN)
	var start := 0
	var low := Vector2i(1 << 30, 1 << 30)
	var high := Vector2i(-(1 << 30), -(1 << 30))
	var count := 0
	for i in points.size():
		var v := voxels[i]
		if not is_finite(v.x):
			continue
		var next_low := Vector2i(mini(low.x, floori(v.x)), mini(low.y, floori(v.y)))
		var next_high := Vector2i(maxi(high.x, floori(v.x) + 1), maxi(high.y, floori(v.y) + 1))
		var columns := (next_high.x - next_low.x + 1) * (next_high.y - next_low.y + 1)
		if count > 0 and columns > 6 * (count + 1) + 16:
			_decode_chunk(points, voxels, start, i, low, high, result)
			start = i
			count = 0
			next_low = Vector2i(floori(v.x), floori(v.y))
			next_high = next_low + Vector2i.ONE
		low = next_low
		high = next_high
		count += 1
	if count > 0:
		_decode_chunk(points, voxels, start, points.size(), low, high, result)
	return result

func _decode_chunk(points: PackedVector2Array, voxels: PackedVector2Array, from: int, to: int, low: Vector2i, high: Vector2i, result: PackedFloat32Array) -> void:
	var scale_m := zone.voxel_scale_m
	var layout = zone.layout
	var bounds: AABB = layout.voxel_bounds(scale_m)
	var base_y := ceili(bounds.position.y)
	var size_y := floori(bounds.end.y) - base_y
	var size := Vector3i(high.x - low.x + 1, size_y, high.y - low.y + 1)
	var area := AABB(Vector3(low.x, base_y, low.y), Vector3(size))
	var tool := zone.get_voxel_tool()
	if not bounds.encloses(area) or not tool.is_area_editable(area):
		for i in range(from, to):
			if is_finite(voxels[i].x):
				result[i] = height_at(points[i])
		return
	if _batch_size != size:
		_batch.create(size.x, size.y, size.z)
		_batch.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
		_batch_size = size
	tool.copy(Vector3i(low.x, base_y, low.y), _batch, 1 << VoxelBuffer.CHANNEL_SDF, false)
	var raw := _batch.get_channel_as_byte_array(VoxelBuffer.CHANNEL_SDF)
	# Raw int16 is get_voxel_f times a constant; the sign tests and the
	# crossing ratio below are invariant to that scale.
	var column := 2 * size_y
	var row := column * size.x
	for i in range(from, to):
		var v := voxels[i]
		if not is_finite(v.x):
			continue
		var x0 := floori(v.x)
		var z0 := floori(v.y)
		var fx := v.x - x0
		var fz := v.y - z0
		var c00 := column * (x0 - low.x) + row * (z0 - low.y)
		var c10 := c00 + column
		var c01 := c00 + row
		var c11 := c01 + column
		var o := 2 * (size_y - 1)
		var prior := lerpf(lerpf(raw.decode_s16(c00 + o), raw.decode_s16(c10 + o), fx), lerpf(raw.decode_s16(c01 + o), raw.decode_s16(c11 + o), fx), fz)
		if prior <= 0:
			continue
		for y in range(size_y - 2, -1, -1):
			o = 2 * y
			var sdf := lerpf(lerpf(raw.decode_s16(c00 + o), raw.decode_s16(c10 + o), fx), lerpf(raw.decode_s16(c01 + o), raw.decode_s16(c11 + o), fx), fz)
			if sdf <= 0:
				var surface_y := float(base_y + y) - sdf / maxf(prior - sdf, 0.0000001)
				result[i] = layout.voxel_to_world(Vector3(v.x, surface_y, v.y), scale_m).y
				break
			prior = sdf

func height_at(xz: Vector2) -> float:
	if not is_instance_valid(zone) or zone.terrain == null or not zone.layout.owns_world_xz(xz):
		return NAN
	var scale_m := zone.voxel_scale_m
	var layout = zone.layout
	var voxel: Vector3 = layout.world_to_voxel(Vector3(xz.x, 0, xz.y), scale_m)
	var bounds: AABB = layout.voxel_bounds(scale_m)
	var base := Vector3i(floori(voxel.x), ceili(bounds.position.y), floori(voxel.z))
	var size_y := floori(bounds.end.y) - base.y
	var area := AABB(Vector3(base), Vector3(2, size_y, 2))
	if not bounds.encloses(area):
		return NAN
	var tool := zone.get_voxel_tool()
	if tool == null or not tool.is_area_editable(area):
		return NAN
	if _buffer_height != size_y:
		_buffer.create(2, size_y, 2)
		_buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
		_buffer_height = size_y
	tool.copy(base, _buffer, 1 << VoxelBuffer.CHANNEL_SDF, false)
	var fx := voxel.x - base.x
	var fz := voxel.z - base.z
	var prior := _sdf(_buffer, size_y - 1, fx, fz)
	if prior <= 0:
		return NAN # Top of the finite domain is solid: no known top surface.
	for y in range(size_y - 2, -1, -1):
		var sdf := _sdf(_buffer, y, fx, fz)
		if sdf <= 0:
			var surface_y := float(base.y + y) - sdf / maxf(prior - sdf, 0.0000001)
			return layout.voxel_to_world(Vector3(voxel.x, surface_y, voxel.z), scale_m).y
		prior = sdf
	return NAN

func _sdf(buffer: VoxelBuffer, y: int, fx: float, fz: float) -> float:
	return lerpf(lerpf(buffer.get_voxel_f(0, y, 0, VoxelBuffer.CHANNEL_SDF), buffer.get_voxel_f(1, y, 0, VoxelBuffer.CHANNEL_SDF), fx), lerpf(buffer.get_voxel_f(0, y, 1, VoxelBuffer.CHANNEL_SDF), buffer.get_voxel_f(1, y, 1, VoxelBuffer.CHANNEL_SDF), fx), fz)

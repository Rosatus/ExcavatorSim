class_name DtmSurfaceSampler
extends RefCounted

## Read-only first air-to-solid crossing of the CURRENT voxel SDF.
## Never fall back to TerrainState (the pre-excavation heightfield).
var zone: VoxelWorkZone
var _buffer := VoxelBuffer.new()
var _buffer_height := 0

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

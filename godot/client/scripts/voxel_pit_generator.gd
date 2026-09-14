extends VoxelGeneratorScript

## Immutable after installation: generation runs on Voxel Tools worker threads.
var scale_m := 0.125
var half_size := Vector2(9, 14)
var depth_m := 0.6
var apron_m := 0.0

func _get_used_channels_mask() -> int:
	return 1 << VoxelBuffer.CHANNEL_SDF

func _generate_block(buffer: VoxelBuffer, origin: Vector3i, lod: int) -> void:
	var size := buffer.get_size()
	for z in size.z:
		for x in size.x:
			var px := float(origin.x + (x << lod)) * scale_m
			var pz := float(origin.z + (z << lod)) * scale_m
			var edge_distance := minf(half_size.x - absf(px), half_size.y - absf(pz))
			# A level perimeter joins the original ground; a gentle soil slope
			# leads to a shallow starter pit with several metres of native soil.
			var surface := -depth_m * smoothstep(1.5, 3.0, edge_distance)
			for y in size.y:
				var py := float(origin.y + (y << lod)) * scale_m
				var distance_m := maxf(py - surface, maxf(absf(px) - half_size.x - apron_m, absf(pz) - half_size.y - apron_m))
				buffer.set_voxel_f(distance_m / scale_m, x, y, z, VoxelBuffer.CHANNEL_SDF)

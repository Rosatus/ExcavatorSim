extends VoxelGeneratorScript

## Immutable after installation: generation runs on Voxel Tools worker threads.
var scale_m := 0.125
var half_size := Vector2(9, 14)
var depth_m := 0.0
var apron_m := 0.0

## Starter-terrain profile, in metres relative to the zone centre (local axes
## match the world layout: -Z is the vehicle approach / spawn side).
## The approach half is a foundation pit: level rims, a constant-grade
## full-width access ramp (the only non-steep slope — the machinery path),
## cut-steep side walls, a flat floor sized to park a machine, and a steep
## dig face on the midline. The far half stays at grade as the remaining dig
## area.
## depth_m = 0 flattens to a level surface for maps that start undisturbed.
const PERIMETER_LEVEL_M := 1.5
const PIT_FLOOR_Z_SPAN_M := 8.0
const DIG_FACE_RUN_M := 0.5
const SIDE_WALL_RUN_M := 0.5

func _get_used_channels_mask() -> int:
	return 1 << VoxelBuffer.CHANNEL_SDF

## Surface height in metres relative to surrounding grade (<= 0 digs down).
## Piecewise linear so the access ramp keeps a constant machinery-friendly
## grade and the dig face reads as a real cut wall.
func surface_height_m(px: float, pz: float) -> float:
	var dist_south := pz + half_size.y
	var dist_side := half_size.x - absf(px)
	var floor_z_edge := half_size.y - PIT_FLOOR_Z_SPAN_M - DIG_FACE_RUN_M
	var z_factor := 0.0
	if pz < 0.0:
		if dist_south >= half_size.y - DIG_FACE_RUN_M:
			# Midline dig face: the current excavation step, left steep.
			z_factor = (half_size.y - dist_south) / DIG_FACE_RUN_M
		elif dist_south >= floor_z_edge:
			z_factor = 1.0
		elif dist_south > PERIMETER_LEVEL_M:
			# Full-width access ramp: the machinery path down into the pit.
			z_factor = (dist_south - PERIMETER_LEVEL_M) / (floor_z_edge - PERIMETER_LEVEL_M)
	var x_factor := clampf((dist_side - PERIMETER_LEVEL_M) / SIDE_WALL_RUN_M, 0.0, 1.0)
	return -depth_m * minf(z_factor, x_factor)

func _generate_block(buffer: VoxelBuffer, origin: Vector3i, lod: int) -> void:
	var size := buffer.get_size()
	for z in size.z:
		for x in size.x:
			var px := float(origin.x + (x << lod)) * scale_m
			var pz := float(origin.z + (z << lod)) * scale_m
			var surface := surface_height_m(px, pz)
			for y in size.y:
				var py := float(origin.y + (y << lod)) * scale_m
				var distance_m := maxf(py - surface, maxf(absf(px) - half_size.x - apron_m, absf(pz) - half_size.y - apron_m))
				buffer.set_voxel_f(distance_m / scale_m, x, y, z, VoxelBuffer.CHANNEL_SDF)

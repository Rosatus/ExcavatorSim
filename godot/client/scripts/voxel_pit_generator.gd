extends VoxelGeneratorScript

## Immutable after installation: generation runs on Voxel Tools worker threads.
var scale_m := 0.125
var half_size := Vector2(9, 14)
var depth_m := 0.0
var apron_m := 0.0
## When true the excavated half occupies local -X instead of -Z: maps whose
## work strip runs along the street edge split along their length axis.
var pit_on_x_half := false

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
	var along := pz
	var side := px
	var half_along := half_size.y
	var half_side := half_size.x
	if pit_on_x_half:
		along = px
		side = pz
		half_along = half_size.x
		half_side = half_size.y
	var dist_approach := along + half_along
	var dist_side := half_side - absf(side)
	var floor_edge := half_along - PIT_FLOOR_Z_SPAN_M - DIG_FACE_RUN_M
	var along_factor := 0.0
	if along < 0.0:
		if dist_approach >= half_along - DIG_FACE_RUN_M:
			# Midline dig face: the current excavation step, left steep.
			along_factor = (half_along - dist_approach) / DIG_FACE_RUN_M
		elif dist_approach >= floor_edge:
			along_factor = 1.0
		elif dist_approach > PERIMETER_LEVEL_M:
			# Full-width access ramp: the machinery path down into the pit.
			along_factor = (dist_approach - PERIMETER_LEVEL_M) / (floor_edge - PERIMETER_LEVEL_M)
	var side_factor := clampf((dist_side - PERIMETER_LEVEL_M) / SIDE_WALL_RUN_M, 0.0, 1.0)
	return -depth_m * minf(along_factor, side_factor)

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

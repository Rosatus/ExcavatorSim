class_name VoxelZoneLayout
extends RefCounted

const Defaults = preload("res://scripts/voxel_work_zone_config.gd")

## Per-runtime spatial configuration. Training defaults match VoxelWorkZoneConfig.
## Single source of truth for the bounded mutable-soil volume. World-space X/Z
## ownership is half-open so the hard-ground and voxel derivatives cannot both
## claim a boundary sample.
var ORIGIN_WORLD := Defaults.ORIGIN_WORLD
var SIZE_WORLD_M := Defaults.SIZE_WORLD_M
var MIN_WORLD := Defaults.MIN_WORLD
var MAX_WORLD := Defaults.MAX_WORLD
var INITIAL_SURFACE_Y := Defaults.INITIAL_SURFACE_Y
var perimeter_inset_m := 0.0
const APPROACH_DEPTH_M := 8.0
const ENTRANCE_WIDTH_M := 8.0
const DEFAULT_VOXEL_SCALE_M := 0.125
const COARSE_VOXEL_SCALE_M := 0.20
const MESH_BLOCK_SIZE_VOXELS := 16
const PROTECTED_SHELL_VOXELS := 2
const TERRAIN_COLLISION_LAYER := 1
const TERRAIN_COLLISION_MASK := 1


func candidate_scales_m() -> PackedFloat32Array:
	return PackedFloat32Array([DEFAULT_VOXEL_SCALE_M, COARSE_VOXEL_SCALE_M])


func world_bounds() -> AABB:
	return AABB(MIN_WORLD, SIZE_WORLD_M)


func voxel_bounds(scale_m: float = DEFAULT_VOXEL_SCALE_M) -> AABB:
	var safe_scale := _validated_scale(scale_m)
	return AABB(
		(MIN_WORLD - ORIGIN_WORLD) / safe_scale,
		SIZE_WORLD_M / safe_scale,
	)


func terrain_transform(scale_m: float = DEFAULT_VOXEL_SCALE_M) -> Transform3D:
	var safe_scale := _validated_scale(scale_m)
	return Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * safe_scale), ORIGIN_WORLD)


func world_to_voxel(world_position: Vector3, scale_m: float = DEFAULT_VOXEL_SCALE_M) -> Vector3:
	return (world_position - ORIGIN_WORLD) / _validated_scale(scale_m)


func voxel_to_world(voxel_position: Vector3, scale_m: float = DEFAULT_VOXEL_SCALE_M) -> Vector3:
	return ORIGIN_WORLD + voxel_position * _validated_scale(scale_m)


func owns_world_xz(world_xz: Vector2) -> bool:
	return world_xz.x >= MIN_WORLD.x and world_xz.x < MAX_WORLD.x \
		and world_xz.y >= MIN_WORLD.z and world_xz.y < MAX_WORLD.z


func owns_world_position(world_position: Vector3) -> bool:
	return owns_world_xz(Vector2(world_position.x, world_position.z)) \
		and world_position.y >= MIN_WORLD.y and world_position.y < MAX_WORLD.y


func owns_hard_surface_cell(cell_center_xz: Vector2) -> bool:
	return owns_world_xz(cell_center_xz)


func is_vehicle_approach_xz(world_xz: Vector2) -> bool:
	return absf(world_xz.x) < 0.5 * ENTRANCE_WIDTH_M \
		and world_xz.y >= 0.0 and world_xz.y < MIN_WORLD.z


func editable_world_bounds(scale_m: float = DEFAULT_VOXEL_SCALE_M) -> AABB:
	var inset := float(PROTECTED_SHELL_VOXELS) * _validated_scale(scale_m)
	return AABB(
		MIN_WORLD + Vector3(maxf(inset, perimeter_inset_m), inset, maxf(inset, perimeter_inset_m)),
		SIZE_WORLD_M - Vector3(maxf(inset, perimeter_inset_m), inset, maxf(inset, perimeter_inset_m)) * 2.0,
	)


func is_world_position_editable(world_position: Vector3, scale_m: float = DEFAULT_VOXEL_SCALE_M) -> bool:
	return editable_world_bounds(scale_m).has_point(world_position)


func mesh_block_coordinate(voxel_position: Vector3) -> Vector3i:
	var block_size := float(MESH_BLOCK_SIZE_VOXELS)
	return Vector3i(
		floori(voxel_position.x / block_size),
		floori(voxel_position.y / block_size),
		floori(voxel_position.z / block_size),
	)


func mesh_block_key(voxel_position: Vector3) -> String:
	var coordinate := mesh_block_coordinate(voxel_position)
	return "%d:%d:%d" % [coordinate.x, coordinate.y, coordinate.z]


func mesh_block_keys_for_area(area_voxels: AABB) -> PackedStringArray:
	var result := PackedStringArray()
	if area_voxels.size.x <= 0.0 or area_voxels.size.y <= 0.0 or area_voxels.size.z <= 0.0:
		return result
	var minimum := mesh_block_coordinate(area_voxels.position)
	# AABBs are half-open. Pull the end inward so an edit ending exactly on a
	# block edge does not dirty the neighboring block.
	var maximum := mesh_block_coordinate(area_voxels.end - Vector3.ONE * 0.00001)
	for z in range(minimum.z, maximum.z + 1):
		for y in range(minimum.y, maximum.y + 1):
			for x in range(minimum.x, maximum.x + 1):
				result.append("%d:%d:%d" % [x, y, z])
	return result


func _validated_scale(scale_m: float) -> float:
	assert(is_finite(scale_m) and scale_m > 0.0, "voxel scale must be finite and positive")
	return scale_m


func configure_area(center: Vector3, size_xz: Vector2) -> void:
	perimeter_inset_m = 1.5
	ORIGIN_WORLD = center
	SIZE_WORLD_M = Vector3(size_xz.x, 10.0, size_xz.y)
	MIN_WORLD = center - Vector3(size_xz.x / 2.0, 6.0, size_xz.y / 2.0)
	MAX_WORLD = MIN_WORLD + SIZE_WORLD_M
	INITIAL_SURFACE_Y = center.y

class_name VoxelWorkZoneConfig
extends RefCounted

## Single source of truth for the bounded mutable-soil volume. World-space X/Z
## ownership is half-open so the hard-ground and voxel derivatives cannot both
## claim a boundary sample.
const ORIGIN_WORLD := Vector3(0.0, 0.0, 24.0)
const SIZE_WORLD_M := Vector3(32.0, 10.0, 32.0)
const MIN_WORLD := Vector3(-16.0, -6.0, 8.0)
const MAX_WORLD := Vector3(16.0, 4.0, 40.0)
const INITIAL_SURFACE_Y := 0.0
const APPROACH_DEPTH_M := 8.0
const ENTRANCE_WIDTH_M := 8.0
const DEFAULT_VOXEL_SCALE_M := 0.125
const COARSE_VOXEL_SCALE_M := 0.20
const MESH_BLOCK_SIZE_VOXELS := 16
const PROTECTED_SHELL_VOXELS := 2
const TERRAIN_COLLISION_LAYER := 1
const TERRAIN_COLLISION_MASK := 1


static func candidate_scales_m() -> PackedFloat32Array:
	return PackedFloat32Array([DEFAULT_VOXEL_SCALE_M, COARSE_VOXEL_SCALE_M])


static func world_bounds() -> AABB:
	return AABB(MIN_WORLD, SIZE_WORLD_M)


static func voxel_bounds(scale_m: float = DEFAULT_VOXEL_SCALE_M) -> AABB:
	var safe_scale := _validated_scale(scale_m)
	return AABB(
		(MIN_WORLD - ORIGIN_WORLD) / safe_scale,
		SIZE_WORLD_M / safe_scale,
	)


static func terrain_transform(scale_m: float = DEFAULT_VOXEL_SCALE_M) -> Transform3D:
	var safe_scale := _validated_scale(scale_m)
	return Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * safe_scale), ORIGIN_WORLD)


static func world_to_voxel(world_position: Vector3, scale_m: float = DEFAULT_VOXEL_SCALE_M) -> Vector3:
	return (world_position - ORIGIN_WORLD) / _validated_scale(scale_m)


static func voxel_to_world(voxel_position: Vector3, scale_m: float = DEFAULT_VOXEL_SCALE_M) -> Vector3:
	return ORIGIN_WORLD + voxel_position * _validated_scale(scale_m)


static func owns_world_xz(world_xz: Vector2) -> bool:
	return world_xz.x >= MIN_WORLD.x and world_xz.x < MAX_WORLD.x \
		and world_xz.y >= MIN_WORLD.z and world_xz.y < MAX_WORLD.z


static func owns_world_position(world_position: Vector3) -> bool:
	return owns_world_xz(Vector2(world_position.x, world_position.z)) \
		and world_position.y >= MIN_WORLD.y and world_position.y < MAX_WORLD.y


static func owns_hard_surface_cell(cell_center_xz: Vector2) -> bool:
	return owns_world_xz(cell_center_xz)


static func is_vehicle_approach_xz(world_xz: Vector2) -> bool:
	return absf(world_xz.x) < 0.5 * ENTRANCE_WIDTH_M \
		and world_xz.y >= 0.0 and world_xz.y < MIN_WORLD.z


static func editable_world_bounds(scale_m: float = DEFAULT_VOXEL_SCALE_M) -> AABB:
	var inset := float(PROTECTED_SHELL_VOXELS) * _validated_scale(scale_m)
	return AABB(
		MIN_WORLD + Vector3.ONE * inset,
		SIZE_WORLD_M - Vector3.ONE * (2.0 * inset),
	)


static func is_world_position_editable(world_position: Vector3, scale_m: float = DEFAULT_VOXEL_SCALE_M) -> bool:
	return editable_world_bounds(scale_m).has_point(world_position)


static func _validated_scale(scale_m: float) -> float:
	assert(is_finite(scale_m) and scale_m > 0.0, "voxel scale must be finite and positive")
	return scale_m

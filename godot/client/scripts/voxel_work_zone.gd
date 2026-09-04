class_name VoxelWorkZone
extends Node3D

const WorkZoneConfig = preload("res://scripts/voxel_work_zone_config.gd")
const CollisionReadiness = preload("res://scripts/voxel_collision_readiness.gd")

## Runtime owner of the finite Voxel Tools terrain instance. Excavation policy
## deliberately lives elsewhere; this class owns only module resources,
## coordinate configuration, derivative readiness and reset/teardown.
@export_range(0.1, 0.25, 0.005) var voxel_scale_m := WorkZoneConfig.DEFAULT_VOXEL_SCALE_M
@export var initialize_on_ready := true
@export var collision_viewer_target_path := NodePath("../../ChassisMotionRoot")

var terrain: VoxelTerrain
var zone_viewer: VoxelViewer
var collision_viewer: VoxelViewer
var readiness := CollisionReadiness.new()
var initial_ticket: Dictionary = {}
var latest_ticket: Dictionary = {}
var last_error := ""
var reset_count := 0


func _ready() -> void:
	if initialize_on_ready:
		build_runtime()


func _physics_process(_delta: float) -> void:
	var viewer_target := get_node_or_null(collision_viewer_target_path) as Node3D
	if collision_viewer != null and viewer_target != null:
		collision_viewer.global_position = viewer_target.global_position
	if terrain == null or initial_ticket.is_empty() or readiness.is_ready(initial_ticket):
		return
	if terrain.is_area_meshed(initial_ticket["area_voxels"] as AABB):
		readiness.mark_meshed(initial_ticket)
		_try_acknowledge_surface(initial_ticket, WorkZoneConfig.ORIGIN_WORLD)


func build_runtime() -> bool:
	last_error = ""
	if terrain != null or zone_viewer != null or collision_viewer != null:
		_teardown_runtime()
	if not _module_contract_available():
		last_error = "Voxel Tools 1.7 classes are unavailable"
		return false

	var format := VoxelFormat.new()
	format.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	var generator := VoxelGeneratorFlat.new()
	generator.channel = VoxelBuffer.CHANNEL_SDF
	generator.height = 0.0
	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_NONE
	mesher.transitions_enabled = false

	terrain = VoxelTerrain.new()
	terrain.name = "VoxelTerrain"
	terrain.transform = WorkZoneConfig.terrain_transform(voxel_scale_m)
	terrain.format = format
	terrain.generator = generator
	terrain.mesher = mesher
	terrain.bounds = WorkZoneConfig.voxel_bounds(voxel_scale_m)
	terrain.mesh_block_size = WorkZoneConfig.MESH_BLOCK_SIZE_VOXELS
	terrain.max_view_distance = ceili(WorkZoneConfig.SIZE_WORLD_M.x / voxel_scale_m)
	terrain.generate_collisions = true
	terrain.collision_layer = WorkZoneConfig.TERRAIN_COLLISION_LAYER
	terrain.collision_mask = WorkZoneConfig.TERRAIN_COLLISION_MASK
	terrain.material_override = _make_soil_material()
	add_child(terrain)

	zone_viewer = VoxelViewer.new()
	zone_viewer.name = "ZoneViewer"
	zone_viewer.position = WorkZoneConfig.ORIGIN_WORLD
	zone_viewer.view_distance = ceili(WorkZoneConfig.SIZE_WORLD_M.x / voxel_scale_m)
	zone_viewer.view_distance_vertical_ratio = 0.4
	zone_viewer.requires_visuals = true
	zone_viewer.requires_collisions = true
	add_child(zone_viewer)

	collision_viewer = VoxelViewer.new()
	collision_viewer.name = "ChassisCollisionViewer"
	collision_viewer.position = WorkZoneConfig.ORIGIN_WORLD
	collision_viewer.view_distance = ceili(12.0 / voxel_scale_m)
	collision_viewer.view_distance_vertical_ratio = 0.5
	collision_viewer.requires_visuals = false
	collision_viewer.requires_collisions = true
	add_child(collision_viewer)

	initial_ticket = readiness.issue(WorkZoneConfig.voxel_bounds(voxel_scale_m), &"initial_surface")
	latest_ticket = initial_ticket
	return true


func reset_zone() -> bool:
	readiness.reset()
	reset_count += 1
	return build_runtime()


func issue_edit_ticket(area_voxels: AABB, purpose: StringName = &"edit") -> Dictionary:
	latest_ticket = readiness.issue(area_voxels, purpose)
	return latest_ticket


func poll_ticket_meshed(ticket: Dictionary) -> bool:
	if terrain == null or ticket.is_empty():
		return false
	if not terrain.is_area_meshed(ticket["area_voxels"] as AABB):
		return false
	return readiness.mark_meshed(ticket)


func acknowledge_ticket_query(ticket: Dictionary) -> bool:
	return readiness.acknowledge_query(ticket)


func retire_ticket(ticket: Dictionary, reason: StringName) -> bool:
	return readiness.retire(ticket, reason)


func get_ticket_status(ticket: Dictionary) -> Dictionary:
	return readiness.status(ticket)


func is_support_ready_at(world_position: Vector3) -> bool:
	return WorkZoneConfig.owns_world_xz(Vector2(world_position.x, world_position.z)) \
		and readiness.is_point_ready(WorkZoneConfig.world_to_voxel(world_position, voxel_scale_m))


func get_voxel_tool() -> VoxelTool:
	return terrain.get_voxel_tool() if terrain != null else null


func get_status_snapshot() -> Dictionary:
	return {
		"generation": readiness.generation,
		"revision": readiness.revision,
		"voxel_scale_m": voxel_scale_m,
		"world_bounds": WorkZoneConfig.world_bounds(),
		"voxel_bounds": WorkZoneConfig.voxel_bounds(voxel_scale_m),
		"initial_readiness": readiness.status(initial_ticket),
		"readiness": readiness.get_status_snapshot(),
		"statistics": terrain.get_statistics() if terrain != null else {},
		"reset_count": reset_count,
		"last_error": last_error,
	}


func _try_acknowledge_surface(ticket: Dictionary, world_position: Vector3) -> bool:
	if not is_inside_tree() or get_world_3d() == null:
		return false
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(world_position.x, 2.0, world_position.z),
		Vector3(world_position.x, -3.0, world_position.z),
		WorkZoneConfig.TERRAIN_COLLISION_LAYER,
	)
	query.collide_with_areas = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return false
	var hit_position: Variant = hit.get("position")
	if not hit_position is Vector3 or absf((hit_position as Vector3).y - WorkZoneConfig.INITIAL_SURFACE_Y) > 0.35:
		return false
	return readiness.acknowledge_query(ticket)


func _teardown_runtime() -> void:
	if zone_viewer != null:
		remove_child(zone_viewer)
		zone_viewer.queue_free()
		zone_viewer = null
	if collision_viewer != null:
		remove_child(collision_viewer)
		collision_viewer.queue_free()
		collision_viewer = null
	if terrain != null:
		remove_child(terrain)
		terrain.queue_free()
		terrain = null
	initial_ticket = {}
	latest_ticket = {}


func _make_soil_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("765537")
	material.roughness = 0.96
	return material


func _module_contract_available() -> bool:
	return ClassDB.class_exists(&"VoxelTerrain") \
		and ClassDB.class_exists(&"VoxelGeneratorFlat") \
		and ClassDB.class_exists(&"VoxelMesherTransvoxel") \
		and ClassDB.class_exists(&"VoxelViewer")

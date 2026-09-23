class_name VoxelWorkZone
extends Node3D

var layout := preload("res://scripts/voxel_zone_layout.gd").new()

const WorkZoneConfig = preload("res://scripts/voxel_work_zone_config.gd")
const SUPPORT_APRON_M := 1.0
const CollisionReadiness = preload("res://scripts/voxel_collision_readiness.gd")

## Runtime owner of the finite Voxel Tools terrain instance. Excavation policy
## deliberately lives elsewhere; this class owns only module resources,
## coordinate configuration, derivative readiness and reset/teardown.
@export_range(0.1, 0.25, 0.005) var voxel_scale_m := WorkZoneConfig.DEFAULT_VOXEL_SCALE_M
@export var initialize_on_ready := true
@export var starter_pit := false
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
		var probe := layout.ORIGIN_WORLD
		_try_acknowledge_surface(initial_ticket, probe)


func build_runtime() -> bool:
	last_error = ""
	if terrain != null or zone_viewer != null or collision_viewer != null:
		_teardown_runtime()
	if not _module_contract_available():
		last_error = "Voxel Tools 1.7 classes are unavailable"
		return false

	var format := VoxelFormat.new()
	format.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	var generator = preload("res://scripts/voxel_pit_generator.gd").new()
	generator.scale_m = voxel_scale_m
	generator.half_size = Vector2(layout.SIZE_WORLD_M.x, layout.SIZE_WORLD_M.z) * 0.5
	generator.depth_m = 0.6 if starter_pit else 0.0
	# Native block bounds round outward. Generate a finite apron under hard
	# ground and clip its presentation to the exact semantic rectangle.
	# Terrain3D heightmap holes also remove neighboring collision triangles.
	# A hidden, immutable one-metre apron bridges that native grid seam.
	generator.apron_m = SUPPORT_APRON_M
	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_NONE
	mesher.transitions_enabled = false

	terrain = VoxelTerrain.new()
	terrain.name = "VoxelTerrain"
	terrain.transform = layout.terrain_transform(voxel_scale_m)
	terrain.format = format
	terrain.generator = generator
	terrain.mesher = mesher
	terrain.bounds = layout.voxel_bounds(voxel_scale_m).grow(ceilf(generator.apron_m / voxel_scale_m) + 1.0)
	terrain.mesh_block_size = WorkZoneConfig.MESH_BLOCK_SIZE_VOXELS
	terrain.max_view_distance = ceili(maxf(layout.SIZE_WORLD_M.x, layout.SIZE_WORLD_M.z) / voxel_scale_m)
	terrain.generate_collisions = true
	terrain.collision_layer = WorkZoneConfig.TERRAIN_COLLISION_LAYER
	terrain.collision_mask = WorkZoneConfig.TERRAIN_COLLISION_MASK
	terrain.material_override = _make_soil_material()
	add_child(terrain)

	zone_viewer = VoxelViewer.new()
	zone_viewer.name = "ZoneViewer"
	zone_viewer.position = layout.ORIGIN_WORLD
	zone_viewer.view_distance = terrain.max_view_distance
	zone_viewer.view_distance_vertical_ratio = 0.4
	zone_viewer.requires_visuals = true
	zone_viewer.requires_collisions = true
	add_child(zone_viewer)

	collision_viewer = VoxelViewer.new()
	collision_viewer.name = "ChassisCollisionViewer"
	collision_viewer.position = layout.ORIGIN_WORLD
	collision_viewer.view_distance = ceili(12.0 / voxel_scale_m)
	collision_viewer.view_distance_vertical_ratio = 0.5
	collision_viewer.requires_visuals = false
	collision_viewer.requires_collisions = true
	add_child(collision_viewer)

	initial_ticket = readiness.issue(support_voxel_bounds(), &"initial_surface")
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


func support_voxel_bounds() -> AABB:
	var bounds: AABB = layout.voxel_bounds(voxel_scale_m)
	var apron := Vector3(SUPPORT_APRON_M / voxel_scale_m, 0.0, SUPPORT_APRON_M / voxel_scale_m)
	return AABB(bounds.position - apron, bounds.size + apron * 2.0)


func is_support_ready_at(world_position: Vector3) -> bool:
	# Apron is immutable physical ground outside the semantic soil rectangle.
	# Check its own block readiness; never borrow a clamped interior receipt.
	var minimum: Vector3 = layout.MIN_WORLD
	var maximum: Vector3 = layout.MAX_WORLD
	return world_position.x >= minimum.x - SUPPORT_APRON_M \
		and world_position.x < maximum.x + SUPPORT_APRON_M \
		and world_position.z >= minimum.z - SUPPORT_APRON_M \
		and world_position.z < maximum.z + SUPPORT_APRON_M \
		and readiness.is_point_ready(layout.world_to_voxel(world_position, voxel_scale_m))


func get_voxel_tool() -> VoxelTool:
	return terrain.get_voxel_tool() if terrain != null else null


## Slope-cut preview sink: pushes the analytic profile into the bounded-soil
## material so the real terrain surface itself marks the soil a confirmed pass
## removes. Pure presentation — no voxel data is touched. Unknown keys are
## ignored by the shader so callers can pass the whole pack verbatim.
func set_cut_preview(uniforms: Dictionary) -> void:
	var material := (terrain.material_override as ShaderMaterial) if terrain != null else null
	if material == null:
		return
	for key in uniforms:
		material.set_shader_parameter(String(key), uniforms[key])


func clear_cut_preview() -> void:
	set_cut_preview({"cut_mode": 0})


func get_status_snapshot() -> Dictionary:
	return {
		"generation": readiness.generation,
		"revision": readiness.revision,
		"voxel_scale_m": voxel_scale_m,
		"world_bounds": layout.world_bounds(),
		"voxel_bounds": layout.voxel_bounds(voxel_scale_m),
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
	var expected_y := layout.INITIAL_SURFACE_Y - (0.6 if starter_pit else 0.0)
	if not hit_position is Vector3 or absf((hit_position as Vector3).y - expected_y) > 0.15:
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


func _make_soil_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = preload("res://assets/terrain/shaders/voxel_soil_bounded.gdshader")
	var visuals = preload("res://scripts/soil_visual_resources.gd")
	material.set_shader_parameter("texture_albedo", visuals.ALBEDO)
	material.set_shader_parameter("texture_normal", visuals.NORMAL_ROUGHNESS)
	material.set_shader_parameter("soil_bounds", Vector4(layout.MIN_WORLD.x, layout.MIN_WORLD.z, layout.MAX_WORLD.x, layout.MAX_WORLD.z))
	material.set_shader_parameter("initial_surface_y", layout.INITIAL_SURFACE_Y)
	material.set_shader_parameter("starter_pit_depth", 0.6 if starter_pit else 0.0)
	return material


func _module_contract_available() -> bool:
	return ClassDB.class_exists(&"VoxelTerrain") \
		and ClassDB.class_exists(&"VoxelGeneratorFlat") \
		and ClassDB.class_exists(&"VoxelMesherTransvoxel") \
		and ClassDB.class_exists(&"VoxelViewer")

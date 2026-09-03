class_name VoxelWorkZoneBoundary
extends Node3D

const WorkZoneConfig = preload("res://scripts/voxel_work_zone_config.gd")
const WALL_HEIGHT_M := 1.1
const WALL_THICKNESS_M := 0.25
const ENTRANCE_WIDTH_M := WorkZoneConfig.ENTRANCE_WIDTH_M


func _ready() -> void:
	build_boundary()


func build_boundary() -> void:
	for child in get_children():
		child.queue_free()
	var center := WorkZoneConfig.ORIGIN_WORLD
	var size := WorkZoneConfig.SIZE_WORLD_M
	_add_segment("WestRetainingWall", Vector3(WorkZoneConfig.MIN_WORLD.x, WALL_HEIGHT_M * 0.5, center.z), Vector3(WALL_THICKNESS_M, WALL_HEIGHT_M, size.z))
	_add_segment("EastRetainingWall", Vector3(WorkZoneConfig.MAX_WORLD.x, WALL_HEIGHT_M * 0.5, center.z), Vector3(WALL_THICKNESS_M, WALL_HEIGHT_M, size.z))
	_add_segment("NorthRetainingWall", Vector3(center.x, WALL_HEIGHT_M * 0.5, WorkZoneConfig.MAX_WORLD.z), Vector3(size.x, WALL_HEIGHT_M, WALL_THICKNESS_M))
	var south_side_width := (size.x - ENTRANCE_WIDTH_M) * 0.5
	_add_segment("SouthWestRetainingWall", Vector3(WorkZoneConfig.MIN_WORLD.x + south_side_width * 0.5, WALL_HEIGHT_M * 0.5, WorkZoneConfig.MIN_WORLD.z), Vector3(south_side_width, WALL_HEIGHT_M, WALL_THICKNESS_M))
	_add_segment("SouthEastRetainingWall", Vector3(WorkZoneConfig.MAX_WORLD.x - south_side_width * 0.5, WALL_HEIGHT_M * 0.5, WorkZoneConfig.MIN_WORLD.z), Vector3(south_side_width, WALL_HEIGHT_M, WALL_THICKNESS_M))


func _add_segment(node_name: String, world_position: Vector3, size: Vector3) -> void:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = node_name
	mesh_instance.position = world_position
	var box := BoxMesh.new()
	box.size = size
	mesh_instance.mesh = box
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("d89b36")
	material.roughness = 0.85
	box.material = material
	add_child(mesh_instance)

extends Node3D

func _ready() -> void:
	# Initial physics can precede deferred child initialization on a cold start.
	call_deferred("_apply_map_bucket_default")

func _apply_map_bucket_default() -> void:
	var catalog := get_node("/root/MapCatalog")
	var config := ConfigFile.new()
	var operator_ui := get_node("OperatorUI") as MotionOperatorUI
	config.load(operator_ui.preferences_path)
	var mode := String(config.get_value(MotionOperatorUI.CONFIG_SECTION_UI, "bucket_ground_mode", ""))
	if BucketGroundInteractionMode.is_valid(mode):
		$ProductSession.request_bucket_ground_mode(mode)
		return
	# Apply the resolved map's default through the normal fixed-tick transition.
	$ProductSession.request_bucket_ground_mode(
		BucketGroundInteractionMode.PASSTHROUGH
		if catalog.active_map_id == "training" else BucketGroundInteractionMode.NORMAL
	)

func _enter_tree() -> void:
	var catalog := get_node("/root/MapCatalog")
	if not catalog.retained_model_id.is_empty():
		$MotionClient.desired_model_id = catalog.retained_model_id
	var scene_path: String = catalog.MAP_SCENES.get(catalog.active_map_id, "")
	if scene_path.is_empty():
		return
	var packed := load(scene_path) as PackedScene
	if packed == null:
		catalog.active_map_id = "training"
		catalog.last_error = "地图资源无法读取，已返回训练场"
		return
	var map := packed.instantiate()
	map.name = "StaticMap"
	# Product Sky3D remains the single lighting owner; the workbench sky is preview-only.
	var preview_sky := map.get_node_or_null("WorldEnvironment")
	if preview_sky != null:
		preview_sky.free()
	# A map may pin the fixed product sun time on its root (e.g. sun_time_hours 12.0).
	$VisualEnvironment.set_daytime_hours(float(map.get_meta(
		"sun_time_hours", VisualEnvironment.FIXED_DAYTIME_HOURS)))
	# Map-baked directional lights would double the client Sky3D sun.
	for light in map.find_children("*", "DirectionalLight3D"):
		light.visible = false
	$TerrainRoot.visible = false
	$TerrainRoot/Terrain3DAdapter.enabled = false
	$TerrainRoot/TerrainCollider.enabled = false
	$TerrainRoot/VoxelWorkZone.initialize_on_ready = false
	$TerrainRoot/ExcavationWorld.simulation_enabled = false
	$TerrainRoot/ExcavationWorld.automatic_soil_enabled = false
	$ChassisMotionRoot.static_map_driving = true
	$ChassisMotionRoot.map_spawn_position = Vector3(0, 0, 0)
	var soil_area := map.get_node_or_null("WorkArea/ExcavationArea") as Node3D
	if soil_area != null and soil_area.get_meta("status", "") == "voxel":
		map.get_node("Ground").set("excavation_enabled", true)
	add_child(map)
	var spawn_point := map.get_node_or_null("WorkArea/SpawnPoint") as Node3D
	if spawn_point != null:
		$ChassisMotionRoot.map_spawn_position = spawn_point.global_position
		$ChassisMotionRoot.map_spawn_yaw_rad = spawn_point.global_rotation.y
	var area := map.get_node_or_null("WorkArea/ExcavationArea") as Node3D
	if area != null and area.get_meta("status", "") == "voxel":
		var zone := $TerrainRoot/VoxelWorkZone
		zone.layout.configure_area(area.global_position, area.get_meta("size_m"),
			float(area.get_meta("editable_inset_m", 1.5)))
		# Start as a half-excavated foundation pit: the approach half is already
		# dug with a machinery ramp, the far half remains at grade for digging.
		# Depth travels with the map so other voxel maps stay undisturbed.
		zone.starter_pit_depth_m = float(area.get_meta("starter_pit_depth_m", 0.0))
		# Maps whose strip runs along the street split along X instead of Z.
		zone.starter_pit_axis_x = bool(area.get_meta("starter_pit_axis_x", false))
		zone.initialize_on_ready = true
		# Only the finite voxel surface is visible; training meshes and walls
		# are not part of the construction map.
		$TerrainRoot.visible = true
		for child in $TerrainRoot.get_children():
			if child is Node3D:
				child.visible = child == zone
		var old_boundary := $TerrainRoot/VoxelWorkZoneBoundary
		$TerrainRoot.remove_child(old_boundary)
		old_boundary.free()
		var old_foundation := $TerrainRoot/FoundationGround
		$TerrainRoot.remove_child(old_foundation)
		old_foundation.free()
		$TerrainRoot/ExcavationWorld.simulation_enabled = true
		$TerrainRoot/ExcavationWorld.automatic_soil_enabled = true

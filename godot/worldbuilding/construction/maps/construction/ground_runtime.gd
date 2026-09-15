@tool
extends Terrain3D

var excavation_enabled := false

func _ready() -> void:
	var area := get_parent().get_node_or_null("WorkArea/ExcavationArea") as Node3D
	if excavation_enabled and not Engine.is_editor_hint() and area != null:
		var size: Vector2 = area.get_meta("size_m")
		var minimum := area.global_position - Vector3(size.x / 2.0, 0, size.y / 2.0)
		var maximum := area.global_position + Vector3(size.x / 2.0, 0, size.y / 2.0)
		material.shader_override = load("res://maps/construction/ground_voxel_seam.gdshader")
		material.shader_override_enabled = true
		material.set_shader_param("voxel_seam_rect", Vector4(minimum.x, minimum.z, maximum.x, maximum.z))
		# The one-metre Terrain3D control grid is kept inside the protected
		# voxel rim. Both its rendered triangles and native collider get holes.
		for z in range(ceili(minimum.z + 0.5), floori(maximum.z - 0.5) + 1):
			for x in range(ceili(minimum.x + 0.5), floori(maximum.x - 0.5) + 1):
				var point := Vector3(x, 0, z)
				data.set_control(point, data.get_control(point) | 4)
		data.update_maps(Terrain3DRegion.TYPE_CONTROL)
	# Terrain3D 1.0.2 creates its collision object on tree entry. Setting legacy
	# aliases before that point does not reliably survive PackedScene generation.
	collision.set_mode(3)
	collision.layer = 1
	collision.mask = 1

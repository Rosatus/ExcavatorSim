@tool
extends Node3D


func _ready() -> void:
	# The editor displays a baked initial surface; runtime owns only the voxel mesh.
	$InitialSoilPreview.visible = Engine.is_editor_hint()
	$VoxelTerrain.visible = not Engine.is_editor_hint()


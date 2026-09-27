extends StaticBody3D

## Urban ground slab. Solid by default so standalone workbench previews and
## older hosts keep a drivable surface; when the host opts the map's
## WorkArea/ExcavationArea marker into voxel status it flips this flag and the
## strip hands visuals + collision to the finite VoxelTerrain.
const SEAM_SHADER := preload("res://maps/urban/urban_ground_seam.gdshader")

@export var excavation_enabled := false:
	set(value):
		excavation_enabled = value
		_apply_excavation_state()

## Duck-typed like the construction Terrain3D ground so shared client code can
## sample the map body's collision RID without knowing the concrete class.
var collision: CollisionObject3D:
	get:
		return self

var _seam_material: ShaderMaterial

func _ready() -> void:
	_apply_excavation_state()

func _apply_excavation_state() -> void:
	var mesh_instance := get_node_or_null("Mesh") as MeshInstance3D
	if mesh_instance != null:
		mesh_instance.material_override = _get_seam_material() if excavation_enabled else null
	var slab := get_node_or_null("Box0") as CollisionShape3D
	if slab != null:
		slab.disabled = excavation_enabled
	for edge_name in ["HoleSouth", "HoleNorth", "HoleWest", "HoleEast"]:
		var edge := get_node_or_null(edge_name) as CollisionShape3D
		if edge != null:
			edge.disabled = not excavation_enabled

func _get_seam_material() -> ShaderMaterial:
	if _seam_material == null:
		_seam_material = ShaderMaterial.new()
		_seam_material.shader = SEAM_SHADER
	return _seam_material

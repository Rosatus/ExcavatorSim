extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"
const REQUIRED_NODE_PATHS: Array[NodePath] = [
	NodePath("WorldEnvironment"),
	NodePath("KeyLight"),
	NodePath("Camera3D"),
	NodePath("ExcavatorRig/base_link"),
	NodePath("ExcavatorRig/base_link/upper_structure_link"),
	NodePath("ExcavatorRig/base_link/upper_structure_link/boom_link"),
	NodePath("ExcavatorRig/base_link/upper_structure_link/boom_link/arm_link"),
	NodePath(
		"ExcavatorRig/base_link/upper_structure_link/boom_link/arm_link/bucket_link"
	),
	NodePath("TerrainRoot"),
	NodePath("PresentationRoot"),
	NodePath("OperatorUI"),
]


func _init() -> void:
	quit(_validate_scene_contract())


func _validate_scene_contract() -> int:
	var packed_scene := load(MAIN_SCENE) as PackedScene
	if packed_scene == null:
		push_error("Unable to load %s" % MAIN_SCENE)
		return 1

	var scene_root := packed_scene.instantiate()
	for node_path in REQUIRED_NODE_PATHS:
		if scene_root.get_node_or_null(node_path) == null:
			push_error("Missing required foundation node: %s" % node_path)
			scene_root.free()
			return 1

	scene_root.free()
	print("Foundation scene contract passed with %d required nodes." % REQUIRED_NODE_PATHS.size())
	return 0

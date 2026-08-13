class_name TerrainWorld
extends Node3D

@export var terrain_seed := TerrainState.DEFAULT_SEED
@export var terrain_rows := TerrainState.DEFAULT_ROWS
@export var terrain_columns := TerrainState.DEFAULT_COLUMNS
@export var terrain_spacing_m := TerrainState.DEFAULT_SPACING_M
@export var terrain3d_adapter_path := NodePath("../Terrain3DAdapter")
@export var foundation_ground_path := NodePath("../FoundationGround")

var terrain_state: TerrainState
@onready var terrain_renderer := get_node_or_null("TerrainMesh") as TerrainRenderer
@onready var terrain3d_adapter := get_node_or_null(terrain3d_adapter_path) as Terrain3DAdapter
@onready var foundation_ground := get_node_or_null(foundation_ground_path) as MeshInstance3D


func _ready() -> void:
	terrain_state = TerrainState.new(terrain_seed, terrain_rows, terrain_columns, terrain_spacing_m)
	if terrain3d_adapter != null and not terrain3d_adapter.backend_changed.is_connected(_on_terrain3d_backend_changed):
		terrain3d_adapter.backend_changed.connect(_on_terrain3d_backend_changed)
	rebuild_mesh()


func enqueue_brush_for_test(sequence: int, center_xz: Vector2, radius_m: float, delta_m: float) -> bool:
	if terrain_state == null:
		return false
	return terrain_state.enqueue_brush(sequence, center_xz, radius_m, delta_m)


func step_fixed_for_test() -> bool:
	if terrain_state == null:
		return false
	var changed := terrain_state.step_fixed()
	if changed:
		rebuild_mesh()
	return changed


func reset_for_test() -> void:
	if terrain_state == null:
		return
	terrain_state.reset()
	rebuild_mesh()


func rebuild_mesh() -> bool:
	if terrain_state == null:
		return false
	var snapshot := terrain_state.surface_snapshot()
	var native_applied := false
	if terrain3d_adapter != null:
		terrain3d_adapter.queue_snapshot(snapshot)
		native_applied = terrain3d_adapter.apply_pending()
		_on_terrain3d_backend_changed(terrain3d_adapter.is_native_mesh_active())
	var fallback_applied := false
	if terrain_renderer != null:
		if not terrain_renderer.queue_snapshot(snapshot) and terrain_renderer.get_applied_identity() != Vector2i(int(snapshot["world_generation"]), int(snapshot["terrain_revision"])):
			return native_applied
		fallback_applied = terrain_renderer.apply_pending()
	return native_applied or fallback_applied


func _on_terrain3d_backend_changed(active: bool) -> void:
	if terrain_renderer != null:
		terrain_renderer.visible = not active
	if foundation_ground != null:
		foundation_ground.visible = not active

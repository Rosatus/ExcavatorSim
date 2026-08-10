class_name TerrainWorld
extends Node3D

@export var terrain_seed := TerrainState.DEFAULT_SEED
@export var terrain_rows := TerrainState.DEFAULT_ROWS
@export var terrain_columns := TerrainState.DEFAULT_COLUMNS
@export var terrain_spacing_m := TerrainState.DEFAULT_SPACING_M

var terrain_state: TerrainState
@onready var terrain_renderer := get_node_or_null("TerrainMesh") as TerrainRenderer


func _ready() -> void:
	terrain_state = TerrainState.new(terrain_seed, terrain_rows, terrain_columns, terrain_spacing_m)
	if terrain_renderer != null:
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
	if terrain_state == null or terrain_renderer == null:
		return false
	if not terrain_renderer.queue_snapshot(terrain_state.surface_snapshot()):
		return false
	return terrain_renderer.apply_pending()

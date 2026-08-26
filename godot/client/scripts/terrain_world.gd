class_name TerrainWorld
extends Node3D

signal world_reset(world_generation: int)

@export var terrain_seed := TerrainState.DEFAULT_SEED
@export var terrain_rows := TerrainState.DEFAULT_ROWS
@export var terrain_columns := TerrainState.DEFAULT_COLUMNS
@export var terrain_spacing_m := TerrainState.DEFAULT_SPACING_M
@export var terrain3d_adapter_path := NodePath("../Terrain3DAdapter")
@export var foundation_ground_path := NodePath("../FoundationGround")
## "terrain3d" uses the native GDExtension surface; "soil_shader" forces the
## built-in procedural soil mesh (deterministic across machines/GPU drivers).
@export var terrain_backend := "soil_shader"

var terrain_state: TerrainState
@onready var terrain_renderer := get_node_or_null("TerrainMesh") as TerrainRenderer
@onready var terrain3d_adapter := get_node_or_null(terrain3d_adapter_path) as Terrain3DAdapter
@onready var foundation_ground := get_node_or_null(foundation_ground_path) as MeshInstance3D

## Latest accepted snapshot, kept so the fail-open fallback renderer can catch
## up in one full rebuild if the native backend ever deactivates.
var _latest_snapshot: Dictionary = {}


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
	world_reset.emit(terrain_state.world_generation)


func reset_state_for_scheduler() -> bool:
	if terrain_state == null:
		return false
	terrain_state.reset()
	return true


func notify_world_reset_from_scheduler() -> void:
	if terrain_state != null:
		world_reset.emit(terrain_state.world_generation)


func rebuild_mesh() -> bool:
	if terrain_state == null:
		return false
	return rebuild_mesh_from_snapshot(terrain_state.surface_snapshot())


func rebuild_mesh_from_snapshot(snapshot: Dictionary) -> bool:
	if terrain_state == null or snapshot.is_empty():
		return false
	if int(snapshot.get("world_generation", -1)) != terrain_state.world_generation:
		return false
	if int(snapshot.get("terrain_revision", -1)) != terrain_state.terrain_revision:
		return false
	_latest_snapshot = snapshot
	var native_applied := false
	var native_active := false
	if terrain_backend == "soil_shader":
		# Deterministic soil-shader presentation: keep the native backend off
		# and hide the white foundation slab so the soil mesh is what shows.
		if terrain3d_adapter != null:
			terrain3d_adapter.set_test_mode(false)
			terrain3d_adapter.deactivate_native_for_test()
		if foundation_ground != null:
			foundation_ground.visible = false
	elif terrain3d_adapter != null:
		terrain3d_adapter.queue_snapshot(snapshot)
		native_applied = terrain3d_adapter.apply_pending()
		native_active = terrain3d_adapter.is_native_mesh_active()
	var fallback_applied := false
	if terrain_renderer != null:
		if native_active and _is_ordinary_patch_snapshot(snapshot):
			# Native Terrain3D owns presentation for ordinary revisions; the
			# hidden fallback mesh need not rebuild every patch. It catches up
			# in full if the native backend ever deactivates.
			return native_applied
		if not terrain_renderer.queue_snapshot(snapshot) and terrain_renderer.get_applied_identity() != Vector2i(int(snapshot["world_generation"]), int(snapshot["terrain_revision"])):
			return native_applied
		fallback_applied = terrain_renderer.apply_pending()
	return native_applied or fallback_applied


func _on_terrain3d_backend_changed(active: bool) -> void:
	if terrain_renderer != null:
		terrain_renderer.visible = not active
	if foundation_ground != null:
		foundation_ground.visible = not active
	if not active:
		_sync_fallback_to_latest()


## Full fallback rebuild from the latest accepted snapshot so there is always
## one visible valid surface when the native backend is gone.
func _sync_fallback_to_latest() -> void:
	if terrain_renderer == null or _latest_snapshot.is_empty():
		return
	var identity := Vector2i(int(_latest_snapshot.get("world_generation", -1)), int(_latest_snapshot.get("terrain_revision", -1)))
	if terrain_renderer.visible and terrain_renderer.get_applied_identity() == identity:
		return
	terrain_renderer.queue_snapshot(_latest_snapshot)
	terrain_renderer.apply_pending()


func _is_ordinary_patch_snapshot(snapshot: Dictionary) -> bool:
	return not bool(snapshot.get("full_refresh", true))

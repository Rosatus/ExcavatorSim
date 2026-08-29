class_name TerrainWorld
extends Node3D

signal world_reset(world_generation: int)

const BACKEND_TERRAIN3D := "terrain3d"
const BACKEND_FALLBACK := "soil_shader"
const OVERRIDE_NONE := "none"
const OVERRIDE_TEST_GRID := "test_grid"
const FALLBACK_CONFIGURED := "configured_soil_shader"
const FALLBACK_TEST_GRID := "test_grid_override"
const FALLBACK_EXTENSION := "native_extension_unavailable"
const FALLBACK_MATERIAL := "native_material_unavailable"
const FALLBACK_MAP := "native_map_materialization_failed"
const FALLBACK_MATERIALIZATION := "native_materialization_failed"
const FALLBACK_SYNC_FAILED := "fallback_sync_failed"

@export var terrain_seed := TerrainState.DEFAULT_SEED
@export var terrain_rows := TerrainState.DEFAULT_ROWS
@export var terrain_columns := TerrainState.DEFAULT_COLUMNS
@export var terrain_spacing_m := TerrainState.DEFAULT_SPACING_M
@export var terrain3d_adapter_path := NodePath("../Terrain3DAdapter")
@export var foundation_ground_path := NodePath("../FoundationGround")
## "terrain3d" uses the native GDExtension surface; "soil_shader" forces the
## built-in procedural soil mesh (deterministic across machines/GPU drivers).
@export var terrain_backend := "terrain3d"

var terrain_state: TerrainState
@onready var terrain_renderer := get_node_or_null("TerrainMesh") as TerrainRenderer
@onready var terrain3d_adapter := get_node_or_null(terrain3d_adapter_path) as Terrain3DAdapter
@onready var foundation_ground := get_node_or_null(foundation_ground_path) as MeshInstance3D

## Latest accepted snapshot, kept so the fail-open fallback renderer can catch
## up in one full rebuild if the native backend ever deactivates.
var _latest_snapshot: Dictionary = {}
var _retired_epochs: Dictionary = {}
var _active_backend := BACKEND_FALLBACK
var _presentation_override := OVERRIDE_NONE
var _fallback_reason := FALLBACK_CONFIGURED
var _switching_surface := false
var _fallback_sync_count := 0
var _fallback_sync_failure_count := 0


func _ready() -> void:
	terrain_state = TerrainState.new(terrain_seed, terrain_rows, terrain_columns, terrain_spacing_m)
	if terrain3d_adapter != null and not terrain3d_adapter.backend_changed.is_connected(_on_terrain3d_backend_changed):
		terrain3d_adapter.backend_changed.connect(_on_terrain3d_backend_changed)
	if terrain3d_adapter != null and not terrain3d_adapter.materialization_failed.is_connected(_on_terrain3d_materialization_failed):
		terrain3d_adapter.materialization_failed.connect(_on_terrain3d_materialization_failed)
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
	var epoch := String(snapshot.get("terrain_epoch", ""))
	if epoch.is_empty() or epoch != terrain_state.terrain_epoch or _retired_epochs.has(epoch):
		return false
	if int(snapshot.get("world_generation", -1)) != terrain_state.world_generation:
		return false
	if int(snapshot.get("terrain_revision", -1)) != terrain_state.terrain_revision:
		return false
	var incoming_identity := Vector2i(int(snapshot["world_generation"]), int(snapshot["terrain_revision"]))
	if not _latest_snapshot.is_empty():
		var latest_epoch := String(_latest_snapshot["terrain_epoch"])
		var latest_identity := _snapshot_identity(_latest_snapshot)
		if epoch == latest_epoch and (incoming_identity.x < latest_identity.x or \
				(incoming_identity.x == latest_identity.x and incoming_identity.y < latest_identity.y)):
			return false
		if epoch != latest_epoch:
			_retired_epochs[latest_epoch] = true
	# Repeated requests for the same logical identity are presentation retries;
	# never replace the retained immutable authority copy with caller-owned data.
	if _latest_snapshot.is_empty() or epoch != String(_latest_snapshot["terrain_epoch"]) \
			or incoming_identity != _snapshot_identity(_latest_snapshot):
		_latest_snapshot = _copy_snapshot(snapshot)
	return _refresh_presentation()


func _refresh_presentation() -> bool:
	if _latest_snapshot.is_empty():
		return false
	if _presentation_override == OVERRIDE_TEST_GRID:
		return _activate_fallback(FALLBACK_TEST_GRID, false)
	var native_applied := false
	if _configured_backend() == BACKEND_FALLBACK:
		# Deterministic soil-shader presentation: keep the native backend off
		# and hide the white foundation slab so the soil mesh is what shows.
		if terrain3d_adapter != null:
			terrain3d_adapter.set_test_mode(false)
		return _activate_fallback(FALLBACK_CONFIGURED, false)
	elif terrain3d_adapter != null:
		terrain3d_adapter.set_test_mode(false)
		var native_identity_matches := terrain3d_adapter.get_applied_epoch() == String(_latest_snapshot["terrain_epoch"]) \
			and terrain3d_adapter.get_applied_identity() == _snapshot_identity(_latest_snapshot)
		var queued := false
		if _active_backend == BACKEND_FALLBACK and native_identity_matches:
			queued = terrain3d_adapter.queue_full_resync(_latest_snapshot)
		else:
			queued = terrain3d_adapter.queue_snapshot(_latest_snapshot)
		native_applied = terrain3d_adapter.apply_pending()
		if native_applied or (not queued and native_identity_matches and terrain3d_adapter.is_native_mesh_active()):
			_commit_native_surface()
			return true
	if _active_backend == BACKEND_FALLBACK and _fallback_applied_matches_latest():
		return true
	return _activate_fallback(_fallback_reason_from_error(terrain3d_adapter.last_error if terrain3d_adapter != null else ""), true)


func _on_terrain3d_backend_changed(active: bool) -> void:
	if _switching_surface:
		return
	if active and _configured_backend() == BACKEND_TERRAIN3D and _presentation_override == OVERRIDE_NONE:
		_commit_native_surface()
	elif active:
		_activate_fallback(FALLBACK_TEST_GRID if _presentation_override == OVERRIDE_TEST_GRID else FALLBACK_CONFIGURED, false)
	elif _active_backend != BACKEND_FALLBACK:
		_activate_fallback(_fallback_reason if not _fallback_reason.is_empty() else FALLBACK_MATERIALIZATION, true)


func _on_terrain3d_materialization_failed(message: String) -> void:
	_activate_fallback(_fallback_reason_from_error(message), true)


## Full fallback rebuild from the latest accepted snapshot so there is always
## one visible valid surface when the native backend is gone.
func _sync_fallback_to_latest(force_full: bool) -> bool:
	if terrain_renderer == null or _latest_snapshot.is_empty():
		return false
	var epoch := String(_latest_snapshot["terrain_epoch"])
	var identity := _snapshot_identity(_latest_snapshot)
	if not force_full and terrain_renderer.get_applied_epoch() == epoch and terrain_renderer.get_applied_identity() == identity:
		return true
	var queued := terrain_renderer.queue_full_resync(_latest_snapshot) if force_full else terrain_renderer.queue_snapshot(_latest_snapshot)
	if not queued:
		return terrain_renderer.get_applied_epoch() == epoch and terrain_renderer.get_applied_identity() == identity
	if not terrain_renderer.apply_pending():
		_fallback_sync_failure_count += 1
		return false
	_fallback_sync_count += 1
	return terrain_renderer.get_applied_epoch() == epoch and terrain_renderer.get_applied_identity() == identity


func set_test_mode(value: bool) -> bool:
	var requested := OVERRIDE_TEST_GRID if value else OVERRIDE_NONE
	if requested == _presentation_override:
		return true
	if value:
		# Synchronize the authoritative fallback before hiding native. The visual
		# switch itself happens only after the full surface exists.
		if not _sync_fallback_to_latest(true):
			_fallback_reason = FALLBACK_SYNC_FAILED
			return false
		_presentation_override = OVERRIDE_TEST_GRID
		if terrain_renderer != null:
			terrain_renderer.set_test_mode(true)
		_commit_fallback_surface(FALLBACK_TEST_GRID)
		if terrain3d_adapter != null:
			terrain3d_adapter.set_test_mode(true)
		return true
	_presentation_override = OVERRIDE_NONE
	if terrain_renderer != null:
		terrain_renderer.set_test_mode(false)
	if _configured_backend() == BACKEND_FALLBACK:
		if terrain3d_adapter != null:
			terrain3d_adapter.set_test_mode(false)
		return _activate_fallback(FALLBACK_CONFIGURED, true)
	if terrain3d_adapter == null or _latest_snapshot.is_empty():
		return _activate_fallback(FALLBACK_EXTENSION, true)
	terrain3d_adapter.set_test_mode(false)
	if terrain3d_adapter.queue_full_resync(_latest_snapshot) and terrain3d_adapter.apply_pending():
		_commit_native_surface()
		return true
	# The failure signal normally performs this transition; keep the fallback
	# active if a stale/no-op queue prevented an apply attempt.
	return _activate_fallback(_fallback_reason_from_error(terrain3d_adapter.last_error), true)


func get_status_snapshot() -> Dictionary:
	var status := terrain3d_adapter.get_status_snapshot() if terrain3d_adapter != null else {"enabled": false, "available": false}
	status["configured_backend"] = _configured_backend()
	status["active_backend"] = _active_backend
	status["active_renderer"] = "terrain3d" if _active_backend == BACKEND_TERRAIN3D else "fallback"
	status["presentation_override"] = _presentation_override
	status["fallback_reason"] = _fallback_reason
	status["accepted_epoch"] = String(_latest_snapshot.get("terrain_epoch", ""))
	status["accepted_generation"] = int(_latest_snapshot.get("world_generation", -1))
	status["accepted_revision"] = int(_latest_snapshot.get("terrain_revision", -1))
	status["fallback_sync_count"] = _fallback_sync_count
	status["fallback_sync_failure_count"] = _fallback_sync_failure_count
	status["fallback"] = terrain_renderer.get_status_snapshot() if terrain_renderer != null else {"available": false}
	status["foundation_visible"] = foundation_ground.visible if foundation_ground != null else false
	status["visible_surface_count"] = int(terrain3d_adapter != null and terrain3d_adapter.is_native_mesh_active()) \
		+ int(terrain_renderer != null and terrain_renderer.visible)
	return status


func _activate_fallback(reason: String, force_full: bool) -> bool:
	if not _sync_fallback_to_latest(force_full):
		_fallback_reason = FALLBACK_SYNC_FAILED
		return false
	_commit_fallback_surface(reason)
	return true


func _commit_fallback_surface(reason: String) -> void:
	_switching_surface = true
	if terrain_renderer != null:
		terrain_renderer.visible = true
	if foundation_ground != null:
		foundation_ground.visible = _configured_backend() == BACKEND_TERRAIN3D or _presentation_override == OVERRIDE_TEST_GRID
	if terrain3d_adapter != null:
		terrain3d_adapter.deactivate_native_for_test()
	_active_backend = BACKEND_FALLBACK
	_fallback_reason = reason
	_switching_surface = false


func _commit_native_surface() -> void:
	_switching_surface = true
	if terrain_renderer != null:
		terrain_renderer.visible = false
	if foundation_ground != null:
		foundation_ground.visible = false
	_active_backend = BACKEND_TERRAIN3D
	_fallback_reason = ""
	_switching_surface = false


func _configured_backend() -> String:
	return BACKEND_TERRAIN3D if terrain_backend == BACKEND_TERRAIN3D else BACKEND_FALLBACK


func _fallback_reason_from_error(message: String) -> String:
	var lowered := message.to_lower()
	if lowered.contains("gdextension") or lowered.contains("class is unavailable"):
		return FALLBACK_EXTENSION
	if lowered.contains("material") or lowered.contains("shader"):
		return FALLBACK_MATERIAL
	if lowered.contains("map") or lowered.contains("image") or lowered.contains("region") or lowered.contains("data"):
		return FALLBACK_MAP
	return FALLBACK_MATERIALIZATION


func _snapshot_identity(snapshot: Dictionary) -> Vector2i:
	return Vector2i(int(snapshot.get("world_generation", -1)), int(snapshot.get("terrain_revision", -1)))


func _fallback_applied_matches_latest() -> bool:
	return terrain_renderer != null and not _latest_snapshot.is_empty() \
		and terrain_renderer.get_applied_epoch() == String(_latest_snapshot["terrain_epoch"]) \
		and terrain_renderer.get_applied_identity() == _snapshot_identity(_latest_snapshot)


func _copy_snapshot(snapshot: Dictionary) -> Dictionary:
	var copied := snapshot.duplicate(true)
	copied["surface"] = (snapshot["surface"] as PackedFloat32Array).duplicate()
	copied["surface_bytes"] = (snapshot["surface_bytes"] as PackedByteArray).duplicate()
	return copied

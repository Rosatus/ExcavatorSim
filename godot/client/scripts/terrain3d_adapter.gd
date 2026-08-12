class_name Terrain3DAdapter
extends Node3D

## Optional Terrain3D presentation backend.
##
## TerrainState remains the logical authority. This node only materializes an
## accepted, copied snapshot into Terrain3D and can be discarded at any time.
## If the GDExtension or a map update is unavailable, callers keep using the
## custom TerrainRenderer/TerrainCollider path.
signal backend_changed(active: bool)

const TERRAIN_CLASS := "Terrain3D"

@export var enabled := true
@export var region_size := 1024
@export var assets_path := "res://demo/data/assets.tres"
@export_enum("Disabled:0", "Dynamic Game:1", "Dynamic Editor:2", "Full Game:3", "Full Editor:4") var native_collision_mode := 0

var available := false
var collision_available := false
var last_error := ""

var _terrain_node: Node3D
var _pending_snapshot: Dictionary = {}
var _queued_epoch := ""
var _queued_generation := -1
var _queued_revision := -1
var _applied_epoch := ""
var _applied_generation := -1
var _applied_revision := -1
var _retired_epochs: Dictionary = {}
var _ready_complete := false


func _ready() -> void:
	# Keep the feature switch in project.godot so a package without the native
	# library can turn this backend off without changing scene data.
	enabled = enabled and bool(ProjectSettings.get_setting("terrain3d/runtime_enabled", true))
	native_collision_mode = int(ProjectSettings.get_setting("terrain3d/collision_mode", native_collision_mode))
	_ready_complete = true
	if enabled:
		call_deferred("_apply_pending_deferred")


func _exit_tree() -> void:
	if _terrain_node != null and is_instance_valid(_terrain_node):
		_terrain_node.queue_free()
	_terrain_node = null
	available = false
	collision_available = false


func queue_snapshot(snapshot: Dictionary) -> bool:
	if not _is_snapshot_valid(snapshot):
		return false
	var epoch := String(snapshot["terrain_epoch"])
	if _retired_epochs.has(epoch):
		return false
	var generation := int(snapshot["world_generation"])
	var revision := int(snapshot["terrain_revision"])
	if epoch == _queued_epoch and (generation < _queued_generation or \
		(generation == _queued_generation and revision <= _queued_revision)):
		return false
	if not _queued_epoch.is_empty() and epoch != _queued_epoch:
		_retired_epochs[_queued_epoch] = true
	_pending_snapshot = {}
	_pending_snapshot = snapshot.duplicate(true)
	_pending_snapshot["surface"] = (snapshot["surface"] as PackedFloat32Array).duplicate()
	_pending_snapshot["surface_bytes"] = (snapshot["surface_bytes"] as PackedByteArray).duplicate()
	_queued_epoch = epoch
	_queued_generation = generation
	_queued_revision = revision
	_set_native_active(false)
	return true


func apply_pending() -> bool:
	if _pending_snapshot.is_empty() or not _ready_complete or not enabled:
		_set_native_active(false)
		return false
	var snapshot := _pending_snapshot
	var epoch := String(snapshot["terrain_epoch"])
	var generation := int(snapshot["world_generation"])
	var revision := int(snapshot["terrain_revision"])
	if epoch != _queued_epoch or generation != _queued_generation or revision != _queued_revision:
		return false
	if epoch == _applied_epoch and (generation < _applied_generation or \
		(generation == _applied_generation and revision <= _applied_revision)):
		_pending_snapshot = {}
		return false
	if not _ensure_terrain_node():
		return false
	if not _materialize_snapshot(snapshot):
		return false
	_applied_epoch = epoch
	_applied_generation = generation
	_applied_revision = revision
	_pending_snapshot = {}
	_set_native_active(true)
	return true


func get_applied_identity() -> Vector2i:
	return Vector2i(_applied_generation, _applied_revision)


func get_applied_epoch() -> String:
	return _applied_epoch


func is_native_mesh_active() -> bool:
	return available


func get_status_snapshot() -> Dictionary:
	return {
		"enabled": enabled,
		"available": available,
		"collision_available": collision_available,
		"last_error": last_error,
		"terrain_class_loaded": ClassDB.class_exists(TERRAIN_CLASS),
		"queued_epoch": _queued_epoch,
		"queued_generation": _queued_generation,
		"queued_revision": _queued_revision,
		"applied_epoch": _applied_epoch,
		"applied_generation": _applied_generation,
		"applied_revision": _applied_revision,
	}


func _apply_pending_deferred() -> void:
	apply_pending()


func _ensure_terrain_node() -> bool:
	if _terrain_node != null and is_instance_valid(_terrain_node):
		return true
	if not ClassDB.class_exists(TERRAIN_CLASS):
		_set_error("Terrain3D GDExtension class is unavailable")
		return false
	var instance: Object = ClassDB.instantiate(TERRAIN_CLASS)
	if instance == null or not (instance is Node3D):
		_set_error("Terrain3D could not be instantiated")
		return false
	_terrain_node = instance as Node3D
	_terrain_node.name = "Terrain3DNative"
	add_child(_terrain_node, true)
	_set_property_if_present(_terrain_node, "region_size", region_size)
	_set_property_if_present(_terrain_node, "collision_mask", 1)
	var assets: Variant = load(assets_path) if not assets_path.is_empty() and ResourceLoader.exists(assets_path) else null
	if assets != null:
		_set_property_if_present(_terrain_node, "assets", assets)
	return true


func _materialize_snapshot(snapshot: Dictionary) -> bool:
	var rows := int(snapshot["rows"])
	var columns := int(snapshot["columns"])
	var spacing := float(snapshot["spacing_m"])
	var origin: Vector2 = snapshot["origin_xz"]
	var surface: PackedFloat32Array = snapshot["surface"]
	var bytes: PackedByteArray = snapshot["surface_bytes"]
	if rows < 2 or columns < 2 or spacing <= 0.0 or surface.size() != rows * columns or bytes.size() != surface.size() * 4:
		_set_error("Terrain3D snapshot dimensions or bytes are invalid")
		return false
	_set_property_if_present(_terrain_node, "vertex_spacing", spacing)
	var data: Variant = _terrain_node.get("data")
	if not (data is Object):
		_set_error("Terrain3D data object is unavailable")
		return false
	var data_object := data as Object
	if not data_object.has_method("import_images"):
		_set_error("Terrain3D data.import_images is unavailable")
		return false
	var height_image := Image.create_from_data(columns, rows, false, Image.FORMAT_RF, bytes)
	if height_image == null or height_image.is_empty():
		_set_error("Terrain3D height image could not be created")
		return false
	var maps: Array = [height_image, null, null]
	# Terrain3D uses world X/Z for import position. The logical digest remains
	# the original row-major TerrainState bytes, independent of this conversion.
	data_object.call("import_images", maps, Vector3(origin.x, 0.0, origin.y), 0.0, 1.0)
	if data_object.has_method("calc_height_range"):
		data_object.call("calc_height_range", true)
	if data_object.has_method("get_regions_active"):
		var regions: Variant = data_object.call("get_regions_active")
		if regions is Array and (regions as Array).is_empty():
			_set_error("Terrain3D imported no active regions")
			return false
	_configure_collision()
	last_error = ""
	return true


func _configure_collision() -> void:
	collision_available = false
	if native_collision_mode <= 0 or _terrain_node == null:
		return
	var collision: Variant = _terrain_node.get("collision")
	if not (collision is Object):
		_set_error("Terrain3D collision object is unavailable")
		return
	var collision_object := collision as Object
	if collision_object.has_method("set_mode"):
		collision_object.call("set_mode", native_collision_mode)
	elif _has_property(collision_object, "mode"):
		collision_object.set("mode", native_collision_mode)
	else:
		_set_error("Terrain3D collision mode API is unavailable")
		return
	collision_available = true


func _set_native_active(active: bool) -> void:
	var changed := available != active
	available = active
	if _terrain_node != null and is_instance_valid(_terrain_node):
		_terrain_node.visible = active
	if changed:
		backend_changed.emit(active)


func _set_error(message: String) -> void:
	last_error = message
	_set_native_active(false)


func _set_property_if_present(object: Object, property_name: String, value: Variant) -> void:
	if _has_property(object, property_name):
		object.set(property_name, value)


func _has_property(object: Object, property_name: String) -> bool:
	for property in object.get_property_list():
		if String(property.get("name", "")) == property_name:
			return true
	return false


func _is_snapshot_valid(snapshot: Dictionary) -> bool:
	return snapshot.has_all(["terrain_epoch", "world_generation", "terrain_revision", "rows", "columns", "spacing_m", "origin_xz", "surface", "surface_bytes"])

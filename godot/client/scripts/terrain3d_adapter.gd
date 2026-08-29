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
const REGION_CLASS := "Terrain3DRegion"
## Terrain3DRegion.MapType.TYPE_HEIGHT (0): real-value height map.
const MAP_TYPE_HEIGHT := 0
const DEMO_MATERIAL := "res://assets/terrain/terrain3d_demo_material.tres"
const DEMO_PARTICLES := "res://addons/terrain_3d/extras/particle_example/Terrain3DParticles.tscn"
const ROCK_SCENES := [
	"res://demo/assets/models/RockA.glb",
	"res://demo/assets/models/RockB.glb",
	"res://demo/assets/models/RockC.glb",
]
const ROCK_ALBEDO := "res://assets/terrain/textures/rock023_alb_ht.png"
const ROCK_NORMAL := "res://assets/terrain/textures/rock023_nrm_rgh.png"

@export var enabled := true
@export var region_size := 128
@export var construction_site_enabled := true
@export var assets_path := ""
@export_file("*.tres") var material_path := DEMO_MATERIAL
@export_enum("Disabled:0", "Dynamic Game:1", "Dynamic Editor:2", "Full Game:3", "Full Editor:4") var native_collision_mode := 0

var available := false
var collision_available := false
var last_error := ""

## Instrumentation for the incremental revision contract: ordinary revisions
## must increment patch_count and never full_import_count.
var full_import_count := 0
var patch_count := 0
var patch_failure_count := 0

var _terrain_node: Node3D
var _pending_snapshot: Dictionary = {}
var _pending_full_refresh := true
var _queued_epoch := ""
var _queued_generation := -1
var _queued_revision := -1
var _applied_epoch := ""
var _applied_generation := -1
var _applied_revision := -1
var _retired_epochs: Dictionary = {}
var _ready_complete := false
var _site_profile := ConstructionSiteTerrainProfile.new()
var _presentation_rows := 0
var _presentation_columns := 0
var _presentation_spacing := 0.0
var _presentation_origin := Vector2.ZERO
var _region_size_verts := 0
var _patch_offset := Vector2i.ZERO
var _patch_capable := false
var _resync_requested := false
var _assets_source := "none"
var _dressing_root: Node3D
var _rock_count := 0
var _tree_count := 0
var _test_mode := false
var _configured_material: Resource
var _configured_material_path := ""
var _terrain_ready := false


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
	_terrain_ready = false
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
	_pending_full_refresh = _resync_requested or _requires_full_materialization(snapshot)
	# No-flicker invariant: the active native surface stays visible while patch
	# or full work is pending. Visibility only changes after a real success or a
	# hard failure inside apply_pending().
	return true


func apply_pending() -> bool:
	if _pending_snapshot.is_empty():
		return false
	if not _ready_complete or not enabled or _test_mode:
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
	var applied := false
	if not _pending_full_refresh and _can_patch(snapshot):
		applied = _patch_snapshot(snapshot)
		if not applied:
			# A failed patch leaves the previous surface visible and schedules a
			# full resync. Retry the same snapshot through the full path once so
			# the applied identity still converges without a stale window.
			patch_failure_count += 1
			_resync_requested = true
			applied = _materialize_snapshot(snapshot)
	else:
		applied = _materialize_snapshot(snapshot)
	if not applied:
		# Roll the queue gate back to the applied identity so the same or any
		# later revision can be re-queued after a recovery or resync.
		if not _applied_epoch.is_empty():
			_retired_epochs.erase(_applied_epoch)
			_queued_epoch = _applied_epoch
			_queued_generation = _applied_generation
			_queued_revision = _applied_revision
		return false
	_applied_epoch = epoch
	_applied_generation = generation
	_applied_revision = revision
	_pending_snapshot = {}
	_pending_full_refresh = false
	# Any successful materialization satisfies a previously requested resync;
	# leaving the flag set would force every later revision through the full
	# import path instead of ordinary patches.
	_resync_requested = false
	_set_native_active(true)
	return true


func get_applied_identity() -> Vector2i:
	return Vector2i(_applied_generation, _applied_revision)


func get_applied_epoch() -> String:
	return _applied_epoch


func is_native_mesh_active() -> bool:
	return available and not _test_mode


## Force the native Terrain3D surface off (soil-shader backend). Idempotent.
func deactivate_native_for_test() -> void:
	_test_mode = false
	_set_native_active(false)


func set_test_mode(value: bool) -> bool:
	if _test_mode == value:
		return true
	_test_mode = value
	if _test_mode:
		# Product decision: test-grid look = Terrain3D's own black/white
		# checkerboard, achieved by dropping its material entirely.
		if _terrain_node != null and is_instance_valid(_terrain_node):
			_set_property_if_present(_terrain_node, "material", null)
		_set_native_active(false)
	elif not _pending_snapshot.is_empty():
		_configure_material()
		apply_pending()
	elif _terrain_node != null and is_instance_valid(_terrain_node) and _applied_generation >= 0:
		_configure_material()
		_set_native_active(true)
	return true


func set_collision_mode(mode: int) -> bool:
	native_collision_mode = clampi(mode, 0, 4)
	_configure_collision()
	return collision_available


func get_status_snapshot() -> Dictionary:
	var material: Object = _terrain_node.get("material") as Object if _terrain_node != null and is_instance_valid(_terrain_node) else null
	var assets: Object = _terrain_node.get("assets") as Object if _terrain_node != null and is_instance_valid(_terrain_node) else null
	var data: Object = _terrain_node.get("data") as Object if _terrain_node != null and is_instance_valid(_terrain_node) else null
	var regions: Array = data.call("get_regions_active") as Array if data != null and data.has_method("get_regions_active") else []
	var mouse_quad := _terrain_node.find_child("MouseQuad", true, false) as MeshInstance3D if _terrain_node != null and is_instance_valid(_terrain_node) else null
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
		"full_import_count": full_import_count,
		"patch_count": patch_count,
		"patch_failure_count": patch_failure_count,
		"resync_requested": _resync_requested,
		"patch_capable": _patch_capable,
		"presentation_rows": _presentation_rows,
		"presentation_columns": _presentation_columns,
		"site_extent_m": ConstructionSiteTerrainProfile.SITE_EXTENT_M if construction_site_enabled else 0.0,
		"material_roles": _site_profile.get_material_roles() if construction_site_enabled else PackedStringArray(),
		"assets_source": _assets_source,
		"material_source": material_path,
		"native_class": _terrain_node.get_class() if _terrain_node != null and is_instance_valid(_terrain_node) else "",
		"native_version": String(_terrain_node.get("version")) if _terrain_node != null and is_instance_valid(_terrain_node) and _has_property(_terrain_node, "version") else "",
		"native_material_class": material.get_class() if material != null else "",
		"native_material_ready": material != null,
		"native_assets_class": assets.get_class() if assets != null else "",
		"native_assets_ready": assets != null,
		"native_region_count": regions.size(),
		"mouse_quad_present": mouse_quad != null,
		"mouse_quad_visible": mouse_quad.visible if mouse_quad != null else false,
		"godot_version": String(Engine.get_version_info().get("string", "unknown")),
		"rendering_method": _project_rendering_feature(),
		"rendering_driver": _rendering_server_string("get_current_rendering_driver_name"),
		"video_adapter": RenderingServer.get_video_adapter_name(),
		"rock_count": _rock_count,
		"tree_count": _tree_count,
		"grass_enabled": not _test_mode and _dressing_root != null and _dressing_root.has_node("Terrain3DParticles"),
		"test_mode": _test_mode,
	}


func _apply_pending_deferred() -> void:
	apply_pending()


func _ensure_terrain_node() -> bool:
	if _terrain_node != null and is_instance_valid(_terrain_node) and _terrain_ready:
		return true
	if _terrain_node == null or not is_instance_valid(_terrain_node):
		if not ClassDB.class_exists(TERRAIN_CLASS):
			_set_error("Terrain3D GDExtension class is unavailable")
			return false
		var instance: Object = ClassDB.instantiate(TERRAIN_CLASS)
		if instance == null or not (instance is Node3D):
			_set_error("Terrain3D could not be instantiated")
			return false
		_terrain_node = instance as Node3D
		_terrain_node.name = "Terrain3DNative"
		var assets: Variant = load(assets_path) if not assets_path.is_empty() and ResourceLoader.exists(assets_path) else null
		if assets != null:
			_assets_source = assets_path
		elif construction_site_enabled:
			assets = _site_profile.create_assets()
			_assets_source = "demo:terrain3d-official" if assets != null else "none"
		if assets != null:
			_set_property_if_present(_terrain_node, "assets", assets)
	if not _configure_material():
		return false
	# Terrain3D initializes as soon as it enters the tree. Assets and material
	# must exist for that first pass, while size settings must follow it because
	# native initialization restores their defaults.
	if not _terrain_node.is_inside_tree():
		add_child(_terrain_node, true)
	_set_property_if_present(_terrain_node, "region_size", region_size)
	_set_property_if_present(_terrain_node, "collision_mask", 1)
	# Native initialization can reset the material during the first pass;
	# re-apply after entering the tree so the shipped build keeps its surface.
	if not _configure_material():
		return false
	_ensure_dressing_root()
	_terrain_ready = true
	return true


func _materialize_snapshot(snapshot: Dictionary) -> bool:
	var presentation := _site_profile.build_maps(snapshot) if construction_site_enabled else {
		"rows": int(snapshot["rows"]),
		"columns": int(snapshot["columns"]),
		"spacing_m": float(snapshot["spacing_m"]),
		"origin_xz": snapshot["origin_xz"],
		"surface": snapshot["surface"],
		"height_bytes": snapshot["surface_bytes"],
		"control_bytes": PackedByteArray(),
	}
	if presentation.is_empty():
		_set_error("Terrain3D construction-site presentation could not be built")
		return false
	var rows := int(presentation["rows"])
	var columns := int(presentation["columns"])
	var spacing := float(presentation["spacing_m"])
	var origin: Vector2 = presentation["origin_xz"]
	var surface: PackedFloat32Array = presentation["surface"]
	var bytes: PackedByteArray = presentation["height_bytes"]
	var control_bytes: PackedByteArray = presentation["control_bytes"]
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
	var control_image: Image = null
	if control_bytes.size() == surface.size() * 4:
		control_image = Image.create_from_data(columns, rows, false, Image.FORMAT_RF, control_bytes)
		if control_image == null or control_image.is_empty():
			_set_error("Terrain3D control image could not be created")
			return false
	var maps: Array = [height_image, control_image, null]
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
	_presentation_rows = rows
	_presentation_columns = columns
	_presentation_spacing = spacing
	_presentation_origin = origin
	_region_size_verts = int(_terrain_node.get("region_size")) if _has_property(_terrain_node, "region_size") else region_size
	_compute_patch_capability(snapshot, presentation)
	full_import_count += 1
	# Dressing is rebuilt only on the full path so ordinary revisions keep the
	# site dressing nodes stable.
	_update_dressing(presentation)
	_configure_collision()
	last_error = ""
	return true


## True when the pending snapshot cannot be applied as an ordinary patch and
## must go through build_maps/import_images. Conservative by design: any
## missing dirty information means a full materialization.
func _requires_full_materialization(snapshot: Dictionary) -> bool:
	if String(snapshot["terrain_epoch"]) != _applied_epoch:
		return true
	if int(snapshot["world_generation"]) != _applied_generation:
		return true
	return bool(snapshot.get("full_refresh", true))


## Patch preconditions: a compatible applied native state plus a contiguous,
## current dirty rectangle. Callers fall back to the full path when false.
func _can_patch(snapshot: Dictionary) -> bool:
	if not available or _terrain_node == null or not is_instance_valid(_terrain_node):
		return false
	if not _patch_capable or _presentation_rows < 2 or _presentation_columns < 2 \
			or _presentation_spacing <= 0.0 or _region_size_verts < 2:
		return false
	if String(snapshot["terrain_epoch"]) != _applied_epoch:
		return false
	if int(snapshot["world_generation"]) != _applied_generation:
		return false
	if int(snapshot["terrain_revision"]) != _applied_revision + 1:
		return false
	if bool(snapshot.get("full_refresh", true)):
		return false
	var dirty: Rect2i = snapshot.get("dirty_rect_with_halo", Rect2i())
	return dirty.size.x > 0 and dirty.size.y > 0


## Ordinary-revision path: edit the existing Terrain3D region height maps for
## the mapped dirty pixels plus halo, mark those regions edited, then refresh
## only edited regions through Terrain3DData.update_maps(). The previous native
## surface stays visible throughout; on failure the caller retries fully.
func _patch_snapshot(snapshot: Dictionary) -> bool:
	var data: Variant = _terrain_node.get("data")
	if not (data is Object) or not (data as Object).has_method("update_maps") \
			or not (data as Object).has_method("get_region"):
		return false
	var data_object := data as Object
	var logical_rows := int(snapshot["rows"])
	var logical_columns := int(snapshot["columns"])
	var surface: PackedFloat32Array = snapshot["surface"]
	if surface.size() != logical_rows * logical_columns:
		return false
	var dirty: Rect2i = snapshot.get("dirty_rect_with_halo", Rect2i())
	if dirty.position.x < 0 or dirty.position.y < 0 \
			or dirty.position.x + dirty.size.x > logical_columns \
			or dirty.position.y + dirty.size.y > logical_rows:
		return false
	# Map the clamped logical halo rectangle onto presentation samples. The
	# central logical patch mirrors logical values bit-for-bit, so no context
	# shaping participates in a patch.
	var pres_min := Vector2i(
		clampi(_patch_offset.x + dirty.position.x, 0, _presentation_columns - 1),
		clampi(_patch_offset.y + dirty.position.y, 0, _presentation_rows - 1)
	)
	var pres_max := Vector2i(
		clampi(_patch_offset.x + dirty.position.x + dirty.size.x - 1, 0, _presentation_columns - 1),
		clampi(_patch_offset.y + dirty.position.y + dirty.size.y - 1, 0, _presentation_rows - 1)
	)
	if pres_max.x < pres_min.x or pres_max.y < pres_min.y:
		return false
	var region_world := float(_region_size_verts) * _presentation_spacing
	if region_world <= 0.0:
		return false
	var world_min := _presentation_origin + Vector2(pres_min) * _presentation_spacing
	var world_max_exclusive := _presentation_origin + Vector2(pres_max.x + 1, pres_max.y + 1) * _presentation_spacing
	var region_min := Vector2i(floori(world_min.x / region_world), floori(world_min.y / region_world))
	var region_max := Vector2i(
		floori((world_max_exclusive.x - 0.01) / region_world),
		floori((world_max_exclusive.y - 0.01) / region_world)
	)
	for region_row in range(region_min.y, region_max.y + 1):
		for region_column in range(region_min.x, region_max.x + 1):
			if not _patch_region_heights(
				data_object,
				Vector2i(region_column, region_row),
				pres_min,
				pres_max,
				logical_rows,
				logical_columns,
				surface
			):
				return false
	data_object.call("update_maps", MAP_TYPE_HEIGHT, false, false)
	if data_object.has_method("calc_height_range"):
		data_object.call("calc_height_range", false)
	patch_count += 1
	last_error = ""
	return true


## Writes one region's share of the dirty rectangle into its live height map
## image and flags the region edited/modified with refreshed height bounds.
func _patch_region_heights(
	data_object: Object,
	region_location: Vector2i,
	pres_min: Vector2i,
	pres_max: Vector2i,
	logical_rows: int,
	logical_columns: int,
	surface: PackedFloat32Array
) -> bool:
	if not bool(data_object.call("has_region", region_location)):
		return false
	var region: Object = data_object.call("get_region", region_location)
	if region == null or bool(region.get("deleted")):
		return false
	var height_map: Image = region.get("height_map")
	if height_map == null or height_map.is_empty() \
			or height_map.get_format() != Image.FORMAT_RF \
			or height_map.get_width() < _region_size_verts or height_map.get_height() < _region_size_verts:
		return false
	var region_origin_world := Vector2(region_location) * float(_region_size_verts) * _presentation_spacing
	var written_low := INF
	var written_high := -INF
	for pres_row in range(pres_min.y, pres_max.y + 1):
		var world_z := _presentation_origin.y + float(pres_row) * _presentation_spacing
		var pixel_y := roundi((world_z - region_origin_world.y) / _presentation_spacing)
		if pixel_y < 0 or pixel_y >= _region_size_verts:
			continue
		var logical_row := pres_row - _patch_offset.y
		if logical_row < 0 or logical_row >= logical_rows:
			continue
		for pres_column in range(pres_min.x, pres_max.x + 1):
			var world_x := _presentation_origin.x + float(pres_column) * _presentation_spacing
			var pixel_x := roundi((world_x - region_origin_world.x) / _presentation_spacing)
			if pixel_x < 0 or pixel_x >= _region_size_verts:
				continue
			var logical_column := pres_column - _patch_offset.x
			if logical_column < 0 or logical_column >= logical_columns:
				continue
			var height := surface[logical_row * logical_columns + logical_column]
			height_map.set_pixel(pixel_x, pixel_y, Color(height, 0.0, 0.0, 1.0))
			written_low = minf(written_low, height)
			written_high = maxf(written_high, height)
	if is_finite(written_low):
		# Expand the region's vertical bounds so the AABB covers new heights;
		# calc_height_range below refreshes the master range afterwards.
		if region.has_method("update_heights"):
			region.call("update_heights", Vector2(written_low, written_high))
	region.set("edited", true)
	region.set("modified", true)
	return true


## Records how the accepted logical grid maps onto the materialized presentation
## grid. Patches require an integral, in-bounds sample offset; otherwise every
## revision takes the full path (correct, just slower).
func _compute_patch_capability(snapshot: Dictionary, presentation: Dictionary) -> void:
	_patch_capable = false
	_patch_offset = Vector2i.ZERO
	var logical_rows := int(snapshot["rows"])
	var logical_columns := int(snapshot["columns"])
	if logical_rows < 2 or logical_columns < 2:
		return
	if not construction_site_enabled:
		_patch_capable = logical_rows == _presentation_rows and logical_columns == _presentation_columns
		return
	var logical_origin: Vector2 = snapshot["origin_xz"]
	var offset_f := (logical_origin - _presentation_origin) / _presentation_spacing
	var offset := Vector2i(roundi(offset_f.x), roundi(offset_f.y))
	var integral := absf(offset_f.x - float(offset.x)) <= 0.01 and absf(offset_f.y - float(offset.y)) <= 0.01
	_patch_capable = integral \
		and offset.x >= 0 and offset.y >= 0 \
		and offset.x + logical_columns <= _presentation_columns \
		and offset.y + logical_rows <= _presentation_rows
	_patch_offset = offset if _patch_capable else Vector2i.ZERO


func _configure_material() -> bool:
	if _terrain_node == null:
		return false
	if construction_site_enabled:
		if _configured_material == null or _configured_material_path != material_path:
			_configured_material = _load_demo_material()
			_configured_material_path = material_path
		if _configured_material == null:
			_set_error("Terrain3D material is unavailable: %s" % material_path)
			return false
		# Terrain3D 1.0.2 keeps RenderingServer dependencies on the assigned
		# material. Replacing it with a freshly duplicated resource immediately
		# after enter-tree leaves stale/null material RIDs on Godot 4.7 D3D12.
		# Reuse the exact pre-tree resource and only reassign if native setup
		# actually cleared or replaced it.
		if _terrain_node.get("material") != _configured_material:
			_set_property_if_present(_terrain_node, "material", _configured_material)
		if _terrain_node.get("material") == null:
			_set_error("Terrain3D material could not be assigned: %s" % material_path)
			return false
	return true


func _load_demo_material() -> Resource:
	var source := load(material_path) as Resource if not material_path.is_empty() and ResourceLoader.exists(material_path) else null
	return source.duplicate(true) if source != null else null


func _rendering_server_string(method_name: StringName) -> String:
	if not RenderingServer.has_method(method_name):
		return "unavailable"
	return String(RenderingServer.call(method_name))


func _project_rendering_feature() -> String:
	var features: PackedStringArray = ProjectSettings.get_setting("application/config/features", PackedStringArray())
	for feature in features:
		if feature in ["Forward Plus", "Mobile", "GL Compatibility"]:
			return feature
	return "unknown"


func _ensure_dressing_root() -> void:
	if _dressing_root != null and is_instance_valid(_dressing_root):
		return
	_dressing_root = Node3D.new()
	_dressing_root.name = "ConstructionSiteDressing"
	add_child(_dressing_root, true)


func _update_dressing(presentation: Dictionary) -> void:
	_ensure_dressing_root()
	for child in _dressing_root.get_children():
		child.free()
	var dressing := _site_profile.build_dressing(presentation)
	var rocks: Array = dressing.get("rocks", [])
	_rock_count = rocks.size()
	_tree_count = 0
	if not rocks.is_empty():
		_add_rock_layers(rocks)
	_add_demo_particles()


func _add_rock_layers(entries: Array) -> void:
	for rock_index in ROCK_SCENES.size():
		var mesh := _load_rock_mesh(ROCK_SCENES[rock_index])
		if mesh == null:
			continue
		var transforms: Array[Transform3D] = []
		for entry_index in entries.size():
			if entry_index % ROCK_SCENES.size() == rock_index:
				transforms.append(_rock_transform(entries[entry_index]))
		if not transforms.is_empty():
			_add_multimesh_layer("Rocks%d" % (rock_index + 1), mesh, transforms)


func _add_multimesh_layer(layer_name: String, mesh: Mesh, transforms: Array[Transform3D]) -> void:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for index in transforms.size():
		multimesh.set_instance_transform(index, transforms[index])
	var instance := MultiMeshInstance3D.new()
	instance.name = layer_name
	instance.multimesh = multimesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_dressing_root.add_child(instance, true)


func _rock_transform(entry: Dictionary) -> Transform3D:
	var scale := float(entry["scale"])
	var position: Vector3 = entry["position"]
	var basis := Basis(Vector3.UP, float(entry["yaw"]))
	basis = basis.scaled(Vector3(scale * 1.15, scale * 0.72, scale))
	return Transform3D(basis, position + Vector3(0.0, scale * 0.18, 0.0))


func _load_rock_mesh(scene_path: String) -> Mesh:
	var packed := load(scene_path) as PackedScene
	if packed == null:
		return null
	var instance := packed.instantiate()
	var mesh_instances := instance.find_children("*", "MeshInstance3D", true, false)
	var mesh_instance := mesh_instances[0] as MeshInstance3D if not mesh_instances.is_empty() else null
	if mesh_instance == null or mesh_instance.mesh == null:
		instance.free()
		return null
	var mesh := mesh_instance.mesh.duplicate(true) as Mesh
	instance.free()
	var material := _create_rock_material()
	for surface in mesh.get_surface_count():
		mesh.surface_set_material(surface, material)
	return mesh


func _create_rock_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = load(ROCK_ALBEDO) as Texture2D
	material.normal_enabled = true
	material.normal_texture = load(ROCK_NORMAL) as Texture2D
	material.roughness = 0.92
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.uv1_scale = Vector3.ONE * 0.2
	return material


func _add_demo_particles() -> void:
	if _terrain_node == null:
		return
	var packed := load(DEMO_PARTICLES) as PackedScene
	if packed == null:
		return
	var particles := packed.instantiate()
	particles.name = "Terrain3DParticles"
	var process_material := particles.get("process_material") as ShaderMaterial
	if process_material != null:
		process_material = process_material.duplicate(true) as ShaderMaterial
		process_material.set_shader_parameter("exclusion_radius", 12.0)
		particles.set("process_material", process_material)
	_dressing_root.add_child(particles, true)
	particles.set("terrain", _terrain_node)


func _configure_collision() -> void:
	collision_available = false
	if _terrain_node == null:
		return
	var collision: Variant = _terrain_node.get("collision")
	if not (collision is Object):
		if native_collision_mode > 0:
			_set_error("Terrain3D collision object is unavailable")
		return
	var collision_object := collision as Object
	if collision_object.has_method("set_mode"):
		collision_object.call("set_mode", native_collision_mode)
	elif _has_property(collision_object, "mode"):
		collision_object.set("mode", native_collision_mode)
	else:
		if native_collision_mode > 0:
			_set_error("Terrain3D collision mode API is unavailable")
		return
	# Terrain3D rebuilds its native shape asynchronously. Mask the collision
	# object immediately on disable so stale shapes cannot remain query-visible
	# during that rebuild window; restore the declared layer when re-enabled.
	if _has_property(collision_object, "layer"):
		collision_object.set("layer", 1 if native_collision_mode > 0 else 0)
	collision_available = native_collision_mode > 0


func _set_native_active(active: bool) -> void:
	var changed := available != active
	available = active
	if _terrain_node != null and is_instance_valid(_terrain_node):
		_terrain_node.visible = active
	if _dressing_root != null and is_instance_valid(_dressing_root):
		_dressing_root.visible = active and not _test_mode
		for particle_value in _dressing_root.find_children("*", "GPUParticles3D", true, false):
			(particle_value as GPUParticles3D).emitting = active and not _test_mode
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

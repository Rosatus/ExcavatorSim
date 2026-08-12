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
const DEMO_MATERIAL := "res://assets/terrain/terrain3d_demo_material.tres"
const DEMO_PARTICLES := "res://addons/terrain_3d/extras/particle_example/Terrain3DParticles.tscn"
const ROCK_SCENES := [
	"res://demo/assets/models/RockA.glb",
	"res://demo/assets/models/RockB.glb",
	"res://demo/assets/models/RockC.glb",
]
const ROCK_ALBEDO := "res://demo/assets/textures/rock023_alb_ht.png"
const ROCK_NORMAL := "res://demo/assets/textures/rock023_nrm_rgh.png"

@export var enabled := true
@export var region_size := 128
@export var construction_site_enabled := true
@export var assets_path := ""
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
var _site_profile := ConstructionSiteTerrainProfile.new()
var _presentation_rows := 0
var _presentation_columns := 0
var _assets_source := "none"
var _dressing_root: Node3D
var _rock_count := 0
var _tree_count := 0


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


func set_collision_mode(mode: int) -> bool:
	native_collision_mode = clampi(mode, 0, 4)
	_configure_collision()
	return collision_available


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
		"presentation_rows": _presentation_rows,
		"presentation_columns": _presentation_columns,
		"site_extent_m": ConstructionSiteTerrainProfile.SITE_EXTENT_M if construction_site_enabled else 0.0,
		"material_roles": _site_profile.get_material_roles() if construction_site_enabled else PackedStringArray(),
		"assets_source": _assets_source,
		"rock_count": _rock_count,
		"tree_count": _tree_count,
		"grass_enabled": _dressing_root != null and _dressing_root.has_node("Terrain3DParticles"),
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
		_assets_source = assets_path
	elif construction_site_enabled:
		assets = _site_profile.create_assets()
		_assets_source = "demo:terrain3d-official" if assets != null else "none"
	if assets != null:
		_set_property_if_present(_terrain_node, "assets", assets)
	_configure_material()
	_ensure_dressing_root()
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
	_update_dressing(presentation)
	_configure_collision()
	last_error = ""
	return true


func _configure_material() -> void:
	if _terrain_node == null or DisplayServer.get_name() == "headless":
		return
	if construction_site_enabled:
		var demo_material := _load_demo_material()
		if demo_material != null:
			_set_property_if_present(_terrain_node, "material", demo_material)


func _load_demo_material() -> Resource:
	var source := load(DEMO_MATERIAL) as Resource
	return source.duplicate(true) if source != null else null


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
	collision_available = native_collision_mode > 0


func _set_native_active(active: bool) -> void:
	var changed := available != active
	available = active
	if _terrain_node != null and is_instance_valid(_terrain_node):
		_terrain_node.visible = active
	if _dressing_root != null and is_instance_valid(_dressing_root):
		_dressing_root.visible = active
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

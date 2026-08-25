class_name ConstructionSiteDressing
extends Node3D

## Deterministic, disposable worksite composition shared by Terrain3D and the
## fallback renderer. Every child is visual-only; this node never creates a
## CollisionObject3D or writes the accepted terrain snapshot.

const PROFILE_VISIBILITY := {
	"test": [],
	"low": ["Primary"],
	"balanced": ["Primary", "Context"],
	"high": ["Primary", "Context", "Detail"],
}
const CATEGORY_KEYS := {
	"Primary": ["barriers", "stakes", "signs"],
	"Context": ["route_markers", "pipes"],
	"Detail": ["track_marks", "aggregate"],
}

@export var terrain_world_path := NodePath("../TerrainWorld")
@export var visual_quality_path := NodePath("../../VisualQualityController")
@export var profile := "balanced"

var _terrain_world: TerrainWorld
var _site_profile := ConstructionSiteTerrainProfile.new()
var _layout_identity := ""
var _world_generation := -1
var _cue_counts := {}
var _materials := {}
var _meshes := {}


func _ready() -> void:
	_terrain_world = get_node_or_null(terrain_world_path) as TerrainWorld
	var quality := get_node_or_null(visual_quality_path)
	if quality != null and quality.has_method("get_quality_snapshot"):
		var quality_snapshot := quality.call("get_quality_snapshot") as Dictionary
		var requested_profile := String(quality_snapshot.get("profile", profile))
		if PROFILE_VISIBILITY.has(requested_profile):
			profile = requested_profile
	if _terrain_world != null:
		_terrain_world.world_reset.connect(_on_world_reset)
	call_deferred("_rebuild_from_world")


func set_quality_profile(profile_name: String) -> bool:
	if not PROFILE_VISIBILITY.has(profile_name):
		return false
	profile = profile_name
	_apply_quality_visibility()
	return true


func get_status_snapshot() -> Dictionary:
	var visible_cues := 0
	var shadow_instances := 0
	for category in CATEGORY_KEYS:
		var root := get_node_or_null(category) as Node3D
		if root != null and root.visible:
			for key in CATEGORY_KEYS[category]:
				visible_cues += int(_cue_counts.get(key, 0))
			for geometry in root.find_children("*", "GeometryInstance3D", true, false):
				if (geometry as GeometryInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
					shadow_instances += 1
	return {
		"profile": profile,
		"layout_identity": _layout_identity,
		"world_generation": _world_generation,
		"cue_counts": _cue_counts.duplicate(true),
		"visible_cues": visible_cues,
		"shadow_instances": shadow_instances,
		"collision_objects": find_children("*", "CollisionObject3D", true, false).size(),
		"category_count": CATEGORY_KEYS.size(),
		"code_native": true,
	}


func _rebuild_from_world() -> void:
	if _terrain_world == null or _terrain_world.terrain_state == null:
		return
	var snapshot := _terrain_world.terrain_state.surface_snapshot()
	var maps := _site_profile.build_maps(snapshot)
	var layout := _site_profile.build_worksite_layout(maps)
	if maps.is_empty() or layout.is_empty():
		return
	_clear_visuals()
	_ensure_resources()
	for category in CATEGORY_KEYS:
		var category_root := Node3D.new()
		category_root.name = category
		add_child(category_root, true)
		for key in CATEGORY_KEYS[category]:
			var entries := layout.get(key, []) as Array
			_cue_counts[key] = entries.size()
			for index in entries.size():
				_add_cue(category_root, key, index, entries[index] as Dictionary)
	_layout_identity = _compute_layout_identity(layout, snapshot)
	_world_generation = int(snapshot.get("world_generation", -1))
	_apply_quality_visibility()


func _add_cue(parent: Node3D, kind: String, index: int, entry: Dictionary) -> void:
	var origin := entry["position"] as Vector3
	var yaw := float(entry.get("yaw", 0.0))
	var cue := Node3D.new()
	cue.name = "%s_%02d" % [kind, index]
	cue.position = origin
	cue.rotation.y = yaw
	parent.add_child(cue, true)
	match kind:
		"barriers":
			_add_mesh(cue, "Beam", _meshes["barrier_beam"], _materials["safety_orange"], Vector3(0.0, 0.9, 0.0))
			_add_mesh(cue, "FootL", _meshes["barrier_foot"], _materials["safety_white"], Vector3(-0.85, 0.12, 0.0))
			_add_mesh(cue, "FootR", _meshes["barrier_foot"], _materials["safety_white"], Vector3(0.85, 0.12, 0.0))
		"stakes":
			_add_mesh(cue, "Stake", _meshes["stake"], _materials["stake_wood"], Vector3(0.0, 0.7, 0.0))
			_add_mesh(cue, "Flag", _meshes["flag"], _materials["safety_orange"], Vector3(0.17, 1.2, 0.0))
		"route_markers":
			_add_mesh(cue, "Cone", _meshes["cone"], _materials["safety_orange"], Vector3(0.0, 0.32, 0.0))
		"track_marks":
			_add_mesh(cue, "Mark", _meshes["track_mark"], _materials["track_mark"], Vector3(0.0, 0.025, 0.0), false)
		"pipes":
			var pipe := _add_mesh(cue, "Pipe", _meshes["pipe"], _materials["concrete"], Vector3(0.0, 0.38, 0.0))
			pipe.rotation.x = PI * 0.5
		"aggregate":
			var aggregate := _add_mesh(cue, "Aggregate", _meshes["aggregate"], _materials["aggregate"], Vector3(0.0, 0.38, 0.0))
			aggregate.scale = Vector3(1.2, 0.55, 1.0)
		"signs":
			_add_mesh(cue, "Pole", _meshes["sign_pole"], _materials["steel"], Vector3(0.0, 1.0, 0.0))
			_add_mesh(cue, "Board", _meshes["sign_board"], _materials["safety_orange"], Vector3(0.0, 1.85, 0.0))


func _add_mesh(parent: Node3D, node_name: String, mesh_value: Mesh, material: Material, offset: Vector3, cast_shadow := true) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh_value
	instance.material_override = material
	instance.position = offset
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance, true)
	return instance


func _ensure_resources() -> void:
	if not _materials.is_empty():
		return
	_materials = {
		"safety_orange": _material(Color("e97819"), 0.72),
		"safety_white": _material(Color("e7e2d1"), 0.82),
		"stake_wood": _material(Color("75513a"), 0.95),
		"track_mark": _material(Color(0.12, 0.095, 0.075, 0.58), 1.0, true),
		"concrete": _material(Color("747875"), 0.93),
		"aggregate": _material(Color("6d665a"), 0.98),
		"steel": _material(Color("555d62"), 0.78),
	}
	_meshes = {
		"barrier_beam": _box(Vector3(2.5, 0.34, 0.22)),
		"barrier_foot": _box(Vector3(0.62, 0.18, 0.72)),
		"stake": _cylinder(0.045, 1.4, 8),
		"flag": _box(Vector3(0.34, 0.22, 0.025)),
		"cone": _cone(0.26, 0.62, 12),
		"track_mark": _box(Vector3(0.52, 0.025, 1.05)),
		"pipe": _cylinder(0.34, 2.4, 20),
		"aggregate": _sphere(0.65, 12, 8),
		"sign_pole": _cylinder(0.055, 2.0, 10),
		"sign_board": _box(Vector3(1.45, 0.85, 0.08)),
	}


func _apply_quality_visibility() -> void:
	var visible_categories := PROFILE_VISIBILITY.get(profile, PROFILE_VISIBILITY["balanced"]) as Array
	for category in CATEGORY_KEYS:
		var root := get_node_or_null(category) as Node3D
		if root == null:
			continue
		root.visible = visible_categories.has(category)
		for geometry in root.find_children("*", "GeometryInstance3D", true, false):
			var instance := geometry as GeometryInstance3D
			var is_track_mark := instance.name == "Mark"
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if profile in ["test", "low"] or is_track_mark else GeometryInstance3D.SHADOW_CASTING_SETTING_ON


func _on_world_reset(_world_generation: int) -> void:
	_rebuild_from_world()


func _clear_visuals() -> void:
	for child in get_children():
		child.free()
	_cue_counts.clear()


func _compute_layout_identity(layout: Dictionary, snapshot: Dictionary) -> String:
	var values := PackedStringArray([str(snapshot.get("seed", 0))])
	for key in ["barriers", "stakes", "route_markers", "track_marks", "pipes", "aggregate", "signs"]:
		for entry in layout.get(key, []):
			var position := (entry as Dictionary)["position"] as Vector3
			values.append("%s:%.3f:%.3f:%.3f" % [key, position.x, position.y, position.z])
	return "|".join(values).sha256_text()


func _material(color: Color, roughness: float, transparent := false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = 0.0
	if transparent:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	return material


func _box(size: Vector3) -> BoxMesh:
	var mesh_value := BoxMesh.new()
	mesh_value.size = size
	return mesh_value


func _cylinder(radius: float, height: float, sides: int) -> CylinderMesh:
	var mesh_value := CylinderMesh.new()
	mesh_value.top_radius = radius
	mesh_value.bottom_radius = radius
	mesh_value.height = height
	mesh_value.radial_segments = sides
	return mesh_value


func _cone(radius: float, height: float, sides: int) -> CylinderMesh:
	var mesh_value := CylinderMesh.new()
	mesh_value.top_radius = 0.035
	mesh_value.bottom_radius = radius
	mesh_value.height = height
	mesh_value.radial_segments = sides
	return mesh_value


func _sphere(radius: float, radial_segments: int, rings: int) -> SphereMesh:
	var mesh_value := SphereMesh.new()
	mesh_value.radius = radius
	mesh_value.height = radius * 2.0
	mesh_value.radial_segments = radial_segments
	mesh_value.rings = rings
	return mesh_value

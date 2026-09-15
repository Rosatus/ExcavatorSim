@tool
extends Node3D

@export var asset_id := "pipe"
@export var use_source_asset := true
var import_state := "proxy"


func _ready() -> void:
	var catalog: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://asset_catalog/catalog.json"))
	for item: Dictionary in catalog.assets:
		if item.id != asset_id:
			continue
		var cached_path: String = "res://" + item.cache
		if use_source_asset and ResourceLoader.exists(cached_path):
			var packed := load(cached_path) as PackedScene
			if packed != null:
				var visual := packed.instantiate() as Node3D
				visual.scale = Vector3.ONE * float(item.scale)
				visual.position.y = float(item.ground_offset) * float(item.scale)
				add_child(visual)
				import_state = "cached_glb"
				return
		var proxy := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(item.size[0], item.size[1], item.size[2])
		proxy.mesh = box
		proxy.position.y = box.size.y * 0.5
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.48, 0.43, 0.34)
		mat.roughness = 0.95
		proxy.material_override = mat
		add_child(proxy)
		return


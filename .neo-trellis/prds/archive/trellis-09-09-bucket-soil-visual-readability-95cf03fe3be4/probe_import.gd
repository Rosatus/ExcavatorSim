extends SceneTree

func _init() -> void:
	for model in ["sy135", "sy205"]:
		var asset := load("res://assets/visual/%s_excavator_godot.glb" % model.to_upper()).instantiate() as Node3D
		root.add_child(asset)
		var bucket := asset.find_child("bucket", true, false) as MeshInstance3D
		var mat := bucket.mesh.surface_get_material(0) as StandardMaterial3D
		print(model, " imported bucket material: albedo=", mat.albedo_color, " roughness=", mat.roughness,
			" metallic=", mat.metallic, " cull=", mat.cull_mode, " transform=", bucket.transform)
		asset.free()
	print("ambient enum sky=", Environment.AMBIENT_SOURCE_SKY, " background=", Environment.AMBIENT_SOURCE_BG)
	quit()

extends SceneTree

const BASE := "res://maps/construction/"

func _initialize() -> void:
	call_deferred("build")

func build() -> void:
	if FileAccess.file_exists(BASE + "terrain_data/terrain3d_00_00.res") and "--replace-generated" not in OS.get_cmdline_user_args():
		push_error("Ground already exists. Edit the terrain in the editor; do not regenerate it.")
		quit(1)
		return
	var terrain := Terrain3D.new()
	terrain.name = "Ground"
	terrain.free_editor_textures = false
	terrain.region_size = 256
	terrain.vertex_spacing = 1.0
	terrain.collision_mode = 3
	terrain.collision_layer = 1
	terrain.collision_mask = 1
	terrain.material = Terrain3DMaterial.new()
	terrain.material.world_background = Terrain3DMaterial.NONE
	terrain.assets = Terrain3DAssets.new()
	var texture := Terrain3DTextureAsset.new()
	texture.name = "Construction concrete"
	var path := BASE + "Construction_Site/Textures/Tileable/MT00086-Concrete/4096x4096/T_MT00086-Concrete_Floor_"
	texture.albedo_texture = load(path + "basecolor.png")
	texture.normal_texture = load(path + "normal.png")
	texture.uv_scale = 0.125
	terrain.assets.set_texture(0, texture)
	root.add_child(terrain)
	# Original temporary plane: x [-298.34,267.66], z [-415.79,276.61].
	# Keep the authored flat grade. Outside the original site is a terrain hole.
	for rz in range(-2, 2):
		for rx in range(-2, 2):
			var height := Image.create(256, 256, false, Image.FORMAT_RF)
			height.fill(Color(-0.02, 0, 0, 1))
			var bits := PackedByteArray()
			bits.resize(256 * 256 * 4)
			for z in 256:
				for x in 256:
					var wx := rx * 256 + x
					var wz := rz * 256 + z
					if wx < -298 or wx > 267 or wz < -415 or wz > 276:
						bits.encode_u32((z * 256 + x) * 4, 4)
			var controls := Image.create_from_data(256, 256, false, Image.FORMAT_RF, bits)
			terrain.data.import_images([height, controls, null], Vector3(rx * 256, 0, rz * 256))
	DirAccess.make_dir_recursive_absolute(BASE + "terrain_data")
	terrain.data.save_directory(BASE + "terrain_data")
	terrain.data_directory = BASE + "terrain_data"
	terrain.set_script(load(BASE + "ground_runtime.gd"))
	var scene := PackedScene.new()
	assert(scene.pack(terrain) == OK)
	assert(ResourceSaver.save(scene, BASE + "Ground.tscn") == OK)
	print("GROUND_BUILT regions=16 original_grade=-0.02")
	quit()

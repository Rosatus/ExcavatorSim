extends SceneTree

const Zone = preload("res://scripts/voxel_work_zone.gd")
const Visuals = preload("res://scripts/soil_visual_resources.gd")


func _initialize() -> void:
	var zone := Zone.new()
	zone.initialize_on_ready = false
	zone.layout.configure_area(Vector3(37.0, 12.0, -19.0), Vector2(24.0, 32.0))
	zone.starter_pit = true
	var material: ShaderMaterial = zone._make_soil_material()
	assert(material.get_shader_parameter("initial_surface_y") == 12.0, "layers follow relocated map datum")
	assert(is_equal_approx(material.get_shader_parameter("starter_pit_depth"), 0.6))
	assert(material.get_shader_parameter("soil_bounds") == Vector4(25.0, -35.0, 49.0, -3.0))
	assert(material.get_shader_parameter("texture_albedo") == Visuals.ALBEDO)
	assert(material.get_shader_parameter("texture_normal") == Visuals.NORMAL_ROUGHNESS)
	var uniforms := material.shader.get_shader_uniform_list()
	assert(not uniforms.is_empty(), "shader parses and exposes uniforms")
	zone.starter_pit = false
	assert(zone._make_soil_material().get_shader_parameter("starter_pit_depth") == 0.0)
	var fill := Visuals.surface_material()
	assert(fill.albedo_texture == Visuals.ALBEDO and fill.normal_texture == Visuals.NORMAL_ROUGHNESS)
	assert(fill.roughness_texture == fill.normal_texture)
	assert(fill.roughness_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_ALPHA)
	assert(fill.uv1_triplanar and not fill.uv1_world_triplanar)
	assert(Visuals.surface_material(true).uv1_world_triplanar)
	assert(Visuals.ALBEDO.get_size() == Vector2(2048, 2048))
	var packed := Visuals.NORMAL_ROUGHNESS.get_image()
	if packed.is_compressed():
		assert(packed.decompress() == OK)
	var minimum := 1.0
	var maximum := 0.0
	for y in range(0, packed.get_height(), 64):
		for x in range(0, packed.get_width(), 64):
			var roughness := packed.get_pixel(x, y).a
			minimum = minf(minimum, roughness)
			maximum = maxf(maximum, roughness)
	assert(maximum - minimum > 0.1 and minimum < 0.95, "import preserves roughness alpha")
	zone.free()
	print("Fine03 soil resources, relocated layers, starter profile and roughness alpha: PASS")
	quit()

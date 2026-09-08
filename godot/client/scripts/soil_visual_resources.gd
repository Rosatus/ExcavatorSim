extends RefCounted

const ALBEDO = preload("res://assets/terrain/textures/ground037_alb_ht.png")
const NORMAL_ROUGHNESS = preload("res://assets/terrain/textures/ground037_nrm_rgh.png")
static var _clod_meshes: Dictionary = {}
static var _dust_texture: ImageTexture


static func surface_material(world_coordinates: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.82, 0.72, 0.59)
	material.albedo_texture = ALBEDO
	material.roughness = 0.96
	material.roughness_texture = NORMAL_ROUGHNESS
	material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_ALPHA
	material.normal_enabled = true
	material.normal_texture = NORMAL_ROUGHNESS
	material.normal_scale = 0.55
	material.uv1_triplanar = true
	material.uv1_world_triplanar = world_coordinates
	material.uv1_scale = Vector3.ONE * 1.4
	material.uv1_triplanar_sharpness = 4.0
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return material


static func clod_mesh(size: Vector3, variant: int = 0) -> ArrayMesh:
	var key := "%s:%d" % [size, variant]
	if _clod_meshes.has(key):
		return _clod_meshes[key] as ArrayMesh
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ring: Array[Vector3] = [Vector3.RIGHT, Vector3.FORWARD, Vector3.LEFT, Vector3.BACK]
	for pole in [Vector3.UP, Vector3.DOWN]:
		for index in 4:
			var a: Vector3 = pole
			var b := ring[index]
			var c := ring[(index + 1) % 4]
			var ab := (a + b).normalized()
			var bc := (b + c).normalized()
			var ca := (c + a).normalized()
			for triangle in [[a, ab, ca], [ab, b, bc], [ca, bc, c], [ab, bc, ca]]:
				var vertices: Array[Vector3] = []
				for direction: Vector3 in triangle:
					var noise := sin(direction.dot(Vector3(11.7, 7.3, 19.1)) + variant * 2.1)
					vertices.append(direction * size * (0.46 + noise * 0.07))
				# Godot front faces are clockwise. Ensure outward normals.
				var normal := (vertices[2] - vertices[0]).cross(vertices[1] - vertices[0]).normalized()
				if normal.dot(vertices[0] + vertices[1] + vertices[2]) < 0.0:
					vertices.reverse()
					normal = -normal
				var shade := 0.92 + 0.08 * sin(float(index + variant * 3))
				for vertex in vertices:
					tool.set_normal(normal)
					tool.set_color(Color(0.46, 0.31, 0.19) * shade)
					tool.add_vertex(vertex)
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 1.0
	tool.set_material(material)
	var mesh := tool.commit()
	_clod_meshes[key] = mesh
	return mesh


static func dust_texture() -> ImageTexture:
	if _dust_texture != null:
		return _dust_texture
	var image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var radius := Vector2((x - 31.5) / 31.5, (y - 31.5) / 31.5).length()
			var alpha := pow(maxf(0.0, 1.0 - radius * radius), 3.0)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	image.generate_mipmaps()
	_dust_texture = ImageTexture.create_from_image(image)
	return _dust_texture

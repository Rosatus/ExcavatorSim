shader_type spatial;
render_mode cull_disabled;

// Municipal utility-trench cutout for the urban ground slab. Fragments inside
// the voxel work-zone rectangle are discarded so the finite VoxelTerrain owns
// the strip — the same seam approach as construction's ground_voxel_seam
// shader, shrunk down for this plain box mesh.
uniform vec4 voxel_seam_rect = vec4(23.8, 27.45, 39.6, 33.0); // min_x, min_z, max_x, max_z

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (world_pos.x >= voxel_seam_rect.x && world_pos.x < voxel_seam_rect.z
			&& world_pos.z >= voxel_seam_rect.y && world_pos.z < voxel_seam_rect.w) {
		discard;
	}
	ALBEDO = vec3(0.14, 0.14, 0.15);
	ROUGHNESS = 0.97;
}

shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

#include "res://assets/terrain/shaders/worksite_soil_common.gdshaderinc"

varying vec3 site_world_position;
varying vec3 site_world_normal;

void vertex() {
	site_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	site_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	WorksiteSoilMaterial soil = worksite_soil_material(
		site_world_position,
		normalize(site_world_normal),
		CAMERA_POSITION_WORLD
	);
	ALBEDO = soil.albedo;
	ROUGHNESS = soil.roughness;
	METALLIC = 0.0;
	SPECULAR = soil.specular;
}

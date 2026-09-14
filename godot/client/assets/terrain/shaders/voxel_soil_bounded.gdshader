shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;
uniform sampler2D texture_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D texture_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 soil_bounds;
varying vec3 soil_world;
varying vec3 soil_normal;
void vertex() {
 soil_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
 soil_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}
void fragment() {
 if (any(lessThan(soil_world.xz, soil_bounds.xy)) || any(greaterThanEqual(soil_world.xz, soil_bounds.zw))) { discard; }
 vec3 weights = pow(abs(soil_normal), vec3(4.0));
 weights /= max(dot(weights, vec3(1.0)), 0.0001);
 vec3 p = soil_world * 1.4;
 vec3 color = texture(texture_albedo, p.zy).rgb * weights.x + texture(texture_albedo, p.xz).rgb * weights.y + texture(texture_albedo, p.xy).rgb * weights.z;
 vec4 bump = texture(texture_normal, p.zy) * weights.x + texture(texture_normal, p.xz) * weights.y + texture(texture_normal, p.xy) * weights.z;
 ALBEDO = color * vec3(0.82, 0.72, 0.59);
 ROUGHNESS = bump.a * 0.96;
 NORMAL_MAP = bump.rgb;
 NORMAL_MAP_DEPTH = 0.55;
}

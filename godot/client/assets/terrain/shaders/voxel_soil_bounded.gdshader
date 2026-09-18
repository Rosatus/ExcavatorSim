shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;
uniform sampler2D texture_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D texture_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 soil_bounds;
// Slope cut preview: the real soil surface marks the soil a confirmed pass
// would remove. Mode 1 blinks the region between solid (tinted) and discarded
// so the hole reads as soil leaving; mode 2 keeps a static tint while the
// assist cuts. The analytic target surface is the piecewise SlopeProfile:
// flat bench at toe height for s < toe_s, straight grade beyond it.
uniform int cut_mode = 0;
uniform vec2 cut_origin_xz = vec2(0.0, 0.0);
uniform vec2 cut_axis = vec2(1.0, 0.0);
uniform vec4 cut_band = vec4(0.0, 0.0, 0.6, 0.0); // x=s_min y=s_max z=half_width w=toe_s
uniform float cut_toe_height = 0.0;
uniform float cut_tan_theta = 0.0;
uniform vec4 cut_tint : source_color = vec4(1.0, 0.55, 0.15, 1.0);
uniform float cut_pulse_hz = 2.2;
varying vec3 soil_world;
varying vec3 soil_normal;
void vertex() {
 soil_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
 soil_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}
void fragment() {
 if (any(lessThan(soil_world.xz, soil_bounds.xy)) || any(greaterThanEqual(soil_world.xz, soil_bounds.zw))) { discard; }
 bool cut_marked = false;
 if (cut_mode != 0) {
  vec2 rel = soil_world.xz - cut_origin_xz;
  float s = dot(rel, cut_axis);
  float t = dot(rel, vec2(-cut_axis.y, cut_axis.x));
  float target_h = cut_toe_height + (s > cut_band.w ? cut_tan_theta * (s - cut_band.w) : 0.0);
  cut_marked = s >= cut_band.x && s <= cut_band.y && abs(t) <= cut_band.z && soil_world.y > target_h;
  if (cut_marked && cut_mode == 1 && fract(TIME * cut_pulse_hz) > 0.5) { discard; }
 }
 vec3 weights = pow(abs(soil_normal), vec3(4.0));
 weights /= max(dot(weights, vec3(1.0)), 0.0001);
 vec3 p = soil_world * 1.4;
 vec3 color = texture(texture_albedo, p.zy).rgb * weights.x + texture(texture_albedo, p.xz).rgb * weights.y + texture(texture_albedo, p.xy).rgb * weights.z;
 vec4 bump = texture(texture_normal, p.zy) * weights.x + texture(texture_normal, p.xz) * weights.y + texture(texture_normal, p.xy) * weights.z;
 ALBEDO = color * vec3(0.82, 0.72, 0.59);
 if (cut_marked) {
  ALBEDO = mix(ALBEDO, cut_tint.rgb, 0.55);
 }
 ROUGHNESS = bump.a * 0.96;
 NORMAL_MAP = bump.rgb;
 NORMAL_MAP_DEPTH = 0.55;
}

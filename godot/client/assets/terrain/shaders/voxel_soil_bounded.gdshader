shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;
uniform sampler2D texture_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D texture_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 soil_bounds;
uniform float initial_surface_y = 0.0;
uniform float starter_pit_depth = 0.0;
uniform float texture_scale = 0.5; // The scan covers 2 x 2 metres.
uniform vec3 subsoil_tint : source_color = vec3(0.80, 0.75, 0.68);
uniform float layer_start_m = 0.18;
uniform float layer_end_m = 0.42;
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
// Half-width of the smooth relu rounding the toe knee — the same C1 blend
// the tracked SlopeProfile uses so the mark boundary matches the surface
// the assist actually cuts (0 = sharp piecewise knee).
uniform float cut_knee_w = 0.0;
uniform vec4 cut_tint : source_color = vec4(1.0, 0.55, 0.15, 1.0);
uniform float cut_pulse_hz = 2.2;
varying vec3 soil_world;
varying vec3 soil_normal;

float soil_noise(vec2 p) {
 vec2 cell = floor(p);
 vec2 f = fract(p);
 f = f * f * (3.0 - 2.0 * f);
 vec4 h = fract(sin(vec4(dot(cell, vec2(127.1, 311.7)), dot(cell + vec2(1.0, 0.0), vec2(127.1, 311.7)), dot(cell + vec2(0.0, 1.0), vec2(127.1, 311.7)), dot(cell + vec2(1.0), vec2(127.1, 311.7)))) * 43758.5453);
 return mix(mix(h.x, h.y, f.x), mix(h.z, h.w, f.x), f.y);
}
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
  float x = s - cut_band.w;
  float rise = x;
  if (cut_knee_w > 0.0 && x < cut_knee_w) {
   rise = x <= -cut_knee_w ? 0.0 : (x + cut_knee_w) * (x + cut_knee_w) / (4.0 * cut_knee_w);
  } else if (x < 0.0) {
   rise = 0.0;
  }
  float target_h = cut_toe_height + cut_tan_theta * rise;
  cut_marked = s >= cut_band.x && s <= cut_band.y && abs(t) <= cut_band.z && soil_world.y > target_h;
  if (cut_marked && cut_mode == 1 && fract(TIME * cut_pulse_hz) > 0.5) { discard; }
 }
 vec3 geometric_normal = normalize(soil_normal);
 vec3 weights = pow(abs(geometric_normal), vec3(4.0));
 weights /= max(dot(weights, vec3(1.0)), 0.0001);
 vec3 p = soil_world * texture_scale;
 vec3 color = texture(texture_albedo, p.zy).rgb * weights.x + texture(texture_albedo, p.xz).rgb * weights.y + texture(texture_albedo, p.xy).rgb * weights.z;
 vec4 bump_x = texture(texture_normal, p.zy);
 vec4 bump_y = texture(texture_normal, p.xz);
 vec4 bump_z = texture(texture_normal, p.xy);
 // Match the immutable generator's optional starter-pit profile. Excavation
 // never moves this datum; color is presentation, not material inventory.
 vec2 edge = min(soil_world.xz - soil_bounds.xy, soil_bounds.zw - soil_world.xz);
 float surface_y = initial_surface_y - starter_pit_depth * smoothstep(1.5, 3.0, min(edge.x, edge.y));
 float depth = surface_y - soil_world.y;
 float irregularity = (soil_noise(soil_world.xz * 1.3) - 0.5) * 0.12;
 float lower_layer = smoothstep(layer_start_m, layer_end_m, depth + irregularity);
 float macro_variation = mix(0.94, 1.04, soil_noise(soil_world.xz * 0.23));
 ALBEDO = color * mix(vec3(1.0), subsoil_tint, lower_layer) * macro_variation;
 if (cut_marked) {
  ALBEDO = mix(ALBEDO, cut_tint.rgb, 0.55);
 }
 float roughness = dot(vec3(bump_x.a, bump_y.a, bump_z.a), weights);
 ROUGHNESS = clamp(roughness + mix(0.10, 0.02, lower_layer), 0.65, 1.0);
 // Reorient each OpenGL normal into its projection plane. Project the
 // perturbation onto the actual surface so a neutral map preserves the mesh
 // normal, including vertical cut walls without mesh UV/tangent attributes.
 vec2 nx = bump_x.rg * 2.0 - 1.0;
 vec2 ny = bump_y.rg * 2.0 - 1.0;
 vec2 nz = bump_z.rg * 2.0 - 1.0;
 vec3 detail = vec3(0.0, -nx.y, nx.x) * weights.x
             + vec3(ny.x, 0.0, -ny.y) * weights.y
             + vec3(nz.x, -nz.y, 0.0) * weights.z;
 detail -= geometric_normal * dot(detail, geometric_normal);
 vec3 world_normal = normalize(geometric_normal + detail * mix(0.55, 0.75, lower_layer));
 NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);
}

shader_type canvas_item;
render_mode unshaded;
// Slow warm sheen sweeping across the industrial menu panel.
uniform float period_s = 6.0;
uniform float band_width = 0.22;
uniform float strength = 0.055;
uniform vec4 tint : source_color = vec4(1.0, 0.82, 0.5, 1.0);
void fragment() {
 float t = fract(TIME / period_s) * (1.0 + band_width * 2.0) - band_width;
 float axis = UV.x * 0.8 + UV.y * 0.45;
 float d = abs(axis - t);
 float a = smoothstep(band_width, 0.0, d) * strength;
 COLOR = vec4(tint.rgb, a * tint.a);
}

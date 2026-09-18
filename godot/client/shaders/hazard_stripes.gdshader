shader_type canvas_item;
render_mode unshaded;
// Continuous scrolling hazard strip for the industrial menu header.
// FRAGCOORD keeps the pattern seamless across the full width; edges fade out.
uniform vec4 stripe_color : source_color = vec4(0.937, 0.714, 0.302, 1.0);
uniform vec4 base_color : source_color = vec4(0.075, 0.082, 0.09, 1.0);
uniform float stripe_px = 16.0;
uniform float scroll_px_s = 26.0;
uniform float slant = 0.85;
void fragment() {
 float p = (FRAGCOORD.x + FRAGCOORD.y * slant + TIME * scroll_px_s) / stripe_px;
 float w = max(fwidth(p) * 2.2, 0.001);
 float on = smoothstep(-w, w, sin(p * 6.28318530718));
 float fade = smoothstep(0.0, 0.04, UV.x) * smoothstep(1.0, 0.96, UV.x);
 vec4 c = mix(base_color, stripe_color, on * 0.85);
 c.a *= fade;
 COLOR = c;
}

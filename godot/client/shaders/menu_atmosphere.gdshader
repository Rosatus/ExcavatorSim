shader_type canvas_item;
render_mode unshaded;
uniform float ui_time = 0.0;
uniform float aspect_ratio = 1.7778;
void fragment() {
 vec2 p = UV * vec2(aspect_ratio, 1.0);
 float phase = ui_time * 0.018;
 vec2 drift = vec2(sin(phase), cos(phase * 0.73)) * 0.07;
 vec2 a = p - vec2(aspect_ratio * 0.78, 0.24) - drift;
 vec2 b = p - vec2(aspect_ratio * 0.17, 0.82) + drift;
 float terrain = sin(p.x * 3.1 + p.y * 2.3 + phase) + 0.45 * sin(p.y * 6.0 - p.x * 1.8 - phase * 0.5) + 0.18 * cos(p.x * 8.0 + p.y * 4.2);
 float contours = abs(fract(terrain * 5.0) - 0.5);
 float width = max(fwidth(terrain * 5.0), 0.001);
 float line = 1.0 - smoothstep(width * 0.35, width * 1.2, contours);
 float edge_mask = smoothstep(0.1, 0.6, abs(UV.x - 0.5) + abs(UV.y - 0.5));
 vec3 base = mix(vec3(0.035, 0.065, 0.085), vec3(0.09, 0.115, 0.13), UV.y);
 base += exp(-dot(a,a)*3.8) * vec3(0.13,0.075,0.025) + exp(-dot(b,b)*2.7) * vec3(0.01,0.065,0.085);
 base += line * edge_mask * vec3(0.08,0.085,0.075) * 0.32;
 COLOR = vec4(base, 0.86);
}

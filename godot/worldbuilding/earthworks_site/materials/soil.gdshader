shader_type spatial;
render_mode diffuse_burley;

varying vec3 world_position;
varying vec3 world_normal;

float hash(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
float noise3(vec3 p) {
	vec3 i = floor(p); vec3 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i), hash(i + vec3(1,0,0)), f.x), mix(hash(i + vec3(0,1,0)), hash(i + vec3(1,1,0)), f.x), f.y), mix(mix(hash(i + vec3(0,0,1)), hash(i + vec3(1,0,1)), f.x), mix(hash(i + vec3(0,1,1)), hash(i + vec3(1,1,1)), f.x), f.y), f.z);
}
void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}
void fragment() {
	float macro = noise3(world_position * 0.18);
	float grain = noise3(world_position * 12.0);
	float strata = sin(world_position.y * 9.0 + noise3(world_position * 0.65) * 2.0) * 0.025;
	float wall = 1.0 - abs(world_normal.y);
	ALBEDO = mix(vec3(0.30, 0.205, 0.12), vec3(0.47, 0.34, 0.20), macro) * (0.90 + grain * 0.18) + vec3(strata * wall);
	ROUGHNESS = 0.94;
	SPECULAR = 0.22;
}

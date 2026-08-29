struct WorksiteSoilMaterial {
	vec3 albedo;
	float roughness;
	float specular;
};

float worksite_soil_hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float worksite_soil_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = worksite_soil_hash(cell);
	float b = worksite_soil_hash(cell + vec2(1.0, 0.0));
	float c = worksite_soil_hash(cell + vec2(0.0, 1.0));
	float d = worksite_soil_hash(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

WorksiteSoilMaterial worksite_soil_material(
	vec3 world_position,
	vec3 world_normal,
	vec3 camera_position
) {
	vec2 xz = world_position.xz;
	float macro = worksite_soil_noise(xz * 0.13) * 0.65
		+ worksite_soil_noise(xz * 0.72) * 0.35;
	float disturbed = smoothstep(0.012, 0.22, abs(world_position.y));
	float slope = clamp(1.0 - world_normal.y, 0.0, 1.0);
	float damp_low = 1.0 - smoothstep(0.0, 7.5, distance(xz, vec2(7.0, 7.0)));
	float track_lane = 1.0 - smoothstep(0.36, 1.15, abs(abs(xz.x) - 1.15));
	vec3 compacted = vec3(0.31, 0.245, 0.185);
	vec3 loose = vec3(0.49, 0.345, 0.225);
	vec3 damp = vec3(0.205, 0.19, 0.16);
	vec3 soil = mix(compacted, loose, max(disturbed, slope * 0.42));
	soil = mix(soil, compacted * 0.88, track_lane * (1.0 - disturbed) * 0.42);
	soil = mix(soil, damp, damp_low * 0.62);
	float view_distance = distance(camera_position, world_position);
	float breakup = mix(
		0.88 + macro * 0.24,
		0.94 + macro * 0.12,
		smoothstep(14.0, 42.0, view_distance)
	);
	WorksiteSoilMaterial result;
	result.albedo = soil * breakup;
	result.roughness = mix(0.98, 0.82, damp_low * 0.45);
	result.specular = mix(0.18, 0.34, damp_low);
	return result;
}

// Terrain3D clipmap/height/normal seam derived from Terrain3D 1.0.2's
// extras/shaders/minimum.gdshader. Project-owned PBR lives in the shared include.
// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

shader_type spatial;
render_mode blend_mix,depth_draw_opaque,cull_back,diffuse_burley,specular_schlick_ggx,skip_vertex_transform;

#include "res://assets/terrain/shaders/worksite_soil_common.gdshaderinc"

#define SKIP_PASS 0
#define VERTEX_PASS 1
#define FRAGMENT_PASS 2

#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	#define fma(a, b, c) ((a) * (b) + (c))
	#define dFdxCoarse(a) dFdx(a)
	#define dFdyCoarse(a) dFdy(a)
#endif

uniform vec3 _camera_pos = vec3(0.f);
uniform float _mesh_size = 48.f;
uniform uint _background_mode = 1u;
uniform uint _mouse_layer = 0x80000000u;
uniform float _vertex_spacing = 1.0;
uniform float _vertex_density = 1.0;
uniform float _region_size = 1024.0;
uniform float _region_texel_size = 0.0009765625;
uniform int _region_map_size = 32;
uniform int _region_map[1024];
uniform highp sampler2DArray _height_maps : repeat_disable;
uniform highp sampler2DArray _control_maps : repeat_disable;

uniform bool flat_terrain_normals = false;

varying float v_vertex_xz_dist;
varying vec3 v_vertex;

ivec3 get_index_coord(const vec2 uv, const int search) {
	vec2 r_uv = round(uv);
	vec2 o_uv = mod(r_uv, _region_size);
	ivec2 pos;
	int bounds, layer_index = -1;
	for (int i = -1; i < clamp(search, SKIP_PASS, FRAGMENT_PASS); i++) {
		if ((layer_index == -1 && _background_mode == 0u) || i < 0) {
			r_uv -= i == -1 ? vec2(0.0) : vec2(
				float(o_uv.x <= o_uv.y),
				float(o_uv.y <= o_uv.x)
			);
			pos = ivec2(floor(r_uv * _region_texel_size)) + (_region_map_size / 2);
			bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
			layer_index = (_region_map[pos.y * _region_map_size + pos.x] * bounds - 1);
		}
	}
	return ivec3(ivec2(mod(r_uv, _region_size)), layer_index);
}

void vertex() {
	v_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_vertex_xz_dist = length(v_vertex.xz - _camera_pos.xz);

	float scale = MODEL_MATRIX[0][0];
	float vertex_lerp = smoothstep(
		0.55,
		0.95,
		(v_vertex_xz_dist / scale - _mesh_size - 4.0) / (_mesh_size - 2.0)
	);
	vec2 v_fract = fract(VERTEX.xz * 0.5) * 2.0;
	vec2 shift = (scale < _vertex_spacing + 1e-6)
		? mix(
			v_fract,
			vec2(v_fract.x, -v_fract.y),
			round(
				fract(round(mod(v_vertex.z * _vertex_density, 4.0))
				* round(mod(v_vertex.x * _vertex_density, 4.0)) * 0.25)
			)
		)
		: v_fract * round((fract(v_vertex.xz * 0.25 / scale) - 0.5) * 4.0);
	vec2 start_pos = v_vertex.xz * _vertex_density;
	vec2 end_pos = (v_vertex.xz - shift * scale) * _vertex_density;
	v_vertex.xz -= shift * scale * vertex_lerp;

	UV = v_vertex.xz * _vertex_density;
	UV2 = fma(UV, vec2(_region_texel_size), vec2(0.5 * _region_texel_size));

	ivec3 v_region = get_index_coord(start_pos, VERTEX_PASS);
	uint control = floatBitsToUint(texelFetch(_control_maps, v_region, 0)).r;
	bool hole = bool(control >> 2u & 0x1u);
	if (!(CAMERA_VISIBLE_LAYERS == _mouse_layer)
			&& (hole || (_background_mode == 0u && v_region.z < 0))) {
		v_vertex.x = 0. / 0.;
	} else {
		ivec3 uv_a = get_index_coord(start_pos, VERTEX_PASS);
		ivec3 uv_b = get_index_coord(end_pos, VERTEX_PASS);
		float h = mix(
			texelFetch(_height_maps, uv_a, 0).r,
			texelFetch(_height_maps, uv_b, 0).r,
			vertex_lerp
		);
		v_vertex.y = h;
	}

	VERTEX = (VIEW_MATRIX * vec4(v_vertex, 1.0)).xyz;
	NORMAL = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	BINORMAL = normalize((MODELVIEW_MATRIX * vec4(BINORMAL, 0.0)).xyz);
	TANGENT = normalize((MODELVIEW_MATRIX * vec4(TANGENT, 0.0)).xyz);
}

void fragment() {
	vec2 uv = UV;
	const vec3 offsets = vec3(0, 1, 2);
	vec2 index_id = floor(uv);
	vec2 weight = fract(uv);
	vec2 invert = 1.0 - weight;
	vec4 weights = vec4(
		invert.x * weight.y,
		weight.x * weight.y,
		weight.x * invert.y,
		invert.x * invert.y
	);

	vec3 base_ddx = dFdxCoarse(v_vertex);
	vec3 base_ddy = dFdyCoarse(v_vertex);
	float region_mip = log2(
		max(length(base_ddx.xz), length(base_ddy.xz)) * _vertex_density
	);
	bool bilerp = region_mip < 0.0;

	ivec3 index[4];
	index[0] = get_index_coord(index_id + offsets.xy, FRAGMENT_PASS);
	index[1] = get_index_coord(index_id + offsets.yy, FRAGMENT_PASS);
	index[2] = get_index_coord(index_id + offsets.yx, FRAGMENT_PASS);
	index[3] = get_index_coord(index_id + offsets.xx, FRAGMENT_PASS);

	vec3 index_normal[4];
	float h[4];
	float u = 0.0;
	float v = 0.0;
	h[3] = texelFetch(_height_maps, index[3], 0).r;
	h[2] = texelFetch(_height_maps, index[2], 0).r;
	h[0] = texelFetch(_height_maps, index[0], 0).r;
	index_normal[3] = normalize(vec3(
		h[3] - h[2] + u,
		_vertex_spacing,
		h[3] - h[0] + v
	));
	vec3 w_normal = index_normal[3];

	if (bilerp) {
		h[1] = texelFetch(_height_maps, index[1], 0).r;
		float h_4 = texelFetch(
			_height_maps,
			get_index_coord(index_id + offsets.yz, FRAGMENT_PASS),
			0
		).r;
		float h_5 = texelFetch(
			_height_maps,
			get_index_coord(index_id + offsets.zy, FRAGMENT_PASS),
			0
		).r;
		float h_6 = texelFetch(
			_height_maps,
			get_index_coord(index_id + offsets.zx, FRAGMENT_PASS),
			0
		).r;
		float h_7 = texelFetch(
			_height_maps,
			get_index_coord(index_id + offsets.xz, FRAGMENT_PASS),
			0
		).r;
		index_normal[0] = normalize(vec3(
			h[0] - h[1] + u,
			_vertex_spacing,
			h[0] - h_7 + v
		));
		index_normal[1] = normalize(vec3(
			h[1] - h_5 + u,
			_vertex_spacing,
			h[1] - h_4 + v
		));
		index_normal[2] = normalize(vec3(
			h[2] - h_6 + u,
			_vertex_spacing,
			h[2] - h[1] + v
		));
		w_normal = index_normal[0] * weights[0]
			+ index_normal[1] * weights[1]
			+ index_normal[2] * weights[2]
			+ index_normal[3] * weights[3];
	}

	vec3 w_tangent = normalize(cross(w_normal, vec3(0.0, 0.0, 1.0)));
	vec3 w_binormal = normalize(cross(w_normal, w_tangent));
	NORMAL = mat3(VIEW_MATRIX) * w_normal;
	TANGENT = mat3(VIEW_MATRIX) * w_tangent;
	BINORMAL = mat3(VIEW_MATRIX) * w_binormal;
	if (flat_terrain_normals) {
		NORMAL = normalize(cross(dFdyCoarse(VERTEX), dFdxCoarse(VERTEX)));
		TANGENT = normalize(cross(NORMAL, VIEW_MATRIX[2].xyz));
		BINORMAL = normalize(cross(NORMAL, TANGENT));
	}

	WorksiteSoilMaterial soil = worksite_soil_material(
		v_vertex,
		normalize(w_normal),
		_camera_pos
	);
	ALBEDO = soil.albedo;
	ROUGHNESS = soil.roughness;
	METALLIC = 0.0;
	SPECULAR = soil.specular;
}

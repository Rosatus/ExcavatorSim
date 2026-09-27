extends SceneTree

# Cut sidewalk tiles + yellow curb strip out of the merged spline mesh.
# Removes surface-0 triangles in the cut rect, clipping boundary triangles
# (with attribute interpolation) so the west edge lands flush with
# gardenPlanter_B6's left face.
# Run:
#   godot --headless --path godot/worldbuilding/urban \
#     --script res://tools/trim_spline_tiles.gd
#
# Tile x-seams in this stretch:
#   15.09 | 18.10 | 21.07 | 23.97 | 26.72 | 28.75 | 32.08 | 35.41 | 39.47
# Section profile (z): curb face 27.59 / yellow curb top 27.59-27.86 /
#   riser 27.86 / flat tiles 27.86-29.59 / upper strip 30.6+ (kept).
# Flush cut x=14.82 = gardenPlanter_B6 west face (mid-tile inside
#   [12.86,15.09]); east end stays on seam 39.47 (hedge107 tile kept).

const GLB_PATH := "res://maps/urban/sidewalk_Straight_Splines_0.glb"
const CUT_X0 := 14.82
const CUT_X1 := 39.48
const CUT_Z0 := 27.45
const CUT_Z1 := 29.65
const OUT_PATH := "res://maps/urban/sidewalk_Straight_Splines_0_trimmed.res"

# Clip a triangle (3 vertex indices) against half-space x<=limit
# (keep_below) or x>=limit. Returns polygon of handles: int index or
# [a:int, b:int, t:float] for an interpolated edge point.
static func clip_x(tri: Array, verts: PackedVector3Array, limit: float,
		keep_below: bool) -> Array:
	var out: Array = []
	var n: int = tri.size()
	for i in n:
		var ai: int = tri[i]
		var bi: int = tri[(i + 1) % n]
		var ax: float = verts[ai].x
		var bx: float = verts[bi].x
		var ina: bool = ax <= limit if keep_below else ax >= limit
		var inb: bool = bx <= limit if keep_below else bx >= limit
		if ina:
			out.append(ai)
		if ina != inb:
			out.append([ai, bi, (limit - ax) / (bx - ax)])
	return out

static func in_cut_band(v: Vector3) -> bool:
	return v.z >= CUT_Z0 and v.z <= CUT_Z1

# Materialize a handle into a vertex index, appending interpolated
# attributes to every present array. stride: floats-per-vertex for
# packed scalar arrays (tangent/weights=4, bones=4 handled by type).
static func materialize(arrays: Array, h, cache: Dictionary, next_idx: Array) -> int:
	if h is int:
		return h
	var key: String = str(h)
	if cache.has(key):
		return cache[key]
	var ni: int = next_idx[0]
	next_idx[0] += 1
	var is_lerp: bool = h is Array
	for ai in Mesh.ARRAY_MAX:
		var data = arrays[ai]
		if data == null or ai == Mesh.ARRAY_INDEX:
			continue
		var a: int = h if not is_lerp else h[0]
		var b: int = a if not is_lerp else h[1]
		var t: float = 0.0 if not is_lerp else h[2]
		match ai:
			Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL:
				data.append(data[a].lerp(data[b], t))
			Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2:
				data.append(data[a].lerp(data[b], t))
			Mesh.ARRAY_COLOR:
				data.append(data[a].lerp(data[b], t))
			Mesh.ARRAY_TANGENT, Mesh.ARRAY_WEIGHTS:
				for k in 4:
					data.append(lerpf(data[a * 4 + k], data[b * 4 + k], t))
			Mesh.ARRAY_BONES:
				for k in 4:
					data.append(data[a * 4 + k])
			_:
				# CUSTOM0-3 or anything else: copy endpoint a.
				data.append(data[a])
	cache[key] = ni
	return ni

func _init() -> void:
	var glb: PackedScene = load(GLB_PATH)
	var root := glb.instantiate()
	var mi: MeshInstance3D = root.find_child("Mesh", true, false)
	var mesh: ArrayMesh = mi.mesh
	var out_mesh := ArrayMesh.new()
	var kept := 0
	var removed := 0
	var clipped := 0
	for surf in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surf)
		if surf == 0:
			arrays = arrays.duplicate(true)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idxs: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var new_idx := PackedInt32Array()
			var cache := {}
			var next_idx := [verts.size()]
			for t in range(0, idxs.size(), 3):
				var tri := [idxs[t], idxs[t + 1], idxs[t + 2]]
				var in_band := true
				for vi in tri:
					if not in_cut_band(verts[vi]):
						in_band = false
				if not in_band:
					new_idx.append_array(tri)
					kept += 1
					continue
				var parts: Array = []
				for poly in [clip_x(tri, verts, CUT_X0, true),
						clip_x(tri, verts, CUT_X1, false)]:
					for i in range(1, poly.size() - 1):
						parts.append([poly[0], poly[i], poly[i + 1]])
				if parts.is_empty():
					removed += 1
					continue
				if parts.size() != 1 or parts[0] != tri:
					clipped += 1
				for p in parts:
					for h in p:
						new_idx.append(materialize(arrays, h, cache, next_idx))
				kept += 1
			arrays[Mesh.ARRAY_INDEX] = new_idx
		out_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out_mesh.surface_set_name(surf, mesh.surface_get_name(surf))
		var mat: Material = mesh.surface_get_material(surf)
		if mat != null:
			out_mesh.surface_set_material(surf, mat)
	print("tris kept:", kept, " removed:", removed, " clipped:", clipped)
	var err := ResourceSaver.save(out_mesh, OUT_PATH)
	print("save:", error_string(err), " -> ", OUT_PATH)
	quit()

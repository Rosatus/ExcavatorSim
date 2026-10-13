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
#   riser 27.86 / flat tiles 27.86-29.59 / upper strip 30.6+.
# West end starts just inside seam 23.97 (tile 21.07-23.97 next to B6
#   kept); the east extension clears through x87 and z33. Buildings stay.

const GLB_PATH := "res://maps/urban/sidewalk_Straight_Splines_0.glb"
const CUT_X0 := 23.96
const CUT_X1 := 87.0
const CUT_Z0 := 27.45
const CUT_Z1 := 33.0
const OUT_PATH := "res://maps/urban/sidewalk_Straight_Splines_0_trimmed.res"

# Clip a polygon against one half-space, interpolating seam attributes.
static func clip_axis(tri: Array, arrays: Array, axis: int, limit: float,
		keep_below: bool, cache: Dictionary, next_idx: Array) -> Array:
	var out: Array = []
	var n: int = tri.size()
	for i in n:
		var ai: int = tri[i]
		var bi: int = tri[(i + 1) % n]
		var ax: float = arrays[Mesh.ARRAY_VERTEX][ai][axis]
		var bx: float = arrays[Mesh.ARRAY_VERTEX][bi][axis]
		var ina: bool = ax <= limit if keep_below else ax >= limit
		var inb: bool = bx <= limit if keep_below else bx >= limit
		if ina:
			out.append(ai)
		if ina != inb:
			out.append(materialize(arrays, [ai, bi, (limit - ax) / (bx - ax)], cache, next_idx))
	return out

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
			var idxs: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var new_idx := PackedInt32Array()
			var cache := {}
			var next_idx := [arrays[Mesh.ARRAY_VERTEX].size()]
			for t in range(0, idxs.size(), 3):
				var tri := [idxs[t], idxs[t + 1], idxs[t + 2]]
				var a: Vector3 = arrays[Mesh.ARRAY_VERTEX][tri[0]]
				var b: Vector3 = arrays[Mesh.ARRAY_VERTEX][tri[1]]
				var c: Vector3 = arrays[Mesh.ARRAY_VERTEX][tri[2]]
				if maxf(a.x, maxf(b.x, c.x)) <= CUT_X0 or minf(a.x, minf(b.x, c.x)) >= CUT_X1 \
						or maxf(a.z, maxf(b.z, c.z)) <= CUT_Z0 or minf(a.z, minf(b.z, c.z)) >= CUT_Z1:
					new_idx.append_array(tri)
					kept += 1
					continue
				var parts: Array = []
				# Partition outside the rectangle; triangles crossing Z edges
				# must be clipped too, not retained as an entire pavement slab.
				var left := clip_axis(tri, arrays, 0, CUT_X0, true, cache, next_idx)
				var remaining := clip_axis(tri, arrays, 0, CUT_X0, false, cache, next_idx)
				var right := clip_axis(remaining, arrays, 0, CUT_X1, false, cache, next_idx)
				remaining = clip_axis(remaining, arrays, 0, CUT_X1, true, cache, next_idx)
				var south := clip_axis(remaining, arrays, 2, CUT_Z0, true, cache, next_idx)
				var north := clip_axis(remaining, arrays, 2, CUT_Z1, false, cache, next_idx)
				for poly in [left, right, south, north]:
					for i in range(1, poly.size() - 1):
						parts.append([poly[0], poly[i], poly[i + 1]])
				if parts.is_empty():
					removed += 1
					continue
				if parts.size() != 1 or parts[0] != tri:
					clipped += 1
				for p in parts:
					for h in p:
						new_idx.append(h)
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
	root.free()
	quit(0 if err == OK else 1)

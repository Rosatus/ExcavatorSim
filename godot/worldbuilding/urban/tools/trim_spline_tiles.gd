extends SceneTree

# Trim sidewalk tiles from the merged spline mesh.
# Removes surface-0 triangles whose centroid lies inside the cut rect:
#   x in [CUT_X0, CUT_X1]  (6 full tiles between gardenPlanter_B6 and
#                           Flg_hedge_Tall107)
#   z > CUT_Z             (flat paver surface; curb/gutter faces at
#                           z<=27.86 are kept)
# Writes the trimmed mesh to a new resource; the source GLB is untouched.
#
# Tile x-seams in this block (from centroid clustering):
#   18.10 | 21.07 | 23.97 | 26.72 | 28.75 | 32.08 | 35.41 | 39.47 | 43.54
# Paver strips per tile (z): curb face 27.59-27.86, flat 27.86-29.59.

const CUT_X0 := 21.06
const CUT_X1 := 39.48
const CUT_Z := 27.87
const OUT_PATH := "res://maps/urban/sidewalk_Straight_Splines_0_trimmed.res"

func _init() -> void:
	var ps: PackedScene = load("res://maps/urban/sidewalk_Straight_Splines_0.glb")
	var root := ps.instantiate()
	var mi: MeshInstance3D = root.get_node("Mesh")
	var src: ArrayMesh = mi.mesh

	var out_mesh := ArrayMesh.new()
	var total_removed := 0
	for s in range(src.get_surface_count()):
		var arrays: Array = src.surface_get_arrays(s)
		var removed := 0
		if s == 0:
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var keep := PackedInt32Array()
			for i in range(0, idx.size(), 3):
				var a: Vector3 = verts[idx[i]]
				var b: Vector3 = verts[idx[i + 1]]
				var c: Vector3 = verts[idx[i + 2]]
				var cx: float = (a.x + b.x + c.x) / 3.0
				var cz: float = (a.z + b.z + c.z) / 3.0
				if cx >= CUT_X0 and cx <= CUT_X1 and cz > CUT_Z:
					removed += 1
					continue
				keep.append_array([idx[i], idx[i + 1], idx[i + 2]])
			arrays[Mesh.ARRAY_INDEX] = keep
		out_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		total_removed += removed
		print("surface ", s, " removed=", removed)

	var err := ResourceSaver.save(out_mesh, OUT_PATH)
	print("saved ", OUT_PATH, " err=", err, " total_removed=", total_removed)
	quit()

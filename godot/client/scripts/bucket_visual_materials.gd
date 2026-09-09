extends RefCounted
## Per-instance PBR corrections; imported GLB materials remain immutable.


static func apply(asset_root: Node3D, manifest: Dictionary, model_id: String) -> void:
	if model_id != "sy135":
		return
	var mapping: Dictionary = manifest.get("frame_map", {})
	var bucket: Dictionary = mapping.get("bucket_link", {})
	for path in bucket.get("visual_nodes", []):
		var mesh_node := asset_root.get_node_or_null(NodePath(path)) as MeshInstance3D
		if mesh_node == null or mesh_node.mesh == null:
			continue
		for surface in mesh_node.mesh.get_surface_count():
			var original := mesh_node.mesh.surface_get_material(surface) as StandardMaterial3D
			if original == null:
				continue
			# SY135 exports untextured near-black paint (linear RGB 0.007143).
			# Use worn dark steel while retaining lit shading and all shadows.
			# Always duplicate the source, so reactivation cannot accumulate gain.
			var corrected := original.duplicate() as StandardMaterial3D
			corrected.albedo_color = Color(0.29, 0.28, 0.26, 1.0)
			corrected.roughness = 0.82
			mesh_node.set_surface_override_material(surface, corrected)

extends SceneTree

func _initialize() -> void:
	var ok := true
	for p in [
		"res://maps/urban/Shaders/Flag_Inst.tres",
		"res://maps/urban/Shaders/Foliage_01_Inst.tres",
		"res://maps/urban/Shaders/prp_tarp_mat.tres",
	]:
		var vs := ResourceLoader.load(p) as VisualShader
		if vs == null:
			print("FAIL load: ", p)
			ok = false
			continue
		var bad := 0
		var good := 0
		for stage in [VisualShader.TYPE_VERTEX, VisualShader.TYPE_FRAGMENT]:
			for id in vs.get_node_list(stage):
				var node := vs.get_node(stage, id)
				if node is VisualShaderNodeExpression:
					var expr: String = node.expression
					if "INV_VIEW_MATRIX * vec4( VERTEX" in expr:
						bad += 1
						print("  BAD expr in ", p, " stage=", stage, " id=", id)
					if "MODEL_MATRIX * vec4( VERTEX" in expr:
						good += 1
		print(p, " | bad=", bad, " good=", good)
		if bad > 0 or good == 0:
			ok = false
	print("SHADER_CHECK: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)

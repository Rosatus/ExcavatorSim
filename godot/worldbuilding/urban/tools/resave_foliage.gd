extends SceneTree

func _initialize() -> void:
	var names = ["flg_bush_01", "flg_bush_02", "flg_groundLeaves", "flg_plane", "flg_plane2", "flg_tree_01", "flg_tree_02", "flg_tree_03"]
	for n in names:
		var p = "res://maps/urban/Prefabs/_foliage/" + n + ".res"
		var r = ResourceLoader.load(p)
		if r == null:
			print("FAIL ", p)
			continue
		print(n, " resave err=", ResourceSaver.save(r, p))
	quit()

extends SceneTree

## Headless contract check for the urban road-surface policy:
## road props keep authored visual height but carry NO colliders, so the
## drivable surface is flat GroundPlane (~y 1.08) even across intersections.

const TARGET_PREFABS := [
	"Prefabs/Cube.tscn",
	"Prefabs/prp_manhole.tscn",
	"Prefabs/prp_sewerGrate.tscn",
	"CrssWk_4L.tscn",
	"CrssWk_1L_Pk.tscn",
]

func _visual_aabb(node: Node) -> AABB:
	var box := AABB()
	var has := false
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and n.mesh != null:
			var b: AABB = n.global_transform * n.mesh.get_aabb()
			box = b if not has else box.merge(b)
			has = true
		stack.append_array(n.get_children())
	return box if has else AABB((node as Node3D).global_position, Vector3.ZERO)


func _initialize() -> void:
	var packed := ResourceLoader.load("res://maps/urban/Urban-City.tscn") as PackedScene
	if packed == null:
		print("FAIL: scene did not load")
		quit(1)
		return
	var scene := packed.instantiate()
	get_root().add_child.call_deferred(scene)
	_run.call_deferred(scene)


func _run(root: Node) -> void:
	await physics_frame
	await physics_frame
	var world: World3D = root.get_world_3d()
	var state := world.direct_space_state

	# 1) no colliders inside any road-prop instance
	var ghost_fails := 0
	var targets := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node3D:
			for suf in TARGET_PREFABS:
				if n.scene_file_path.ends_with(suf):
					targets += 1
					var s2: Array[Node] = [n]
					while not s2.is_empty():
						var d: Node = s2.pop_back()
						if d is CollisionObject3D:
							ghost_fails += 1
							print("COLLIDER: ", n.name, " -> ", d.name)
						s2.append_array(d.get_children())
					break
		stack.append_array(n.get_children())
	print("prop instances: ", targets, " with colliders: ", ghost_fails)

	# 2) drive surface across both intersections must read ~1.08
	var flat_fails := 0
	for iname in ["Intersection1", "Intersection2"]:
		var inode := root.find_child(iname, true, false) as Node3D
		if inode == null:
			print("MISSING ", iname)
			flat_fails += 1
			continue
		var box := _visual_aabb(inode)
		var x := box.position.x + box.size.x * 0.2
		while x <= box.position.x + box.size.x * 0.8:
			var z := box.position.z + box.size.z * 0.2
			while z <= box.position.z + box.size.z * 0.8:
				var q := PhysicsRayQueryParameters3D.create(
					Vector3(x, 12.0, z), Vector3(x, -20.0, z))
				var hit := state.intersect_ray(q)
				if hit.is_empty() or absf(hit.position.y - 1.08) > 0.05:
					flat_fails += 1
					print("UNFLAT ", iname, " (", x, ",", z, ") -> ", hit.get("position", Vector3.ZERO))
				z += 2.5
			x += 2.5

	if ghost_fails == 0 and flat_fails == 0:
		print("VERIFY: PASS")
		quit(0)
	else:
		print("VERIFY: FAIL ghosts=", ghost_fails, " unflat=", flat_fails)
		quit(1)

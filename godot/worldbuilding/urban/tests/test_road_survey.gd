@tool
extends McpTestSuite

## Road-furniture contract for Urban-City.tscn.
## Road props (manholes, sewer grates, crosswalks, asphalt slabs) are
## VISUAL ONLY — authored heights are kept (raised covers are intended);
## their prefabs carry no colliders so the drivable surface stays flat.
## test_survey writes res://tests/_road_survey.json (diagnostic);
## test_props_are_collision_ghosts / test_intersection_drive_surface
## are the regression contract.

const OUT_PATH := "res://tests/_road_survey.json"
const TARGET_PREFABS := [
	"Prefabs/Cube.tscn",
	"Prefabs/prp_manhole.tscn",
	"Prefabs/prp_sewerGrate.tscn",
	"CrssWk_4L.tscn",
	"CrssWk_1L_Pk.tscn",
]

func suite_name() -> String:
	return "road_survey"


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
	return box if has else AABB(node.global_transform.origin if node is Node3D else Vector3.ZERO, Vector3.ZERO)


func _own_collider_rids(node: Node) -> Array[RID]:
	var rids: Array[RID] = []
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is CollisionObject3D:
			rids.append(n.get_rid())
		stack.append_array(n.get_children())
	return rids


func _support_y(world: World3D, x: float, z: float, from_y: float, exclude: Array[RID]) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(
		Vector3(x, from_y, z), Vector3(x, from_y - 40.0, z))
	q.exclude = exclude
	var hit: Dictionary = world.direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return {}
	var col := hit.get("collider") as Object
	var cname := ""
	if col != null:
		var n := col as Node
		cname = n.name if n != null else str(col)
	return {
		"y": snappedf(hit.position.y, 0.001),
		"collider": cname,
	}


func test_survey() -> void:
	var root := EditorInterface.get_edited_scene_root() as Node3D
	assert_true(root != null, "no edited scene root (or root is not Node3D)")
	if root == null:
		return
	var world: World3D = root.get_world_3d()
	var report := {"targets": [], "grid": {}, "grid_anomalies": []}

	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node3D:
			var sp := n.scene_file_path
			var hit_prefab := ""
			for suf in TARGET_PREFABS:
				if sp.ends_with(suf):
					hit_prefab = suf
					break
			if hit_prefab != "":
				var box := _visual_aabb(n)
				var rids := _own_collider_rids(n)
				var sup := _support_y(world, box.get_center().x, box.get_center().z,
					box.position.y + box.size.y + 2.0, rids)
				report.targets.append({
					"name": n.name, "path": str(root.get_path_to(n)),
					"prefab": hit_prefab.get_file(),
					"pos_y": snappedf(n.global_position.y, 0.001),
					"pos_x": snappedf(n.global_position.x, 0.001),
					"pos_z": snappedf(n.global_position.z, 0.001),
					"aabb_min_y": snappedf(box.position.y, 0.001),
					"aabb_max_y": snappedf(box.position.y + box.size.y, 0.001),
					"x": snappedf(box.get_center().x, 0.01),
					"z": snappedf(box.get_center().z, 0.01),
					"support": sup,
				})
		stack.append_array(n.get_children())

	# Coarse physics grid over the drivable area to find all surface steps.
	var hist := {}
	var anomalies: Array = []
	var xr := -140.0
	while xr <= 80.0:
		var zr := -90.0
		while zr <= 95.0:
			var s := _support_y(world, xr, zr, 12.0, [])
			if not s.is_empty():
				var yv: float = s.y
				var key := str(snappedf(yv, 0.05))
				hist[key] = int(hist.get(key, 0)) + 1
				if yv > 1.115 or yv < 1.04:
					anomalies.append({"x": xr, "z": zr, "y": yv, "col": s.collider})
			zr += 2.5
		xr += 2.5
	report.grid = hist
	report.grid_anomalies = anomalies.slice(0, 400)

	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	print("survey written: ", OUT_PATH, " targets=", report.targets.size(),
		" gridcells=", hist.size(), " anomalies=", anomalies.size())
	assert_true(report.targets.size() > 0, "no targets found")


func _collect_targets(root: Node) -> Array[Node3D]:
	var out: Array[Node3D] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node3D:
			var sp := n.scene_file_path
			for suf in TARGET_PREFABS:
				if sp.ends_with(suf):
					out.append(n)
					break
		stack.append_array(n.get_children())
	return out


## A ray dropped through the centre of any road prop must reach the surface
## BELOW it — i.e. the prop itself must not be the first collider hit.
func test_props_are_collision_ghosts() -> void:
	var root := EditorInterface.get_edited_scene_root() as Node3D
	assert_true(root != null, "no edited scene root (or root is not Node3D)")
	if root == null:
		return
	var world: World3D = root.get_world_3d()
	var fails := 0
	for n: Node3D in _collect_targets(root):
		var box := _visual_aabb(n)
		var c := box.get_center()
		var hit: Dictionary = world.direct_space_state.intersect_ray(
			PhysicsRayQueryParameters3D.create(
				Vector3(c.x, box.position.y + box.size.y + 2.0, c.z),
				Vector3(c.x, box.position.y + box.size.y - 40.0, c.z)))
		if hit.is_empty():
			continue
		var col := hit.get("collider") as Node
		if col != null and (col == n or n.is_ancestor_of(col)):
			fails += 1
			push_error("%s still collides (ray hit %s at y=%.3f)" %
				[n.name, col.name, hit.position.y])
	assert_true(fails == 0, "%d road props still have colliders" % fails)


## Wheels must ride the flat GroundPlane across both intersections:
## every probe inside the slab footprint (20% margin) must report the
## drivable surface near y=1.08, regardless of the raised slab visual.
func test_intersection_drive_surface() -> void:
	var root := EditorInterface.get_edited_scene_root() as Node3D
	assert_true(root != null, "no edited scene root (or root is not Node3D)")
	if root == null:
		return
	var world: World3D = root.get_world_3d()
	for iname in [&"Intersection1", &"Intersection2"]:
		var n := root.find_child(String(iname), true, false) as Node3D
		assert_true(n != null, "%s not found" % iname)
		if n == null:
			continue
		var box := _visual_aabb(n)
		var bad := 0
		var samples := 0
		var x := box.position.x + box.size.x * 0.2
		while x <= box.position.x + box.size.x * 0.8:
			var z := box.position.z + box.size.z * 0.2
			while z <= box.position.z + box.size.z * 0.8:
				var s := _support_y(world, x, z, 12.0, [])
				samples += 1
				if s.is_empty() or s.y < 1.05 or s.y > 1.12:
					bad += 1
					push_error("%s drive probe (%.1f, %.1f): %s" %
						[iname, x, z, s])
				z += 2.5
			x += 2.5
		assert_true(bad == 0,
			"%s: %d/%d probes off the flat road surface" % [iname, bad, samples])

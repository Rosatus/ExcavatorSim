@tool
extends McpTestSuite

## Road-furniture height survey for Urban-City.tscn.
## Measures every road-surface prop (manholes, sewer grates, crosswalks,
## asphalt slabs) against the physics surface actually supporting it,
## plus a coarse raycast grid over the road area to map all collision
## height anomalies. Writes res://tests/_road_survey.json.

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


const EPS := {"CrssWk_4L.tscn": 0.003, "CrssWk_1L_Pk.tscn": 0.003,
	"Cube.tscn": 0.005, "prp_sewerGrate.tscn": 0.004, "prp_manhole.tscn": 0.004}

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


## One undoable action: drop every road-furniture node whose visual top sits
## more than ~3 cm proud of the collidable support below it (and less than
## 25 cm — larger gaps are curb/sidewalk-zone props at intentional height).
## Idempotent: fixed nodes end up at gap <= EPS and are skipped on rerun.
func test_apply_fix() -> void:
	var root := EditorInterface.get_edited_scene_root() as Node3D
	assert_true(root != null, "no edited scene root (or root is not Node3D)")
	if root == null:
		return
	var world: World3D = root.get_world_3d()
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Align road props to road surface", 0, root)
	var moved := 0
	for n: Node3D in _collect_targets(root):
		var box := _visual_aabb(n)
		var top_y := box.position.y + box.size.y
		var sup := _support_y(world, box.get_center().x, box.get_center().z,
			top_y + 2.0, _own_collider_rids(n))
		if sup.is_empty():
			continue
		var gap := top_y - float(sup.y)
		if gap < 0.03 or gap > 0.25:
			continue
		var eps: float = EPS.get(n.scene_file_path.get_file(), 0.004)
		var new_y := float(sup.y) + eps - (top_y - n.global_position.y)
		var old_pos := n.position
		var new_pos := Vector3(old_pos.x, new_y, old_pos.z)
		ur.add_do_property(n, "position", new_pos)
		ur.add_undo_property(n, "position", old_pos)
		moved += 1
	if moved > 0:
		ur.commit_action()
	print("road fix moved ", moved, " nodes")
	assert_true(moved > 0, "no nodes needed fixing")

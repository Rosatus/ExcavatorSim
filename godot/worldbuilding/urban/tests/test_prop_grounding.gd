@tool
extends McpTestSuite

## Prop grounding survey + fix plan.
## For every instanced Node3D in the scene, compare its visual AABB bottom
## against a downward raycast to the supporting surface.
##   gap <= MAX_LOWER_GAP  -> "lower" (drop so the bottom rests on support)
##   gap >  MAX_LOWER_GAP  -> "wall"   (bracket/wall-mounted, intentional)
## Nodes inside a gardenPlanter footprint -> "in_planter" (manual review).
## Building/door modules are skipped: their gaps are covered by
## BuildingPlinths (see test_building_plinths.gd).

const OUT_PATH := "res://tests/_prop_grounding.json"
const MAX_LOWER_GAP := 0.60
const EMBED_FOLIAGE := 0.03
const EMBED_HARD := 0.005

const SKIP_PREFABS := [
	"Prefabs/Cube.tscn", "Prefabs/Cube_1.tscn",
	"Prefabs/prp_manhole.tscn", "Prefabs/prp_sewerGrate.tscn",
	"CrssWk_4L.tscn", "CrssWk_1L_Pk.tscn",
]
const WALL_MOUNTED := ["Awning_mdl", "StoreSign_", "prp_flag", "prp_vent_",
	"prp_powerlines"]
# Whole modular-building kit (F1 plinths cover ground floor; upper floors
# stack by design). Floor_* plates, Door*/door_* leaf modules too.
const BUILDING_KIT := [
	"/B1_", "/B2_", "/B3_", "/B4_", "/B5_", "/B6_", "/B7_", "/B9_",
	"/Building_", "/Floor_", "/Door", "/door_", "Urban-City.tscn",
]

func suite_name() -> String:
	return "prop_grounding"


func _visual_aabb(n: Node) -> AABB:
	var box := AABB()
	var has := false
	var stack: Array[Node] = [n]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		if c is MeshInstance3D and c.mesh != null:
			var b: AABB = c.global_transform * c.mesh.get_aabb()
			box = b if not has else box.merge(b)
			has = true
		stack.append_array(c.get_children())
	return box


func _own_rids(n: Node) -> Array[RID]:
	var rids: Array[RID] = []
	var stack: Array[Node] = [n]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		if c is CollisionObject3D:
			rids.append(c.get_rid())
		stack.append_array(c.get_children())
	return rids


func _has_any(path: String, pats: Array) -> bool:
	for p in pats:
		if path.contains(p):
			return true
	return false


func _inside_planter(o: Vector3, bottom: float, planters: Array,
		entry: Dictionary) -> bool:
	for pl in planters:
		var pb: AABB = pl[1]
		if o.x > pb.position.x and o.x < pb.position.x + pb.size.x \
				and o.z > pb.position.z and o.z < pb.position.z + pb.size.z \
				and bottom > pb.position.y + 0.05:
			entry["planter"] = pl[0]
			return true
	return false


func test_build_fix_plan() -> void:
	var root := EditorInterface.get_edited_scene_root() as Node3D
	assert_true(root != null, "no scene root")
	if root == null:
		return
	var world: World3D = root.get_world_3d()

	var inst: Array[Node3D] = []
	var planters: Array = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node3D and n.scene_file_path != "":
			inst.append(n)
			if n.scene_file_path.contains("gardenPlanter"):
				var pb := _visual_aabb(n)
				if pb.size.x > 0.01:
					planters.append([n.name, pb])
		stack.append_array(n.get_children())

	var report := []
	var counts := {"lower": 0, "ok": 0, "wall": 0, "in_planter": 0,
		"skip": 0, "no_hit": 0}
	for n in inst:
		var sp: String = n.scene_file_path
		if _has_any(sp, SKIP_PREFABS) or _has_any(sp, WALL_MOUNTED) \
				or _has_any(sp, BUILDING_KIT):
			counts.skip += 1
			continue
		var box := _visual_aabb(n)
		if box.size.y < 0.01:
			counts.skip += 1
			continue
		var q := PhysicsRayQueryParameters3D.create(
			Vector3(box.get_center().x, box.position.y + box.size.y + 0.5,
				box.get_center().z),
			Vector3(box.get_center().x, box.position.y - 5.0,
				box.get_center().z))
		q.exclude = _own_rids(n)
		var hit: Dictionary = world.direct_space_state.intersect_ray(q)
		if hit.is_empty():
			counts.no_hit += 1
			report.append({"name": n.name, "prefab": sp.get_file(),
				"action": "no_hit"})
			continue
		var gap: float = box.position.y - hit.position.y
		var o: Vector3 = n.global_position
		var owner := ""
		var col: Node = hit.get("collider")
		if col != null:
			var a := col
			while a != null and a != root:
				if a.scene_file_path != "":
					owner = a.name
					break
				a = a.get_parent()
		var entry := {"name": n.name, "prefab": sp.get_file(),
			"o": [o.x, o.y, o.z], "gap": snappedf(gap, 0.001),
			"support": snappedf(hit.position.y, 0.001),
			"support_owner": owner,
			"support_col": str(col.name if col != null else "?")}
		if gap <= 0.02:
			counts.ok += 1
			continue
		if gap > MAX_LOWER_GAP:
			entry.action = "wall"
			counts.wall += 1
		elif _inside_planter(o, box.position.y, planters, entry):
			entry.action = "in_planter"
			counts.in_planter += 1
		else:
			var embed := EMBED_FOLIAGE if sp.contains("flg_") or sp.contains("Flg_") \
				else EMBED_HARD
			entry.action = "lower"
			entry["dy"] = snappedf(-(gap + embed), 0.0001)
			counts.lower += 1
		report.append(entry)

	var planter_out := []
	for pl in planters:
		var pb: AABB = pl[1]
		planter_out.append({"name": pl[0],
			"min": [pb.position.x, pb.position.y, pb.position.z],
			"max": [pb.position.x + pb.size.x, pb.position.y + pb.size.y,
				pb.position.z + pb.size.z]})

	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"counts": counts, "report": report,
		"planters": planter_out}, "  "))
	f.close()
	print("counts: ", counts)
	# Regression contract: no ground-standing prop may float.
	# (Wall/roof-mounted items above MAX_LOWER_GAP and the building kit
	# are excluded by design; see report JSON for per-node detail.)
	assert_true(counts.lower == 0, "floating props remain: %s" % [
		JSON.stringify(report.filter(
			func(r): return r.get("action") == "lower")).left(4000)])

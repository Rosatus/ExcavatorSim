@tool
extends McpTestSuite

## Building-plinth contract for Urban-City.tscn.
## UE-migrated ground-floor modules (B*_F1_*, door_*, Door*_mdl,
## Building_*_*) have their mesh bottom at the node origin, which sits
## ~3-30cm above the drivable surface (GroundPlane top y=1.08, sidewalk
## slabs ~1.297). The BuildingPlinths MultiMesh drops a concrete skirt
## under every ground-floor module: footprint + 5cm margin, top embedded
## 2.5cm into the module, bottom 80cm below the module origin. A sibling
## StaticBody3D "BuildingPlinthsCollision" mirrors every plinth instance
## with a matching box collider so tracked machines cannot clip through
## building foundations.

const GROUND_FLOOR_MAX_Y := 2.0
const TOP_EMBED := 0.025
const BOT_DEPTH := 0.80
const MARGIN := 0.05

## prefab basename -> local mesh AABB in XZ (measured headless)
const FOOTPRINT := {
	"B1_F1_A": [-4.000,0.000,-0.702,0.750], "B1_F1_B": [-4.000,0.000,-0.702,0.750],
	"B1_F1_C": [-8.001,0.000,-0.702,2.702], "B1_F1_D": [-1.000,0.702,-0.702,1.000],
	"B2_F1_A": [-6.000,0.601,-0.601,6.000], "B2_F1_B": [-5.500,0.000,-0.601,1.157],
	"B2_F1_C": [-5.500,0.000,-0.601,1.157], "B2_F1_D": [-5.500,0.000,-0.601,1.157],
	"B3_F1_A": [-0.186,0.750,-0.000,6.000], "B3_F1_B": [-0.186,3.545,-0.186,3.500],
	"B3_F1_C": [-0.186,0.750,-0.000,6.000], "B3_F1_D": [-0.186,0.845,-0.000,3.000],
	"B4_F1_A": [-4.000,0.000,-0.605,0.675], "B4_F1_B": [-4.500,0.612,-0.605,4.500],
	"B4_F1_C": [-4.000,0.000,-0.605,0.675], "B4_F1_D": [-4.000,0.000,-0.605,0.675],
	"B5_F1_A": [-2.000,0.227,-0.227,2.000], "B5_F1_B": [-6.002,0.000,-0.227,1.250],
	"B5_F1_C": [-6.005,0.000,-0.227,1.250], "B5_F1_D": [-6.004,0.000,-0.227,1.250],
	"B5_F1_E": [-6.005,0.000,-0.227,1.250],
	"B6_F1_A": [-3.500,0.252,-0.252,3.500], "B6_F1_B": [-3.000,0.000,-0.252,0.500],
	"B6_F1_C": [-3.000,0.000,-0.252,1.000],
	"B7_F1_A": [-4.501,0.536,-0.536,4.501], "B7_F1_B": [-4.003,0.000,-0.536,0.500],
	"B7_F1_C": [-4.000,0.000,-0.536,0.500], "B7_F1_D": [-4.000,0.000,-0.536,0.500],
	"B9_F1_A": [-4.000,0.000,-0.000,4.000], "B9_F1_B": [-4.000,0.000,-0.000,0.250],
	"B9_F1_C": [-4.000,0.000,-0.000,0.250], "B9_F1_D": [-4.000,0.000,-0.095,1.000],
	"Building_2_01": [-43.801,0.801,-0.801,43.801], "Building_2_02": [-44.301,0.301,-0.241,37.361],
	"Building_6_01": [-25.337,0.337,-0.337,21.337], "Building_7_01": [-24.808,1.808,-1.808,41.308],
	"Building_7_02": [-24.808,1.808,-1.808,41.308], "Building_9_01": [-25.167,0.294,-0.294,25.167],
	"Building_9_02": [-20.167,0.294,-5.167,40.167],
	"Door1_mdl": [-0.000,1.525,-0.037,0.189], "Door2_mdl": [-0.001,1.521,-0.037,0.128],
	"door_A": [0.000,2.159,-0.000,0.050], "door_B": [0.000,1.075,-0.000,0.050],
	"door_C": [0.000,1.200,-0.000,0.050],
}

func suite_name() -> String:
	return "building_plinths"


func _expected_plinth_transform(node: Node3D, fp: Array) -> Transform3D:
	var sx: float = (fp[1] - fp[0]) + 2.0 * MARGIN
	var sz: float = (fp[3] - fp[2]) + 2.0 * MARGIN
	var sy: float = TOP_EMBED + BOT_DEPTH
	var c := Vector3((fp[0] + fp[1]) * 0.5, (TOP_EMBED - BOT_DEPTH) * 0.5,
		(fp[2] + fp[3]) * 0.5)
	var local := Transform3D(Basis.from_scale(Vector3(sx, sy, sz)), c)
	return node.global_transform * local


func _ground_floor_modules(root: Node) -> Array[Node3D]:
	var out: Array[Node3D] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node3D and n.global_position.y < GROUND_FLOOR_MAX_Y:
			var base := n.scene_file_path.get_file().get_basename()
			if FOOTPRINT.has(base):
				out.append(n)
		stack.append_array(n.get_children())
	return out


func test_every_ground_floor_module_has_plinth() -> void:
	var root := EditorInterface.get_edited_scene_root()
	assert_true(root != null, "no edited scene root")
	var pl := root.get_node_or_null("BuildingPlinths") as MultiMeshInstance3D
	assert_true(pl != null, "BuildingPlinths node missing")
	if pl == null:
		return
	var mm := pl.multimesh
	var modules := _ground_floor_modules(root)
	print("ground-floor modules=", modules.size(), " plinths=", mm.instance_count)
	assert_true(mm.instance_count == modules.size(), "plinth count must match ground-floor module count")

	# verify each module's expected plinth transform exists in the array
	var buf := mm.buffer
	var missing := 0
	for n in modules:
		var want := _expected_plinth_transform(n, FOOTPRINT[n.scene_file_path.get_file().get_basename()])
		var found := false
		for i in mm.instance_count:
			var got := _read_instance(buf, i)
			if got.origin.distance_to(want.origin) < 0.01 \
					and abs(got.basis.x.length() - want.basis.x.length()) < 0.01:
				found = true
				break
		if not found:
			missing += 1
			push_warning("missing plinth for %s pos=%s want_origin=%s" %
				[n.name, n.global_position, want.origin])
	assert_true(missing == 0, "%d modules without matching plinth" % missing)


## MultiMesh.buffer stores 12 floats per instance:
## (basis row0, origin.x), (basis row1, origin.y), (basis row2, origin.z).
func _read_instance(buf: PackedFloat32Array, i: int) -> Transform3D:
	var b := i * 12
	return Transform3D(Basis(
		Vector3(buf[b], buf[b + 4], buf[b + 8]),
		Vector3(buf[b + 1], buf[b + 5], buf[b + 9]),
		Vector3(buf[b + 2], buf[b + 6], buf[b + 10])),
		Vector3(buf[b + 3], buf[b + 7], buf[b + 11]))


func test_plinth_colliders_match_multimesh() -> void:
	var root := EditorInterface.get_edited_scene_root()
	var pl := root.get_node_or_null("BuildingPlinths") as MultiMeshInstance3D
	assert_true(pl != null, "BuildingPlinths node missing")
	var body := root.get_node_or_null("BuildingPlinthsCollision") as StaticBody3D
	assert_true(body != null, "BuildingPlinthsCollision body missing")
	if pl == null or body == null:
		return
	var shapes := body.find_children("*", "CollisionShape3D", true, false)
	assert_true(shapes.size() == pl.multimesh.instance_count,
		"collider count %d must match plinth count %d" % [shapes.size(), pl.multimesh.instance_count])
	var buf := pl.multimesh.buffer
	var unmatched := 0
	for i in pl.multimesh.instance_count:
		var inst := _read_instance(buf, i)
		# the plinth covers a unit box under its basis; compare world AABBs so
		# yaw-rotated instances (axes permuted in the shared BoxShape) still match
		var want_aabb := inst * AABB(-Vector3.ONE * 0.5, Vector3.ONE)
		var found := false
		for s in shapes:
			var cs := s as CollisionShape3D
			var box := cs.shape as BoxShape3D
			if box == null:
				continue
			var got_aabb := cs.global_transform * AABB(-box.size * 0.5, box.size)
			if got_aabb.position.distance_to(want_aabb.position) < 0.01 \
					and got_aabb.size.distance_to(want_aabb.size) < 0.01:
				found = true
				break
		if not found:
			unmatched += 1
			push_warning("plinth %d has no matching collider aabb=%s" % [i, want_aabb])
	assert_true(unmatched == 0, "%d plinths without matching collider" % unmatched)

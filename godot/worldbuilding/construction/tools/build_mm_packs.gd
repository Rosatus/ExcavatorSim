extends SceneTree

## MultiMesh pack generator for the construction map.
##
## Batches repeated prefab instances into per-type, per-cell MultiMesh packs
## under maps/construction/MM_Packs/, matching the upstream pack format:
##   - MM_Packs/Meshes/<type>_mesh.res   (ArrayMesh, surface materials baked)
##   - MM_Packs/Shapes/<type>_shape.tres (shared Shape3D)
##   - MM_Packs/<type>__c<cx>_<cy>_<cz>.tscn
##     root Node3D + MM (MultiMeshInstance3D, mm_init.gd) + SBi/CSi per instance
##
## Rendering becomes one draw call per pack; collision stays per instance.
## Skinned meshes (Skeleton3D) are excluded: MultiMesh cannot skin per instance.
##
## Usage (headless, from the workbench project):
##   godot --headless --path . --script res://tools/build_mm_packs.gd -- --analyze
##   godot --headless --path . --script res://tools/build_mm_packs.gd -- --apply

const SCENE_PATH := "res://maps/construction/Construction-Site.tscn"
const PACKS_DIR := "res://maps/construction/MM_Packs"
const MESHES_DIR := "res://maps/construction/MM_Packs/Meshes"
const SHAPES_DIR := "res://maps/construction/MM_Packs/Shapes"
const MM_INIT_SCRIPT := "res://maps/construction/MM_Packs/mm_init.gd"
const PREFAB_PREFIX := "res://maps/construction/Prefabs/"
const CELL_SIZE := 64.0
## Instances of types already covered by upstream packs stay untouched in v1:
## merging into existing pack files would mean editing upstream-authored data.
const SKIP_TYPES_WITH_PACKS := true
const MIN_INSTANCES := 4

var analyze_only := true

func _initialize() -> void:
	analyze_only = not ("--apply" in OS.get_cmdline_user_args())
	call_deferred("_run")

func _run() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		push_error("Cannot load " + SCENE_PATH)
		quit(1)
		return
	var root := packed.instantiate()
	var groups := {}
	for child in root.get_children():
		var sp := String(child.scene_file_path)
		if sp.begins_with(PREFAB_PREFIX):
			if not groups.has(sp):
				groups[sp] = []
			(groups[sp] as Array).append(child)

	var report: Array = []
	var plan := {}
	var totals := {"instances": 0, "batchable": 0, "skip_existing": 0, "skip_small": 0, "skip_structure": 0}
	var type_paths: Array = groups.keys()
	type_paths.sort()
	for sp in type_paths:
		var type_name := String(sp).get_file().get_basename()
		var instances: Array = groups[sp]
		totals["instances"] += instances.size()
		if SKIP_TYPES_WITH_PACKS and _type_has_packs(type_name):
			totals["skip_existing"] += instances.size()
			report.append({"type": type_name, "count": instances.size(), "verdict": "skip_existing_pack"})
			continue
		if instances.size() < MIN_INSTANCES:
			totals["skip_small"] += instances.size()
			report.append({"type": type_name, "count": instances.size(), "verdict": "skip_small"})
			continue
		var structure := _analyze_prefab(sp)
		if not structure.ok:
			totals["skip_structure"] += instances.size()
			report.append({"type": type_name, "count": instances.size(),
				"verdict": "skip_structure", "reason": structure.reason})
			continue
		var cells := {}
		for inst in instances:
			cells[_cell_of((inst as Node3D).position)] = true
		totals["batchable"] += instances.size()
		plan[sp] = structure
		report.append({"type": type_name, "count": instances.size(), "verdict": "batch",
			"cells": cells.size(), "surfaces": structure.surfaces, "shape": structure.shape_type})
	for r in report:
		print("MMGEN ", JSON.stringify(r))
	print("MMGEN SUMMARY ", JSON.stringify(totals), " analyze_only=", analyze_only)
	if analyze_only:
		quit(0)
		return
	var errors := _apply(root, groups, plan)
	print("MMGEN APPLY_OK" if errors == 0 else "MMGEN APPLY_ERRORS %d" % errors)
	quit(1 if errors > 0 else 0)

func _type_has_packs(type_name: String) -> bool:
	for f in DirAccess.get_files_at(PACKS_DIR):
		if String(f).begins_with(type_name + "__c"):
			return true
	return false

## A type is batchable when it has exactly one MeshInstance3D at the origin,
## no skeleton, and at most one CollisionShape3D (identity local transform).
func _analyze_prefab(path: String) -> Dictionary:
	var packed := load(path) as PackedScene
	if packed == null:
		return {"ok": false, "reason": "load_failed"}
	var inst := packed.instantiate()
	var meshes := inst.find_children("*", "MeshInstance3D", true, false)
	if inst.find_children("*", "Skeleton3D", true, false).size() > 0:
		inst.free()
		return {"ok": false, "reason": "skinned_mesh"}
	if meshes.size() != 1:
		inst.free()
		return {"ok": false, "reason": "mesh_nodes_%d" % meshes.size()}
	var mi := meshes[0] as MeshInstance3D
	if mi.mesh == null:
		inst.free()
		return {"ok": false, "reason": "null_mesh"}
	if not _is_identity(mi.transform):
		inst.free()
		return {"ok": false, "reason": "mesh_not_at_origin"}
	var shapes := inst.find_children("*", "CollisionShape3D", true, false)
	var shape: Shape3D = null
	var shape_xform := Transform3D()
	var shape_type := "none"
	if shapes.size() > 1:
		inst.free()
		return {"ok": false, "reason": "shape_nodes_%d" % shapes.size()}
	elif shapes.size() == 1:
		var cs := shapes[0] as CollisionShape3D
		if cs.shape == null:
			inst.free()
			return {"ok": false, "reason": "null_shape"}
		shape = cs.shape
		shape_xform = _xform_relative(cs, inst)
		shape_type = cs.shape.get_class()
		if not _is_identity(shape_xform):
			inst.free()
			return {"ok": false, "reason": "shape_offset"}
	var out := {"ok": true, "surfaces": mi.mesh.get_surface_count(),
		"shape_type": shape_type, "mesh": mi.mesh, "overrides": _collect_overrides(mi),
		"shape": shape, "shape_xform": shape_xform}
	inst.free()
	return out

func _collect_overrides(mi: MeshInstance3D) -> Array:
	var overrides := []
	for s in mi.mesh.get_surface_count():
		overrides.append(mi.get_surface_override_material(s))
	return overrides

func _is_identity(t: Transform3D) -> bool:
	return t.basis.is_equal_approx(Basis()) and t.origin.is_equal_approx(Vector3())

## Transform of `node` relative to `ancestor`, walking parents directly.
func _xform_relative(node: Node3D, ancestor: Node) -> Transform3D:
	var t := node.transform
	var cur := node.get_parent()
	while cur != null and cur != ancestor:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t

func _cell_of(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / CELL_SIZE), floori(p.y / CELL_SIZE), floori(p.z / CELL_SIZE))

## Generates packs, rewrites the scene. Returns an error count.
func _apply(root: Node, groups: Dictionary, plan: Dictionary) -> int:
	var errors := 0
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MESHES_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHAPES_DIR))
	var dir := DirAccess.open("res://maps/construction")
	if dir != null:
		var backup_name := "Construction-Site.tscn.bak-%d" % Time.get_unix_time_from_system()
		dir.copy("Construction-Site.tscn", backup_name)
		print("MMGEN backup ", backup_name)
	var to_remove: Array = []
	var to_add: Array = []
	for sp in plan:
		var type_name := String(sp).get_file().get_basename()
		var structure: Dictionary = plan[sp]
		var mesh := (structure.mesh as Mesh).duplicate()
		var overrides: Array = structure.overrides
		for s in overrides.size():
			if overrides[s] != null:
				mesh.surface_set_material(s, overrides[s])
		var mesh_path := "%s/%s_mesh.res" % [MESHES_DIR, type_name]
		if ResourceSaver.save(mesh, mesh_path) != OK:
			push_error("mesh save failed " + mesh_path)
			errors += 1
			continue
		var shape_path := ""
		if structure.shape != null:
			shape_path = "%s/%s_shape.tres" % [SHAPES_DIR, type_name]
			if ResourceSaver.save((structure.shape as Shape3D).duplicate(), shape_path) != OK:
				push_error("shape save failed " + shape_path)
				errors += 1
				continue
		var by_cell := {}
		for inst in groups[sp]:
			var n3d := inst as Node3D
			var cell := _cell_of(n3d.position)
			if not by_cell.has(cell):
				by_cell[cell] = []
			(by_cell[cell] as Array).append(n3d)
		var type_ok := true
		for cell in by_cell:
			var cell_instances: Array = by_cell[cell]
			var xforms := PackedFloat32Array()
			for inst in cell_instances:
				xforms.append_array(_xform_floats((inst as Node3D).transform))
			var pack_path := "%s/%s__c%d_%d_%d.tscn" % [PACKS_DIR, type_name, cell.x, cell.y, cell.z]
			if _write_pack(pack_path, type_name, mesh_path, shape_path,
					structure.shape_xform, xforms, cell_instances.size()) != OK:
				push_error("pack write failed " + pack_path)
				errors += 1
				type_ok = false
				continue
			var pack_scene := load(pack_path) as PackedScene
			if pack_scene == null:
				push_error("pack reload failed " + pack_path)
				errors += 1
				type_ok = false
				continue
			var mm := pack_scene.instantiate()
			mm.name = "MMpack_%s_c%d_%d_%d" % [type_name, cell.x, cell.y, cell.z]
			to_add.append(mm)
			for inst in cell_instances:
				to_remove.append(inst)
			print("MMGEN pack ", pack_path, " instances=", cell_instances.size())
		if not type_ok:
			continue
	for inst in to_remove:
		root.remove_child(inst)
		inst.free()
	for mm in to_add:
		root.add_child(mm)
		mm.owner = root
	var new_packed := PackedScene.new()
	if new_packed.pack(root) != OK:
		push_error("scene pack failed")
		return errors + 1
	if ResourceSaver.save(new_packed, SCENE_PATH) != OK:
		push_error("scene save failed")
		return errors + 1
	print("MMGEN scene rewritten: removed=", to_remove.size(), " packs=", to_add.size())
	return errors

## 12 floats per transform, row-major — same layout as the tscn Transform3D
## serialization and as mm_init.gd expects.
func _xform_floats(t: Transform3D) -> PackedFloat32Array:
	var arr := PackedFloat32Array()
	for r in 3:
		for c in 3:
			arr.append(t.basis[r][c])
	arr.append(t.origin.x)
	arr.append(t.origin.y)
	arr.append(t.origin.z)
	return arr

## Writes one pack scene file as text, mirroring the upstream format.
func _write_pack(path: String, type_name: String, mesh_path: String, shape_path: String,
		shape_xform: Transform3D, xforms: PackedFloat32Array, instance_count: int) -> Error:
	var steps := 4 if shape_path != "" else 3
	var out := "[gd_scene load_steps=%d format=3]\n\n" % steps
	out += "[ext_resource type=\"ArrayMesh\" path=\"%s\" id=\"1_m\"]\n" % mesh_path
	if shape_path != "":
		out += "[ext_resource type=\"Shape3D\" path=\"%s\" id=\"2_s\"]\n" % shape_path
	out += "[ext_resource type=\"Script\" path=\"%s\" id=\"3_sc\"]\n\n" % MM_INIT_SCRIPT
	out += "[node name=\"%s_MM\" type=\"Node3D\"]\n\n" % type_name
	out += "[node name=\"MM\" type=\"MultiMeshInstance3D\" parent=\".\"]\n"
	out += "script = ExtResource(\"3_sc\")\n"
	out += "mm_mesh = ExtResource(\"1_m\")\n"
	out += "xforms = PackedFloat32Array(%s)\n\n" % _fmt_floats(xforms)
	if shape_path != "":
		for i in instance_count:
			var o := i * 12
			var t := Transform3D(
				Basis(Vector3(xforms[o], xforms[o + 3], xforms[o + 6]),
					Vector3(xforms[o + 1], xforms[o + 4], xforms[o + 7]),
					Vector3(xforms[o + 2], xforms[o + 5], xforms[o + 8])),
				Vector3(xforms[o + 9], xforms[o + 10], xforms[o + 11]))
			out += "[node name=\"SB%d\" type=\"StaticBody3D\" parent=\".\"]\n" % i
			out += "transform = Transform3D(%s)\n" % _fmt_xform(t)
			out += "[node name=\"CS%d\" type=\"CollisionShape3D\" parent=\"SB%d\"]\n" % [i, i]
			if not _is_identity(shape_xform):
				out += "transform = %s\n" % _fmt_xform(shape_xform)
			out += "shape = ExtResource(\"2_s\")\n\n"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(out)
	f.close()
	return OK

func _fmt_xform(t: Transform3D) -> String:
	var parts := PackedStringArray()
	for r in 3:
		for c in 3:
			parts.append("%.7g" % t.basis[r][c])
	parts.append("%.7g" % t.origin.x)
	parts.append("%.7g" % t.origin.y)
	parts.append("%.7g" % t.origin.z)
	return ", ".join(parts)

func _fmt_floats(arr: PackedFloat32Array) -> String:
	var parts := PackedStringArray()
	for v in arr:
		parts.append("%.7g" % v)
	return ", ".join(parts)

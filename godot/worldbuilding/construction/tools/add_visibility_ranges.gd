extends SceneTree

## Adds visibility_range_end to small-prop prefabs so scattered instances are
## distance-culled. The property is inserted into the prefab file text, on the
## node block that declares the prefab's MeshInstance3D, so every instance in
## Construction-Site.tscn inherits it without touching the big scene.
##
## Tiers by merged mesh AABB max dimension:
##   < 1.2 m            -> 400 m
##   1.2 m .. < 2.5 m   -> 600 m
##   >= 2.5 m           -> untouched (structures, vehicles, pipes, beams)
##
## Usage:
##   godot --headless --path . --script res://tools/add_visibility_ranges.gd --           (dry run)
##   godot --headless --path . --script res://tools/add_visibility_ranges.gd -- --apply

const PREFAB_DIR := "res://maps/construction/Prefabs"
const TIER_SMALL := 1.2
const TIER_MID := 2.5
const RANGE_SMALL := 400.0
const RANGE_MID := 600.0

var apply := false

func _initialize() -> void:
	apply = "--apply" in OS.get_cmdline_user_args()
	call_deferred("_run")

func _run() -> void:
	var changed := 0
	var skipped := 0
	for f in DirAccess.get_files_at(PREFAB_DIR):
		if not f.ends_with(".tscn"):
			continue
		var path := PREFAB_DIR + "/" + f
		var packed := load(path) as PackedScene
		if packed == null:
			print("VVIS LOAD_FAIL ", f)
			continue
		var inst := packed.instantiate()
		var meshes := inst.find_children("*", "MeshInstance3D", true, false)
		if meshes.size() != 1:
			print("VVIS SKIP ", f, " mesh_nodes=", meshes.size())
			skipped += 1
			inst.free()
			continue
		var mi := meshes[0] as MeshInstance3D
		if mi.mesh == null:
			print("VVIS SKIP ", f, " null_mesh")
			skipped += 1
			inst.free()
			continue
		var max_dim: float = max(mi.mesh.get_aabb().size.x,
			max(mi.mesh.get_aabb().size.y, mi.mesh.get_aabb().size.z))
		var range_end := 0.0
		if max_dim < TIER_SMALL:
			range_end = RANGE_SMALL
		elif max_dim < TIER_MID:
			range_end = RANGE_MID
		if range_end == 0.0:
			print("VVIS KEEP %s max_dim=%.2f" % [f, max_dim])
			skipped += 1
			inst.free()
			continue
		# Node block coordinates relative to the prefab root.
		var name_part := String(mi.name)
		var parent_parts := []
		var walker: Node = mi.get_parent()
		while walker != inst and walker != null:
			parent_parts.push_front(String(walker.name))
			walker = walker.get_parent()
		var parent_attr := "." if parent_parts.is_empty() else "/".join(parent_parts)
		if not _insert_property(path, name_part, parent_attr, range_end):
			print("VVIS EDIT_FAIL ", f)
			errors += 1
			inst.free()
			continue
		changed += 1
		print("VVIS %s %s max_dim=%.2f range=%.0f" % ["APPLIED" if apply else "WOULD", f, max_dim, range_end])
		inst.free()
	print("VVIS SUMMARY apply=", apply, " changed=", changed, " skipped=", skipped, " errors=", errors)
	quit(1 if errors > 0 else 0)

var errors := 0

## Inserts `visibility_range_end = value` into the node block whose header is
## [node name="<name_part>" parent="<parent_attr>" ...], if not already present.
func _insert_property(path: String, name_part: String, parent_attr: String, value: float) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()
	var header := "[node name=\"%s\" parent=\"%s\"" % [name_part, parent_attr]
	var idx := text.find(header)
	if idx < 0:
		# The tscn writer sometimes pads `name = ` with spaces.
		header = "[node name = \"%s\" parent = \"%s\"" % [name_part, parent_attr]
		idx = text.find(header)
		if idx < 0:
			return false
	var prop := "visibility_range_end = %.1f" % value
	if prop in text:
		return true
	var line_end := text.find("\n", idx)
	var insert_at := (line_end + 1) if line_end >= 0 else text.length()
	text = text.insert(insert_at, prop + "\n")
	var w := FileAccess.open(path, FileAccess.WRITE)
	if w == null:
		return false
	w.store_string(text)
	w.close()
	return true

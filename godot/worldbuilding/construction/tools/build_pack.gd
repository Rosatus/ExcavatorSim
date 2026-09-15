extends SceneTree

# Pack only the namespaced map and its imported payloads. Host addons, project
# settings and script-class caches must never be overlaid by an optional map.
var files: Dictionary = {}
var uid_paths: Dictionary = {}

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("Usage: --script res://tools/build_pack.gd -- <absolute-output.pck>")
		quit(1)
		return
	collect("res://maps/construction")
	var uid_file := "user://construction_uid_map.json"
	var output := FileAccess.open(uid_file, FileAccess.WRITE)
	output.store_string(JSON.stringify(uid_paths))
	output.close()
	var packer := PCKPacker.new()
	assert(packer.pck_start(args[0]) == OK)
	assert(packer.add_file("res://maps/construction/uid_map.json", uid_file) == OK)
	for path in files:
		assert(packer.add_file(path, path) == OK, path)
	assert(packer.flush() == OK)
	print("CONSTRUCTION_PACK_OK files=%d output=%s" % [files.size(), args[0]])
	quit()

func collect(directory: String) -> void:
	for child in DirAccess.get_directories_at(directory):
		collect(directory.path_join(child))
	for filename in DirAccess.get_files_at(directory):
		var path := directory.path_join(filename)
		if filename.ends_with(".uid") or filename.ends_with(".tmp"):
			continue
		if filename.ends_with(".import"):
			var config := ConfigFile.new()
			assert(config.load(path) == OK)
			var uid := String(config.get_value("remap", "uid", ""))
			if not uid.is_empty():
				uid_paths[uid] = path.trim_suffix(".import")
			files[path] = true
			for imported in config.get_value("deps", "dest_files", PackedStringArray()):
				assert(imported.begins_with("res://.godot/imported/"))
				assert(FileAccess.file_exists(imported), "Import project before building: " + imported)
				files[imported] = true
		elif not FileAccess.file_exists(path + ".import"):
			files[path] = true

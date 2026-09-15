extends SceneTree

# Run with --path pointing to the ORIGINAL export (read-only source assets),
# --script <absolute-this-file> -- <absolute-workbench-directory>.
const PREFIX := "res://maps/construction/"
var destination := ""
var visited: Dictionary = {}

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	assert(args.size() == 1)
	destination = args[0]
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(destination.path_join("source_manifest.json")))
	var count := 0
	for entry in manifest["files"]:
		var relative := String(entry["path"])
		if not relative.ends_with(".res"):
			continue
		var resource := ResourceLoader.load("res://" + relative, "", ResourceLoader.CACHE_MODE_IGNORE)
		assert(resource != null, relative)
		visited.clear()
		rewrite_children(resource)
		var output := destination.path_join("maps/construction").path_join(relative)
		assert(ResourceSaver.save(resource, output, ResourceSaver.FLAG_COMPRESS) == OK, output)
		count += 1
	print("BINARY_RESOURCES_RELOCATED ", count)
	quit()

func rewrite_children(resource: Resource) -> void:
	if visited.has(resource.get_instance_id()):
		return
	visited[resource.get_instance_id()] = true
	for property in resource.get_property_list():
		if int(property["usage"]) & PROPERTY_USAGE_STORAGE:
			rewrite_value(resource.get(property["name"]))

func rewrite_value(value: Variant) -> void:
	if value is Resource:
		var path: String = value.resource_path
		if path.begins_with("res://") and not path.begins_with(PREFIX) and not path.contains("::"):
			value.take_over_path(PREFIX + path.trim_prefix("res://").trim_prefix("/"))
		else:
			rewrite_children(value)
	elif value is Array:
		for item in value:
			rewrite_value(item)
	elif value is Dictionary:
		for item in value.values():
			rewrite_value(item)

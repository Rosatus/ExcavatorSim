extends SceneTree

var missing: Array[String] = []
var binary_dependencies: Dictionary = {}

func _initialize() -> void:
	walk("res://maps/construction")
	print("DEPENDENCY_AUDIT ", JSON.stringify({"missing": missing, "binary_dependencies": binary_dependencies}))
	quit(0 if missing.is_empty() else 1)

func walk(directory: String) -> void:
	for child in DirAccess.get_directories_at(directory):
		walk(directory.path_join(child))
	for file in DirAccess.get_files_at(directory):
		if file.get_extension() not in ["tscn", "tres", "res"]:
			continue
		var path := directory.path_join(file)
		var dependencies := ResourceLoader.get_dependencies(path)
		if file.ends_with(".res") and not dependencies.is_empty():
			binary_dependencies[path] = Array(dependencies)
		for entry in dependencies:
			var dependency := entry.get_slice("::", entry.get_slice_count("::") - 1)
			if not ResourceLoader.exists(dependency):
				missing.append(path + " -> " + dependency)

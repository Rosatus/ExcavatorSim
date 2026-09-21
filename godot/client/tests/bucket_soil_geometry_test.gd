extends SceneTree
const Geometry = preload("res://scripts/bucket_soil_geometry.gd")
const Fill = preload("res://scripts/bucket_fill_surface.gd")
const Release = preload("res://scripts/bucket_soil_release.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var contract: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://resources/attachments/gb12_s50_soil_contract.json"))
	assert(Geometry.validate(contract.soil_geometry, contract).is_empty())
	var invalid := contract.duplicate(true)
	invalid.proxies.opening.normal_godot = [0, 1, 0]
	assert(not Geometry.validate(invalid.soil_geometry, invalid).is_empty())
	invalid = contract.duplicate(true)
	invalid.soil_geometry.fill_profile_sha256 = "0".repeat(64)
	var fill := Fill.new()
	assert(fill.configure_contract(contract, Vector3.ONE))
	assert(not fill.configure_contract(invalid, Vector3.ONE))
	assert(fill.build_arrays(1.0).is_empty(), "invalid profile must discard previous geometry state")
	# Convex planar polygons and arbitrary tool-local orientation are supported.
	var polygon := [[-1, 0, 1], [1, 0, 1], [1.2, 0, 0], [0.5, 0, -1], [-1, 0, -1]]
	var shape := Geometry.mouth(polygon)
	assert(not shape.is_empty() and shape.transform.basis.y.is_equal_approx(Vector3.UP))
	var rotation := Basis.from_euler(Vector3(0.4, 0.7, -0.2))
	var moved: Array = []
	for point in polygon:
		moved.append(Geometry.array(rotation * Geometry.vector(point) + Vector3(2, -1, 3)))
	var other := Geometry.mouth(moved)
	assert(not other.is_empty() and other.transform.basis.y.is_equal_approx(rotation * Vector3.UP))
	assert(Geometry.mouth([[0,0,0],[1,0,0],[2,0,0]]).is_empty())
	assert(Geometry.mouth([[0,0,0],[1,0,0],[1,0.1,1],[0,0,1]]).is_empty())
	assert(Geometry.mouth([[0,0,0],[1,0,1],[0,0,1],[1,0,0]]).is_empty())
	assert(Geometry.mouth([[0,0,0],[1,0,0],[0.5,0,0.2],[1,0,1],[0,0,1]]).is_empty())
	# The actual transformed mouth wins over a conflicting old normal field.
	var pose := {"contract": contract, "opening_normal_world": Vector3.UP,
		"current": {"opening": Transform3D(Basis(Vector3.RIGHT, PI), Vector3.ZERO)}}
	assert(Release.opening_normal(pose).is_equal_approx(Vector3.DOWN))
	pose.current.clear()
	assert(Release.opening_normal(pose) == Vector3.ZERO)
	assert(is_equal_approx(Release.threshold({}), 0.5))
	assert(is_equal_approx(Release.threshold(contract.interaction), 0.15))
	# A newly named tool uses only its contract resource, never a code registry.
	var profile: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(contract.soil_geometry.fill_profile_path))
	profile.model_id = "independent_test_bucket"
	var temporary_path := "res://output/independent_test_bucket_profile.json"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://output"))
	var text := JSON.stringify(profile)
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	var independent := contract.duplicate(true)
	independent.fill_profile_id = profile.model_id
	independent.soil_geometry.fill_profile_path = temporary_path
	independent.soil_geometry.fill_profile_sha256 = text.sha256_text()
	var valid := fill.configure_contract(independent, Vector3.ONE)
	var has_fill := not fill.build_arrays(0.5).is_empty()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary_path))
	assert(valid and has_fill, "new tool identity must need no registry edit")
	print("bucket_soil_geometry_test: PASS")
	quit(0)

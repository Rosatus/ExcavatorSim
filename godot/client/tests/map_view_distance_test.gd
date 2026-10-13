extends SceneTree

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var catalog := root.get_node("MapCatalog")
	for map_id in ["urban", "construction", "training"]:
		if map_id != "training" and not catalog.map_available(map_id):
			failures.append("Missing map pack: " + map_id)
			continue
		catalog.active_map_id = map_id
		catalog.retained_model_id = "sy135"
		var scene := load("res://scenes/main.tscn").instantiate() as Node3D
		root.add_child(scene)
		current_scene = scene
		await process_frame
		var quality := scene.get_node("VisualQualityController") as VisualQualityController
		var camera := scene.get_node("Camera3D") as CameraRig
		for profile in ["low", "balanced", "high", "test", "balanced"]:
			if not quality.apply_profile(profile):
				failures.append("%s: profile %s failed: %s" % [map_id, profile, quality.last_error])
			var profile_far := float(VisualQualityController.PROFILES[profile]["camera_far"])
			var expected_far := profile_far if map_id == "training" else 1500.0
			if not is_equal_approx(camera.far, expected_far):
				failures.append("%s/%s: camera far %s != %s" % [map_id, profile, camera.far, expected_far])
			if not is_equal_approx(float(quality.get_quality_snapshot()["camera_far"]), camera.far):
				failures.append("%s/%s: snapshot differs from camera" % [map_id, profile])
			if not is_equal_approx(camera.max_distance_m, profile_far * 0.1):
				failures.append("%s/%s: orbit zoom limit changed" % [map_id, profile])
		if map_id == "construction":
			var ranged_meshes := 0
			for mesh in scene.get_node("StaticMap").find_children("*", "GeometryInstance3D", true, false):
				if mesh.visibility_range_end > 0.0:
					ranged_meshes += 1
					if mesh.visibility_range_end < 400.0:
						failures.append("Short prop range: %s (%s)" % [mesh.get_path(), mesh.visibility_range_end])
			if ranged_meshes == 0:
				failures.append("Construction pack has no ranged props to verify")
		scene.queue_free()
		await process_frame
		await process_frame
	for failure in failures:
		push_error(failure)
	print("map_view_distance_test: ", "PASS" if failures.is_empty() else "FAIL", " ", failures)
	quit(0 if failures.is_empty() else 1)

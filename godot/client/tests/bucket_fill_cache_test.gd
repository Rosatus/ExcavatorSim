extends SceneTree

const Surface = preload("res://scripts/bucket_fill_surface.gd")
const Legacy = preload("res://tests/fixtures/pre_cached_fill_surface.gd")


func _init() -> void:
	var current := Surface.new()
	var legacy := Legacy.new()
	for path in ["res://resources/models/sy135_soil_contract.json", "res://resources/models/sy205_soil_contract.json", "res://resources/models/sy80u_soil_contract.json", "res://resources/attachments/gb12_s50_soil_contract.json", "res://resources/models/sy135_soil_contract.json"]:
		var contract: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not current.configure_contract(contract, Vector3.ONE) or not legacy.configure_contract(contract, Vector3.ONE):
			push_error("configure " + path)
			quit(1)
			return
		# Includes empty/tiny, grid levels, off-grid levels, descending and refill.
		for ratio in [0.0, 0.005, 0.05, 0.1, 0.237, 0.5, 0.75, 1.0, 0.83, 0.3, 0.001, 0.0, 0.5]:
			var expected := legacy.build_arrays(ratio)
			var actual := current.build_arrays(ratio)
			if actual != expected:
				push_error("exact mesh arrays differ " + path + " ratio=" + str(ratio))
				quit(1)
				return
	for tool in [legacy, current]:
		var start := Time.get_ticks_usec()
		for index in 50:
			tool.build_arrays(0.5)
		print("FILL_BUILD_50_USEC ", "legacy=" if tool == legacy else "current=", Time.get_ticks_usec() - start)
	print("bucket_fill_cache_test: PASS")
	quit(0)

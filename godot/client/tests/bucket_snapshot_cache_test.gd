extends SceneTree

const Legacy = preload("res://tests/fixtures/pre_cached_bucket_snapshot.gd")
var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var current := BucketSoilTool.new()
	var legacy := Legacy.new()
	# Reuse objects across native/attachment changes to catch stale static geometry.
	for path in ["res://resources/models/sy135_soil_contract.json", "res://resources/models/sy80u_soil_contract.json", "res://resources/attachments/gb12_s50_soil_contract.json", "res://resources/models/sy135_soil_contract.json"]:
		var contract: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		_check(current.configure(contract) and legacy.configure(contract), "configure " + path)
		for index in 160:
			var previous := Transform3D(Basis.from_euler(Vector3(index * 0.03, index * -0.01, index * 0.02)), Vector3(-2.0, 0.4, 1.0))
			var next := previous * Transform3D(Basis(Vector3.RIGHT, float(index % 20) * 0.025), Vector3(float(index % 15) * 0.03, -0.01, 0.04))
			if index % 3 == 0:
				next = previous
			var actual := current.compose_snapshot(previous, next, true, "parity")
			var expected := legacy.compose_snapshot(previous, next, true, "parity")
			_check(actual == expected, "exact snapshot including sweep order/bounds " + path + ":" + str(index))
			if index == 0:
				actual.regions[0].shape.clear()
				actual.regions[0].stable_soil_roles.clear()
				actual.regions[0].current_points.clear()
				var exterior := current.exterior_contact_points()
				exterior.clear()
				_check(current.compose_snapshot(previous, next, true, "parity") == expected, "detached returned containers")
		_check(current.compose_snapshot(Transform3D.IDENTITY, Transform3D.IDENTITY, false, "history") == legacy.compose_snapshot(Transform3D.IDENTITY, Transform3D.IDENTITY, false, "history"), "missing history")
		_check(current.compose_snapshot(Transform3D.IDENTITY, Transform3D.IDENTITY, true, "") == legacy.compose_snapshot(Transform3D.IDENTITY, Transform3D.IDENTITY, true, ""), "missing identity")
		_check(not current.configure({}) and not legacy.configure({}), "invalid reconfigure")
		_check(current.exterior_contact_points().is_empty(), "invalid reconfigure clears points")
		_check(current.compose_snapshot(Transform3D.IDENTITY, Transform3D.IDENTITY, true, "invalid") == legacy.compose_snapshot(Transform3D.IDENTITY, Transform3D.IDENTITY, true, "invalid"), "no stale snapshot after invalid reconfigure")
	var contract := SoilContractDescriptor.load_for_model("sy135").to_dictionary()
	current.configure(contract)
	legacy.configure(contract)
	var next := Transform3D(Basis(Vector3.RIGHT, 0.03), Vector3(0.02, -0.03, 0.0))
	for tool in [legacy, current]:
		var start := Time.get_ticks_usec()
		for index in 2000:
			tool.compose_snapshot(Transform3D.IDENTITY, next, true, "benchmark")
		print("BUCKET_SNAPSHOT_2000_USEC ", "legacy=" if tool == legacy else "current=", Time.get_ticks_usec() - start)
	for failure in failures:
		push_error(failure)
	print("bucket_snapshot_cache_test: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)


func _check(ok: bool, label: String) -> void:
	if not ok:
		failures.append(label)

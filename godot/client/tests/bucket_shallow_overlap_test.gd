extends SceneTree

## Focused contract for the cutting resistance migration: soil never blocks
## the cutting edge (shell/rear still do), benign shallow start overlap stays
## valid evidence, deep burial disarms, and edge penetration below grade is
## reported for the resistance load.

const SOIL_CONTRACT := "res://resources/models/sy205_soil_contract.json"
const MODEL_ID := "sy205"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if ProjectSettings.get_setting("physics/3d/physics_engine") != "Jolt Physics":
		return _fail("Jolt Physics is not selected")
	var host := Node3D.new()
	host.name = "BucketShallowOverlapTest"
	root.add_child(host)
	var terrain_world := TerrainWorld.new()
	terrain_world.name = "TerrainWorld"
	host.add_child(terrain_world)
	var terrain_collider := TerrainCollider.new()
	terrain_collider.name = "TerrainCollider"
	terrain_collider.enabled = true
	host.add_child(terrain_collider)
	await process_frame
	var snapshot := terrain_world.terrain_state.surface_snapshot()
	if not terrain_collider.queue_snapshot(snapshot) or not terrain_collider.apply_pending():
		return _fail("terrain collider materializes")
	await physics_frame
	var contract := _read_json(SOIL_CONTRACT)
	if contract.is_empty():
		return _fail("soil contract loads")
	var sweeper := BucketProxySweeper.new()
	if not sweeper.configure(MODEL_ID, contract, terrain_collider, 1):
		return _fail("sweeper configures")
	var identity := terrain_collider.get_applied_identity()
	var tick := Engine.get_physics_frames()

	var air := _stroke(sweeper, host, 0.30, 0.24, identity, 1)
	if not bool(air.get("valid", false)):
		failures.append("clean air approach stays valid")
	if not (air.get("quality_flags", []) as Array).is_empty():
		failures.append("clean air approach carries no quality flags")

	var shallow := _stroke(sweeper, host, -0.04, -0.10, identity, 2)
	if not bool(shallow.get("valid", false)):
		failures.append("shallow cutting overlap remains valid evidence")
	if not (shallow.get("quality_flags", []) as Array).has("bucket_query_shallow_cutting_overlap"):
		failures.append("shallow stroke reports the benign flag: %s" % str(shallow.get("quality_flags", [])))
	for record in shallow.get("contacts", []) as Array:
		var contact := record as Dictionary
		if String(contact.get("query_source", "")) != "terrain_collider":
			failures.append("shallow stroke accepts only TerrainCollider query evidence")
			break
		if bool(contact.get("initial_overlap", false)):
			failures.append("shallow stroke must not produce pathological records")
			break
	if (shallow.get("contacts", []) as Array).is_empty():
		failures.append("shallow stroke produces cutting contacts")
	if float(shallow.get("accepted_fraction", 0.0)) < 0.9:
		failures.append("pressing within the cutting envelope must not block motion: %.3f" % float(shallow.get("accepted_fraction", 0.0)))

	var press := _stroke(sweeper, host, -0.02, -0.30, identity, 5)
	if not bool(press.get("valid", false)):
		failures.append("a benign start pose stays valid even when the stroke target is deep")
	if (press.get("contacts", []) as Array).is_empty():
		failures.append("pressing past the envelope still records cutting evidence")
	if float(press.get("accepted_fraction", 0.0)) < 0.9:
		failures.append("soil must never block the cutting edge: %.3f" % float(press.get("accepted_fraction", 0.0)))

	var air_probe := sweeper.probe_cut_penetration(
		Transform3D(Basis.IDENTITY, Vector3(-0.38, 0.30 + 1.0, 0.0)),
		terrain_world.terrain_state
	)
	if absf(air_probe) > 0.001:
		failures.append("edge above grade reports no penetration: %.3f" % air_probe)
	var deep_probe := sweeper.probe_cut_penetration(
		Transform3D(Basis.IDENTITY, Vector3(-0.38, -0.60 + 1.0, 0.0)),
		terrain_world.terrain_state
	)
	if deep_probe < 0.3:
		failures.append("edge below grade reports penetration for the resistance load: %.3f" % deep_probe)

	var deep := _stroke(sweeper, host, -0.60, -0.66, identity, 3)
	if bool(deep.get("valid", false)):
		failures.append("deep burial disarms the query")
	if not (deep.get("quality_flags", []) as Array).has("bucket_query_initial_overlap"):
		failures.append("deep burial reports the pathological flag")

	var shell := _stroke_shell(sweeper, host, -0.04, -0.10, identity, 4)
	if bool(shell.get("valid", false)):
		failures.append("shell initial overlap disarms even at shallow depth")
	if not (shell.get("quality_flags", []) as Array).has("bucket_query_initial_overlap"):
		failures.append("shell overlap reports the pathological flag")

	if failures.is_empty():
		print("bucket_shallow_overlap_test: PASS")
		host.queue_free()
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		host.queue_free()
		quit(1)


func _stroke(
	sweeper: BucketProxySweeper,
	host: Node3D,
	start_edge_y: float,
	end_edge_y: float,
	identity: Vector2i,
	sequence: int
) -> Dictionary:
	var previous := Transform3D(Basis.IDENTITY, Vector3(-0.5, start_edge_y + 1.0, 0.0))
	var candidate := Transform3D(Basis.IDENTITY, Vector3(-0.38, end_edge_y + 1.0, 0.0))
	return sweeper.sweep(host.get_world_3d(), previous, candidate, identity, Engine.get_physics_frames(), "epoch", sequence)


func _stroke_shell(
	sweeper: BucketProxySweeper,
	host: Node3D,
	start_shell_y: float,
	end_shell_y: float,
	identity: Vector2i,
	sequence: int
) -> Dictionary:
	var previous := Transform3D(Basis.IDENTITY, Vector3(-0.5, start_shell_y + 0.36, 0.12))
	var candidate := Transform3D(Basis.IDENTITY, Vector3(-0.38, end_shell_y + 0.36, 0.12))
	return sweeper.sweep(host.get_world_3d(), previous, candidate, identity, Engine.get_physics_frames(), "epoch", sequence)


func _read_json(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	return parsed as Dictionary if parsed is Dictionary else {}


func _fail(message: String) -> void:
	push_error("bucket_shallow_overlap_test failed: %s" % message)
	quit(1)

extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		return _fail("main scene unavailable")
	var scene := packed.instantiate()
	root.add_child(scene)
	for _frame in 6:
		await physics_frame
	var excavation := scene.get_node_or_null("TerrainRoot/ExcavationWorld") as ExcavationWorld
	if excavation == null:
		return _fail("main scene excavation world unavailable")
	if not excavation.set_soil_surface_solver_mode("arcade_stamp_v3"):
		return _fail("arcade stamp solver selection failed")
	await physics_frame
	var status := excavation.get_status_snapshot()
	if String(status.get("soil_material_lifecycle_mode", "")) != "active_patch" or String(status.get("soil_surface_solver_mode", "")) != "arcade_stamp_v3":
		return _fail("arcade stamp did not bind at a clean active generation")
	var arcade := status.get("arcade_stamp", {}) as Dictionary
	if not bool(arcade.get("configured", false)):
		return _fail("arcade stamp was selected but not configured")
	if bool((status.get("active_soil_patch", {}) as Dictionary).get("configured", false)):
		return _fail("arcade stamp retained the v2 active soil patch")
	if bool((status.get("soil_lifecycle_active", {}) as Dictionary).get("configured", false)):
		return _fail("arcade stamp retained the v2 interaction authority")
	excavation.set_active_soil_patch_prototype_enabled(true)
	if bool((excavation.get_status_snapshot().get("active_soil_patch", {}) as Dictionary).get("configured", false)):
		return _fail("v2 prototype toggle instantiated active soil during arcade v3")
	excavation.set_active_soil_patch_prototype_enabled(false)
	var selected := status.get("selected_soil_payload", {}) as Dictionary
	if String(selected.get("source", "")) != "arcade_stamp_v3":
		return _fail("arcade scalar payload was not selected")
	scene.queue_free()
	print("arcade_excavation_world_test: PASS")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)

extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"
var failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene := load(MAIN_SCENE).instantiate() as Node3D
	if scene == null:
		_fail("main scene did not instantiate")
		quit(1)
		return
	root.add_child(scene)
	await process_frame
	await physics_frame
	var session := scene.get_node_or_null("ProductSession") as ProductSession
	var client := scene.get_node_or_null("MotionClient") as MotionClient
	var chassis := scene.get_node_or_null("ChassisMotionRoot") as TrackedChassisController
	var presentation := scene.get_node_or_null("MotionPresentation") as MotionPresentation
	var truth := scene.get_node_or_null("SimulationTruthPublisher") as SimulationTruthPublisher
	var excavation := scene.get_node_or_null("TerrainRoot/ExcavationWorld") as ExcavationWorld
	var dressing := scene.get_node_or_null("TerrainRoot/ConstructionSiteDressing") as ConstructionSiteDressing
	if session == null or client == null or chassis == null or presentation == null or truth == null or excavation == null or dressing == null:
		_fail("offline main scene is missing a required product node")
	else:
		if client.connection_state != MotionClient.STATE_DISCONNECTED:
			_fail("offline startup attempted a transport connection")
		if session.lifecycle != ProductSession.LIFECYCLE_STOPPED:
			_fail("offline startup did not begin stopped")
		if presentation.get_active_model_id() != "sy205":
			_fail("offline startup did not activate SY205")
		if client.get_equipment_gamepad_model_id() != "sy205":
			_fail("offline startup did not install the SY205 gamepad direction profile")
		var site_identity := String(dressing.get_status_snapshot().get("layout_identity", ""))
		if site_identity.is_empty() or int(dressing.get_status_snapshot().get("collision_objects", -1)) != 0:
			_fail("offline worksite dressing was not deterministic and collision-free")
		if not bool(chassis.get_status_snapshot().get("configured", false)):
			_fail("offline Jolt chassis was not configured")
		var local_truth := truth.build_snapshot()
		if local_truth == null or local_truth.to_dictionary().get("identity", {}).get("session_id", "") != ProductSession.LOCAL_SESSION_ID:
			_fail("offline truth did not use local authority identity")
		var initial_selection := excavation.get_status_snapshot().get("soil_authority_selection", {}) as Dictionary
		if String(initial_selection.get("selected_mode", "")) != "active_patch" or not bool(initial_selection.get("single_owner_valid", false)):
			_fail("offline product did not start with one active-patch material owner")
		var initial_soil_status := excavation.get_status_snapshot()
		var initial_lifecycle := initial_soil_status.get("soil_lifecycle_active", {}) as Dictionary
		if (
			int(initial_lifecycle.get("generation", -1))
			!= int(initial_soil_status.get("world_generation", -2))
		):
			_fail("active soil authority did not retain the selected world generation")
		if not excavation.set_soil_material_lifecycle_mode("legacy"):
			_fail("offline legacy fallback request was rejected")
		if String(excavation.get_status_snapshot().get("soil_material_lifecycle_mode", "")) != "active_patch":
			_fail("soil authority changed before a clean generation boundary")
		if not session.request_reset():
			_fail("offline reset could not apply legacy fallback")
		var legacy_status := excavation.get_status_snapshot()
		if String(legacy_status.get("soil_material_lifecycle_mode", "")) != "legacy":
			_fail("offline clean boundary did not apply legacy fallback")
		if not excavation.set_soil_material_lifecycle_mode("active_patch") or not session.request_reset():
			_fail("offline reset could not restore active soil authority")
		var active_status := excavation.get_status_snapshot()
		var active_selection := active_status.get("soil_authority_selection", {}) as Dictionary
		if String(active_selection.get("selected_mode", "")) != "active_patch" or not bool(active_selection.get("single_owner_valid", false)):
			_fail("offline reset did not select one active-patch material owner")
		if String((active_status.get("selected_soil_payload", {}) as Dictionary).get("source", "")) != "active_patch":
			_fail("offline Jolt payload source did not follow active soil authority")
		var active_truth := truth.build_snapshot()
		if active_truth == null or not active_truth.to_dictionary().has("soil_lifecycle_active"):
			_fail("offline truth did not publish the selected active lifecycle")
		if not session.request_start() or session.lifecycle != ProductSession.LIFECYCLE_RUNNING:
			_fail("offline start failed")
		await physics_frame
		if not bool(chassis.get_status_snapshot().get("enabled", false)):
			_fail("offline start did not enable chassis")
		if not session.request_pause() or session.lifecycle != ProductSession.LIFECYCLE_PAUSED:
			_fail("offline pause failed")
		if not session.request_model_switch("sy135") or presentation.get_active_model_id() != "sy135":
			_fail("offline SY135 switch failed")
		if client.get_equipment_gamepad_model_id() != "sy135":
			_fail("offline SY135 switch did not refresh gamepad directions")
		if String(dressing.get_status_snapshot().get("layout_identity", "")) != site_identity:
			_fail("model switch changed model-independent worksite placement")
		if _visible_model_count(scene.get_node("ChassisMotionRoot/PresentationRoot")) != 1:
			_fail("offline model switch was not singular")
		var epoch_before := session.authority_epoch
		if not session.request_reset() or session.lifecycle != ProductSession.LIFECYCLE_STOPPED:
			_fail("offline reset failed")
		if session.authority_epoch == epoch_before:
			_fail("offline reset did not rotate local epoch")

	queue_free_scene(scene)
	if failures.is_empty():
		print("Offline Godot product contract passed.")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)

func queue_free_scene(scene: Node) -> void:
	scene.queue_free()

func _visible_model_count(parent: Node) -> int:
	var count := 0
	for child in parent.get_children():
		if child is Node3D and (child as Node3D).visible:
			count += 1
	return count

func _fail(message: String) -> void:
	failures.append(message)

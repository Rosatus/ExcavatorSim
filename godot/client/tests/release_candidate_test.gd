extends SceneTree

const MAIN_SCENE := "res://scenes/main.tscn"
const FIXTURE_PATH := "res://tests/fixtures/sy205_frame_parity_cases.json"
const VERSIONS := {
	"protocol_version": "godot-pinocchio-v4",
	"state_schema_version": "godot-pinocchio-state-v2",
	"model_version": "sy205-glb-urdf-v4",
	"calibration_version": "machine-calibration-v2",
	"software_version": "0.1.0",
	"terrain_spec_version": "terrain-spec-v1",
	"terrain_algorithm_version": "terrain-algorithm-v2",
	"visual_model_version": "original-skin-v1",
}


class FakeTransport extends RefCounted:
	var opened := false

	func connect_to_url(_endpoint: String) -> int:
		opened = true
		return OK

	func poll() -> void:
		pass

	func get_ready_state() -> int:
		return WebSocketPeer.STATE_OPEN if opened else WebSocketPeer.STATE_CLOSED

	func send_text(_message: String) -> int:
		return OK

	func get_available_packet_count() -> int:
		return 0

	func close() -> void:
		opened = false


var _transport: FakeTransport


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var result := await _test_connected_operate_reset_reconnect()
	if result == 0:
		print("Integration release candidate contracts passed.")
	quit(result)


func _test_connected_operate_reset_reconnect() -> int:
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		return _fail("main scene loads")
	var instance := packed.instantiate()
	(instance.get_node("TerrainRoot/ExcavationWorld") as ExcavationWorld).soil_material_lifecycle_mode = "legacy"
	var client := instance.get_node("MotionClient") as MotionClient
	client.auto_connect = false
	client.set_transport_factory_for_test(Callable(self, "_new_transport"))
	root.add_child(instance)
	await process_frame
	var presentation := instance.get_node("MotionPresentation") as MotionPresentation
	var excavation := instance.get_node("TerrainRoot/ExcavationWorld") as ExcavationWorld
	var effects := instance.get_node("SoilEffects") as SoilEffects
	if presentation.get_contract_error() != "" or excavation.soil_state == null:
		return _fail("motion and excavation contracts initialize")
	client.connect_to_service()
	client.process_for_test(0.01)
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE_PATH))
	var asymmetric: Dictionary = fixture["poses"]["asymmetric"]
	client.inject_server_frame(_hello_ack("release-session-a", "release-epoch-a", "running"))
	client.inject_server_frame(_view_state(asymmetric, "release-epoch-a", 1, 1))
	await process_frame
	if client.get_connection_state() != MotionClient.STATE_READY or client.get_pose_buffer_size() != 1:
		return _fail("hello/view state reaches ready client")
	var h := excavation.terrain_world.terrain_state.sample_surface_at(Vector2.ZERO)
	if not excavation.queue_cut_world(1, Vector3(0.0, h, 0.0), Vector3(0.0, h - 0.2, 0.0)):
		return _fail("connected scene queues dig")
	var cut := excavation.step_fixed_for_test()
	var pool := excavation._parcel_pool as SoilParcelPool
	var cut_transport := pool.get_pool_snapshot()
	if (
		not cut.get("changed", false)
		or float(excavation.soil_state.bucket_volume_m3) != 0.0
		or int(cut_transport.get("active", 0)) <= 0
		or float(cut_transport.get("volume_m3", 0.0)) <= 0.0
	):
		return _fail("connected scene dig feeds the parcel transport stage")
	var parcel_index := _first_active(pool)
	if parcel_index < 0:
		return _fail("cut parcel resolves for capture")
	var parcel_body := pool.get_body(parcel_index)
	parcel_body.linear_velocity = Vector3.ZERO
	var cavity := Transform3D(Basis.IDENTITY, parcel_body.global_position)
	for _tick in 20:
		pool.step_pool(1.0 / 60.0, cavity, Vector3(0.25, 0.25, 0.35))
	if excavation.soil_state.bucket_volume_m3 <= BucketSoilState.EPSILON_M3:
		return _fail("captured parcel becomes carried bucket payload")
	var carried_volume := excavation.soil_state.bucket_volume_m3
	var dump_height := excavation.terrain_world.terrain_state.sample_surface_at(Vector2.ZERO) + 0.2
	var released := pool.release_volume(carried_volume, Vector3(0.0, dump_height, 0.0), Vector3.DOWN)
	var dump_transport := pool.get_pool_snapshot()
	if (
		released <= BucketSoilState.EPSILON_M3
		or excavation.soil_state.bucket_volume_m3 >= carried_volume
		or int(dump_transport.get("guarded", 0)) <= 0
	):
		return _fail("connected scene carry/dump hands payload back to guarded parcels")
	var old_generation := client.get_generation()
	client.reconnect_now()
	client.process_for_test(0.01)
	client.inject_server_frame(_hello_ack("release-session-b", "release-epoch-b", "stopped"))
	await process_frame
	if client.get_generation() <= old_generation or client.get_pose_buffer_size() != 0:
		return _fail("authority epoch change clears motion generation: old=%d new=%d poses=%d" % [old_generation, client.get_generation(), client.get_pose_buffer_size()])
	if (
		excavation.soil_state.bucket_volume_m3 != 0.0
		or pool.active_count() != 0
		or effects.get_effect_snapshot()["generation"] <= 0
	):
		return _fail("authority epoch change clears local inventory and effects")
	excavation.reset_for_test()
	if excavation.soil_state.bucket_volume_m3 != 0.0 or excavation.terrain_world.terrain_state.world_generation <= 0:
		return _fail("reset returns clean local world")
	instance.queue_free()
	await process_frame
	return 0


func _new_transport() -> FakeTransport:
	_transport = FakeTransport.new()
	return _transport


func _first_active(pool: SoilParcelPool) -> int:
	for index in pool._records.size():
		if bool(pool._records[index].get("active", false)):
			return index
	return -1


func _hello_ack(session: String, epoch: String, lifecycle: String) -> Dictionary:
	return {
		"type": "hello_ack",
		"session_id": session,
		"simulation_epoch": epoch,
		"recording_epoch": "release-recording",
		"versions": VERSIONS.duplicate(true),
		"model_url": "/api/model",
		"lifecycle": lifecycle,
		"capabilities": ["commands", "input_snapshot"],
	}


func _view_state(pose: Dictionary, epoch: String, revision: int, source_sequence: int) -> Dictionary:
	return {
		"type": "view_state",
		"emitted_sequence": revision,
		"source_sequence": source_sequence,
		"simulation_epoch": epoch,
		"recording_epoch": "release-recording",
		"buffer_generation": 0,
		"end_sample_sequence": source_sequence,
		"view_revision": revision,
		"source_mode": "live",
		"playback_state": "following",
		"cursor_recording_time_ns": 0,
		"retained_start_ns": 0,
		"retained_end_ns": 0,
		"selected_sample_sequence": source_sequence,
		"simulation_time_s": 0.0,
		"lifecycle": "running",
		"versions": VERSIONS.duplicate(true),
		"joint_names": ["swing_joint", "boom_joint", "arm_joint", "bucket_joint"],
		"joint_position": pose["joint_angles"],
		"joint_velocity": [0.0, 0.0, 0.0, 0.0],
		"joint_acceleration": [0.0, 0.0, 0.0, 0.0],
		"frame_transforms": pose["frame_transforms"],
		"quality_flags": [],
		"last_input_client_sequence": null,
		"server_monotonic_ms": 0.0,
	}


func _fail(message: String) -> int:
	push_error("M7 check failed: %s" % message)
	return 1

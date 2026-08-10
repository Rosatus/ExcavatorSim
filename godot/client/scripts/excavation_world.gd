class_name ExcavationWorld
extends Node3D

signal excavation_changed(status: Dictionary)

@export var terrain_world_path := NodePath("../TerrainWorld")
@export var terrain_collider_path := NodePath("../TerrainCollider")
@export var motion_presentation_path := NodePath("../../MotionPresentation")
@export var motion_client_path := NodePath("../../MotionClient")
@export var local_tooth_offset := Vector3(0.0, -0.55, 0.0)

var terrain_world: TerrainWorld
var terrain_collider: TerrainCollider
var soil_state: BucketSoilState
var _next_command_sequence := 0
var _previous_tooth := Vector3.ZERO
var _has_previous_tooth := false


func _ready() -> void:
	_initialize()


func _initialize() -> void:
	terrain_world = get_node_or_null(terrain_world_path) as TerrainWorld
	terrain_collider = get_node_or_null(terrain_collider_path) as TerrainCollider
	if terrain_world == null or terrain_world.terrain_state == null:
		call_deferred("_initialize")
		return
	soil_state = BucketSoilState.new(terrain_world.terrain_state)
	if terrain_collider != null:
		terrain_collider.queue_snapshot(terrain_world.terrain_state.surface_snapshot())
		terrain_collider.apply_pending()
	var motion_client := get_node_or_null(motion_client_path) as MotionClient
	if motion_client != null:
		motion_client.pose_cleared.connect(_on_pose_cleared)
		motion_client.authority_changed.connect(_on_authority_changed)


func _physics_process(_delta: float) -> void:
	if soil_state == null:
		return
	var result := soil_state.step_fixed()
	if bool(result.get("changed", false)):
		if terrain_world != null:
			terrain_world.rebuild_mesh()
		if terrain_collider != null:
			terrain_collider.queue_snapshot(terrain_world.terrain_state.surface_snapshot())
			terrain_collider.apply_pending()
		excavation_changed.emit(get_status_snapshot())


func queue_cut_world(sequence: int, previous_tooth: Vector3, current_tooth: Vector3) -> bool:
	if soil_state == null:
		return false
	_next_command_sequence = maxi(_next_command_sequence, sequence + 1)
	return soil_state.queue_cut(sequence, previous_tooth, current_tooth)


func queue_deposit_world(sequence: int, center: Vector3) -> bool:
	if soil_state == null:
		return false
	_next_command_sequence = maxi(_next_command_sequence, sequence + 1)
	return soil_state.queue_deposit(sequence, center)


func step_fixed_for_test() -> Dictionary:
	if soil_state == null:
		return {"changed": false, "reason": "unavailable"}
	var result := soil_state.step_fixed()
	if bool(result.get("changed", false)):
		if terrain_world != null:
			terrain_world.rebuild_mesh()
		if terrain_collider != null:
			terrain_collider.queue_snapshot(terrain_world.terrain_state.surface_snapshot())
			terrain_collider.apply_pending()
		excavation_changed.emit(get_status_snapshot())
	return result


func request_dig() -> bool:
	var current: Variant = _bucket_tooth_world()
	if current == null:
		return false
	var current_tooth: Vector3 = current
	var previous_tooth: Vector3 = _previous_tooth if _has_previous_tooth else current_tooth
	var accepted: bool = queue_cut_world(_next_command_sequence, previous_tooth, current_tooth)
	if accepted:
		_previous_tooth = current_tooth
		_has_previous_tooth = true
		step_fixed_for_test()
	return accepted


func request_deposit() -> bool:
	var center: Variant = _bucket_tooth_world()
	if center == null:
		return false
	var accepted: bool = queue_deposit_world(_next_command_sequence, center)
	if accepted:
		step_fixed_for_test()
	return accepted


func reset_for_test() -> void:
	if terrain_world == null or terrain_world.terrain_state == null:
		return
	terrain_world.reset_for_test()
	if soil_state != null:
		soil_state.reset_for_generation(terrain_world.terrain_state.world_generation)
	_next_command_sequence = 0
	_previous_tooth = Vector3.ZERO
	_has_previous_tooth = false
	if terrain_collider != null:
		terrain_collider.queue_snapshot(terrain_world.terrain_state.surface_snapshot())
		terrain_collider.apply_pending()
	excavation_changed.emit(get_status_snapshot())


func get_status_snapshot() -> Dictionary:
	var status := soil_state.get_status_snapshot() if soil_state != null else {"bucket_volume_m3": 0.0, "world_generation": -1}
	status["collider_available"] = terrain_collider != null and terrain_collider.available
	status["collider_enabled"] = terrain_collider != null and terrain_collider.enabled
	status["physics_fail_open"] = true
	return status


func _on_pose_cleared(_generation: int, _reason: String) -> void:
	if soil_state != null and terrain_world != null:
		soil_state.reset_for_generation(terrain_world.terrain_state.world_generation)
	_previous_tooth = Vector3.ZERO
	_has_previous_tooth = false
	excavation_changed.emit(get_status_snapshot())


func _on_authority_changed(_session_id: String, _simulation_epoch: String, _generation: int) -> void:
	_on_pose_cleared(0, "authority_generation")


func _bucket_tooth_world() -> Variant:
	var presentation := get_node_or_null(motion_presentation_path) as MotionPresentation
	if presentation == null:
		return null
	var bucket_frame := presentation.get_frame_node("bucket_link")
	if bucket_frame == null:
		return null
	return bucket_frame.global_transform * local_tooth_offset

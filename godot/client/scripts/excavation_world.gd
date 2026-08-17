class_name ExcavationWorld
extends Node3D

signal excavation_changed(status: Dictionary)

@export var terrain_world_path := NodePath("../TerrainWorld")
@export var terrain_collider_path := NodePath("../TerrainCollider")
@export var motion_presentation_path := NodePath("../../MotionPresentation")
@export var motion_client_path := NodePath("../../MotionClient")
@export var tracked_chassis_controller_path := NodePath("../../ChassisMotionRoot")
@export var automatic_soil_enabled := true
@export var debug_manual_controls := false
@export var hero_clods_enabled := true
@export var backend_feedback_enabled := false
@export_enum("low", "balanced", "high") var feedback_quality := "balanced"
@export var local_tooth_offset := Vector3(0.0, -0.55, 0.0)

var terrain_world: TerrainWorld
var terrain_collider: TerrainCollider
var terrain_scheduler: TerrainCommitScheduler
var soil_state: BucketSoilState
var authority_generation := 0

var _presentation: MotionPresentation
var _motion_client: MotionClient
var _tracked_chassis_controller: TrackedChassisController
var _next_command_sequence := 0
var _last_pose_snapshot: Dictionary = {}
var _last_interaction := "idle"
var _last_support: Dictionary = {"active": false, "penetration_m": 0.0}
var _last_flow_volume_m3 := 0.0
var _last_raw_support_point := Vector3.ZERO
var _has_raw_support_point := false
var _material_generation := 0
var _initialized := false


func _ready() -> void:
	process_physics_priority = 20
	_initialize()


func _initialize() -> void:
	if _initialized:
		return
	terrain_world = get_node_or_null(terrain_world_path) as TerrainWorld
	terrain_collider = get_node_or_null(terrain_collider_path) as TerrainCollider
	_presentation = get_node_or_null(motion_presentation_path) as MotionPresentation
	if terrain_world == null or terrain_world.terrain_state == null or _presentation == null:
		call_deferred("_initialize")
		return
	var contract := _presentation.get_soil_contract()
	if contract.is_empty():
		call_deferred("_initialize")
		return
	_sync_local_tooth_offset(contract)
	terrain_scheduler = TerrainCommitScheduler.new(terrain_world.terrain_state, terrain_world, terrain_collider)
	soil_state = BucketSoilState.new(terrain_world.terrain_state, contract, terrain_scheduler)
	terrain_scheduler.refresh_collider_derivative()
	_motion_client = get_node_or_null(motion_client_path) as MotionClient
	_tracked_chassis_controller = get_node_or_null(tracked_chassis_controller_path) as TrackedChassisController
	if _motion_client != null:
		if not _motion_client.pose_cleared.is_connected(_on_pose_cleared):
			_motion_client.pose_cleared.connect(_on_pose_cleared)
		if not _motion_client.authority_changed.is_connected(_on_authority_changed):
			_motion_client.authority_changed.connect(_on_authority_changed)
	if not _presentation.model_activated.is_connected(_on_model_activated):
		_presentation.model_activated.connect(_on_model_activated)
	if not terrain_world.world_reset.is_connected(_on_world_reset):
		terrain_world.world_reset.connect(_on_world_reset)
	_initialized = true
	excavation_changed.emit(get_status_snapshot())


func _physics_process(delta: float) -> void:
	if soil_state == null or terrain_scheduler == null:
		return
	if automatic_soil_enabled:
		_step_automatic_interaction(delta)
	var soil_result := soil_state.step_fixed()
	_last_flow_volume_m3 = float(soil_result.get("cut_volume_m3", 0.0)) + float(soil_result.get("deposit_volume_m3", 0.0))
	var cells_changed := _settle_bucket_cells(delta)
	var commit_result := terrain_scheduler.step_fixed(delta)
	soil_state.reconcile_transfers(
		commit_result.get("committed_transfer_ids", []),
		commit_result.get("rejected_transfer_ids", [])
	)
	_queue_backend_feedback()
	if bool(soil_result.get("changed", false)) or cells_changed or bool(commit_result.get("changed", false)):
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
	if soil_state == null or terrain_scheduler == null:
		return {"changed": false, "reason": "unavailable"}
	var result := soil_state.step_fixed()
	_last_flow_volume_m3 = float(result.get("cut_volume_m3", 0.0)) + float(result.get("deposit_volume_m3", 0.0))
	var commit := terrain_scheduler.step_fixed(0.0, true)
	soil_state.reconcile_transfers(
		commit.get("committed_transfer_ids", []),
		commit.get("rejected_transfer_ids", [])
	)
	result["bucket_volume_m3"] = soil_state.bucket_volume_m3
	result["terrain_committed"] = bool(commit.get("changed", false))
	result["terrain_commit"] = commit
	if bool(result.get("changed", false)) or bool(commit.get("changed", false)):
		excavation_changed.emit(get_status_snapshot())
	return result


func request_dig() -> bool:
	if not debug_manual_controls:
		return false
	var snapshot := _sample_bucket_pose()
	if not bool(snapshot.get("valid", false)):
		return false
	var previous: Dictionary = snapshot["previous"]
	var current: Dictionary = snapshot["current"]
	var accepted := queue_cut_world(
		_next_command_sequence,
		(previous["cutting_edge"] as Transform3D).origin,
		(current["cutting_edge"] as Transform3D).origin
	)
	if accepted:
		step_fixed_for_test()
	return accepted


func request_deposit() -> bool:
	if not debug_manual_controls:
		return false
	var snapshot := _sample_bucket_pose()
	if snapshot.is_empty():
		return false
	var current: Dictionary = snapshot.get("current", {})
	if not current.has("opening"):
		return false
	var accepted := queue_deposit_world(_next_command_sequence, (current["opening"] as Transform3D).origin)
	if accepted:
		step_fixed_for_test()
	return accepted


func reset_for_test() -> void:
	if terrain_scheduler == null:
		return
	terrain_scheduler.reset_world()
	excavation_changed.emit(get_status_snapshot())


func set_automatic_soil_enabled(value: bool) -> void:
	if automatic_soil_enabled == value:
		return
	automatic_soil_enabled = value
	_clear_local_material("feature_toggle")


func set_backend_feedback_enabled(value: bool) -> void:
	backend_feedback_enabled = value
	if not value and _motion_client != null:
		_motion_client.clear_bucket_load_feedback()


func get_status_snapshot() -> Dictionary:
	var status := soil_state.get_status_snapshot() if soil_state != null else {"bucket_volume_m3": 0.0, "world_generation": -1}
	status["authority_generation"] = authority_generation
	status["automatic_soil_enabled"] = automatic_soil_enabled
	status["debug_manual_controls"] = debug_manual_controls
	status["hero_clods_enabled"] = hero_clods_enabled
	status["backend_feedback_enabled"] = backend_feedback_enabled
	status["interaction_state"] = _last_interaction
	status["material_generation"] = _material_generation
	status["flow_volume_m3"] = _last_flow_volume_m3
	status["bucket_pose"] = _last_pose_snapshot.duplicate(true)
	status["support_contact"] = _last_support.duplicate(true)
	status["terrain_commit"] = terrain_scheduler.get_status_snapshot() if terrain_scheduler != null else {}
	status["collider_available"] = terrain_collider != null and terrain_collider.available
	status["collider_enabled"] = terrain_collider != null and terrain_collider.enabled
	status["terrain3d"] = terrain_world.terrain3d_adapter.get_status_snapshot() if terrain_world != null and terrain_world.terrain3d_adapter != null else {"enabled": false, "available": false}
	status["physics_fail_open"] = true
	return status


func get_bucket_pose_snapshot_for_test() -> Dictionary:
	return _last_pose_snapshot.duplicate(true)


func step_automatic_snapshot_for_test(snapshot: Dictionary, delta: float = 1.0 / 60.0) -> Dictionary:
	if soil_state == null or terrain_scheduler == null:
		return {"changed": false, "reason": "unavailable"}
	_process_bucket_snapshot(snapshot, delta)
	var soil_result := soil_state.step_fixed()
	_last_flow_volume_m3 = float(soil_result.get("cut_volume_m3", 0.0)) + float(soil_result.get("deposit_volume_m3", 0.0))
	_settle_bucket_cells(delta)
	var commit_result := terrain_scheduler.step_fixed(delta, true)
	soil_state.reconcile_transfers(
		commit_result.get("committed_transfer_ids", []),
		commit_result.get("rejected_transfer_ids", [])
	)
	var result := get_status_snapshot()
	result["changed"] = bool(soil_result.get("changed", false)) or bool(commit_result.get("changed", false))
	result["terrain_commit_result"] = commit_result
	excavation_changed.emit(result)
	return result


func _bucket_tooth_world() -> Variant:
	if _presentation == null:
		return null
	var contract := _presentation.get_soil_contract()
	var cutting: Dictionary = (contract.get("proxies", {}) as Dictionary).get("cutting_edge", {})
	var raw_center: Variant = cutting.get("center_godot", [])
	var frame := _presentation.get_frame_node(String(cutting.get("frame", "bucket_link")))
	if frame == null or not raw_center is Array or (raw_center as Array).size() != 3:
		return null
	var center := Vector3(float(raw_center[0]), float(raw_center[1]), float(raw_center[2]))
	return frame.global_transform * center


func get_soil_visual_snapshot() -> Dictionary:
	var status := soil_state.get_status_snapshot() if soil_state != null else {}
	return {
		"world_generation": int(status.get("world_generation", -1)),
		"authority_generation": authority_generation,
		"material_generation": _material_generation,
		"fill_ratio": float(status.get("fill_ratio", 0.0)),
		"fill_profile": status.get("fill_profile", PackedFloat32Array()),
		"cell_grid": status.get("cell_grid", [1, 1, 1]),
		"center_of_mass_local": status.get("center_of_mass_local", Vector3.ZERO),
		"flow_volume_m3": _last_flow_volume_m3,
		"interaction_state": _last_interaction,
		"hero_clods_enabled": hero_clods_enabled,
		"bucket_pose": _last_pose_snapshot.duplicate(true),
	}


func _step_automatic_interaction(delta: float) -> void:
	var snapshot := _sample_bucket_pose()
	_process_bucket_snapshot(snapshot, delta)


func _process_bucket_snapshot(snapshot: Dictionary, delta: float) -> void:
	_last_pose_snapshot = snapshot.duplicate(true)
	if not bool(snapshot.get("valid", false)):
		_last_interaction = "no_pose"
		_last_support = {"active": false, "penetration_m": 0.0}
		_last_raw_support_point = Vector3.ZERO
		_has_raw_support_point = false
		if _tracked_chassis_controller != null:
			_tracked_chassis_controller.clear_bucket_support_contact()
		return
	var previous: Dictionary = snapshot["previous"]
	var current: Dictionary = snapshot["current"]
	var previous_cutting := previous["cutting_edge"] as Transform3D
	var current_cutting := current["cutting_edge"] as Transform3D
	var movement := current_cutting.origin - previous_cutting.origin
	var contract: Dictionary = snapshot["contract"]
	var interaction: Dictionary = contract.get("interaction", {})
	_update_support_contact(snapshot, current, contract)
	var deposit_center: Variant = _settled_deposit_center((current["opening"] as Transform3D).origin)
	var opening_down_dot := (snapshot["opening_normal_world"] as Vector3).dot(Vector3.DOWN)
	var dump_threshold := float(interaction.get("dump_opening_down_dot", 0.3))
	if deposit_center is Vector3 and soil_state.bucket_volume_m3 > BucketSoilState.EPSILON_M3 and opening_down_dot > dump_threshold:
		var dump_rate := soil_state.bucket_capacity_m3 * lerpf(0.35, 1.4, clampf((opening_down_dot - dump_threshold) / maxf(0.01, 1.0 - dump_threshold), 0.0, 1.0))
		var requested := minf(soil_state.bucket_volume_m3, dump_rate * delta)
		if soil_state.queue_deposit_volume(_next_command_sequence, deposit_center as Vector3, requested):
			_next_command_sequence += 1
			_last_interaction = "dump"
			return
	var spill_threshold := float(interaction.get("spill_opening_down_dot", dump_threshold - 0.25))
	var fill_ratio := soil_state.bucket_volume_m3 / maxf(soil_state.nominal_capacity_m3, BucketSoilState.EPSILON_M3)
	if deposit_center is Vector3 and soil_state.bucket_volume_m3 > BucketSoilState.EPSILON_M3 and opening_down_dot > spill_threshold and fill_ratio > 0.45:
		var exposure := clampf((opening_down_dot - spill_threshold) / maxf(0.01, dump_threshold - spill_threshold), 0.0, 1.0)
		var spill_rate := soil_state.bucket_capacity_m3 * lerpf(0.04, 0.22, exposure)
		var spill_volume := minf(soil_state.bucket_volume_m3, spill_rate * delta)
		if soil_state.queue_deposit_volume(_next_command_sequence, deposit_center as Vector3, spill_volume):
			_next_command_sequence += 1
			_last_interaction = "spill"
			return
	var minimum_sweep := float(interaction.get("minimum_sweep_m", 0.004))
	if movement.length() < minimum_sweep:
		_last_interaction = "carry" if soil_state.bucket_volume_m3 > BucketSoilState.EPSILON_M3 else "idle"
		return
	var center_xz := Vector2(current_cutting.origin.x, current_cutting.origin.z)
	if not terrain_world.terrain_state.is_inside_grid(center_xz):
		_last_interaction = "outside_grid"
		return
	var surface := terrain_world.terrain_state.sample_surface_bilinear_at(center_xz)
	var tolerance := float(interaction.get("contact_tolerance_m", BucketSoilState.CONTACT_TOLERANCE_M))
	var in_contact := not is_nan(surface) and current_cutting.origin.y <= surface + tolerance
	var cutting_direction := snapshot["cutting_direction_world"] as Vector3
	var forward_cut := movement.normalized().dot(cutting_direction) > 0.12
	var downward_cut := movement.y < -minimum_sweep * 0.35
	if in_contact and (forward_cut or downward_cut):
		if soil_state.queue_cut(_next_command_sequence, previous_cutting.origin, current_cutting.origin):
			_next_command_sequence += 1
			_last_interaction = "cut"
			return
	_last_interaction = "push" if in_contact else ("carry" if soil_state.bucket_volume_m3 > BucketSoilState.EPSILON_M3 else "idle")


func _update_support_contact(snapshot: Dictionary, current: Dictionary, contract: Dictionary) -> void:
	var support_transform := current["rear_support"] as Transform3D
	var raw_support_transform := support_transform
	if _tracked_chassis_controller != null:
		raw_support_transform = _tracked_chassis_controller.raw_world_transform(support_transform)
	var center_xz := Vector2(raw_support_transform.origin.x, raw_support_transform.origin.z)
	var surface := terrain_world.terrain_state.sample_surface_bilinear_at(center_xz)
	var support_contract: Dictionary = (contract.get("proxies", {}) as Dictionary).get("rear_support", {})
	var radius := float(support_contract.get("radius_m", 0.0))
	var penetration := 0.0 if is_nan(surface) else maxf(0.0, surface + radius - raw_support_transform.origin.y)
	var movement := raw_support_transform.origin - _last_raw_support_point if _has_raw_support_point else Vector3.ZERO
	var penetration_delta := penetration - float(_last_support.get("penetration_m", 0.0))
	var cutting_direction := snapshot.get("cutting_direction_world", Vector3.DOWN) as Vector3
	var opening_normal := snapshot.get("opening_normal_world", Vector3.UP) as Vector3
	var classification := BucketGroundLiftReaction.classify_contact(
		penetration,
		penetration_delta,
		movement,
		Vector3.UP,
		cutting_direction,
		opening_normal,
		bool(_last_support.get("eligible", false))
	)
	var eligible := bool(classification.get("eligible", false))
	_last_support = {
		"active": penetration > 0.0,
		"eligible": eligible,
		"classification": String(classification.get("classification", "invalid")),
		"penetration_m": penetration,
		"point_world": raw_support_transform.origin,
		"movement_world": movement,
		"surface_y": surface,
		"terrain_normal_world": Vector3.UP,
		"opening_down_dot": opening_normal.dot(Vector3.DOWN),
		"model_id": _presentation.get_active_model_id() if _presentation != null else "",
		"authority_generation": authority_generation,
		"physics_hint_status": "heightfield_fallback",
	}
	_last_raw_support_point = raw_support_transform.origin
	_has_raw_support_point = true
	if _tracked_chassis_controller != null:
		_tracked_chassis_controller.submit_bucket_support_contact(_last_support)


func _sample_bucket_pose() -> Dictionary:
	if _presentation == null or terrain_world == null or terrain_world.terrain_state == null:
		return {"valid": false, "reason": "unavailable"}
	return _presentation.sample_bucket_pose_fixed(terrain_world.terrain_state.world_generation, authority_generation)


func _settle_bucket_cells(delta: float) -> bool:
	var current: Dictionary = _last_pose_snapshot.get("current", {})
	if not current.has("cavity"):
		return false
	return soil_state.settle_cells(current["cavity"] as Transform3D, delta)


func _queue_backend_feedback() -> void:
	if not backend_feedback_enabled or _motion_client == null or soil_state == null:
		return
	var status := soil_state.get_status_snapshot()
	var interaction := soil_state.soil_contract.get("interaction", {}) as Dictionary
	var maximum_depth := float(interaction.get("maximum_cut_depth_m", 0.08))
	var penetration := float(_last_support.get("penetration_m", 0.0))
	_motion_client.queue_bucket_load_feedback(
		{
			"world_generation": int(status.get("world_generation", 0)),
			"authority_generation": authority_generation,
			"payload_mass_kg": float(status.get("payload_mass_kg", 0.0)),
			"center_of_mass_local": status.get("center_of_mass_local", Vector3.ZERO),
			"fill_ratio": clampf(float(status.get("fill_ratio", 0.0)), 0.0, 1.5),
			"resistance": clampf(penetration / maxf(maximum_depth, 0.001), 0.0, 1.0),
			"quality": feedback_quality,
		}
	)


func _settled_deposit_center(opening_world: Vector3) -> Variant:
	var center_xz := Vector2(opening_world.x, opening_world.z)
	if not terrain_world.terrain_state.is_inside_grid(center_xz):
		return null
	var surface := terrain_world.terrain_state.sample_surface_bilinear_at(center_xz)
	if is_nan(surface):
		return null
	return Vector3(opening_world.x, maxf(opening_world.y, surface + BucketSoilState.DUMP_CLEARANCE_M), opening_world.z)


func _on_pose_cleared(generation: int, _reason: String) -> void:
	authority_generation = maxi(authority_generation, generation)
	_clear_local_material("pose_cleared")


func _on_authority_changed(_session_id: String, _simulation_epoch: String, generation: int) -> void:
	_on_pose_cleared(generation, "authority_generation")


func _on_model_activated(_model_id: String, _asset_root: Node3D) -> void:
	_sync_local_tooth_offset(_presentation.get_soil_contract())
	if soil_state != null:
		soil_state.configure_contract(_presentation.get_soil_contract())
	_clear_local_material("model_activated")


func _sync_local_tooth_offset(contract: Dictionary) -> void:
	var cutting: Dictionary = (contract.get("proxies", {}) as Dictionary).get("cutting_edge", {})
	var raw_center: Variant = cutting.get("center_godot", [])
	if raw_center is Array and (raw_center as Array).size() == 3:
		local_tooth_offset = Vector3(float(raw_center[0]), float(raw_center[1]), float(raw_center[2]))


func _on_world_reset(generation: int) -> void:
	if terrain_scheduler != null:
		terrain_scheduler.reset_for_generation(generation)
	if soil_state != null:
		soil_state.reset_for_generation(generation)
	_next_command_sequence = 0
	_last_pose_snapshot.clear()
	_last_interaction = "reset"
	_last_support = {"active": false, "penetration_m": 0.0}
	_last_raw_support_point = Vector3.ZERO
	_has_raw_support_point = false
	if _tracked_chassis_controller != null:
		_tracked_chassis_controller.clear_bucket_support_contact()
	_last_flow_volume_m3 = 0.0
	if _motion_client != null:
		_motion_client.clear_bucket_load_feedback()
	_material_generation += 1
	if _presentation != null:
		_presentation.clear_bucket_pose_history()
	excavation_changed.emit(get_status_snapshot())


func _clear_local_material(reason: String) -> void:
	if terrain_world != null and terrain_world.terrain_state != null:
		if terrain_scheduler != null:
			terrain_scheduler.reset_for_generation(terrain_world.terrain_state.world_generation)
		if soil_state != null:
			soil_state.reset_for_generation(terrain_world.terrain_state.world_generation)
	_last_pose_snapshot.clear()
	_last_interaction = reason
	_last_support = {"active": false, "penetration_m": 0.0}
	_last_raw_support_point = Vector3.ZERO
	_has_raw_support_point = false
	if _tracked_chassis_controller != null:
		_tracked_chassis_controller.clear_bucket_support_contact()
	_last_flow_volume_m3 = 0.0
	if _motion_client != null:
		_motion_client.clear_bucket_load_feedback()
	_material_generation += 1
	if _presentation != null:
		_presentation.clear_bucket_pose_history()
	excavation_changed.emit(get_status_snapshot())

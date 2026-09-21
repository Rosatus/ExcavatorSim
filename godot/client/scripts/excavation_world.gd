class_name ExcavationWorld
extends Node3D

signal excavation_changed(status: Dictionary)
signal performance_step_sampled(sample: Dictionary)

const SOIL_PROXY_ORDER := ["cutting_edge", "opening", "cavity", "shell", "rear_support"]
const VoxelAuthority = preload("res://scripts/voxel_excavation_authority.gd")
const TEST_BUCKET_CAPACITY_M3 := 1000.0

@export var terrain_world_path := NodePath("../TerrainWorld")
@export var terrain_collider_path := NodePath("../TerrainCollider")
@export var voxel_work_zone_path := NodePath("../VoxelWorkZone")
@export var motion_presentation_path := NodePath("../../MotionPresentation")
@export var motion_client_path := NodePath("../../MotionClient")
@export var tracked_chassis_controller_path := NodePath("../../ChassisMotionRoot")
@export var soil_effects_path := NodePath("../../SoilEffects")
@export var automatic_soil_enabled := true
@export var simulation_enabled := true
@export var debug_manual_controls := false
@export var hero_clods_enabled := true
@export var backend_feedback_enabled := false
@export var soil_tool_shadow_enabled := false
@export var active_soil_patch_prototype_enabled := false
@export var voxel_unlimited_bucket_for_testing := false
@export var voxel_diagnostics_enabled := false
@export_enum("loose", "compact", "sand", "damp") var active_soil_material_preset := "loose"
@export_enum("voxel") var soil_material_lifecycle_mode := "voxel"
## Keep the existing product writer selected until the v2 release candidate has
## completed its manual digging gate. Shadow/owner requests apply only at a
## clean material-generation boundary through the setter below.
@export_enum("voxel_bucket_v1") var soil_surface_solver_mode := "voxel_bucket_v1"
@export_enum("low", "balanced", "high") var feedback_quality := "balanced"
@export var local_tooth_offset := Vector3(0.0, -0.55, 0.0)

var terrain_world: TerrainWorld
var performance_capture_enabled := false
var terrain_collider: TerrainCollider
var voxel_work_zone: VoxelWorkZone
var terrain_scheduler: TerrainCommitScheduler
var soil_state: BucketSoilState
var authority_generation := 0

var _presentation: MotionPresentation
var _motion_client: MotionClient
var _tracked_chassis_controller: TrackedChassisController
var _soil_effects: SoilEffects
var _next_command_sequence := 0
var _last_pose_snapshot: Dictionary = {}
var _last_interaction := "idle"
var _last_support: Dictionary = {"active": false, "penetration_m": 0.0}
var _last_flow_volume_m3 := 0.0
var _last_raw_support_point := Vector3.ZERO
var _has_raw_support_point := false
var _material_generation := 0
var _initialized := false
var _last_interaction_batch: Dictionary = {}
var _consumed_batch_keys: Dictionary = {}
var _consumed_batch_order: Array[String] = []
var _parcel_pool: SoilParcelPool
var _soil_tool_classifier := BucketSoilTool.new()
var _bucket_surface_sweep := BucketSurfaceSweep.new()
var _active_soil_patch: ActiveSoilPatch
var _active_soil_presenter: ActiveSoilPatchPresenter
var _active_soil_event_sequence := 0
var _soil_interaction_authority: SoilInteractionAuthority
var _arcade_stamp: ArcadeExcavationStamp
var _voxel_authority: VoxelExcavationAuthority
var _soil_lifecycle_tick := -1
var _soil_authority_modes := SoilAuthorityModeController.new()
var _bucket_ground_mode := BucketGroundInteractionMode.NORMAL
var _bucket_ground_transition_count := 0
var _bucket_ground_bypass_ticks := 0
var _bucket_ground_execution_ticks := 0
var _automatic_samples_executed := 0
var _automatic_samples_bypassed := 0
var _soil_steps_executed := 0
var _soil_steps_bypassed := 0
var _terrain_commits_executed := 0
var _terrain_commits_bypassed := 0
var _parcel_steps_executed := 0
var _parcel_steps_bypassed := 0
var _last_bucket_ground_transition: Dictionary = {}
var _last_voxel_capacity_override_error := ""


func _ready() -> void:
	process_physics_priority = 20
	_initialize()


func _initialize() -> void:
	if not simulation_enabled:
		return
	if _initialized:
		return
	terrain_world = get_node_or_null(terrain_world_path) as TerrainWorld
	terrain_collider = get_node_or_null(terrain_collider_path) as TerrainCollider
	voxel_work_zone = get_node_or_null(voxel_work_zone_path) as VoxelWorkZone
	_presentation = get_node_or_null(motion_presentation_path) as MotionPresentation
	if terrain_world == null or terrain_world.terrain_state == null or _presentation == null:
		call_deferred("_initialize")
		return
	var contract := _presentation.get_soil_contract()
	if contract.is_empty():
		call_deferred("_initialize")
		return
	_sync_local_tooth_offset(contract)
	_soil_tool_classifier.configure(contract)
	_motion_client = get_node_or_null(motion_client_path) as MotionClient
	_tracked_chassis_controller = get_node_or_null(tracked_chassis_controller_path) as TrackedChassisController
	_soil_effects = get_node_or_null(soil_effects_path) as SoilEffects
	if _motion_client != null:
		if not _motion_client.pose_cleared.is_connected(_on_pose_cleared):
			_motion_client.pose_cleared.connect(_on_pose_cleared)
		if not _motion_client.authority_changed.is_connected(_on_authority_changed):
			_motion_client.authority_changed.connect(_on_authority_changed)
	if not _presentation.model_activated.is_connected(_on_model_activated):
		_presentation.model_activated.connect(_on_model_activated)
	if not _presentation.attachment_changed.is_connected(_on_attachment_changed):
		_presentation.attachment_changed.connect(_on_attachment_changed)
	if not terrain_world.world_reset.is_connected(_on_world_reset):
		terrain_world.world_reset.connect(_on_world_reset)
	_soil_authority_modes.set_requested_mode(soil_material_lifecycle_mode)
	_soil_authority_modes.set_requested_solver_mode(soil_surface_solver_mode)
	_initialized = true
	_begin_soil_authority_generation("initialize")
	excavation_changed.emit(get_status_snapshot())


func _physics_process(delta: float) -> void:
	if not _initialized:
		return
	if _bucket_ground_bypassed():
		_bucket_ground_bypass_ticks += 1
		_automatic_samples_bypassed += 1
		_soil_steps_bypassed += 1
		_terrain_commits_bypassed += 1
		_parcel_steps_bypassed += 1
		return
	_bucket_ground_execution_ticks += 1
	if _selected_soil_mode() == "voxel":
		if _voxel_authority == null or not _soil_authority_modes.can_product_owner_write("voxel"):
			return
		var capture_start := Time.get_ticks_usec() if performance_capture_enabled else 0
		if performance_capture_enabled:
			# Disabled automatic soil or rejected pose identities may skip cutter
			# submission entirely. Never attribute the prior tick's phases again.
			_voxel_authority.cutter.performance_sample.clear()
		# Voxel falling-soil presentation is driven by committed one-shot release
		# events. Never keep a cut/deposit volume sticky across idle frames.
		_last_flow_volume_m3 = 0.0
		# Product soil model has no track compaction; dumped soil is stable immediately.
		if automatic_soil_enabled:
			_automatic_samples_executed += 1
			_step_automatic_interaction(delta)
		var capture_after_input := Time.get_ticks_usec() if performance_capture_enabled else 0
		_soil_steps_executed += 1
		var voxel_result := _voxel_authority.step_fixed(delta)
		var capture_after_step := Time.get_ticks_usec() if performance_capture_enabled else 0
		if bool(voxel_result.get("changed", false)):
			var transaction := voxel_result.get("transaction", {}) as Dictionary
			_last_interaction = "dump" if String(transaction.get("operation", "cut")) == "deposit" else String(transaction.get("operation", "cut"))
		if bool(voxel_result.get("changed", false)) or bool(voxel_result.get("release_changed", false)):
			excavation_changed.emit(get_status_snapshot())
		_queue_backend_feedback()
		if performance_capture_enabled:
			var capture_end := Time.get_ticks_usec()
			performance_step_sampled.emit({
				"physics_frame": Engine.get_physics_frames(),
				"process_frame": Engine.get_process_frames(),
				"ended_usec": capture_end,
				"automatic_usec": capture_after_input - capture_start,
				"step_usec": capture_after_step - capture_after_input,
				"publish_usec": capture_end - capture_after_step,
				"total_usec": capture_end - capture_start,
				"transaction": voxel_result.get("transaction", {}),
				"cutter_phases": _voxel_authority.cutter.performance_sample,
			})
		return


func queue_cut_world(sequence: int, previous_tooth: Vector3, current_tooth: Vector3) -> bool:
	if _bucket_ground_bypassed() or soil_state == null or _selected_soil_mode() in ["active_patch", "voxel"]:
		return false
	_next_command_sequence = maxi(_next_command_sequence, sequence + 1)
	return soil_state.queue_cut(sequence, previous_tooth, current_tooth)


func queue_deposit_world(sequence: int, center: Vector3) -> bool:
	if _bucket_ground_bypassed() or soil_state == null or _selected_soil_mode() in ["active_patch", "voxel"]:
		return false
	_next_command_sequence = maxi(_next_command_sequence, sequence + 1)
	return soil_state.queue_deposit(sequence, center)


func step_fixed_for_test() -> Dictionary:
	if _bucket_ground_bypassed():
		_soil_steps_bypassed += 1
		_terrain_commits_bypassed += 1
		return {"changed": false, "reason": "bucket_ground_interaction_bypassed"}
	if _selected_soil_mode() == "voxel":
		return _voxel_authority.step_fixed(1.0 / 60.0) if _voxel_authority != null else {"changed": false, "reason": "unavailable"}
	return {"changed": false, "reason": "unavailable"}


func request_dig() -> bool:
	if _bucket_ground_bypassed() or not debug_manual_controls:
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
	if _bucket_ground_bypassed() or not debug_manual_controls:
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
	if _selected_soil_mode() == "voxel" and terrain_world != null:
		terrain_world.reset_for_test()
		return
	if terrain_scheduler == null:
		return
	terrain_scheduler.reset_world()
	excavation_changed.emit(get_status_snapshot())


func set_automatic_soil_enabled(value: bool) -> void:
	if automatic_soil_enabled == value:
		return
	automatic_soil_enabled = value
	_clear_local_material("feature_toggle")


func can_set_bucket_ground_mode(value: String) -> bool:
	return BucketGroundInteractionMode.is_valid(value) and _initialized and _soil_effects != null


func set_bucket_ground_mode(value: String) -> bool:
	if not can_set_bucket_ground_mode(value):
		return false
	if _bucket_ground_mode == value:
		return true
	var previous_mode := _bucket_ground_mode
	var previous_payload := get_selected_soil_payload_snapshot()
	var terrain_identity := _terrain_identity_snapshot()
	_bucket_ground_mode = value
	_soil_effects.set_bucket_ground_mode(value)
	_clear_local_material("bucket_ground_mode_transition")
	_bucket_ground_transition_count += 1
	_last_bucket_ground_transition = {
		"from": previous_mode,
		"to": value,
		"cleared_payload_mass_kg": float(previous_payload.get("payload_mass_kg", 0.0)),
		"cleared_bucket_volume_m3": float(previous_payload.get("bucket_volume_m3", 0.0)),
		"terrain_identity_before": terrain_identity,
		"terrain_identity_after": _terrain_identity_snapshot(),
		"material_generation": _material_generation,
	}
	print("Bucket-ground mode transition: %s" % JSON.stringify(_last_bucket_ground_transition))
	return true


func can_set_voxel_unlimited_bucket_for_testing() -> bool:
	return _selected_soil_mode() == "voxel" \
		and _voxel_authority != null and _voxel_authority.configured


func set_voxel_unlimited_bucket_for_testing(enabled: bool) -> bool:
	if not can_set_voxel_unlimited_bucket_for_testing():
		_last_voxel_capacity_override_error = "voxel_authority_unavailable"
		return false
	var capacity_override := TEST_BUCKET_CAPACITY_M3 if enabled else 0.0
	var result := _voxel_authority.set_bucket_capacity_override_for_testing(capacity_override)
	if not bool(result.get("accepted", false)):
		_last_voxel_capacity_override_error = String(result.get("reason", "capacity_override_rejected"))
		excavation_changed.emit(get_status_snapshot())
		return false
	voxel_unlimited_bucket_for_testing = enabled
	_last_voxel_capacity_override_error = ""
	excavation_changed.emit(get_status_snapshot())
	return true


func set_backend_feedback_enabled(value: bool) -> void:
	backend_feedback_enabled = value
	if not value and _motion_client != null:
		_motion_client.clear_bucket_load_feedback()


func set_voxel_diagnostics_enabled(enabled: bool) -> void:
	voxel_diagnostics_enabled = enabled
	if _voxel_authority != null:
		_voxel_authority.set_diagnostics_enabled(enabled)
	elif voxel_work_zone != null:
		voxel_work_zone.readiness.set_diagnostics_enabled(enabled)
	excavation_changed.emit(get_status_snapshot())


func set_performance_capture_enabled(enabled: bool) -> void:
	performance_capture_enabled = enabled
	if _voxel_authority != null:
		_voxel_authority.performance_timing_enabled = enabled


func get_performance_context() -> Dictionary:
	# Recorder calls at four Hz, never once per rendered frame. Keep the general
	# world/UI projection (and its unrelated subsystem snapshots) out of this path.
	if _voxel_authority == null:
		return {"available": false}
	var status := _voxel_authority.get_status_snapshot()
	var result := {
		"available": true, "voxel_scale_m": voxel_work_zone.voxel_scale_m if voxel_work_zone != null else 0.0,
		"automatic_soil_enabled": automatic_soil_enabled, "bucket_ground_bypassed": _bucket_ground_bypassed(),
		"unlimited_bucket_for_testing": voxel_unlimited_bucket_for_testing, "diagnostics_enabled": voxel_diagnostics_enabled,
	}
	for key in ["model_id", "generation", "data_revision", "mesh_revision", "collision_revision", "queue_depth", "pending_readiness_count", "readiness_timed_out", "committed", "rejected", "engaged", "bucket_mass_q", "fill_ratio", "conservation_error_q", "phase_timings_usec", "voxel_statistics", "readiness"]:
		result[key] = status.get(key)
	# Full diagnostics remain at the user's setting. Capture only observes these
	# low-rate counters; it does not enable per-transaction SDF digests or sorting.
	if not voxel_diagnostics_enabled and voxel_work_zone != null:
		result["voxel_statistics"] = voxel_work_zone.terrain.get_statistics() if voxel_work_zone.terrain != null else {}
		result["readiness"] = voxel_work_zone.readiness.get_status_snapshot()
	return result


func set_soil_tool_shadow_enabled(value: bool) -> void:
	soil_tool_shadow_enabled = value
	if not value:
		_last_interaction_batch.erase("soil_tool_shadow")


func set_active_soil_patch_prototype_enabled(_value: bool) -> void:
	active_soil_patch_prototype_enabled = false
	_reset_active_soil_patch(false)


func set_soil_material_lifecycle_mode(value: String) -> bool:
	if value not in SoilAuthorityModeController.MODES:
		return false
	soil_material_lifecycle_mode = value
	if not _soil_authority_modes.set_requested_mode(value):
		return false
	excavation_changed.emit(get_status_snapshot())
	return true


func set_soil_surface_solver_mode(value: String) -> bool:
	if value not in SoilAuthorityModeController.SOLVER_MODES:
		return false
	if value == soil_surface_solver_mode and (not _initialized or _selected_soil_solver_mode() == value):
		return true
	soil_surface_solver_mode = value
	if not _soil_authority_modes.set_requested_solver_mode(value):
		return false
	# Solver ownership is generation-bound. A public runtime change must not
	# report success while silently leaving the old selected writer active;
	# drain ordinary material, clear pose history and begin one clean generation.
	if _initialized and _selected_soil_solver_mode() != value:
		return _clear_local_material("solver_mode_change")
	excavation_changed.emit(get_status_snapshot())
	return true


func get_status_snapshot() -> Dictionary:
	var legacy_status := soil_state.get_status_snapshot() if soil_state != null else {"bucket_volume_m3": 0.0, "world_generation": -1}
	var lifecycle_status := _soil_interaction_authority.get_status_snapshot() if _soil_interaction_authority != null else {"configured": false}
	var arcade_status := _arcade_stamp.get_status_snapshot() if _arcade_stamp != null else {"configured": false}
	var voxel_status := _voxel_authority.get_status_snapshot() if _voxel_authority != null else {"configured": false}
	var status := legacy_status.duplicate(true)
	if _selected_soil_mode() == "voxel" and bool(voxel_status.get("configured", false)):
		status = voxel_status.duplicate(true)
	elif _is_arcade_stamp_selected() and bool(arcade_status.get("configured", false)):
		status = arcade_status.duplicate(true)
	elif _selected_soil_mode() == "active_patch" and bool(lifecycle_status.get("configured", false)):
		status = lifecycle_status.duplicate(true)
	var selected_payload := get_selected_soil_payload_snapshot()
	status["world_generation"] = terrain_world.terrain_state.world_generation if terrain_world != null and terrain_world.terrain_state != null else int(status.get("world_generation", -1))
	status["authority_generation"] = authority_generation
	status["automatic_soil_enabled"] = automatic_soil_enabled
	status["debug_manual_controls"] = debug_manual_controls
	status["hero_clods_enabled"] = hero_clods_enabled
	status["backend_feedback_enabled"] = backend_feedback_enabled
	status["soil_tool_shadow_enabled"] = soil_tool_shadow_enabled
	status["active_soil_patch_prototype_enabled"] = active_soil_patch_prototype_enabled
	status["soil_material_lifecycle_mode"] = _selected_soil_mode()
	status["requested_soil_material_lifecycle_mode"] = soil_material_lifecycle_mode
	status["soil_surface_solver_mode"] = _selected_soil_solver_mode()
	status["requested_soil_surface_solver_mode"] = soil_surface_solver_mode
	status["voxel_unlimited_bucket_for_testing"] = voxel_unlimited_bucket_for_testing
	status["voxel_diagnostics_enabled"] = voxel_diagnostics_enabled
	status["voxel_unlimited_bucket_toggle_available"] = can_set_voxel_unlimited_bucket_for_testing()
	status["voxel_capacity_override_error"] = _last_voxel_capacity_override_error
	status["soil_authority_mode"] = (
		"visual_first_arcade_stamp"
		if _is_arcade_stamp_selected()
		else {
			"shadow": "conservative_shadow",
			"active_patch": "conservative_active_patch",
			"voxel": "voxel_bucket_authority",
		}.get(_selected_soil_mode(), "legacy_analytic_parcel")
	)
	status["soil_authority_selection"] = _soil_authority_modes.get_status_snapshot()
	status["arcade_stamp"] = arcade_status
	status["voxel_excavation"] = voxel_status
	status["active_soil_patch"] = _active_soil_patch.get_status_snapshot() if _active_soil_patch != null else {"configured": false}
	status["soil_lifecycle_shadow"] = lifecycle_status.duplicate(true) if _selected_soil_mode() == "shadow" else {"configured": false, "mode": "legacy"}
	status["soil_lifecycle_active"] = lifecycle_status.duplicate(true) if _selected_soil_mode() == "active_patch" and not _is_arcade_stamp_selected() else {"configured": false, "mode": "legacy"}
	status["legacy_soil_status"] = legacy_status
	status["legacy_runtime_constructed"] = soil_state != null or terrain_scheduler != null
	status["parcel_runtime_constructed"] = _parcel_pool != null
	status["selected_soil_payload"] = selected_payload
	status["selected_soil_ledger_identity"] = String(selected_payload.get("ledger_identity", "legacy:unavailable"))
	var lifecycle_shadow := status["soil_lifecycle_shadow"] as Dictionary
	if bool(lifecycle_shadow.get("configured", false)):
		var legacy_volume := float(status.get("bucket_volume_m3", 0.0))
		var shadow_volume := float(lifecycle_shadow.get("bucket_volume_m3", 0.0))
		status["soil_lifecycle_comparison"] = {
			"selected_source": String(selected_payload.get("source", "legacy")),
			"legacy_ledger_identity": "legacy:%d:%d" % [int(legacy_status.get("world_generation", -1)), int(legacy_status.get("last_applied_sequence", -1))],
			"shadow_ledger_identity": String(lifecycle_shadow.get("ledger_identity", "shadow:unavailable")),
			"legacy_bucket_volume_m3": legacy_volume,
			"shadow_bucket_volume_m3": shadow_volume,
			"bucket_volume_delta_m3": shadow_volume - legacy_volume,
			"legacy_payload_mass_kg": float(legacy_status.get("payload_mass_kg", 0.0)),
			"shadow_payload_mass_kg": float(lifecycle_shadow.get("payload_mass_kg", 0.0)),
			"shadow_conservation_drift_m3": float(lifecycle_shadow.get("conservation_drift_m3", 0.0)),
			"shadow_invariant_failure_count": int(lifecycle_shadow.get("invariant_failure_count", 0)),
		}
	status["interaction_state"] = _last_interaction
	status["material_generation"] = _material_generation
	status["flow_volume_m3"] = _last_flow_volume_m3
	status["bucket_pose"] = _last_pose_snapshot.duplicate(true)
	status["support_contact"] = _last_support.duplicate(true)
	status["soil_interaction_batch"] = _last_interaction_batch.duplicate(true)
	status["terrain_commit"] = terrain_scheduler.get_status_snapshot() if terrain_scheduler != null else {}
	status["collider_available"] = terrain_collider != null and terrain_collider.available
	status["collider_enabled"] = terrain_collider != null and terrain_collider.enabled
	status["terrain3d"] = terrain_world.get_status_snapshot() if terrain_world != null else {"enabled": false, "available": false}
	status["digging_response"] = _tracked_chassis_controller.get_digging_response_snapshot() if _tracked_chassis_controller != null else {"configured": false}
	status["physics_fail_open"] = true
	status["bucket_ground_interaction"] = _bucket_ground_interaction_status()
	return status


## Lightweight per-tick input surface for the digging-response shaper and the
## simulation-truth publisher. Contains only the fields those consumers read;
## the full get_status_snapshot() aggregation remains the signal/UI surface.
func get_interaction_snapshot() -> Dictionary:
	var mode := _selected_soil_mode()
	var selected_payload := get_selected_soil_payload_snapshot()
	var lifecycle_status: Dictionary = {}
	if _soil_interaction_authority != null and mode in ["shadow", "active_patch"]:
		lifecycle_status = _soil_interaction_authority.get_status_snapshot()
	return {
		"soil_lifecycle_shadow": lifecycle_status if mode == "shadow" else {"configured": false, "mode": "legacy"},
		"soil_lifecycle_active": lifecycle_status if mode == "active_patch" and not _is_arcade_stamp_selected() else {"configured": false, "mode": "legacy"},
		"selected_soil_payload": selected_payload,
		"fill_ratio": float(selected_payload.get("fill_ratio", 0.0)),
		"bucket_volume_m3": float(selected_payload.get("bucket_volume_m3", 0.0)),
		"payload_mass_kg": float(selected_payload.get("payload_mass_kg", 0.0)),
		"center_of_mass_local": selected_payload.get("center_of_mass_local", Vector3.ZERO),
		"flow_volume_m3": _last_flow_volume_m3,
		"interaction_state": _last_interaction,
		"soil_interaction_batch": _last_interaction_batch.duplicate(true),
	}


func get_bucket_ground_interaction_snapshot() -> Dictionary:
	return _bucket_ground_interaction_status()


func is_soil_runtime_ready() -> bool:
	if not _initialized:
		return false
	if _selected_soil_mode() == "voxel":
		return _voxel_authority != null and _voxel_authority.configured
	return soil_state != null and terrain_scheduler != null


func get_selected_soil_payload_snapshot() -> Dictionary:
	if _selected_soil_mode() == "voxel" and _voxel_authority != null and _voxel_authority.configured:
		return _voxel_authority.get_payload_snapshot()
	if _is_arcade_stamp_selected() and _arcade_stamp != null:
		var arcade := _arcade_stamp.get_status_snapshot()
		if bool(arcade.get("configured", false)):
			return {
				"source": "arcade_stamp_v3",
				"ledger_identity": String(arcade.get("ledger_identity", "arcade:unavailable")),
				"world_generation": terrain_world.terrain_state.world_generation if terrain_world != null and terrain_world.terrain_state != null else int(arcade.get("generation", -1)),
				"bucket_volume_m3": float(arcade.get("bucket_volume_m3", 0.0)),
				"payload_mass_kg": float(arcade.get("payload_mass_kg", 0.0)),
				"fill_ratio": float(arcade.get("fill_ratio", 0.0)),
				"center_of_mass_local": arcade.get("center_of_mass_local", Vector3.ZERO),
				"fill_profile": arcade.get("fill_profile", PackedFloat32Array()),
				"cell_grid": arcade.get("cell_grid", [1, 1, 1]),
			}
	if _selected_soil_mode() == "active_patch" and _soil_interaction_authority != null:
		var active := _soil_interaction_authority.get_status_snapshot()
		if bool(active.get("configured", false)):
			return {
				"source": "active_patch",
				"ledger_identity": String(active.get("ledger_identity", "active:unavailable")),
				"world_generation": terrain_world.terrain_state.world_generation if terrain_world != null and terrain_world.terrain_state != null else int(active.get("generation", -1)),
				"bucket_volume_m3": float(active.get("bucket_volume_m3", 0.0)),
				"payload_mass_kg": float(active.get("payload_mass_kg", 0.0)),
				"fill_ratio": float(active.get("fill_ratio", 0.0)),
				"center_of_mass_local": active.get("center_of_mass_local", Vector3.ZERO),
				"fill_profile": active.get("fill_profile", PackedFloat32Array()),
				"cell_grid": active.get("cell_grid", [1, 1, 1]),
			}
	var legacy := soil_state.get_status_snapshot() if soil_state != null else {}
	return {
		"source": "legacy",
		"ledger_identity": "legacy:%d:%d" % [
			int(legacy.get("world_generation", -1)),
			int(legacy.get("last_applied_sequence", -1)),
		],
		"world_generation": int(legacy.get("world_generation", -1)),
		"bucket_volume_m3": float(legacy.get("bucket_volume_m3", 0.0)),
		"payload_mass_kg": float(legacy.get("payload_mass_kg", 0.0)),
		"fill_ratio": float(legacy.get("fill_ratio", 0.0)),
		"center_of_mass_local": legacy.get("center_of_mass_local", Vector3.ZERO),
		"fill_profile": legacy.get("fill_profile", PackedFloat32Array()),
		"cell_grid": legacy.get("cell_grid", [1, 1, 1]),
	}


func get_bucket_pose_snapshot_for_test() -> Dictionary:
	return _last_pose_snapshot.duplicate(true)


func get_dig_diagnostics() -> Dictionary:
	# Live press-block triage: every gate on the downward-dig path in one read.
	var chassis := _tracked_chassis_controller.peek_runtime_snapshot() if _tracked_chassis_controller != null else {}
	var boom := {}
	for state_value in chassis.get("joints", []):
		var state := state_value as Dictionary
		if String(state.get("name", "")) == "boom_joint":
			boom = state
	var payload := chassis.get("payload", {}) as Dictionary
	var batch := _last_interaction_batch
	return {
		"interaction": _last_interaction,
		"penetration_m": float(batch.get("analytic_penetration_m", 0.0)),
		"engagement": float(payload.get("cut_engagement", 0.0)),
		"boom_velocity": float(boom.get("velocity_rad_s", 0.0)),
		"boom_position": float(boom.get("position_rad", 0.0)),
		"enabled": _tracked_chassis_controller != null and _tracked_chassis_controller.controller_enabled,
		"focused": _tracked_chassis_controller != null and _tracked_chassis_controller.is_input_focused(),
	}


func step_automatic_snapshot_for_test(snapshot: Dictionary, delta: float = 1.0 / 60.0) -> Dictionary:
	if _bucket_ground_bypassed():
		_automatic_samples_bypassed += 1
		_soil_steps_bypassed += 1
		_terrain_commits_bypassed += 1
		return {"changed": false, "reason": "bucket_ground_interaction_bypassed"}
	_automatic_samples_executed += 1
	_process_bucket_snapshot(snapshot, delta)
	if _selected_soil_mode() == "voxel":
		var voxel_result := _voxel_authority.step_fixed(delta) if _voxel_authority != null else {"changed": false, "reason": "unavailable"}
		var voxel_status := get_status_snapshot()
		voxel_status["changed"] = bool(voxel_result.get("changed", false))
		voxel_status["terrain_commit_result"] = voxel_result
		excavation_changed.emit(voxel_status)
		return voxel_status
	return {"changed": false, "reason": "unavailable"}


func _bucket_tooth_world() -> Variant:
	if _presentation == null:
		return null
	var contract := _presentation.get_soil_contract()
	var cutting: Dictionary = (contract.get("proxies", {}) as Dictionary).get("cutting_edge", {})
	var raw_center: Variant = cutting.get("center_godot", [])
	var frame := _presentation.get_soil_frame_node(String(cutting.get("frame", "bucket_link")))
	if frame == null or not raw_center is Array or (raw_center as Array).size() != 3:
		return null
	var center := Vector3(float(raw_center[0]), float(raw_center[1]), float(raw_center[2]))
	return frame.global_transform * center


func get_soil_visual_snapshot() -> Dictionary:
	var status := get_selected_soil_payload_snapshot()
	var lifecycle_shadow := _soil_interaction_authority.get_status_snapshot() if _soil_interaction_authority != null else {}
	var arcade_status := _arcade_stamp.get_status_snapshot() if _arcade_stamp != null else {}
	var voxel_status := _voxel_authority.get_visual_snapshot() if _voxel_authority != null else {}
	var visual_source := voxel_status if _selected_soil_mode() == "voxel" else (arcade_status if _is_arcade_stamp_selected() else lifecycle_shadow)
	var last_transaction := visual_source.get("last_transaction", {}) as Dictionary
	return {
		"world_generation": int(status.get("world_generation", -1)),
		"authority_generation": authority_generation,
		"material_generation": _material_generation,
		"fill_ratio": float(status.get("fill_ratio", 0.0)),
		"bucket_volume_m3": float(status.get("bucket_volume_m3", 0.0)),
		"payload_mass_kg": float(status.get("payload_mass_kg", 0.0)),
		"selected_source": String(status.get("source", "legacy")),
		"selected_ledger_identity": String(status.get("ledger_identity", "legacy:unavailable")),
		"fill_profile": status.get("fill_profile", PackedFloat32Array()),
		"cell_grid": status.get("cell_grid", [1, 1, 1]),
		"center_of_mass_local": status.get("center_of_mass_local", Vector3.ZERO),
		"flow_volume_m3": _last_flow_volume_m3,
		"interaction_state": _last_interaction,
		"interaction_batch_key": String(_last_interaction_batch.get("key", "")),
		"interaction_operation": String(_last_interaction_batch.get("operation", _last_interaction)),
		"interaction_penetration_m": float(_last_interaction_batch.get("analytic_penetration_m", 0.0)),
		"transaction_queued": bool(_last_interaction_batch.get("transaction_queued", false)),
		"last_transaction": last_transaction if _selected_soil_mode() == "voxel" else last_transaction.duplicate(true),
		"accepted_dump_event_id": String(visual_source.get("accepted_dump_event_id", "")),
		"accepted_dump_event": visual_source.get("accepted_dump_event", {}) if _selected_soil_mode() == "voxel" \
			else (visual_source.get("accepted_dump_event", {}) as Dictionary).duplicate(true),
		"dump_release_world": visual_source.get("dump_release_world", Vector3.ZERO),
		"dump_released_fill_ratio": float(visual_source.get("dump_released_fill_ratio", 0.0)),
		"dump_pose_valid": bool(visual_source.get("dump_pose_valid", false)),
		"opening_down_dot": float(visual_source.get("opening_down_dot", -1.0)),
		"contract_dump_threshold": float(visual_source.get("contract_dump_threshold", SoilContractDescriptor.MIN_DUMP_OPENING_DOWN_DOT)),
		"effective_dump_threshold": float(visual_source.get("effective_dump_threshold", SoilContractDescriptor.MIN_DUMP_OPENING_DOWN_DOT)),
		"dump_gate_active": bool(visual_source.get("dump_gate_active", false)),
		"rejected_dump_event_id": String(visual_source.get("rejected_dump_event_id", "")),
		"rejected_dump_world": visual_source.get("rejected_dump_world", Vector3.ZERO),
		"hero_clods_enabled": hero_clods_enabled,
		"bucket_pose": _last_pose_snapshot.duplicate(true),
		"soil_material_lifecycle_mode": _selected_soil_mode(),
		"lifecycle_shadow": lifecycle_shadow,
		"digging_response": _tracked_chassis_controller.get_digging_response_snapshot() if _tracked_chassis_controller != null else {},
	}


func _step_automatic_interaction(delta: float) -> void:
	var snapshot := _sample_bucket_pose()
	_process_bucket_snapshot(snapshot, delta)


func _process_voxel_bucket_snapshot(snapshot: Dictionary, delta: float) -> void:
	if _voxel_authority == null or not _voxel_authority.configured:
		_last_interaction = "voxel_authority_unavailable"
		_report_active_runtime_failure(_last_interaction)
		return
	var identity := _voxel_fixed_identity(snapshot)
	if identity.is_empty():
		_last_interaction = "voxel_identity_rejected"
		_last_interaction_batch = {"eligible": false, "operation": _last_interaction}
		return
	var submission := _voxel_authority.submit_pose(snapshot, identity, delta)
	_last_interaction = String(submission.get("reason", "voxel_rejected"))
	_last_interaction_batch = {
		"key": "%s|%d|%d" % [
			String(identity.get("authority_epoch", "")),
			int(identity.get("physics_tick", -1)),
			int(identity.get("motion_sequence", -1)),
		],
		"authority_epoch": String(identity.get("authority_epoch", "")),
		"physics_tick": int(identity.get("physics_tick", -1)),
		"terrain_generation": int(identity.get("generation", -1)),
		"bucket_motion_sequence": int(identity.get("motion_sequence", -1)),
		"eligible": bool(submission.get("accepted", false)),
		"operation": String(submission.get("operation", "voxel_cut")) if bool(submission.get("accepted", false)) else _last_interaction,
		"transaction_queued": bool(submission.get("accepted", false)),
		"queue_depth": int(submission.get("queue_depth", 0)),
	}


func _voxel_fixed_identity(snapshot: Dictionary) -> Dictionary:
	if _voxel_authority == null:
		return {}
	var chassis := _tracked_chassis_controller.peek_runtime_snapshot() if _tracked_chassis_controller != null else {}
	var jolt_authoritative := (
		_tracked_chassis_controller != null
		and _tracked_chassis_controller.authority_profile == AuthorityProfile.JOLT_AUTHORITATIVE
	)
	if not jolt_authoritative:
		var local_tick := Engine.get_physics_frames()
		return {
			"generation": _voxel_authority.generation,
			"physics_tick": local_tick,
			"motion_sequence": local_tick,
			"authority_epoch": String(snapshot.get("identity", "local")),
		}
	var query := chassis.get("bucket_query", {}) as Dictionary
	var physics_tick := int(query.get("physics_tick", -1))
	var motion_sequence := int(query.get("motion_sequence", -1))
	var epoch := String(query.get("authority_epoch", ""))
	var identity_valid := bool(query.get("valid", false)) \
		and epoch == String(chassis.get("authority_epoch", "")) \
		and physics_tick == int(chassis.get("physics_tick", -1)) \
		and motion_sequence == int(chassis.get("bucket_motion_sequence", -1)) \
		and bool(chassis.get("terrain_identity_valid", false)) \
		and int(query.get("terrain_generation", -1)) == int(chassis.get("terrain_generation", -2)) \
		and int(query.get("terrain_revision", -1)) == int(chassis.get("terrain_revision", -2))
	if not identity_valid:
		return {}
	return {
		"generation": _voxel_authority.generation,
		"physics_tick": physics_tick,
		"motion_sequence": motion_sequence,
		"authority_epoch": epoch,
	}


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
	if _selected_soil_mode() == "voxel":
		_process_voxel_bucket_snapshot(snapshot, delta)
		return


func _reset_active_soil_patch(settle_active: bool) -> void:
	if _active_soil_patch != null:
		_active_soil_patch.clear(settle_active)
	_active_soil_patch = null
	_active_soil_event_sequence = 0
	if _active_soil_presenter != null:
		_active_soil_presenter.clear()


func _reset_arcade_stamp() -> void:
	if _arcade_stamp != null:
		_arcade_stamp.clear()
	_arcade_stamp = null


func _reset_soil_interaction_authority() -> void:
	if _soil_interaction_authority != null:
		_soil_interaction_authority.clear()
	_soil_interaction_authority = null
	_soil_lifecycle_tick = -1


func _cavity_extents_from_contract(contract: Dictionary) -> Vector3:
	var cavity_proxy: Dictionary = (contract.get("proxies", {}) as Dictionary).get("cavity", {})
	var size_array: Variant = cavity_proxy.get("size_m", [])
	if size_array is Array and (size_array as Array).size() == 3:
		return Vector3(float(size_array[0]), float(size_array[1]), float(size_array[2])) * 0.5
	return Vector3(0.25, 0.25, 0.35)


func _sample_bucket_pose() -> Dictionary:
	if _presentation == null or terrain_world == null or terrain_world.terrain_state == null:
		return {"valid": false, "reason": "unavailable"}
	return _presentation.sample_bucket_pose_fixed(terrain_world.terrain_state.world_generation, authority_generation)


func _queue_backend_feedback() -> void:
	if not backend_feedback_enabled or _motion_client == null:
		return
	var status := get_selected_soil_payload_snapshot()
	var contract := _presentation.get_soil_contract() if _presentation != null else {}
	var interaction := contract.get("interaction", {}) as Dictionary
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


func _on_pose_cleared(generation: int, _reason: String) -> void:
	authority_generation = maxi(authority_generation, generation)
	if not _clear_local_material("pose_cleared"):
		return


func _on_authority_changed(_session_id: String, _simulation_epoch: String, generation: int) -> void:
	_on_pose_cleared(generation, "authority_generation")


func _on_model_activated(_model_id: String, _asset_root: Node3D) -> void:
	_reconfigure_tool_contract("model_activated")


func _on_attachment_changed(_attachment_id: String) -> void:
	_reconfigure_tool_contract("attachment_changed")


func _reconfigure_tool_contract(reason: String) -> void:
	if not _clear_local_material(reason):
		return
	var contract := _presentation.get_soil_contract()
	_sync_local_tooth_offset(contract)
	_soil_tool_classifier.configure(contract)
	if soil_state != null:
		soil_state.configure_contract(contract)
	if _parcel_pool != null:
		_parcel_pool.configure_barrier_extents(_cavity_extents_from_contract(contract))
	if _selected_soil_mode() == "voxel" and (_voxel_authority == null or _voxel_authority.model_id != String(contract.get("model_id", ""))):
		_report_active_runtime_failure("voxel_model_reconfigure_failed")


func _sync_local_tooth_offset(contract: Dictionary) -> void:
	var cutting: Dictionary = (contract.get("proxies", {}) as Dictionary).get("cutting_edge", {})
	var raw_center: Variant = cutting.get("center_godot", [])
	if raw_center is Array and (raw_center as Array).size() == 3:
		local_tooth_offset = Vector3(float(raw_center[0]), float(raw_center[1]), float(raw_center[2]))


func _on_world_reset(generation: int) -> void:
	if _selected_soil_mode() == "voxel" and voxel_work_zone != null:
		voxel_work_zone.reset_zone()
	if terrain_scheduler != null:
		terrain_scheduler.reset_for_generation(generation)
	if soil_state != null:
		soil_state.reset_for_generation(generation)
	if _parcel_pool != null:
		_parcel_pool.clear_all()
	_next_command_sequence = 0
	_last_pose_snapshot.clear()
	_last_interaction = "reset"
	_last_support = {"active": false, "penetration_m": 0.0}
	_last_raw_support_point = Vector3.ZERO
	_has_raw_support_point = false
	_last_interaction_batch.clear()
	_consumed_batch_keys.clear()
	_consumed_batch_order.clear()
	if _tracked_chassis_controller != null:
		_tracked_chassis_controller.clear_bucket_support_contact()
	_last_flow_volume_m3 = 0.0
	if _motion_client != null:
		_motion_client.clear_bucket_load_feedback()
	_material_generation += 1
	if _presentation != null:
		_presentation.clear_bucket_pose_history()
	_reset_soil_interaction_authority()
	_reset_active_soil_patch(false)
	_reset_arcade_stamp()
	_reset_voxel_authority()
	_begin_soil_authority_generation("world_reset")
	excavation_changed.emit(get_status_snapshot())


func _clear_local_material(reason: String) -> bool:
	if _soil_interaction_authority != null and _active_soil_patch != null:
		var boundary_tick := maxi(Engine.get_physics_frames(), _soil_lifecycle_tick + 1)
		var drain := _soil_interaction_authority.settle_all_for_boundary(
			_active_soil_patch,
			boundary_tick,
			_boundary_material_origin(),
		)
		if not bool(drain.get("drained", false)):
			_report_active_runtime_failure("material_boundary_%s" % String(drain.get("reason", "drain_failed")))
			return false
	if terrain_world != null and terrain_world.terrain_state != null:
		if terrain_scheduler != null:
			terrain_scheduler.reset_for_generation(terrain_world.terrain_state.world_generation)
		if soil_state != null:
			soil_state.reset_for_generation(terrain_world.terrain_state.world_generation)
	if _parcel_pool != null:
		_parcel_pool.clear_all()
	_last_pose_snapshot.clear()
	_last_interaction = reason
	_last_support = {"active": false, "penetration_m": 0.0}
	_last_raw_support_point = Vector3.ZERO
	_has_raw_support_point = false
	_last_interaction_batch.clear()
	_consumed_batch_keys.clear()
	_consumed_batch_order.clear()
	if _tracked_chassis_controller != null:
		_tracked_chassis_controller.clear_bucket_support_contact()
	_last_flow_volume_m3 = 0.0
	if _motion_client != null:
		_motion_client.clear_bucket_load_feedback()
	_material_generation += 1
	if _presentation != null:
		_presentation.clear_bucket_pose_history()
	_reset_soil_interaction_authority()
	_reset_active_soil_patch(false)
	_reset_arcade_stamp()
	_reset_voxel_authority()
	_begin_soil_authority_generation(reason)
	excavation_changed.emit(get_status_snapshot())
	return true


func _boundary_material_origin() -> Vector3:
	var current := _last_pose_snapshot.get("current", {}) as Dictionary
	for key in ["opening", "cutting_edge"]:
		if current.has(key):
			return (current[key] as Transform3D).origin
	if _active_soil_patch != null:
		return _active_soil_patch.get_status_snapshot().get("focus_world", Vector3.ZERO) as Vector3
	return Vector3.ZERO


func _selected_soil_mode() -> String:
	var selected := _soil_authority_modes.selected_mode
	return selected if selected in SoilAuthorityModeController.MODES else "voxel"


func _selected_soil_solver_mode() -> String:
	var selected := _soil_authority_modes.selected_solver_mode
	return selected if selected in SoilAuthorityModeController.SOLVER_MODES else "voxel_bucket_v1"


func _is_arcade_stamp_selected() -> bool:
	return _selected_soil_mode() == "active_patch" and _selected_soil_solver_mode() == "arcade_stamp_v3"


func _destroy_legacy_runtime() -> void:
	if _parcel_pool != null:
		_parcel_pool.clear_all()
		remove_child(_parcel_pool)
		_parcel_pool.queue_free()
		_parcel_pool = null
	soil_state = null
	terrain_scheduler = null


func _ensure_voxel_authority() -> bool:
	if voxel_work_zone == null or voxel_work_zone.terrain == null or _presentation == null \
		or terrain_world == null or terrain_world.terrain_state == null \
		or _selected_soil_solver_mode() != "voxel_bucket_v1":
		return false
	var contract := _presentation.get_soil_contract()
	if contract.is_empty():
		return false
	_reset_voxel_authority()
	_voxel_authority = VoxelAuthority.new()
	_voxel_authority.set_diagnostics_enabled(voxel_diagnostics_enabled)
	_voxel_authority.performance_timing_enabled = performance_capture_enabled
	var capacity_override := TEST_BUCKET_CAPACITY_M3 if voxel_unlimited_bucket_for_testing else 0.0
	return _voxel_authority.configure(
		voxel_work_zone,
		contract,
		terrain_world.terrain_state.world_generation,
		capacity_override,
	)


func _reset_voxel_authority() -> void:
	if _voxel_authority != null:
		_voxel_authority.clear()
	_voxel_authority = null


func _bucket_ground_bypassed() -> bool:
	return BucketGroundInteractionMode.is_passthrough(_bucket_ground_mode)


func _terrain_identity_snapshot() -> Dictionary:
	if terrain_world == null or terrain_world.terrain_state == null:
		return {"world_generation": -1, "revision": -1}
	return {
		"world_generation": terrain_world.terrain_state.world_generation,
		"terrain_revision": terrain_world.terrain_state.terrain_revision,
	}


func _bucket_ground_interaction_status() -> Dictionary:
	return {
		"mode": _bucket_ground_mode,
		"transition_count": _bucket_ground_transition_count,
		"bypass_ticks": _bucket_ground_bypass_ticks,
		"execution_ticks": _bucket_ground_execution_ticks,
		"automatic_samples_executed": _automatic_samples_executed,
		"automatic_samples_bypassed": _automatic_samples_bypassed,
		"soil_steps_executed": _soil_steps_executed,
		"soil_steps_bypassed": _soil_steps_bypassed,
		"terrain_commits_executed": _terrain_commits_executed,
		"terrain_commits_bypassed": _terrain_commits_bypassed,
		"parcel_steps_executed": _parcel_steps_executed,
		"parcel_steps_bypassed": _parcel_steps_bypassed,
		"last_transition": _last_bucket_ground_transition.duplicate(true),
	}


func _soil_generation_key(reason: String) -> String:
	var terrain_generation := terrain_world.terrain_state.world_generation if terrain_world != null and terrain_world.terrain_state != null else -1
	var model_id := _presentation.get_active_model_id() if _presentation != null else "unknown"
	return "%d:%d:%d:%s:%s" % [terrain_generation, _material_generation, authority_generation, model_id, reason]


func _begin_soil_authority_generation(reason: String) -> bool:
	# Migrate old serialized mode requests at a clean generation boundary.
	soil_material_lifecycle_mode = "voxel"
	soil_surface_solver_mode = "voxel_bucket_v1"
	active_soil_patch_prototype_enabled = false
	_soil_authority_modes.set_requested_mode(soil_material_lifecycle_mode)
	_soil_authority_modes.set_requested_solver_mode(soil_surface_solver_mode)
	if not _soil_authority_modes.begin_generation(_soil_generation_key(reason)):
		return false
	_destroy_legacy_runtime()
	_reset_soil_interaction_authority()
	_reset_active_soil_patch(false)
	_reset_arcade_stamp()
	if not _ensure_voxel_authority():
		_reset_voxel_authority()
		_soil_authority_modes.report_runtime_failure("voxel_initialization_failed")
		_last_interaction = "soil_authority_fault"
		return false
	return _soil_authority_modes.has_single_product_owner()


func _report_active_runtime_failure(reason: String) -> void:
	if _soil_authority_modes.report_runtime_failure(reason):
		soil_material_lifecycle_mode = "voxel"
		soil_surface_solver_mode = "voxel_bucket_v1"
		_last_interaction = "soil_authority_fault"
		if _motion_client != null:
			_motion_client.clear_bucket_load_feedback()

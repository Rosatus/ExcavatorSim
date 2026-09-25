class_name ProductSession
extends Node

## Godot-owned product control plane. The optional MotionClient remains a
## transport adapter for explicit compatibility profiles and diagnostics.

signal lifecycle_changed(lifecycle: String, authority_epoch: String, generation: int)
signal authority_changed(session_id: String, authority_epoch: String, generation: int)
signal model_changed(model_id: String)
signal attachment_changed(attachment_id: String)
signal bucket_ground_mode_changed(mode: String)
signal status_changed(snapshot: Dictionary)

const LOCAL_SESSION_ID := "godot-local-authority"
const LIFECYCLE_STOPPED := "stopped"
const LIFECYCLE_RUNNING := "running"
const LIFECYCLE_PAUSED := "paused"
const MODEL_IDS := ["sy205", "sy135", "sy135neo", "sy80u", "sy155w"]

@export var motion_presentation_path := NodePath("../MotionPresentation")
@export var motion_client_path := NodePath("../MotionClient")
@export var chassis_path := NodePath("../ChassisMotionRoot")
@export var excavation_world_path := NodePath("../TerrainRoot/ExcavationWorld")
@export var attachment_rig_path := NodePath("../AttachmentRig")
@export var gateway_enabled := false
@export var lifecycle_input_enabled := true

var lifecycle := LIFECYCLE_STOPPED
var active_model_id := "sy205"
var active_coupler_id := "none"
var active_tool_id := "standard_bucket"
var authority_epoch := ""
var generation := 0
var focused := true
var last_error: Dictionary = {}
var bucket_ground_mode := BucketGroundInteractionMode.NORMAL
var requested_bucket_ground_mode := BucketGroundInteractionMode.NORMAL
var bucket_ground_transition_sequence := 0
var level_assist_enabled := false
var race_mode_enabled := false

var _presentation: MotionPresentation
var _motion_client: MotionClient
var _chassis: TrackedChassisController
var _excavation: ExcavationWorld
var _attachment_rig: AttachmentRig
var _bucket_ground_mode_pending := false


func _ready() -> void:
	process_physics_priority = -30
	authority_epoch = _new_epoch()
	_presentation = get_node_or_null(motion_presentation_path) as MotionPresentation
	_motion_client = get_node_or_null(motion_client_path) as MotionClient
	_chassis = get_node_or_null(chassis_path) as TrackedChassisController
	if _chassis != null and race_mode_enabled:
		_chassis.set_race_mode(race_mode_enabled)
	_excavation = get_node_or_null(excavation_world_path) as ExcavationWorld
	_attachment_rig = get_node_or_null(attachment_rig_path) as AttachmentRig
	if _attachment_rig != null:
		_attachment_rig.attachment_activated.connect(_on_attachment_activated)
		_sync_attachment_ids()
	call_deferred("_activate_initial_model")


func _physics_process(_delta: float) -> void:
	_apply_pending_bucket_ground_mode()
	if lifecycle_input_enabled:
		if Input.is_action_just_pressed("motion_start"):
			request_start()
		if Input.is_action_just_pressed("motion_pause"):
			request_pause()
		if Input.is_action_just_pressed("motion_reset"):
			request_reset()
	if _chassis != null:
		_chassis.set_product_session_state(lifecycle == LIFECYCLE_RUNNING, focused)
	status_changed.emit(get_status_snapshot())


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		set_focused(false)
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		set_focused(true)


func request_start() -> bool:
	if lifecycle == LIFECYCLE_RUNNING:
		return true
	lifecycle = LIFECYCLE_RUNNING
	_apply_lifecycle()
	_emit_transition()
	return true


func request_pause() -> bool:
	if lifecycle == LIFECYCLE_PAUSED:
		return true
	lifecycle = LIFECYCLE_PAUSED
	_apply_lifecycle()
	_emit_transition()
	return true


func request_reset() -> bool:
	lifecycle = LIFECYCLE_STOPPED
	authority_epoch = _new_epoch()
	generation += 1
	if _chassis != null:
		_chassis.reset_for_test()
	if _excavation != null:
		_excavation.reset_for_test()
	_apply_lifecycle()
	_emit_transition()
	return true


func request_model_switch(model_id: String) -> bool:
	if not MODEL_IDS.has(model_id):
		last_error = {"code": "unknown_model", "message": model_id}
		status_changed.emit(get_status_snapshot())
		return false
	if _presentation == null:
		last_error = {"code": "presentation_unavailable"}
		return false
	if model_id == active_model_id and not _presentation.get_contract_error().is_empty():
		return false
	var previous := active_model_id
	if not _presentation.activate_model_for_test(model_id):
		last_error = {"code": "model_contract_mismatch", "message": _presentation.get_contract_error()}
		return false
	if _chassis != null and not _chassis.configure_model_for_test(model_id):
		last_error = {"code": "model_contract_mismatch", "message": _chassis.contract_error}
		if previous != model_id:
			_presentation.activate_model_for_test(previous)
			_chassis.configure_model_for_test(previous)
		return false
	if _motion_client != null and not _motion_client.configure_equipment_model(model_id):
		last_error = {"code": "equipment_command_profile_invalid", "message": model_id}
		if previous != model_id:
			_presentation.activate_model_for_test(previous)
			if _chassis != null:
				_chassis.configure_model_for_test(previous)
		return false
	active_model_id = model_id
	authority_epoch = _new_epoch()
	generation += 1
	if _excavation != null:
		_excavation.reset_for_test()
	_apply_lifecycle()
	model_changed.emit(active_model_id)
	_emit_transition()
	return true


func set_focused(value: bool) -> void:
	focused = value
	if not focused and _chassis != null:
		_chassis.stop_product_motion()
	status_changed.emit(get_status_snapshot())


func get_equipment_input_axes() -> Vector4:
	if lifecycle != LIFECYCLE_RUNNING or not focused or _motion_client == null:
		return Vector4.ZERO
	return _motion_client.get_authoritative_input_axes()


func get_attachment_input_axes() -> Vector2:
	if lifecycle != LIFECYCLE_RUNNING or not focused or _motion_client == null:
		return Vector2.ZERO
	if _chassis != null and _chassis.input_axes_suspended():
		return Vector2.ZERO
	return _motion_client.get_attachment_input_axes()


## Model-local presentation axis input in [-1, 1] (e.g. SY80U boom offset).
## Gated on lifecycle/focus like the authoritative equipment axes; while the
## chassis suspends operator axes (assist picker, slope preview) the local
## axes stay neutral so a menu D-pad press cannot jog the attachment layer.
func get_local_axis_input(axis_id: String, negative_action: String, positive_action: String) -> float:
	if lifecycle != LIFECYCLE_RUNNING or not focused or _motion_client == null:
		return 0.0
	if _chassis != null and _chassis.input_axes_suspended():
		return 0.0
	return _motion_client.get_local_axis_input(axis_id, negative_action, positive_action)


func request_coupler_switch(coupler_id: String) -> bool:
	return _request_attachment_switch(coupler_id, active_tool_id)


func request_tool_switch(tool_id: String) -> bool:
	return _request_attachment_switch(active_coupler_id, tool_id)


func _request_attachment_switch(coupler_id: String, tool_id: String) -> bool:
	if _attachment_rig == null:
		last_error = {"code": "attachment_rig_unavailable", "message": "%s+%s" % [coupler_id, tool_id]}
		status_changed.emit(get_status_snapshot())
		return false
	var accepted := false
	if coupler_id != active_coupler_id:
		accepted = _attachment_rig.request_coupler(coupler_id)
	else:
		accepted = _attachment_rig.request_tool(tool_id)
	if not accepted:
		last_error = {
			"code": "attachment_activation_failed",
			"message": "%s+%s: %s" % [coupler_id, tool_id, _attachment_rig.get_catalog_error()],
		}
		status_changed.emit(get_status_snapshot())
		return false
	_sync_attachment_ids()
	last_error.clear()
	attachment_changed.emit(_attachment_rig.active_attachment_id())
	status_changed.emit(get_status_snapshot())
	return true


func _on_attachment_activated(_attachment_id: String) -> void:
	_sync_attachment_ids()


## The rig also changes state outside request paths — model-activation
## defaults and cross-model remounts — while the UI guards selections on
## the session's recorded pair. A stale pair makes the matching option a
## no-op, so resync on every activation signal (and once at startup, in
## case the rig mounted before this node was ready).
func _sync_attachment_ids() -> void:
	if _attachment_rig == null:
		return
	var coupler := _attachment_rig.active_coupler_id()
	var tool := _attachment_rig.active_tool_id()
	if coupler == active_coupler_id and tool == active_tool_id:
		return
	active_coupler_id = coupler
	active_tool_id = tool
	attachment_changed.emit(active_attachment_id())
	status_changed.emit(get_status_snapshot())


func active_attachment_id() -> String:
	return "%s+%s" % [active_coupler_id, active_tool_id]


func get_attachment_status_snapshot() -> Dictionary:
	if _attachment_rig == null:
		return {"coupler_id": active_coupler_id, "tool_id": active_tool_id}
	return _attachment_rig.get_status_snapshot()


func request_bucket_ground_mode(mode: String) -> bool:
	if not BucketGroundInteractionMode.is_valid(mode):
		last_error = {"code": "invalid_bucket_ground_mode", "message": mode}
		status_changed.emit(get_status_snapshot())
		return false
	requested_bucket_ground_mode = mode
	_bucket_ground_mode_pending = mode != bucket_ground_mode
	last_error.clear()
	status_changed.emit(get_status_snapshot())
	return true


func request_level_assist(enabled: bool) -> bool:
	level_assist_enabled = enabled
	if _chassis != null:
		_chassis.set_level_assist_enabled(enabled)
		level_assist_enabled = _chassis.level_assist_enabled
	last_error.clear()
	status_changed.emit(get_status_snapshot())
	return true


func request_race_mode(enabled: bool) -> bool:
	race_mode_enabled = enabled
	if _chassis != null:
		_chassis.set_race_mode(enabled)
		race_mode_enabled = _chassis.race_mode_enabled
	last_error.clear()
	status_changed.emit(get_status_snapshot())
	return true


## Slope-assist state machine mirror of the chassis controller: advance moves
## off -> preview -> active -> off (same as the T/Enter keys), cancel drops
## back to off from any state (same as Esc during preview).
func advance_slope_assist() -> String:
	var state := "off"
	if _chassis != null:
		state = _chassis.advance_slope_mode()
	last_error.clear()
	status_changed.emit(get_status_snapshot())
	return state


func cancel_slope_assist() -> void:
	if _chassis != null:
		_chassis.cancel_slope_mode()
	last_error.clear()
	status_changed.emit(get_status_snapshot())


## Assist-menu mirror: T opens the picker (machine frozen while open),
## activation dispatches to each assist's own advance/toggle semantics.
func open_assist_menu() -> void:
	if _chassis != null:
		_chassis.set_assist_menu_open(true)
	last_error.clear()
	status_changed.emit(get_status_snapshot())


func close_assist_menu() -> void:
	if _chassis != null:
		_chassis.set_assist_menu_open(false)
	last_error.clear()
	status_changed.emit(get_status_snapshot())


func activate_assist_entry(index: int) -> String:
	var result := ""
	if _chassis != null:
		result = _chassis.activate_assist_entry(index)
	last_error.clear()
	status_changed.emit(get_status_snapshot())
	return result


func get_status_snapshot() -> Dictionary:
	return {
		"authority_profile": String(ProjectSettings.get_setting("simulation/authority_profile", "jolt_authoritative")),
		"session_id": LOCAL_SESSION_ID,
		"authority_epoch": authority_epoch,
		"simulation_epoch": authority_epoch,
		"generation": generation,
		"lifecycle": lifecycle,
		"focused": focused,
		"active_model_id": active_model_id,
		"active_attachment_id": active_attachment_id(),
		"active_coupler_id": active_coupler_id,
		"active_tool_id": active_tool_id,
		"gateway_enabled": gateway_enabled,
		"gateway_state": "disabled" if not gateway_enabled else "optional",
		"bucket_ground_mode": bucket_ground_mode,
		"requested_bucket_ground_mode": requested_bucket_ground_mode,
		"bucket_ground_mode_pending": _bucket_ground_mode_pending,
		"bucket_ground_transition_sequence": bucket_ground_transition_sequence,
		"level_assist_enabled": _chassis.level_assist_enabled if _chassis != null else level_assist_enabled,
		"race_mode_enabled": _chassis.race_mode_enabled if _chassis != null else race_mode_enabled,
		"slope_assist": _chassis.slope_status_snapshot() if _chassis != null else {"state": "off"},
		"assist_menu": _chassis.assist_menu_snapshot() if _chassis != null else {"open": false, "index": 0, "entries": []},
		"assist_view": _chassis.assist_view_snapshot() if _chassis != null else {},
		"last_error": last_error,
	}


func _activate_initial_model() -> void:
	if _presentation != null and _presentation.get_active_model_id().is_empty():
		_presentation.activate_model_for_test(active_model_id)
	if _presentation != null and not _presentation.get_active_model_id().is_empty():
		active_model_id = _presentation.get_active_model_id()
	if _chassis != null and not _chassis.active_model_id.is_empty():
		active_model_id = _chassis.active_model_id
	if _motion_client != null:
		if not _motion_client.configure_equipment_model(active_model_id):
			last_error = {"code": "equipment_command_profile_invalid", "message": active_model_id}
			if _chassis != null:
				_chassis.set_controller_enabled(false)
			return
	_apply_lifecycle()
	_emit_transition()


func _apply_lifecycle() -> void:
	if _chassis == null:
		return
	_chassis.set_controller_enabled(lifecycle == LIFECYCLE_RUNNING)
	if lifecycle != LIFECYCLE_RUNNING:
		_chassis.stop_product_motion()


func _apply_pending_bucket_ground_mode() -> void:
	if not _bucket_ground_mode_pending:
		return
	if (
		_chassis == null
		or _excavation == null
		or not _chassis.can_set_bucket_ground_mode(requested_bucket_ground_mode)
		or not _excavation.can_set_bucket_ground_mode(requested_bucket_ground_mode)
	):
		last_error = {
			"code": "bucket_ground_mode_unavailable",
			"message": requested_bucket_ground_mode,
		}
		requested_bucket_ground_mode = bucket_ground_mode
		_bucket_ground_mode_pending = false
		return
	if (
		not _chassis.set_bucket_ground_mode(requested_bucket_ground_mode)
		or not _excavation.set_bucket_ground_mode(requested_bucket_ground_mode)
	):
		_chassis.set_bucket_ground_mode(BucketGroundInteractionMode.NORMAL)
		_excavation.set_bucket_ground_mode(BucketGroundInteractionMode.NORMAL)
		last_error = {
			"code": "bucket_ground_mode_transition_failed",
			"message": requested_bucket_ground_mode,
		}
		bucket_ground_mode = BucketGroundInteractionMode.NORMAL
		requested_bucket_ground_mode = BucketGroundInteractionMode.NORMAL
		_bucket_ground_mode_pending = false
		return
	bucket_ground_mode = requested_bucket_ground_mode
	bucket_ground_transition_sequence += 1
	_bucket_ground_mode_pending = false
	last_error.clear()
	bucket_ground_mode_changed.emit(bucket_ground_mode)


func _emit_transition() -> void:
	lifecycle_changed.emit(lifecycle, authority_epoch, generation)
	authority_changed.emit(LOCAL_SESSION_ID, authority_epoch, generation)
	status_changed.emit(get_status_snapshot())


func _new_epoch() -> String:
	return "%s-%s" % [LOCAL_SESSION_ID, str(Time.get_ticks_usec())]

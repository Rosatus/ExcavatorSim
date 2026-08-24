class_name ProductSession
extends Node

## Godot-owned product control plane. The optional MotionClient remains a
## transport adapter for explicit compatibility profiles and diagnostics.

signal lifecycle_changed(lifecycle: String, authority_epoch: String, generation: int)
signal authority_changed(session_id: String, authority_epoch: String, generation: int)
signal model_changed(model_id: String)
signal status_changed(snapshot: Dictionary)

const LOCAL_SESSION_ID := "godot-local-authority"
const LIFECYCLE_STOPPED := "stopped"
const LIFECYCLE_RUNNING := "running"
const LIFECYCLE_PAUSED := "paused"
const MODEL_IDS := ["sy205", "sy135"]

@export var motion_presentation_path := NodePath("../MotionPresentation")
@export var chassis_path := NodePath("../ChassisMotionRoot")
@export var excavation_world_path := NodePath("../TerrainRoot/ExcavationWorld")
@export var gateway_enabled := false
@export var lifecycle_input_enabled := true

var lifecycle := LIFECYCLE_STOPPED
var active_model_id := "sy205"
var authority_epoch := ""
var generation := 0
var focused := true
var last_error: Dictionary = {}

var _presentation: MotionPresentation
var _chassis: TrackedChassisController
var _excavation: ExcavationWorld


func _ready() -> void:
	process_physics_priority = -30
	authority_epoch = _new_epoch()
	_presentation = get_node_or_null(motion_presentation_path) as MotionPresentation
	_chassis = get_node_or_null(chassis_path) as TrackedChassisController
	_excavation = get_node_or_null(excavation_world_path) as ExcavationWorld
	call_deferred("_activate_initial_model")


func _physics_process(_delta: float) -> void:
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
	if lifecycle != LIFECYCLE_RUNNING or not focused:
		return Vector4.ZERO
	return Vector4(
		Input.get_axis("motion_swing_negative", "motion_swing_positive"),
		Input.get_axis("motion_boom_negative", "motion_boom_positive"),
		Input.get_axis("motion_arm_negative", "motion_arm_positive"),
		Input.get_axis("motion_bucket_negative", "motion_bucket_positive")
	)


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
		"gateway_enabled": gateway_enabled,
		"gateway_state": "disabled" if not gateway_enabled else "optional",
		"last_error": last_error,
	}


func _activate_initial_model() -> void:
	if _presentation != null and _presentation.get_active_model_id().is_empty():
		_presentation.activate_model_for_test(active_model_id)
	if _presentation != null and not _presentation.get_active_model_id().is_empty():
		active_model_id = _presentation.get_active_model_id()
	if _chassis != null and not _chassis.active_model_id.is_empty():
		active_model_id = _chassis.active_model_id
	_apply_lifecycle()
	_emit_transition()


func _apply_lifecycle() -> void:
	if _chassis == null:
		return
	_chassis.set_controller_enabled(lifecycle == LIFECYCLE_RUNNING)
	if lifecycle != LIFECYCLE_RUNNING:
		_chassis.stop_product_motion()


func _emit_transition() -> void:
	lifecycle_changed.emit(lifecycle, authority_epoch, generation)
	authority_changed.emit(LOCAL_SESSION_ID, authority_epoch, generation)
	status_changed.emit(get_status_snapshot())


func _new_epoch() -> String:
	return "%s-%s" % [LOCAL_SESSION_ID, str(Time.get_ticks_usec())]

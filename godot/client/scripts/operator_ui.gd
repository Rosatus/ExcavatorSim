class_name MotionOperatorUI
extends CanvasLayer

@export var motion_client_path := NodePath("../MotionClient")
@export var excavation_world_path := NodePath("../TerrainRoot/ExcavationWorld")

var _motion_client: MotionClient
var _excavation_world: ExcavationWorld
var _model_selector: OptionButton
@onready var _connection_label: Label = $StatusPanel/Margin/VBox/Connection
@onready var _authority_label: Label = $StatusPanel/Margin/VBox/Authority
@onready var _lifecycle_label: Label = $StatusPanel/Margin/VBox/Lifecycle
@onready var _diagnostics_label: Label = $StatusPanel/Margin/VBox/Diagnostics
@onready var _bucket_volume_label: Label = $StatusPanel/Margin/VBox/BucketVolume
@onready var _start_button: Button = $StatusPanel/Margin/VBox/Buttons/Start
@onready var _pause_button: Button = $StatusPanel/Margin/VBox/Buttons/Pause
@onready var _reset_button: Button = $StatusPanel/Margin/VBox/Buttons/Reset


func _ready() -> void:
	_motion_client = get_node_or_null(motion_client_path) as MotionClient
	_excavation_world = get_node_or_null(excavation_world_path) as ExcavationWorld
	_model_selector = get_node_or_null("StatusPanel/Margin/VBox/ModelSelector") as OptionButton
	if _model_selector == null:
		_model_selector = OptionButton.new()
		_model_selector.name = "ModelSelector"
		_model_selector.tooltip_text = "Select the excavator model for a fresh session"
		$StatusPanel/Margin/VBox.add_child(_model_selector)
	_model_selector.add_item("SANY SY205", 0)
	_model_selector.set_item_metadata(0, "sy205")
	_model_selector.add_item("SANY SY135", 1)
	_model_selector.set_item_metadata(1, "sy135")
	_model_selector.item_selected.connect(_on_model_selected)
	_start_button.pressed.connect(_on_start_pressed)
	_pause_button.pressed.connect(_on_pause_pressed)
	_reset_button.pressed.connect(_on_reset_pressed)
	if _excavation_world != null:
		_excavation_world.excavation_changed.connect(_on_excavation_changed)
		_refresh_bucket_volume()
	if _motion_client == null:
		_diagnostics_label.text = "Motion service: offline (static visual mode)"
		return
	_motion_client.connection_changed.connect(_on_connection_changed)
	_motion_client.authority_changed.connect(_on_authority_changed)
	_motion_client.diagnostics_changed.connect(_on_diagnostics_changed)
	_motion_client.input_acknowledged.connect(_on_input_acknowledged)
	_motion_client.command_acknowledged.connect(_on_command_acknowledged)
	_refresh()
	_refresh_model_selector()


func _on_start_pressed() -> void:
	if _motion_client != null:
		_motion_client.request_start()


func _on_pause_pressed() -> void:
	if _motion_client != null:
		_motion_client.request_pause()


func _on_reset_pressed() -> void:
	if _motion_client != null:
		_motion_client.request_reset()
	if _excavation_world != null:
		_excavation_world.reset_for_test()


func _on_connection_changed(_state: String, _diagnostics: Dictionary) -> void:
	_refresh()


func _on_authority_changed(_session_id: String, _epoch: String, _generation: int) -> void:
	_refresh()


func _on_diagnostics_changed(_diagnostics: Dictionary) -> void:
	_refresh()


func _on_input_acknowledged(_ack: Dictionary) -> void:
	_refresh()


func _on_command_acknowledged(_ack: Dictionary) -> void:
	_refresh()


func _on_model_selected(index: int) -> void:
	if _motion_client == null or _model_selector == null:
		return
	var model_id := String(_model_selector.get_item_metadata(index))
	_motion_client.request_model_switch(model_id)


func _refresh_model_selector() -> void:
	if _model_selector == null or _motion_client == null:
		return
	var selected := _motion_client.active_model_id if not _motion_client.active_model_id.is_empty() else _motion_client.desired_model_id
	for index in range(_model_selector.item_count):
		if String(_model_selector.get_item_metadata(index)) == selected:
			_model_selector.select(index)
			return


func _on_excavation_changed(_status: Dictionary) -> void:
	_refresh_bucket_volume()


func _refresh() -> void:
	if _motion_client == null:
		return
	var status := _motion_client.get_status_snapshot()
	var connection := String(status.get("connection_state", "disconnected"))
	_connection_label.text = "Connection: %s" % connection
	var session := String(status.get("session_id", ""))
	var epoch := String(status.get("simulation_epoch", ""))
	if session.is_empty():
		_authority_label.text = "Authority: waiting for Python"
	else:
		_authority_label.text = "Authority: %s / %s" % [session.left(8), epoch.left(8)]
	_lifecycle_label.text = "Lifecycle: %s   Gen: %d   Rev: %d" % [
		String(status.get("lifecycle", "stopped")),
		int(status.get("generation", 0)),
		int(status.get("accepted_view_revision", -1)),
	]
	var last_ack: Dictionary = status.get("last_input_ack", {})
	var last_error: Dictionary = status.get("last_error", {})
	var diagnostics := "Input ACK: %s" % (str(last_ack.get("client_sequence", "—")) if not last_ack.is_empty() else "—")
	if not last_error.is_empty():
		diagnostics += "   Error: %s" % String(last_error.get("code", "unknown"))
	_diagnostics_label.text = diagnostics
	_refresh_bucket_volume()
	_refresh_model_selector()


func _refresh_bucket_volume() -> void:
	if _bucket_volume_label == null:
		return
	if _excavation_world == null:
		_bucket_volume_label.text = "Bucket soil: unavailable"
		return
	var status := _excavation_world.get_status_snapshot()
	_bucket_volume_label.text = "Bucket soil: %.3f / %.2f m³" % [
		float(status.get("bucket_volume_m3", 0.0)),
		float(status.get("bucket_capacity_m3", 0.35)),
	]

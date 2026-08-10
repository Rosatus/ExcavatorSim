class_name MotionOperatorUI
extends CanvasLayer

@export var motion_client_path := NodePath("../MotionClient")

var _motion_client: MotionClient
@onready var _connection_label: Label = $StatusPanel/Margin/VBox/Connection
@onready var _authority_label: Label = $StatusPanel/Margin/VBox/Authority
@onready var _lifecycle_label: Label = $StatusPanel/Margin/VBox/Lifecycle
@onready var _diagnostics_label: Label = $StatusPanel/Margin/VBox/Diagnostics
@onready var _start_button: Button = $StatusPanel/Margin/VBox/Buttons/Start
@onready var _pause_button: Button = $StatusPanel/Margin/VBox/Buttons/Pause
@onready var _reset_button: Button = $StatusPanel/Margin/VBox/Buttons/Reset


func _ready() -> void:
	_motion_client = get_node_or_null(motion_client_path) as MotionClient
	_start_button.pressed.connect(_on_start_pressed)
	_pause_button.pressed.connect(_on_pause_pressed)
	_reset_button.pressed.connect(_on_reset_pressed)
	if _motion_client == null:
		_diagnostics_label.text = "Motion service: offline (static visual mode)"
		return
	_motion_client.connection_changed.connect(_on_connection_changed)
	_motion_client.authority_changed.connect(_on_authority_changed)
	_motion_client.diagnostics_changed.connect(_on_diagnostics_changed)
	_motion_client.input_acknowledged.connect(_on_input_acknowledged)
	_motion_client.command_acknowledged.connect(_on_command_acknowledged)
	_refresh()


func _on_start_pressed() -> void:
	if _motion_client != null:
		_motion_client.request_start()


func _on_pause_pressed() -> void:
	if _motion_client != null:
		_motion_client.request_pause()


func _on_reset_pressed() -> void:
	if _motion_client != null:
		_motion_client.request_reset()


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

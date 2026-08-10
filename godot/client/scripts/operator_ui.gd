class_name MotionOperatorUI
extends CanvasLayer

@export var motion_client_path := NodePath("../MotionClient")
@export var excavation_world_path := NodePath("../TerrainRoot/ExcavationWorld")

var _motion_client: MotionClient
var _excavation_world: ExcavationWorld
@onready var _connection_label: Label = $StatusPanel/Margin/VBox/Connection
@onready var _authority_label: Label = $StatusPanel/Margin/VBox/Authority
@onready var _lifecycle_label: Label = $StatusPanel/Margin/VBox/Lifecycle
@onready var _diagnostics_label: Label = $StatusPanel/Margin/VBox/Diagnostics
@onready var _bucket_volume_label: Label = $StatusPanel/Margin/VBox/BucketVolume
@onready var _start_button: Button = $StatusPanel/Margin/VBox/Buttons/Start
@onready var _pause_button: Button = $StatusPanel/Margin/VBox/Buttons/Pause
@onready var _reset_button: Button = $StatusPanel/Margin/VBox/Buttons/Reset
@onready var _dig_button: Button = $StatusPanel/Margin/VBox/Buttons/Dig
@onready var _deposit_button: Button = $StatusPanel/Margin/VBox/Buttons/Deposit


func _ready() -> void:
	_motion_client = get_node_or_null(motion_client_path) as MotionClient
	_excavation_world = get_node_or_null(excavation_world_path) as ExcavationWorld
	_start_button.pressed.connect(_on_start_pressed)
	_pause_button.pressed.connect(_on_pause_pressed)
	_reset_button.pressed.connect(_on_reset_pressed)
	_dig_button.pressed.connect(_on_dig_pressed)
	_deposit_button.pressed.connect(_on_deposit_pressed)
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


func _on_dig_pressed() -> void:
	if _excavation_world != null:
		_excavation_world.request_dig()


func _on_deposit_pressed() -> void:
	if _excavation_world != null:
		_excavation_world.request_deposit()


func _unhandled_input(event: InputEvent) -> void:
	var key_event: InputEventKey = event as InputEventKey
	if key_event == null or not key_event.pressed or key_event.echo:
		return
	if key_event.keycode == KEY_F9:
		_on_dig_pressed()
	elif key_event.keycode == KEY_F10:
		_on_deposit_pressed()


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

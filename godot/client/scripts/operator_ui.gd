class_name MotionOperatorUI
extends CanvasLayer

const UIStrings := preload("res://scripts/operator_ui_strings.gd")
const CONFIG_PATH := "user://operator_ui.cfg"
const CONFIG_SECTION := "onboarding"
const CONFIG_GUIDE_DISMISSED := "guide_dismissed"

@export var motion_client_path := NodePath("../MotionClient")
@export var product_session_path := NodePath("../ProductSession")
@export var excavation_world_path := NodePath("../TerrainRoot/ExcavationWorld")
@export var chassis_path := NodePath("../ChassisMotionRoot")
@export var camera_path := NodePath("../Camera3D")
@export var feedback_path := NodePath("../MachineFeedback")
@export var visual_quality_path := NodePath("../VisualQualityController")

var _motion_client: MotionClient
var _product_session: ProductSession
var _excavation_world: ExcavationWorld
var _chassis: TrackedChassisController
var _camera: CameraRig
var _feedback: MachineFeedback
var _visual_quality: VisualQualityController
var _prompt_mode := "keyboard"
var _ignore_model_selection := false
var _pending_action := ""
var _pending_model_id := ""
var _awaiting_action := ""
var _awaiting_model_id := ""
var _awaiting_generation := -1
var _soil_generation_key := ""
var _current_fill_ratio := 0.0
var _panel_collapsed := false
var _quality_before_test := "balanced"
var _ignore_quality_toggle := false

@onready var _status_panel: PanelContainer = $StatusPanel
@onready var _panel_toggle_button: Button = $PanelToggle
@onready var _title_label: Label = $StatusPanel/Margin/VBox/Title
@onready var _model_selector: OptionButton = $StatusPanel/Margin/VBox/Header/ModelSelector
@onready var _lifecycle_badge: Label = $StatusPanel/Margin/VBox/Header/LifecycleBadge
@onready var _operation_label: Label = $StatusPanel/Margin/VBox/Operation
@onready var _bucket_status_label: Label = $StatusPanel/Margin/VBox/BucketStatus
@onready var _bucket_fill: ProgressBar = $StatusPanel/Margin/VBox/BucketFill
@onready var _control_hint: Label = $StatusPanel/Margin/VBox/ControlHint
@onready var _automatic_soil_hint: Label = $StatusPanel/Margin/VBox/AutomaticSoilHint
@onready var _camera_mode_label: Label = $StatusPanel/Margin/VBox/CameraRow/Mode
@onready var _camera_selector: OptionButton = $StatusPanel/Margin/VBox/CameraRow/Selector
@onready var _reset_view_button: Button = $StatusPanel/Margin/VBox/CameraRow/ResetView
@onready var _warning_label: Label = $StatusPanel/Margin/VBox/Warning
@onready var _completion_label: Label = $StatusPanel/Margin/VBox/Completion
@onready var _connection_label: Label = $StatusPanel/Margin/VBox/AdvancedPanel/Connection
@onready var _authority_label: Label = $StatusPanel/Margin/VBox/AdvancedPanel/Authority
@onready var _lifecycle_label: Label = $StatusPanel/Margin/VBox/AdvancedPanel/Lifecycle
@onready var _diagnostics_label: Label = $StatusPanel/Margin/VBox/AdvancedPanel/Diagnostics
@onready var _can_status_label: Label = $StatusPanel/Margin/VBox/AdvancedPanel/CANStatus
@onready var _can_output_button: Button = $StatusPanel/Margin/VBox/Tools/CANOutputToggle
@onready var _ict_button: Button = $StatusPanel/Margin/VBox/Tools/ICTConnectToggle
@onready var _timed_can_button: Button = $StatusPanel/Margin/VBox/Tools/TimedCANTrigger
@onready var _ict_host_edit: LineEdit = $StatusPanel/Margin/VBox/AdvancedPanel/ICTHost
@onready var _ict_port_edit: LineEdit = $StatusPanel/Margin/VBox/AdvancedPanel/ICTPort

const ICT_CONFIG_PATH := "user://ict_config.cfg"
@onready var _bucket_volume_label: Label = $StatusPanel/Margin/VBox/AdvancedPanel/BucketVolume
@onready var _advanced_panel: VBoxContainer = $StatusPanel/Margin/VBox/AdvancedPanel
@onready var _start_button: Button = $StatusPanel/Margin/VBox/Actions/Start
@onready var _pause_button: Button = $StatusPanel/Margin/VBox/Actions/Pause
@onready var _reset_button: Button = $StatusPanel/Margin/VBox/Actions/Reset
@onready var _guide_button: Button = $StatusPanel/Margin/VBox/Tools/Guide
@onready var _advanced_button: CheckButton = $StatusPanel/Margin/VBox/Tools/Advanced
@onready var _mute_audio_button: CheckButton = $StatusPanel/Margin/VBox/Tools/MuteAudio
@onready var _test_graphics_button: CheckButton = $StatusPanel/Margin/VBox/Tools/TestGraphics
@onready var _guide_panel: PanelContainer = $GuidePanel
@onready var _guide_title_label: Label = $GuidePanel/Margin/VBox/Title
@onready var _guide_intro_label: Label = $GuidePanel/Margin/VBox/Intro
@onready var _guide_device_label: Label = $GuidePanel/Margin/VBox/Device
@onready var _guide_controls_label: Label = $GuidePanel/Margin/VBox/Controls
@onready var _guide_recovery_label: Label = $GuidePanel/Margin/VBox/Recovery
@onready var _guide_close_button: Button = $GuidePanel/Margin/VBox/Close
@onready var _confirmation: ConfirmationDialog = $DestructiveConfirmation


func _ready() -> void:
	_motion_client = get_node_or_null(motion_client_path) as MotionClient
	_product_session = get_node_or_null(product_session_path) as ProductSession
	_excavation_world = get_node_or_null(excavation_world_path) as ExcavationWorld
	_chassis = get_node_or_null(chassis_path) as TrackedChassisController
	_camera = get_node_or_null(camera_path) as CameraRig
	_feedback = get_node_or_null(feedback_path) as MachineFeedback
	_visual_quality = get_node_or_null(visual_quality_path) as VisualQualityController
	_apply_static_copy()
	_configure_model_selector()
	_configure_camera_selector()
	_panel_toggle_button.pressed.connect(_on_panel_toggle_pressed)
	_start_button.pressed.connect(_on_start_pressed)
	_pause_button.pressed.connect(_on_pause_pressed)
	_reset_button.pressed.connect(_on_reset_pressed)
	_guide_button.pressed.connect(show_control_guide)
	_advanced_button.toggled.connect(_on_advanced_toggled)
	_mute_audio_button.toggled.connect(_on_audio_muted)
	_test_graphics_button.toggled.connect(_on_test_graphics_toggled)
	_can_output_button.pressed.connect(_on_can_output_pressed)
	_ict_button.pressed.connect(_on_ict_pressed)
	_timed_can_button.pressed.connect(_on_timed_can_pressed)
	_load_ict_config()
	_ict_host_edit.text_changed.connect(func(_t: String) -> void: _save_ict_config())
	_ict_port_edit.text_changed.connect(func(_t: String) -> void: _save_ict_config())
	_guide_close_button.pressed.connect(_on_guide_closed)
	_reset_view_button.pressed.connect(_on_reset_view_pressed)
	_confirmation.confirmed.connect(_on_destructive_confirmed)
	_confirmation.canceled.connect(_on_destructive_canceled)
	if _excavation_world != null:
		_excavation_world.excavation_changed.connect(_on_excavation_changed)
	if _motion_client != null:
		_motion_client.connection_changed.connect(_on_connection_changed)
		_motion_client.authority_changed.connect(_on_authority_changed)
		_motion_client.diagnostics_changed.connect(_on_diagnostics_changed)
		_motion_client.input_acknowledged.connect(_on_input_acknowledged)
		_motion_client.command_acknowledged.connect(_on_command_acknowledged)
		_motion_client.model_changed.connect(_on_gateway_model_changed)
	if _product_session != null:
		_product_session.status_changed.connect(_on_product_status_changed)
		_product_session.model_changed.connect(_on_product_model_changed)
	if _camera != null:
		_camera.mode_changed.connect(_on_camera_mode_changed)
	_advanced_panel.visible = false
	_set_panel_collapsed(false)
	_sync_test_graphics_toggle()
	_guide_panel.visible = not _guide_was_dismissed()
	_refresh_prompt_copy()
	_refresh()
	_refresh_model_selector()


func _apply_static_copy() -> void:
	_title_label.text = UIStrings.TITLE
	_automatic_soil_hint.text = UIStrings.SOIL_AUTOMATIC_HINT
	_start_button.text = UIStrings.BUTTON_START
	_pause_button.text = UIStrings.BUTTON_PAUSE
	_reset_button.text = UIStrings.BUTTON_RESET
	_guide_button.text = UIStrings.BUTTON_GUIDE
	_advanced_button.text = UIStrings.BUTTON_ADVANCED
	_mute_audio_button.text = UIStrings.BUTTON_MUTE_AUDIO
	_test_graphics_button.text = UIStrings.BUTTON_TEST_GRAPHICS
	_test_graphics_button.tooltip_text = "Use an untextured black/white terrain grid and hide site dressing."
	_guide_title_label.text = UIStrings.GUIDE_TITLE
	_guide_intro_label.text = UIStrings.GUIDE_INTRO
	_guide_recovery_label.text = UIStrings.GUIDE_RECOVERY
	_guide_close_button.text = UIStrings.BUTTON_CLOSE
	_reset_view_button.text = UIStrings.BUTTON_RESET_VIEW
	_panel_toggle_button.tooltip_text = "Hide or restore the operator control panel"


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("motion_start"):
		_on_start_pressed()
	if Input.is_action_just_pressed("motion_pause"):
		_on_pause_pressed()
	if Input.is_action_just_pressed("motion_reset"):
		_on_reset_pressed()


func _on_test_graphics_toggled(enabled: bool) -> void:
	if _ignore_quality_toggle:
		return
	if _visual_quality == null:
		_sync_test_graphics_toggle()
		return
	if enabled:
		var current := String(_visual_quality.get_quality_snapshot().get("profile", "balanced"))
		if current != "test":
			_quality_before_test = current
	var requested := "test" if enabled else _quality_before_test
	if not VisualQualityController.PROFILES.has(requested) or (not enabled and requested == "test"):
		requested = "balanced"
	if not _visual_quality.apply_profile(requested):
		_sync_test_graphics_toggle()


func _sync_test_graphics_toggle() -> void:
	_ignore_quality_toggle = true
	_test_graphics_button.button_pressed = (
		_visual_quality != null
		and String(_visual_quality.get_quality_snapshot().get("profile", "")) == "test"
	)
	_ignore_quality_toggle = false


func set_test_graphics_for_test(enabled: bool) -> void:
	_on_test_graphics_toggled(enabled)
	_sync_test_graphics_toggle()


func is_test_graphics_enabled_for_test() -> bool:
	return _test_graphics_button.button_pressed


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		_set_prompt_mode("gamepad")
	elif event is InputEventKey or event is InputEventMouse:
		_set_prompt_mode("keyboard")


func _configure_model_selector() -> void:
	_model_selector.clear()
	_model_selector.add_item(UIStrings.model_name("sy205"))
	_model_selector.set_item_metadata(0, "sy205")
	_model_selector.add_item(UIStrings.model_name("sy135"))
	_model_selector.set_item_metadata(1, "sy135")
	_model_selector.tooltip_text = "Choose an excavator model. Switching starts a fresh work session."
	_model_selector.item_selected.connect(_on_model_selected)


func _configure_camera_selector() -> void:
	_camera_selector.clear()
	for mode in CameraRig.MODES:
		_camera_selector.add_item(String(CameraRig.MODE_NAMES[mode]))
		_camera_selector.set_item_metadata(_camera_selector.item_count - 1, mode)
	_camera_selector.item_selected.connect(_on_camera_mode_selected)
	_refresh_camera_selector()


func _on_camera_mode_selected(index: int) -> void:
	if _camera != null:
		_camera.set_mode(String(_camera_selector.get_item_metadata(index)))


func _on_reset_view_pressed() -> void:
	if _camera != null:
		_camera.reset_view()


func _on_camera_mode_changed(_mode: String, _display_name: String) -> void:
	_refresh_camera_selector()


func _refresh_camera_selector() -> void:
	if _camera == null:
		_camera_mode_label.text = "VIEW UNAVAILABLE"
		_camera_selector.disabled = true
		_reset_view_button.disabled = true
		return
	_camera_mode_label.text = "VIEW"
	for index in range(_camera_selector.item_count):
		if String(_camera_selector.get_item_metadata(index)) == _camera.get_mode():
			_camera_selector.select(index)
			break


func _on_start_pressed() -> void:
	if _product_session != null and _is_local_authority():
		_product_session.request_start()
	elif _motion_client != null:
		_motion_client.request_start()


func _on_pause_pressed() -> void:
	if _product_session != null and _is_local_authority():
		_product_session.request_pause()
	elif _motion_client != null:
		_motion_client.request_pause()


func _on_reset_pressed() -> void:
	if _confirmation.visible:
		return
	_pending_action = "reset"
	_pending_model_id = ""
	_confirmation.title = "Reset work session"
	_confirmation.dialog_text = UIStrings.reset_confirmation()
	_confirmation.popup_centered()


func _on_model_selected(index: int) -> void:
	if _ignore_model_selection or _confirmation.visible:
		return
	var model_id := String(_model_selector.get_item_metadata(index))
	if model_id == _active_model_id():
		return
	_pending_action = "model_switch"
	_pending_model_id = model_id
	_confirmation.title = "Change excavator model"
	_confirmation.dialog_text = UIStrings.model_confirmation(model_id)
	_confirmation.popup_centered()


func _on_destructive_confirmed() -> void:
	var status := _authority_status()
	_awaiting_action = _pending_action
	_awaiting_model_id = _pending_model_id
	_awaiting_generation = int(status.get("generation", -1))
	var accepted := true
	if _pending_action == "reset":
		if _product_session != null and _is_local_authority():
			accepted = _product_session.request_reset()
		elif _motion_client != null:
			_motion_client.request_reset()
		else:
			accepted = false
	elif _pending_action == "model_switch":
		if _product_session != null and _is_local_authority():
			accepted = _product_session.request_model_switch(_pending_model_id)
		elif _motion_client != null:
			accepted = _motion_client.request_model_switch(_pending_model_id)
		else:
			accepted = false
	_pending_action = ""
	_pending_model_id = ""
	if not accepted:
		_completion_label.text = "Action could not be completed. Open Advanced for details."
		_awaiting_action = ""
	_refresh()


func _on_destructive_canceled() -> void:
	_pending_action = ""
	_pending_model_id = ""
	_refresh_model_selector()


func _on_advanced_toggled(pressed: bool) -> void:
	_advanced_panel.visible = pressed


func _on_can_output_pressed() -> void:
	var bridge := _can_bridge()
	if bridge == null:
		return
	var enable := _can_output_button.button_pressed
	if enable:
		if not bridge.is_gateway_online():
			push_warning("CAN gateway offline; retrying spawn")
			bridge.respawn_gateway()
		bridge.set_recording(true)
	else:
		bridge.set_recording(false)
		_offer_segment_save(bridge)
	_refresh_can_status()


## Stop-flow: ask the user where to keep the captured segment (rename/move),
## falling back to Explorer selection if the dialog is unavailable.
func _offer_segment_save(bridge: Node) -> void:
	var source := String(bridge.get_last_segment_path())
	if source.is_empty() or not FileAccess.file_exists(source):
		return
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.current_file = source.get_file()
	dialog.root_subfolder = source.get_base_dir()
	dialog.add_filter("*.csv", "CAN CSV")
	dialog.ok_button_text = "保存"
	dialog.title = "保存 CAN 记录"
	dialog.file_selected.connect(func(target: String) -> void:
		var err := DirAccess.rename_absolute(source, target) \
			if source.to_lower() != target.to_lower() else OK
		if err != OK and source.to_lower() != target.to_lower():
			err = FileAccess.open(source, FileAccess.READ).get_buffer(-1) != null if false else err
		if err == OK and source.to_lower() != target.to_lower():
			DirAccess.remove_absolute(source)
		if err == OK:
			bridge.set_last_segment_path(target)
		dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	get_tree().root.add_child.call_deferred(dialog)
	dialog.popup_centered(Vector2i(900, 600))


func _on_ict_pressed() -> void:
	var bridge := _can_bridge()
	if bridge == null:
		_ict_button.button_pressed = false
		return
	var enable := _ict_button.button_pressed
	if enable:
		if not bridge.set_tcp_endpoint(
			_ict_host_edit.text.strip_edges(), _ict_port_edit.text.strip_edges()
		):
			var error := String(bridge.get_last_gateway_error())
			_completion_label.text = "ICT endpoint invalid: %s" % error
			push_warning(_completion_label.text)
			_ict_button.button_pressed = false
			return
	bridge.set_ict_connected(enable)
	_refresh_can_status()


func _on_timed_can_pressed() -> void:
	var bridge := _can_bridge()
	if bridge == null or not bridge.trigger_timed_can():
		var detail := "gateway unavailable" if bridge == null else String(bridge.get_last_gateway_error())
		_completion_label.text = "Timed CAN frame was not started: %s" % detail
		push_warning(_completion_label.text)
		return
	_completion_label.text = "CAN 0x18FFF100: sending at 50 Hz for 10 seconds."


func _load_ict_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(ICT_CONFIG_PATH) == OK:
		_ict_host_edit.text = String(cfg.get_value("ict", "host", ""))
		_ict_port_edit.text = String(cfg.get_value("ict", "port", ""))


func _save_ict_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("ict", "host", _ict_host_edit.text.strip_edges())
	cfg.set_value("ict", "port", _ict_port_edit.text.strip_edges())
	cfg.save(ICT_CONFIG_PATH)


func _refresh_can_status() -> void:
	var bridge := _can_bridge()
	if bridge == null:
		_can_status_label.text = "CAN Gateway: unavailable"
		_can_output_button.text = "开始记录 CAN"
		_can_output_button.button_pressed = false
		_set_ict_button(false, false, false, "CAN 网关不可用")
		_timed_can_button.disabled = true
		return
	var linux_gw: bool = bridge.is_linux_gateway()
	match int(bridge.get_status()):
		0:
			var gateway_error := String(bridge.get_last_gateway_error())
			_can_status_label.text = "CAN Gateway: offline" if gateway_error.is_empty() \
				else "CAN Gateway: offline (%s)" % gateway_error
			_can_output_button.text = "开始记录 CAN（离线，点击重试）"
			_can_output_button.button_pressed = false
			_set_ict_button(
				false, linux_gw, bridge.is_ict_requested(),
				"网关正在启动或重启" if bridge.is_ict_requested() else "网关离线，连接后重试"
			)
			_timed_can_button.disabled = true
		1:
			_can_status_label.text = "CAN Gateway: online (idle)"
			_can_output_button.text = "开始记录 CAN"
			_can_output_button.button_pressed = false
			_set_ict_button(true, linux_gw, bridge.is_ict_requested(), "")
			_timed_can_button.disabled = false
		2:
			_can_status_label.text = "CAN Gateway: recording"
			_can_output_button.text = "停止并保存"
			_can_output_button.button_pressed = true
			_set_ict_button(true, linux_gw, bridge.is_ict_requested(), "")
			_timed_can_button.disabled = false


func _set_ict_button(online: bool, linux_gateway: bool, active: bool, disabled_reason: String) -> void:
	var usable := online
	_ict_button.disabled = not usable
	_ict_button.tooltip_text = disabled_reason if not usable else (
		"Linux 网关：vcan 直发" if linux_gateway
		else "Windows 网关：PC001 TCP %s:%s（对端用 socket_client_to_vcan 桥接）"
			% [_ict_host_edit.text.strip_edges() if not _ict_host_edit.text.strip_edges().is_empty() else "0.0.0.0",
				_ict_port_edit.text.strip_edges() if not _ict_port_edit.text.strip_edges().is_empty() else "5678"]
	)
	if not usable:
		_ict_button.text = "ICT 正在重连…" if active else "连接 ICT（网关离线）"
		_ict_button.button_pressed = active
	elif active:
		_ict_button.text = "断开 ICT"
		_ict_button.button_pressed = true
	else:
		_ict_button.text = "连接 ICT"
		_ict_button.button_pressed = false


func _can_bridge() -> Node:
	if not is_inside_tree():
		return null
	var tree := get_tree()
	if tree == null:
		return null
	return tree.root.get_node_or_null("CanTelemetryBridge")



func _on_panel_toggle_pressed() -> void:
	_set_panel_collapsed(not _panel_collapsed)


func _set_panel_collapsed(collapsed: bool) -> void:
	_panel_collapsed = collapsed
	_status_panel.visible = not collapsed
	_panel_toggle_button.text = UIStrings.BUTTON_EXPAND_PANEL if collapsed else UIStrings.BUTTON_COLLAPSE_PANEL
	_panel_toggle_button.tooltip_text = "Restore the operator control panel" if collapsed else "Hide the operator control panel"
	_panel_toggle_button.position = Vector2(16.0, 16.0) if collapsed else Vector2(382.0, 22.0)
	_panel_toggle_button.size = Vector2(110.0, 32.0) if collapsed else Vector2(94.0, 28.0)


func set_panel_collapsed_for_test(collapsed: bool) -> void:
	_set_panel_collapsed(collapsed)


func is_panel_collapsed_for_test() -> bool:
	return _panel_collapsed


func _on_audio_muted(pressed: bool) -> void:
	if _feedback != null:
		_feedback.set_muted(pressed)


func show_control_guide() -> void:
	_guide_panel.visible = true


func _on_guide_closed() -> void:
	_guide_panel.visible = false
	var config := ConfigFile.new()
	config.load(CONFIG_PATH)
	config.set_value(CONFIG_SECTION, CONFIG_GUIDE_DISMISSED, true)
	config.save(CONFIG_PATH)


func _guide_was_dismissed() -> bool:
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		return false
	return bool(config.get_value(CONFIG_SECTION, CONFIG_GUIDE_DISMISSED, false))


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


func _on_product_status_changed(_status: Dictionary) -> void:
	_refresh()


func _on_product_model_changed(_model_id: String) -> void:
	_refresh()


func _on_gateway_model_changed(_model_id: String) -> void:
	_refresh()


func _on_excavation_changed(_status: Dictionary) -> void:
	_refresh_soil()
	_refresh_camera_selector()


func _refresh() -> void:
	if _motion_client == null and _product_session == null:
		return
	var local_mode := _is_local_authority()
	var status := _authority_status()
	var lifecycle := String(status.get("lifecycle", "stopped"))
	var model_id := String(status.get("active_model_id", _active_model_id()))
	var connection := String(status.get("gateway_state", "disabled")) if local_mode else String(status.get("connection_state", "disconnected"))
	var session := String(status.get("session_id", ""))
	var epoch := String(status.get("authority_epoch", status.get("simulation_epoch", "")))
	_lifecycle_badge.text = UIStrings.lifecycle_text(lifecycle)
	_lifecycle_badge.add_theme_color_override("font_color", _lifecycle_color(lifecycle))
	_connection_label.text = "Gateway: %s" % connection if local_mode else "Connection: %s" % connection
	_authority_label.text = "Authority: Godot/Jolt %s / %s" % [session.left(8), epoch.left(8)] if local_mode else ("Authority: waiting for Python" if session.is_empty() else "Authority: %s / %s" % [session.left(8), epoch.left(8)])
	_lifecycle_label.text = "Lifecycle: %s   Gen: %d   Rev: %d" % [lifecycle, int(status.get("generation", 0)), int(status.get("accepted_view_revision", -1))]
	var last_ack: Dictionary = status.get("last_input_ack", {})
	var last_error: Dictionary = status.get("last_error", {})
	var diagnostics := "Local input" if local_mode else "Input ACK: %s" % (str(last_ack.get("client_sequence", "—")) if not last_ack.is_empty() else "—")
	if not last_error.is_empty():
		diagnostics += "   Error: %s" % String(last_error.get("code", "unknown"))
	_diagnostics_label.text = diagnostics
	_refresh_can_status()
	_model_selector.tooltip_text = "%s — switching starts a fresh work session" % UIStrings.model_name(model_id)
	_refresh_soil()
	_refresh_warning(status, lifecycle, connection)
	_maybe_complete_action(status)
	_refresh_model_selector()


func _refresh_soil() -> void:
	if _excavation_world == null:
		_operation_label.text = "SOIL STATUS UNAVAILABLE"
		_bucket_status_label.text = "Bucket payload unavailable"
		_bucket_fill.value = 0.0
		_bucket_volume_label.text = "Bucket soil: unavailable"
		return
	var status := _excavation_world.get_status_snapshot()
	var selected := _excavation_world.get_selected_soil_payload_snapshot()
	var generation_key := "%d:%d:%s" % [int(selected.get("world_generation", -1)), int(status.get("material_generation", -1)), String(selected.get("source", "unknown"))]
	if generation_key != _soil_generation_key:
		_soil_generation_key = generation_key
		_operation_label.text = UIStrings.operation_text("idle")
	var fill_ratio := clampf(float(selected.get("fill_ratio", 0.0)), 0.0, 1.0)
	_current_fill_ratio = fill_ratio
	var volume := maxf(0.0, float(selected.get("bucket_volume_m3", 0.0)))
	var capacity := maxf(volume, float(status.get("bucket_capacity_m3", 0.35)))
	var operation := _derive_operation(status, fill_ratio)
	_operation_label.text = UIStrings.operation_text(operation)
	_operation_label.add_theme_color_override("font_color", _operation_color(operation))
	_bucket_status_label.text = "Bucket %s   %d%%" % [UIStrings.fill_text(fill_ratio), roundi(fill_ratio * 100.0)]
	_bucket_fill.value = fill_ratio * 100.0
	var dig := _excavation_world.get_dig_diagnostics()
	_bucket_volume_label.text = "Bucket soil: %.3f / %.2f m³   Dig: %s pen=%.3f eng=%d%% boomV=%.2f boomPos=%.2f en=%d foc=%d" % [volume, capacity, String(dig.get("interaction", "?")), float(dig.get("penetration_m", 0.0)), roundi(float(dig.get("engagement", 0.0)) * 100.0), float(dig.get("boom_velocity", 0.0)), float(dig.get("boom_position", 0.0)), int(bool(dig.get("enabled", false))), int(bool(dig.get("focused", false)))]


func _derive_operation(status: Dictionary, fill_ratio: float) -> String:
	var response := status.get("digging_response", {}) as Dictionary
	var phase := String(response.get("raw_phase", response.get("phase", "free")))
	var interaction := String(status.get("interaction_state", "idle"))
	if phase in ["contact", "scrape", "cut", "load", "dump", "overflow"]:
		return phase
	if interaction in ["cut", "cutting"]:
		return "cut"
	if interaction in ["dump", "spill", "push"]:
		return interaction
	return "carry" if fill_ratio > 0.02 else "idle"


func _refresh_warning(status: Dictionary, lifecycle: String, connection: String) -> void:
	var warnings: Array[String] = []
	if not bool(status.get("focused", true)):
		warnings.append(UIStrings.WARNING_FOCUS)
	if lifecycle == "paused":
		warnings.append(UIStrings.WARNING_PAUSED)
	elif lifecycle == "stopped":
		warnings.append(UIStrings.WARNING_STOPPED)
	if not _is_local_authority() and connection not in ["ready", "stale"]:
		warnings.append(UIStrings.WARNING_GATEWAY)
	if _current_fill_ratio >= 0.98:
		warnings.append(UIStrings.WARNING_OVERFLOW)
	var last_error := status.get("last_error", {}) as Dictionary
	if not last_error.is_empty():
		warnings.append("Recovery needed: %s" % String(last_error.get("message", last_error.get("code", "unknown error"))))
	if _chassis != null:
		var chassis_status := _chassis.get_status_snapshot()
		if not bool(chassis_status.get("neutral_armed", true)) or not bool(chassis_status.get("track_neutral_armed", true)):
			warnings.append(UIStrings.WARNING_NEUTRAL)
	_warning_label.text = UIStrings.WARNING_NONE if warnings.is_empty() else " • ".join(PackedStringArray(warnings))
	_warning_label.add_theme_color_override("font_color", Color("73d99b") if warnings.is_empty() else Color("ffc45b"))


func _maybe_complete_action(status: Dictionary) -> void:
	if _awaiting_action.is_empty():
		return
	var generation := int(status.get("generation", -1))
	var model_id := String(status.get("active_model_id", ""))
	if _awaiting_action == "reset" and generation > _awaiting_generation:
		_completion_label.text = "Work session reset complete. Return controls to neutral, then press Start."
		_awaiting_action = ""
	elif _awaiting_action == "model_switch" and model_id == _awaiting_model_id and generation > _awaiting_generation:
		_completion_label.text = "%s ready. Return controls to neutral, then press Start." % UIStrings.model_name(model_id)
		_awaiting_action = ""


func _refresh_model_selector() -> void:
	_ignore_model_selection = true
	var selected := _active_model_id()
	for index in range(_model_selector.item_count):
		if String(_model_selector.get_item_metadata(index)) == selected:
			_model_selector.select(index)
			break
	_ignore_model_selection = false


func _active_model_id() -> String:
	if _product_session != null and _is_local_authority():
		return _product_session.active_model_id
	if _motion_client != null:
		return _motion_client.active_model_id if not _motion_client.active_model_id.is_empty() else _motion_client.desired_model_id
	return "sy205"


func _authority_status() -> Dictionary:
	if _product_session != null and _is_local_authority():
		return _product_session.get_status_snapshot()
	return _motion_client.get_status_snapshot() if _motion_client != null else {}


func _is_local_authority() -> bool:
	return String(ProjectSettings.get_setting("simulation/authority_profile", AuthorityProfile.JOLT_AUTHORITATIVE)) == AuthorityProfile.JOLT_AUTHORITATIVE


func _set_prompt_mode(value: String) -> void:
	if value == _prompt_mode or value not in ["keyboard", "gamepad"]:
		return
	_prompt_mode = value
	_refresh_prompt_copy()


func _lifecycle_color(value: String) -> Color:
	return {
		"running": Color("67dfa0"),
		"paused": Color("ffc45b"),
		"stopped": Color("b8c0c8"),
	}.get(value, Color.WHITE)


func _operation_color(value: String) -> Color:
	if value in ["cut", "load", "scrape", "contact"]:
		return Color("ffbf5b")
	if value in ["dump", "spill"]:
		return Color("7bdca7")
	if value in ["overflow"]:
		return Color("ff766d")
	if value == "carry":
		return Color("72c7ff")
	return Color("e8eef3")


func _refresh_prompt_copy() -> void:
	_control_hint.text = UIStrings.CONTROL_HINT_GAMEPAD if _prompt_mode == "gamepad" else UIStrings.CONTROL_HINT_KEYBOARD
	_guide_device_label.text = "Current input: GAMEPAD" if _prompt_mode == "gamepad" else "Current input: KEYBOARD + MOUSE"
	_guide_controls_label.text = UIStrings.GUIDE_GAMEPAD if _prompt_mode == "gamepad" else UIStrings.GUIDE_KEYBOARD


func set_prompt_mode_for_test(value: String) -> void:
	_set_prompt_mode(value)


func get_prompt_mode_for_test() -> String:
	return _prompt_mode


func get_soil_generation_key_for_test() -> String:
	return _soil_generation_key

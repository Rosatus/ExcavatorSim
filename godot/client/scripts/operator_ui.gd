class_name MotionOperatorUI
extends CanvasLayer

const MenuLayout := preload("res://scripts/game_menu_layout.gd")
const GameSkin := preload("res://scripts/game_ui_theme.gd")
const Capture := preload("res://scripts/performance_capture.gd")

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
var _performance_capture: Capture
var _capture_button: Button
var _capture_marker_button: Button
var _capture_folder_button: Button
var _capture_status: Label
var _capture_badge: Label
var _prompt_mode := "keyboard"
var _ignore_model_selection := false
var _pending_action := ""
var _pending_model_id := ""
var _awaiting_action := ""
var _awaiting_model_id := ""
var _awaiting_generation := -1
var _soil_generation_key := ""
var _current_fill_ratio := 0.0
var _panel_collapsed := true
var _menu: Dictionary = {}
var _menu_owns_pause := false
var _resume_after_menu := false
var _menu_refresh_elapsed := 0.0
var _menu_visual_time := 0.0
var _page_tween: Tween
var _saved_mouse_mode := Input.MOUSE_MODE_VISIBLE
var _hud: ControlInputHUD
var _menu_tween: Tween
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
@onready var _gateway_button: Button = $StatusPanel/Margin/VBox/Tools/GatewayRestartButton
@onready var _pc001_handshake_lamp: Panel = $StatusPanel/Margin/VBox/Tools/PC001HandshakeStatus/Lamp
@onready var _pc001_handshake_label: Label = $StatusPanel/Margin/VBox/Tools/PC001HandshakeStatus/Label
@onready var _timed_can_button: Button = $StatusPanel/Margin/VBox/Tools/TimedCANTrigger
@onready var _gateway_host_edit: LineEdit = $StatusPanel/Margin/VBox/AdvancedPanel/GatewayHost
@onready var _gateway_port_edit: LineEdit = $StatusPanel/Margin/VBox/AdvancedPanel/GatewayPort
@onready var _unlimited_bucket_button: CheckButton = $StatusPanel/Margin/VBox/AdvancedPanel/UnlimitedBucketCapacity
@onready var _cutting_diagnostics_button: CheckButton = $StatusPanel/Margin/VBox/AdvancedPanel/CuttingDiagnostics

const GATEWAY_CONFIG_PATH := "user://ict_config.cfg"
@onready var _bucket_volume_label: Label = $StatusPanel/Margin/VBox/AdvancedPanel/BucketVolume
@onready var _advanced_panel: VBoxContainer = $StatusPanel/Margin/VBox/AdvancedPanel
@onready var _reset_button: Button = $StatusPanel/Margin/VBox/Actions/Reset
@onready var _mute_audio_button: CheckButton = $StatusPanel/Margin/VBox/Tools/MuteAudio
@onready var _test_graphics_button: CheckButton = $StatusPanel/Margin/VBox/Tools/TestGraphics
@onready var _bucket_passthrough_button: CheckButton = $StatusPanel/Margin/VBox/Tools/BucketPassthrough
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
	_performance_capture = get_node_or_null("../PerformanceCapture") as Capture
	process_mode = Node.PROCESS_MODE_ALWAYS
	_confirmation.theme = GameSkin.create()
	_confirmation.ok_button_text = "确认"
	_confirmation.cancel_button_text = "取消"
	_apply_static_copy()
	_configure_model_selector()
	_configure_camera_selector()
	_panel_toggle_button.pressed.connect(_on_panel_toggle_pressed)
	_reset_button.pressed.connect(_on_reset_pressed)
	_mute_audio_button.toggled.connect(_on_audio_muted)
	_test_graphics_button.toggled.connect(_on_test_graphics_toggled)
	_bucket_passthrough_button.toggled.connect(_on_bucket_passthrough_toggled)
	_unlimited_bucket_button.toggled.connect(_on_unlimited_bucket_toggled)
	_cutting_diagnostics_button.toggled.connect(_on_cutting_diagnostics_toggled)
	_can_output_button.pressed.connect(_on_can_output_pressed)
	_gateway_button.pressed.connect(_on_gateway_restart_pressed)
	_timed_can_button.pressed.connect(_on_timed_can_pressed)
	_load_gateway_config()
	_guide_close_button.pressed.connect(_on_guide_closed)
	_reset_view_button.pressed.connect(_on_reset_view_pressed)
	_confirmation.window_input.connect(_on_confirmation_input)
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
	var can_bridge := _can_bridge()
	if can_bridge != null and can_bridge.has_signal("ict_link_status_changed"):
		can_bridge.connect("ict_link_status_changed", _on_pc001_link_status_changed)
	_menu = MenuLayout.build(self)
	_build_capture_controls()
	_hud = $ControlInputHUD as ControlInputHUD
	_advanced_panel.visible = true
	(_menu["resume"] as Button).pressed.connect(_on_panel_toggle_pressed)
	(_menu["tabs"] as TabContainer).tab_changed.connect(_on_menu_tab_changed)
	(_menu["tabs"] as TabContainer).get_tab_bar().focus_mode = Control.FOCUS_ALL
	get_viewport().size_changed.connect(_layout_menu)
	(_menu["hardware"] as Control).resized.connect(_layout_menu)
	_layout_menu()
	_set_panel_collapsed(true)
	_sync_test_graphics_toggle()
	_guide_panel.visible = false
	call_deferred("_start_product_gameplay")
	_refresh_prompt_copy()
	_refresh()
	_refresh_model_selector()


func _apply_static_copy() -> void:
	_title_label.text = UIStrings.TITLE
	_automatic_soil_hint.text = UIStrings.SOIL_AUTOMATIC_HINT
	_reset_button.text = UIStrings.BUTTON_RESET
	_mute_audio_button.text = UIStrings.BUTTON_MUTE_AUDIO
	_test_graphics_button.text = UIStrings.BUTTON_TEST_GRAPHICS
	_test_graphics_button.tooltip_text = "Use an untextured black/white terrain grid and hide site dressing."
	_bucket_passthrough_button.tooltip_text = "Let the bucket pass through terrain. Entering or leaving clears bucket soil and pending soil work."
	_unlimited_bucket_button.tooltip_text = "Testing only: raise collection capacity while keeping the visible full-bucket level at the model contract capacity."
	_cutting_diagnostics_button.tooltip_text = "按需采集切削耗时与地形统计；关闭可减少开销。重新开启将清空旧计时样本，不影响地形和斗内土量。"
	_guide_title_label.text = UIStrings.GUIDE_TITLE
	_guide_intro_label.text = UIStrings.GUIDE_INTRO
	_guide_recovery_label.text = UIStrings.GUIDE_RECOVERY
	_guide_close_button.text = UIStrings.BUTTON_CLOSE
	_reset_view_button.text = UIStrings.BUTTON_RESET_VIEW
	_panel_toggle_button.tooltip_text = "Esc / 手柄菜单键：打开作业菜单"


func _start_product_gameplay() -> void:
	# Product entry point only; low-level session reset/compatibility stays stopped.
	if _is_local_authority() and _panel_collapsed and _product_session != null and _product_session.last_error.is_empty():
		_on_start_pressed()


func _process(delta: float) -> void:
	if _panel_collapsed:
		return
	_menu_visual_time += delta
	(_menu["atmosphere"] as ShaderMaterial).set_shader_parameter("ui_time", _menu_visual_time)
	_menu_refresh_elapsed += delta
	if _menu_refresh_elapsed >= 0.2:
		_menu_refresh_elapsed = 0.0
		_refresh_can_status()


func get_control_for_test(id: String) -> Control:
	# Stable semantic seam; the visual hierarchy may evolve independently.
	return {
		"bucket_passthrough": _bucket_passthrough_button,
		"camera_selector": _camera_selector,
		"gateway_restart": _gateway_button,
		"gateway_port": _gateway_port_edit,
		"completion": _completion_label,
		"ict_indicator": _pc001_handshake_lamp.get_parent(),
		"ict_lamp": _pc001_handshake_lamp,
		"ict_label": _pc001_handshake_label,
		"cutting_diagnostics": _cutting_diagnostics_button,
		"performance_capture": _capture_button,
		"performance_marker": _capture_marker_button,
		"performance_folder": _capture_folder_button,
		"performance_status": _capture_status,
		"control_hint": _control_hint,
		"controls_page": (_menu["tabs"] as TabContainer).get_tab_control(1),
	}.get(id) as Control


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and not _confirmation.visible:
		if event.keycode == KEY_F12:
			_on_capture_pressed()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_F10 and _performance_capture != null and _performance_capture.recording:
			_performance_capture.add_marker()
			get_viewport().set_input_as_handled()
			return
	if event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf(event.axis_value) > 0.3):
		_set_prompt_mode("gamepad")
	elif event is InputEventKey or event is InputEventMouseButton:
		_set_prompt_mode("keyboard")
	var toggle: bool = (event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed and not event.echo) or (event is InputEventJoypadButton and event.button_index == JOY_BUTTON_START and event.pressed)
	var back: bool = event is InputEventJoypadButton and event.button_index == JOY_BUTTON_B and event.pressed
	if toggle or (back and not _panel_collapsed):
		get_viewport().set_input_as_handled()
		if _confirmation.visible:
			_confirmation.hide()
			_on_destructive_canceled()
		else:
			_on_panel_toggle_pressed()
	elif not _panel_collapsed and event is InputEventJoypadButton and event.pressed and event.button_index in [JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER]:
		var tabs := _menu["tabs"] as TabContainer
		tabs.current_tab = wrapi(tabs.current_tab + (-1 if event.button_index == JOY_BUTTON_LEFT_SHOULDER else 1), 0, tabs.get_tab_count())
		get_viewport().set_input_as_handled()
	elif not _panel_collapsed and not _confirmation.visible and _menu_navigation_direction(event) != 0:
		_move_menu_focus(_menu_navigation_direction(event))
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.keycode == KEY_F8 and event.pressed and not event.echo:
		get_viewport().set_input_as_handled()
		_on_reset_pressed()


func _menu_navigation_direction(event: InputEvent) -> int:
	if event is InputEventJoypadButton and event.pressed:
		if event.button_index == JOY_BUTTON_DPAD_DOWN:
			return 1
		if event.button_index == JOY_BUTTON_DPAD_UP:
			return -1
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_DOWN or (event.keycode == KEY_TAB and not event.shift_pressed):
			return 1
		if event.keycode == KEY_UP or (event.keycode == KEY_TAB and event.shift_pressed):
			return -1
	return 0


func _move_menu_focus(direction: int) -> void:
	var tabs := _menu["tabs"] as TabContainer
	var controls: Array[Control] = [_menu["resume"] as Control, tabs.get_tab_bar()]
	_collect_menu_focus(tabs.get_current_tab_control(), controls)
	var index := controls.find(get_viewport().gui_get_focus_owner())
	controls[wrapi(index + direction, 0, controls.size())].grab_focus()


func _collect_menu_focus(node: Node, result: Array[Control]) -> void:
	if node is Control and not (node as Control).is_visible_in_tree():
		return
	if node is BaseButton and not (node as BaseButton).disabled:
		result.append(node as Control)
	elif node is LineEdit:
		result.append(node as Control)
	for child in node.get_children():
		_collect_menu_focus(child, result)


func _layout_menu() -> void:
	if _menu.is_empty():
		return
	var viewport_size := get_viewport().get_visible_rect().size
	(_menu["atmosphere"] as ShaderMaterial).set_shader_parameter("aspect_ratio", viewport_size.x / maxf(viewport_size.y, 1.0))
	var dock_width := (_menu["hardware"] as Control).size.x
	var available_left := dock_width + 56.0
	var extent := Vector2(clampf(viewport_size.x - available_left - 28.0, 1.0, 760.0), clampf(viewport_size.y - 48.0, 1.0, 660.0))
	var center_shift := available_left / 2.0 - 14.0
	_status_panel.offset_left = center_shift - extent.x / 2.0
	_status_panel.offset_right = center_shift + extent.x / 2.0
	_status_panel.offset_top = -extent.y / 2.0
	_status_panel.offset_bottom = extent.y / 2.0
	_panel_toggle_button.position = Vector2(28, viewport_size.y - 70)
	_panel_toggle_button.size = Vector2(160, 42)


func _on_menu_tab_changed(_index: int) -> void:
	if _page_tween != null:
		_page_tween.kill()
	var tabs := _menu["tabs"] as TabContainer
	for index in range(tabs.get_tab_count()):
		tabs.get_tab_control(index).modulate.a = 1.0
	var page := tabs.get_current_tab_control()
	page.modulate.a = 0.65
	_page_tween = create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_page_tween.tween_property(page, "modulate:a", 1.0, 0.16)
	# The tab bar keeps controller focus; Down enters the selected page.
	(_menu["tabs"] as TabContainer).get_tab_bar().grab_focus()


func _exit_tree() -> void:
	if _menu_owns_pause and get_tree() != null:
		get_tree().paused = false
		Input.mouse_mode = _saved_mouse_mode


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


func _on_bucket_passthrough_toggled(enabled: bool) -> void:
	if _product_session == null:
		_sync_bucket_passthrough_toggle()
		return
	var requested := (
		BucketGroundInteractionMode.PASSTHROUGH
		if enabled
		else BucketGroundInteractionMode.NORMAL
	)
	if not _product_session.request_bucket_ground_mode(requested):
		_sync_bucket_passthrough_toggle()


func _on_unlimited_bucket_toggled(enabled: bool) -> void:
	if _excavation_world == null \
			or not _excavation_world.set_voxel_unlimited_bucket_for_testing(enabled):
		_sync_unlimited_bucket_toggle()
		if _excavation_world != null:
			var status := _excavation_world.get_status_snapshot()
			var reason := String(status.get("voxel_capacity_override_error", "unavailable"))
			_completion_label.text = (
				"Cannot restore normal bucket capacity while the bucket exceeds its contract capacity; dump soil first."
				if reason == "bucket_mass_exceeds_requested_capacity"
				else "Unlimited bucket test mode is unavailable: %s" % reason
			)


func _on_cutting_diagnostics_toggled(enabled: bool) -> void:
	if _excavation_world != null:
		_excavation_world.set_voxel_diagnostics_enabled(enabled)
	_sync_cutting_diagnostics_toggle()


func _sync_cutting_diagnostics_toggle() -> void:
	_cutting_diagnostics_button.disabled = _excavation_world == null or (_performance_capture != null and _performance_capture.recording)
	_cutting_diagnostics_button.set_pressed_no_signal(
		_excavation_world != null and _excavation_world.voxel_diagnostics_enabled
	)


func _build_capture_controls() -> void:
	var group := VBoxContainer.new()
	_advanced_panel.add_child(group)
	_capture_button = Button.new()
	_capture_button.text = "开始性能录制 · F12"
	group.add_child(_capture_button)
	_capture_button.pressed.connect(_on_capture_pressed)
	_capture_marker_button = Button.new()
	_capture_marker_button.text = "标记卡顿 · F10"
	group.add_child(_capture_marker_button)
	_capture_marker_button.pressed.connect(func():
		if _performance_capture != null:
			_performance_capture.add_marker()
	)
	_capture_folder_button = Button.new()
	_capture_folder_button.text = "打开性能文件目录"
	group.add_child(_capture_folder_button)
	_capture_folder_button.pressed.connect(_on_capture_folder_pressed)
	_capture_status = Label.new()
	_capture_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	group.add_child(_capture_status)
	_capture_badge = Label.new()
	_capture_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_capture_badge.add_theme_color_override("font_color", GameSkin.ACCENT)
	_capture_badge.add_theme_color_override("font_shadow_color", Color.BLACK)
	_capture_badge.add_theme_constant_override("shadow_offset_x", 1)
	_capture_badge.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_capture_badge)
	_capture_badge.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_capture_badge.offset_left = -350
	_capture_badge.offset_right = -24
	_capture_badge.offset_top = 20
	_capture_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if _performance_capture != null:
		_performance_capture.state_changed.connect(_refresh_capture_status)
	_refresh_capture_status()


func _on_capture_pressed() -> void:
	if _performance_capture == null:
		return
	var status := _performance_capture.get_capture_status()
	if _performance_capture.recording:
		_performance_capture.stop_capture()
	elif bool(status.get("unsaved", false)):
		_performance_capture.save_capture()
	else:
		_performance_capture.start_capture()
	_refresh_capture_status()


func _on_capture_folder_pressed() -> void:
	var directory := ProjectSettings.globalize_path(Capture.OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(directory)
	var error := OS.shell_open(directory)
	if error != OK:
		_capture_status.text = "无法打开目录：%s" % directory


func _refresh_capture_status() -> void:
	if _capture_button == null:
		return
	_capture_button.disabled = _performance_capture == null
	_capture_marker_button.disabled = _performance_capture == null or not _performance_capture.recording
	_capture_badge.visible = _performance_capture != null and _performance_capture.recording
	_sync_cutting_diagnostics_toggle()
	if _performance_capture == null:
		_capture_status.text = "性能录制不可用"
		return
	var status := _performance_capture.get_capture_status()
	_capture_button.text = "停止并保存性能录制 · F12" if _performance_capture.recording else ("重试保存性能录制" if bool(status["unsaved"]) else "开始性能录制 · F12")
	if _performance_capture.recording:
		_capture_badge.text = "● 性能录制 %ds · 标记 %d · F12 停止" % [int(status["elapsed_s"]), int(status["markers"])]
		_capture_status.text = "录制中，最长 3 分钟（含菜单时间）。返回驾驶复现卡顿，F10 标记，F12 停止并保存。"
	elif not String(status["error"]).is_empty():
		_capture_status.text = String(status["error"])
	elif not String(status["path"]).is_empty():
		_capture_status.text = "已保存：%s\n把这个 JSON 文件交给我分析。" % status["path"]
		if int(status["active_frames"]) == 0:
			_capture_status.text += "\n本次没有有效驾驶帧，请返回驾驶并保持窗口焦点后再录制。"
	else:
		_capture_status.text = "记录帧耗时与挖掘阶段，停止后保存 JSON。建议先空闲 10 秒，再挖掘和卸土。"


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
	_set_panel_collapsed(false)
	if _confirmation.visible:
		return
	_pending_action = "reset"
	_pending_model_id = ""
	_confirmation.title = "重新开始作业"
	_confirmation.dialog_text = UIStrings.reset_confirmation()
	_confirmation.popup_centered()
	_confirmation.get_cancel_button().grab_focus()


func _on_model_selected(index: int) -> void:
	if _ignore_model_selection or _confirmation.visible:
		return
	var model_id := String(_model_selector.get_item_metadata(index))
	if model_id == _active_model_id():
		return
	_pending_action = "model_switch"
	_pending_model_id = model_id
	_confirmation.title = "切换挖掘机"
	_confirmation.dialog_text = UIStrings.model_confirmation(model_id)
	_confirmation.popup_centered()
	_confirmation.get_cancel_button().grab_focus()


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
	if accepted:
		_resume_after_menu = true
		_set_panel_collapsed(true)
	if not accepted:
		_completion_label.text = "Action could not be completed. Open Advanced for details."
		_awaiting_action = ""
	_refresh()


func _on_confirmation_input(event: InputEvent) -> void:
	var back: bool = event is InputEventJoypadButton and event.pressed and event.button_index in [JOY_BUTTON_B, JOY_BUTTON_START]
	if back:
		_confirmation.set_input_as_handled()
		_confirmation.hide()
		_on_destructive_canceled()


func _on_destructive_canceled() -> void:
	_pending_action = ""
	_pending_model_id = ""
	_refresh_model_selector()
	(_menu["resume"] as Button).grab_focus()


func _on_advanced_toggled(pressed: bool) -> void:
	(_menu["tabs"] as TabContainer).current_tab = 2 if pressed else 0


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


func _on_gateway_restart_pressed() -> void:
	var bridge := _can_bridge()
	if bridge == null:
		_completion_label.text = "Gateway is unavailable."
		return
	if not bridge.set_tcp_endpoint(
		_gateway_host_edit.text.strip_edges(), _gateway_port_edit.text.strip_edges()
	):
		var endpoint_error := String(bridge.get_last_gateway_error())
		_completion_label.text = "Gateway endpoint invalid: %s" % endpoint_error
		push_warning(_completion_label.text)
		return
	_save_gateway_config()
	if not bridge.respawn_gateway():
		var spawn_error := String(bridge.get_last_gateway_error())
		_completion_label.text = "Gateway failed to start: %s" % (
			spawn_error if not spawn_error.is_empty() else "restart request was rejected"
		)
		push_warning(_completion_label.text)
	else:
		_completion_label.text = "Gateway restart requested; waiting for a fresh heartbeat."
	_refresh_can_status()


func _on_timed_can_pressed() -> void:
	var bridge := _can_bridge()
	if bridge == null or not bridge.trigger_timed_can():
		var detail := "gateway unavailable" if bridge == null else String(bridge.get_last_gateway_error())
		_completion_label.text = "Timed CAN frame was not started: %s" % detail
		push_warning(_completion_label.text)
		return
	_completion_label.text = "CAN 0x18FFF100: sending at 50 Hz for 10 seconds."


func _load_gateway_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(GATEWAY_CONFIG_PATH) == OK:
		_gateway_host_edit.text = String(cfg.get_value("ict", "host", ""))
		_gateway_port_edit.text = String(cfg.get_value("ict", "port", ""))


func _save_gateway_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("ict", "host", _gateway_host_edit.text.strip_edges())
	cfg.set_value("ict", "port", _gateway_port_edit.text.strip_edges())
	cfg.save(GATEWAY_CONFIG_PATH)


func _refresh_can_status() -> void:
	var bridge := _can_bridge()
	if bridge == null:
		_can_status_label.text = "CAN Gateway: unavailable"
		_can_output_button.text = "开始记录 CAN"
		_can_output_button.button_pressed = false
		_set_gateway_button(null)
		_set_pc001_handshake_indicator("unavailable")
		_timed_can_button.disabled = true
		return
	if bridge.is_ict_handshake_connected():
		_set_pc001_handshake_indicator("connected")
	else:
		_set_pc001_handshake_indicator("waiting" if bridge.is_gateway_online() else "offline")
	_set_gateway_button(bridge)
	match int(bridge.get_status()):
		0:
			var gateway_error := String(bridge.get_last_gateway_error())
			var lifecycle := String(bridge.get_gateway_lifecycle_state())
			if lifecycle == "starting":
				_can_status_label.text = "CAN Gateway: starting"
			elif lifecycle == "stopping":
				_can_status_label.text = "CAN Gateway: restarting" \
					if bridge.is_gateway_restart_pending() else "CAN Gateway: stopping"
			elif not gateway_error.is_empty():
				_can_status_label.text = "CAN Gateway: failed (%s)" % gateway_error
			else:
				_can_status_label.text = "CAN Gateway: offline"
			_can_output_button.text = "开始记录 CAN"
			_can_output_button.button_pressed = false
			_timed_can_button.disabled = true
		1:
			var idle_error := String(bridge.get_last_gateway_error())
			_can_status_label.text = "CAN Gateway: online (idle)" if idle_error.is_empty() \
				else "CAN Gateway: online — %s" % idle_error
			_can_output_button.text = "开始记录 CAN"
			_can_output_button.button_pressed = false
			_timed_can_button.disabled = false
		2:
			_can_status_label.text = "CAN Gateway: recording"
			_can_output_button.text = "停止并保存"
			_can_output_button.button_pressed = true
			_timed_can_button.disabled = false


func _set_gateway_button(bridge: Node) -> void:
	if bridge == null:
		_gateway_button.text = "Gateway 不可用"
		_gateway_button.disabled = true
		_gateway_button.tooltip_text = "CAN 网关不可用"
		return
	var endpoint := "PC001 TCP %s:%s" % [
		_gateway_host_edit.text.strip_edges() if not _gateway_host_edit.text.strip_edges().is_empty() else "0.0.0.0",
		_gateway_port_edit.text.strip_edges() if not _gateway_port_edit.text.strip_edges().is_empty() else "5678",
	]
	_gateway_button.tooltip_text = "%s；仅重启本 Godot 实例托管的 Gateway" % endpoint
	match String(bridge.get_gateway_lifecycle_state()):
		"starting":
			_gateway_button.text = "Gateway 启动中…"
			_gateway_button.disabled = true
		"stopping":
			_gateway_button.text = "Gateway 重启中…" \
				if bridge.is_gateway_restart_pending() else "Gateway 停止中…"
			_gateway_button.disabled = true
		"failed":
			_gateway_button.text = "重试启动 Gateway"
			_gateway_button.disabled = false
		_:
			_gateway_button.text = "重启 Gateway" if bridge.is_gateway_online() \
				else ("重试启动 Gateway" if not String(bridge.get_last_gateway_error()).is_empty() else "启动 Gateway")
			_gateway_button.disabled = false


func _set_pc001_handshake_indicator(state: String) -> void:
	match state:
		"connected":
			_pc001_handshake_lamp.self_modulate = Color("67dfa0")
			_pc001_handshake_label.text = "已握手"
			_pc001_handshake_label.tooltip_text = "PC001 客户端已完成 who / PC001 握手"
		"not_applicable":
			_pc001_handshake_lamp.self_modulate = Color("b8c0c8")
			_pc001_handshake_label.text = "直连"
			_pc001_handshake_label.tooltip_text = "Linux/can0 直连，无需 PC001 TCP 握手"
		"waiting":
			_pc001_handshake_lamp.self_modulate = Color("ef5350")
			_pc001_handshake_label.text = "待握手"
			_pc001_handshake_label.tooltip_text = "Gateway 在线，等待 PC001 客户端完成握手"
		_:
			_pc001_handshake_lamp.self_modulate = Color("ef5350")
			_pc001_handshake_label.text = "未连接"
			_pc001_handshake_label.tooltip_text = "尚无已完成握手的 PC001 客户端"
	_pc001_handshake_lamp.tooltip_text = _pc001_handshake_label.tooltip_text


func _on_pc001_link_status_changed(_connected: bool, _platform_linux: bool) -> void:
	_refresh_can_status()


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
	var changed := collapsed != _panel_collapsed
	_panel_collapsed = collapsed
	if _menu.is_empty():
		return
	(_menu["root"] as Control).visible = not collapsed
	_hud.visible = collapsed
	_panel_toggle_button.visible = collapsed
	_panel_toggle_button.text = "Esc  /  菜单"
	_panel_toggle_button.focus_mode = Control.FOCUS_NONE
	_panel_toggle_button.theme = GameSkin.create()
	if not changed:
		return
	if _camera != null:
		_camera.set_menu_input_blocked(not collapsed)
	if not collapsed:
		_saved_mouse_mode = Input.mouse_mode
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_resume_after_menu = String(_authority_status().get("lifecycle", "stopped")) == "running" and not get_tree().paused
		if _resume_after_menu:
			_on_pause_pressed()
		if _motion_client != null:
			_motion_client.set_focused(false)
		_menu_owns_pause = not get_tree().paused
		get_tree().paused = true
		(_menu["resume"] as Button).grab_focus()
		if _menu_tween != null:
			_menu_tween.kill()
		(_menu["root"] as Control).modulate.a = 0.0
		_menu_tween = create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
		_menu_tween.tween_property(_menu["root"], "modulate:a", 1.0, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	else:
		_confirmation.hide()
		if _menu_owns_pause:
			get_tree().paused = false
		_menu_owns_pause = false
		Input.mouse_mode = _saved_mouse_mode
		if _motion_client != null:
			_motion_client.set_focused(get_window().has_focus())
		if _resume_after_menu:
			_on_start_pressed()
		_resume_after_menu = false
		var focus := get_viewport().gui_get_focus_owner()
		if focus != null:
			focus.release_focus()


func set_panel_collapsed_for_test(collapsed: bool) -> void:
	_set_panel_collapsed(collapsed)


func is_panel_collapsed_for_test() -> bool:
	return _panel_collapsed


func _on_audio_muted(pressed: bool) -> void:
	if _feedback != null:
		_feedback.set_muted(pressed)


func show_control_guide() -> void:
	_set_panel_collapsed(false)
	(_menu["tabs"] as TabContainer).current_tab = 1


func _on_guide_closed() -> void:
	(_menu["tabs"] as TabContainer).current_tab = 0
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
	_sync_unlimited_bucket_toggle()
	_sync_cutting_diagnostics_toggle()


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
	diagnostics += "\n%s" % _terrain_diagnostics_text()
	diagnostics += "\n%s" % _bucket_ground_diagnostics_text(status)
	_diagnostics_label.text = diagnostics
	_refresh_can_status()
	_model_selector.tooltip_text = "%s — switching starts a fresh work session" % UIStrings.model_name(model_id)
	_refresh_soil()
	_refresh_warning(status, lifecycle, connection)
	_maybe_complete_action(status)
	_refresh_model_selector()
	_sync_bucket_passthrough_toggle()
	_sync_unlimited_bucket_toggle()
	_sync_cutting_diagnostics_toggle()


func _terrain_diagnostics_text() -> String:
	if _excavation_world == null:
		return "Terrain: unavailable"
	var excavation_status := _excavation_world.get_status_snapshot()
	var terrain_status := excavation_status.get("terrain3d", {}) as Dictionary
	var configured := String(terrain_status.get("configured_backend", "unknown"))
	var active := String(terrain_status.get("active_backend", "unknown"))
	var material := String(terrain_status.get("material_identity", "unknown"))
	var line := "Terrain: %s -> %s   Material: %s" % [configured, active, material]
	var fallback_reason := String(terrain_status.get("fallback_reason", "")).strip_edges()
	if not fallback_reason.is_empty():
		line += "   Fallback: %s" % fallback_reason.replace("\n", " ").left(120)
	return line


func _bucket_ground_diagnostics_text(session_status: Dictionary) -> String:
	var active := String(session_status.get("bucket_ground_mode", BucketGroundInteractionMode.NORMAL))
	var requested := String(session_status.get("requested_bucket_ground_mode", active))
	var pending := bool(session_status.get("bucket_ground_mode_pending", false))
	var soil_status := (
		_excavation_world.get_status_snapshot().get("bucket_ground_interaction", {}) as Dictionary
		if _excavation_world != null
		else {}
	)
	var last_transition := soil_status.get("last_transition", {}) as Dictionary
	var cleared_text := (
		"   cleared %.3f m³ / %.1f kg" % [
			float(last_transition.get("cleared_bucket_volume_m3", 0.0)),
			float(last_transition.get("cleared_payload_mass_kg", 0.0)),
		]
		if not last_transition.is_empty()
		else ""
	)
	return "Bucket ground: %s%s%s   soil exec/bypass: %d/%d" % [
		active,
		" -> %s (pending)" % requested if pending else "",
		cleared_text,
		int(soil_status.get("soil_steps_executed", 0)),
		int(soil_status.get("soil_steps_bypassed", 0)),
	]


func _sync_bucket_passthrough_toggle() -> void:
	if _bucket_passthrough_button == null:
		return
	var status := _product_session.get_status_snapshot() if _product_session != null else {}
	var requested := String(status.get(
		"requested_bucket_ground_mode",
		status.get("bucket_ground_mode", BucketGroundInteractionMode.NORMAL),
	))
	_bucket_passthrough_button.set_pressed_no_signal(
		BucketGroundInteractionMode.is_passthrough(requested)
	)


func _sync_unlimited_bucket_toggle() -> void:
	if _unlimited_bucket_button == null:
		return
	var status := _excavation_world.get_status_snapshot() if _excavation_world != null else {}
	_unlimited_bucket_button.disabled = not bool(
		status.get("voxel_unlimited_bucket_toggle_available", false)
	)
	_unlimited_bucket_button.set_pressed_no_signal(
		bool(status.get("voxel_unlimited_bucket_for_testing", false))
	)


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
	var visual_capacity := float(selected.get(
		"visual_bucket_capacity_m3",
		selected.get("contract_bucket_capacity_m3", status.get("bucket_capacity_m3", 0.35)),
	))
	var capacity := maxf(0.0, visual_capacity)
	var operation := _derive_operation(status, fill_ratio)
	_operation_label.text = UIStrings.operation_text(operation)
	_operation_label.add_theme_color_override("font_color", _operation_color(operation))
	_bucket_status_label.text = "斗载   %d%%     /     %.2f m³" % [roundi(fill_ratio * 100.0), volume]
	_bucket_fill.value = fill_ratio * 100.0
	var dig := _excavation_world.get_dig_diagnostics()
	var capacity_suffix := " (unlimited collection test)" if bool(status.get("voxel_unlimited_bucket_for_testing", false)) else ""
	_bucket_volume_label.text = "Bucket soil: %.3f / %.2f m³%s   Dig: %s pen=%.3f eng=%d%% boomV=%.2f boomPos=%.2f en=%d foc=%d" % [volume, capacity, capacity_suffix, String(dig.get("interaction", "?")), float(dig.get("penetration_m", 0.0)), roundi(float(dig.get("engagement", 0.0)) * 100.0), float(dig.get("boom_velocity", 0.0)), float(dig.get("boom_position", 0.0)), int(bool(dig.get("enabled", false))), int(bool(dig.get("focused", false)))]


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
	if String(status.get("bucket_ground_mode", BucketGroundInteractionMode.NORMAL)) == BucketGroundInteractionMode.PASSTHROUGH:
		warnings.append("Bucket-ground interaction bypassed for performance")
	var last_error := status.get("last_error", {}) as Dictionary
	if not last_error.is_empty():
		warnings.append("Recovery needed: %s" % String(last_error.get("message", last_error.get("code", "unknown error"))))
	if _chassis != null:
		var chassis_status := _chassis.get_status_snapshot()
		if not bool(chassis_status.get("neutral_armed", true)) or not bool(chassis_status.get("track_neutral_armed", true)):
			warnings.append(UIStrings.WARNING_NEUTRAL)
	_warning_label.text = UIStrings.WARNING_NONE if warnings.is_empty() else " • ".join(PackedStringArray(warnings))
	_warning_label.visible = not warnings.is_empty()
	_warning_label.add_theme_color_override("font_color", Color("73d99b") if warnings.is_empty() else Color("ffc45b"))


func _maybe_complete_action(status: Dictionary) -> void:
	if _awaiting_action.is_empty():
		return
	var generation := int(status.get("generation", -1))
	var model_id := String(status.get("active_model_id", ""))
	if _awaiting_action == "reset" and generation > _awaiting_generation:
		_completion_label.text = "Work session reset complete. Return controls to neutral to continue."
		_awaiting_action = ""
	elif _awaiting_action == "model_switch" and model_id == _awaiting_model_id and generation > _awaiting_generation:
		_completion_label.text = "%s ready. Return controls to neutral to continue." % UIStrings.model_name(model_id)
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
	if _hud != null:
		_hud.set_prompt_mode(_prompt_mode)
	_control_hint.text = UIStrings.CONTROL_HINT_GAMEPAD if _prompt_mode == "gamepad" else UIStrings.CONTROL_HINT_KEYBOARD
	_guide_device_label.text = "当前输入：手柄" if _prompt_mode == "gamepad" else "当前输入：键盘与鼠标"
	_guide_controls_label.text = UIStrings.GUIDE_GAMEPAD if _prompt_mode == "gamepad" else UIStrings.GUIDE_KEYBOARD


func set_prompt_mode_for_test(value: String) -> void:
	_set_prompt_mode(value)


func get_prompt_mode_for_test() -> String:
	return _prompt_mode


func get_soil_generation_key_for_test() -> String:
	return _soil_generation_key

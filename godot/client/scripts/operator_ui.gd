class_name MotionOperatorUI
extends CanvasLayer

const MenuLayout := preload("res://scripts/game_menu_layout.gd")
const GameSkin := preload("res://scripts/game_ui_theme.gd")
const Capture := preload("res://scripts/performance_capture.gd")
const MenuControls := preload("res://scenes/operator_menu_controls.tscn")

const UIStrings := preload("res://scripts/operator_ui_strings.gd")
const SlopeSideView := preload("res://scripts/slope_side_view.gd")
const DtmPanel := preload("res://scripts/dtm_dashboard.gd")
const CONFIG_PATH := "user://operator_ui.cfg"
# Standalone test runners can isolate preferences before this node enters the tree.
var preferences_path := CONFIG_PATH
const CONFIG_SECTION := "onboarding"
const CONFIG_GUIDE_DISMISSED := "guide_dismissed"
const CONFIG_SECTION_UI := "ui"
const CONFIG_UI_THEME := "theme"
const CONFIG_SECTION_VIDEO := "video"
const CONFIG_VIDEO_WINDOW_MODE := "window_mode"
const CONFIG_VIDEO_FPS_LIMIT := "fps_limit"
const WINDOW_MODE_FULLSCREEN := "fullscreen"
const WINDOW_MODE_BORDERLESS := "borderless"
const WINDOW_MODE_WINDOWED := "windowed"

@export var motion_client_path := NodePath("../MotionClient")
@export var product_session_path := NodePath("../ProductSession")
@export var excavation_world_path := NodePath("../TerrainRoot/ExcavationWorld")
@export var chassis_path := NodePath("../ChassisMotionRoot")
@export var camera_path := NodePath("../Camera3D")
@export var feedback_path := NodePath("../MachineFeedback")
@export var visual_quality_path := NodePath("../VisualQualityController")
@export var attachment_rig_path := NodePath("../AttachmentRig")

var _motion_client: MotionClient
var _product_session: ProductSession
var _attachment_rig: AttachmentRig
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
var _performance_overlay: Control
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
var _close_tween: Tween
var _quality_before_test := "balanced"
var _ignore_quality_toggle := false
var _menu_nav_joy_latch := 0

var _status_panel: PanelContainer
var _panel_toggle_button: Button
var _title_label: Label
var _model_selector: OptionButton
var _coupler_selector: OptionButton
var _attachment_selector: OptionButton
var _ignore_attachment_selection := false
var _lifecycle_badge: Label
var _operation_label: Label
var _bucket_status_label: Label
var _bucket_fill: ProgressBar
var _control_hint: Label
var _automatic_soil_hint: Label
var _camera_mode_label: Label
var _camera_selector: OptionButton
var _reset_view_button: Button
var _warning_label: Label
var _completion_label: Label
var _connection_label: Label
var _authority_label: Label
var _lifecycle_label: Label
var _diagnostics_label: Label
var _can_status_label: Label
var _can_output_button: Button
var _gateway_button: Button
var _pc001_handshake_lamp: Panel
var _pc001_handshake_label: Label
var _timed_can_button: Button
var _gateway_host_edit: LineEdit
var _gateway_port_edit: LineEdit
var _unlimited_bucket_button: CheckButton
var _cutting_diagnostics_button: CheckButton
var _race_mode_button: CheckButton
var _relaxed_assist_button: CheckButton
var _offzone_soil_button: CheckButton
var _simple_digging_selector: OptionButton

const GATEWAY_CONFIG_PATH := "user://ict_config.cfg"
var _bucket_volume_label: Label
var _advanced_panel: VBoxContainer
var _reset_button: Button
var _mute_audio_button: CheckButton
var _menu_preferences_loaded := false
var _saved_level_assist := false
var _test_graphics_button: CheckButton
var _bucket_passthrough_button: CheckButton
var _level_assist_button: CheckButton
var _slope_assist_button: Button
var _guide_panel: PanelContainer
var _guide_title_label: Label
var _guide_intro_label: Label
var _guide_device_label: Label
var _guide_controls_label: Label
var _guide_recovery_label: Label
var _guide_close_button: Button
var _confirmation: ConfirmationDialog
var _assist_menu_panel: PanelContainer
var _navigation_label: Label
var _assist_menu_rows_box: VBoxContainer
var _assist_menu_rows: Array[Button] = []
var _assist_menu_stripe: ColorRect
var _assist_menu_tick: ColorRect
var _assist_menu_title: Label
var _assist_menu_micro: Label
var _assist_menu_hint: Label
var _slope_side_view: SlopeSideView
var _dtm: DtmPanel
var _dtm_toggle: Button
var _dtm_open := false
var _dtm_file: FileDialog
var _dtm_placement: OptionButton
var _dtm_height: SpinBox
var _dtm_import_owns_menu := false
var _ui_theme := GameSkin.VARIANT_DEBUG


func _init() -> void:
	# Instantiate bindings only at runtime, so the main scene never displays
	# the pre-composition control layout in the editor.
	_instantiate_menu_controls()


func _instantiate_menu_controls() -> void:
	var controls := MenuControls.instantiate()
	for child in controls.get_children():
		controls.remove_child(child)
		# The instantiated scene owns these nodes; clear ownership so adding
		# and reparenting them under OperatorUI stays consistent on rebuild.
		_clear_owner_recursive(child)
		add_child(child)
	controls.free()


static func _clear_owner_recursive(node: Node) -> void:
	node.owner = null
	for child in node.get_children():
		_clear_owner_recursive(child)


func _bind_controls() -> void:
	_status_panel = $StatusPanel
	_panel_toggle_button = $PanelToggle
	_title_label = $StatusPanel/Margin/VBox/Title
	_model_selector = $StatusPanel/Margin/VBox/Header/ModelSelector
	_lifecycle_badge = $StatusPanel/Margin/VBox/Header/LifecycleBadge
	_operation_label = $StatusPanel/Margin/VBox/Operation
	_bucket_status_label = $StatusPanel/Margin/VBox/BucketStatus
	_bucket_fill = $StatusPanel/Margin/VBox/BucketFill
	_control_hint = $StatusPanel/Margin/VBox/ControlHint
	_automatic_soil_hint = $StatusPanel/Margin/VBox/AutomaticSoilHint
	_camera_mode_label = $StatusPanel/Margin/VBox/CameraRow/Mode
	_camera_selector = $StatusPanel/Margin/VBox/CameraRow/Selector
	_reset_view_button = $StatusPanel/Margin/VBox/CameraRow/ResetView
	_warning_label = $StatusPanel/Margin/VBox/Warning
	_completion_label = $StatusPanel/Margin/VBox/Completion
	_connection_label = $StatusPanel/Margin/VBox/AdvancedPanel/Connection
	_authority_label = $StatusPanel/Margin/VBox/AdvancedPanel/Authority
	_lifecycle_label = $StatusPanel/Margin/VBox/AdvancedPanel/Lifecycle
	_diagnostics_label = $StatusPanel/Margin/VBox/AdvancedPanel/Diagnostics
	_can_status_label = $StatusPanel/Margin/VBox/AdvancedPanel/CANStatus
	_can_output_button = $StatusPanel/Margin/VBox/Tools/CANOutputToggle
	_gateway_button = $StatusPanel/Margin/VBox/Tools/GatewayRestartButton
	_pc001_handshake_lamp = $StatusPanel/Margin/VBox/Tools/PC001HandshakeStatus/Lamp
	_pc001_handshake_label = $StatusPanel/Margin/VBox/Tools/PC001HandshakeStatus/Label
	_timed_can_button = $StatusPanel/Margin/VBox/Tools/TimedCANTrigger
	_gateway_host_edit = $StatusPanel/Margin/VBox/AdvancedPanel/GatewayHost
	_gateway_port_edit = $StatusPanel/Margin/VBox/AdvancedPanel/GatewayPort
	_unlimited_bucket_button = $StatusPanel/Margin/VBox/AdvancedPanel/UnlimitedBucketCapacity
	_cutting_diagnostics_button = $StatusPanel/Margin/VBox/AdvancedPanel/CuttingDiagnostics
	_race_mode_button = $StatusPanel/Margin/VBox/AdvancedPanel/RaceMode
	_relaxed_assist_button = $StatusPanel/Margin/VBox/AdvancedPanel/RelaxedAssist
	_simple_digging_selector = $StatusPanel/Margin/VBox/AdvancedPanel/SimpleDigging
	_bucket_volume_label = $StatusPanel/Margin/VBox/AdvancedPanel/BucketVolume
	_advanced_panel = $StatusPanel/Margin/VBox/AdvancedPanel
	_reset_button = $StatusPanel/Margin/VBox/Actions/Reset
	_mute_audio_button = $StatusPanel/Margin/VBox/Tools/MuteAudio
	_test_graphics_button = $StatusPanel/Margin/VBox/Tools/TestGraphics
	_bucket_passthrough_button = $StatusPanel/Margin/VBox/Tools/BucketPassthrough
	_level_assist_button = $StatusPanel/Margin/VBox/Tools/LevelAssist
	_slope_assist_button = $StatusPanel/Margin/VBox/Tools/SlopeAssist
	_guide_panel = $GuidePanel
	_guide_title_label = $GuidePanel/Margin/VBox/Title
	_guide_intro_label = $GuidePanel/Margin/VBox/Intro
	_guide_device_label = $GuidePanel/Margin/VBox/Device
	_guide_controls_label = $GuidePanel/Margin/VBox/Controls
	_guide_recovery_label = $GuidePanel/Margin/VBox/Recovery
	_guide_close_button = $GuidePanel/Margin/VBox/Close
	_confirmation = $DestructiveConfirmation


func _connect_controls() -> void:
	_panel_toggle_button.pressed.connect(_on_panel_toggle_pressed)
	_reset_button.pressed.connect(_on_reset_pressed)
	_mute_audio_button.toggled.connect(_on_audio_muted)
	_test_graphics_button.toggled.connect(_on_test_graphics_toggled)
	_bucket_passthrough_button.toggled.connect(_on_bucket_passthrough_toggled)
	_level_assist_button.toggled.connect(_on_level_assist_toggled)
	_slope_assist_button.pressed.connect(_on_slope_assist_pressed)
	_unlimited_bucket_button.toggled.connect(_on_unlimited_bucket_toggled)
	_cutting_diagnostics_button.toggled.connect(_on_cutting_diagnostics_toggled)
	_race_mode_button.toggled.connect(_on_race_mode_toggled)
	_relaxed_assist_button.toggled.connect(_on_relaxed_assist_toggled)
	_offzone_soil_button = CheckButton.new()
	_offzone_soil_button.name = "OffzoneSoil"
	_offzone_soil_button.text = "区外堆土（可挖掘、可行驶）"
	_offzone_soil_button.tooltip_text = "在地图地面倾倒形成土堆。关闭后已有土堆保留，重置地图清除。简易挖掘生效时不能卸土。"
	_simple_digging_selector.get_parent().add_child(_offzone_soil_button)
	_offzone_soil_button.disabled = get_parent().get_node_or_null("StaticMap/Ground") == null
	if _offzone_soil_button.disabled:
		_offzone_soil_button.tooltip_text = "区外堆土适用于 urban 和 construction 地图。"
	_offzone_soil_button.set_pressed_no_signal(_product_session != null and _product_session.offzone_soil_enabled)
	_offzone_soil_button.toggled.connect(_on_offzone_soil_toggled)
	_configure_simple_digging_selector()
	_can_output_button.pressed.connect(_on_can_output_pressed)
	_gateway_button.pressed.connect(_on_gateway_restart_pressed)
	_timed_can_button.pressed.connect(_on_timed_can_pressed)
	_guide_close_button.pressed.connect(_on_guide_closed)
	_reset_view_button.pressed.connect(_on_reset_view_pressed)
	_confirmation.window_input.connect(_on_confirmation_input)
	_confirmation.confirmed.connect(_on_destructive_confirmed)
	_confirmation.canceled.connect(_on_destructive_canceled)


func _ready() -> void:
	_motion_client = get_node_or_null(motion_client_path) as MotionClient
	_product_session = get_node_or_null(product_session_path) as ProductSession
	_ensure_ui_pad_bindings()
	_excavation_world = get_node_or_null(excavation_world_path) as ExcavationWorld
	_attachment_rig = get_node_or_null(attachment_rig_path) as AttachmentRig
	_chassis = get_node_or_null(chassis_path) as TrackedChassisController
	_camera = get_node_or_null(camera_path) as CameraRig
	_feedback = get_node_or_null(feedback_path) as MachineFeedback
	_visual_quality = get_node_or_null(visual_quality_path) as VisualQualityController
	_performance_capture = get_node_or_null("../PerformanceCapture") as Capture
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ui_theme = _load_ui_theme()
	_bind_controls()
	if _feedback != null:
		_mute_audio_button.set_pressed_no_signal(_feedback.is_muted())
	_connect_controls()
	_apply_dialog_theme()
	_apply_static_copy()
	_configure_model_selector()
	_configure_camera_selector()
	_load_gateway_config()
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
		_product_session.attachment_changed.connect(_on_attachment_changed)
	if _camera != null:
		_camera.mode_changed.connect(_on_camera_mode_changed)
	var can_bridge := _can_bridge()
	if can_bridge != null and can_bridge.has_signal("ict_link_status_changed"):
		can_bridge.connect("ict_link_status_changed", _on_pc001_link_status_changed)
	_apply_saved_video_settings()
	_menu = MenuLayout.build(self, _ui_theme)
	_wire_built_menu()
	_build_capture_controls()
	_hud = $ControlInputHUD as ControlInputHUD
	_hud.set_theme_variant(_ui_theme)
	_advanced_panel.visible = true
	get_viewport().size_changed.connect(_layout_menu)
	_layout_menu()
	_set_panel_collapsed(true)
	_sync_test_graphics_toggle()
	_load_race_mode()
	_load_assist_options()
	_load_menu_preferences()
	_guide_panel.visible = false
	_build_assist_menu()
	_build_slope_side_view()
	_build_dtm()
	call_deferred("_start_product_gameplay")
	_refresh_prompt_copy()
	_refresh()
	_refresh_model_selector()
	_refresh_attachment_selector()


func _apply_dialog_theme() -> void:
	_confirmation.theme = GameSkin.create(_ui_theme)
	_confirmation.ok_button_text = "确认"
	_confirmation.cancel_button_text = "取消"
	_style_assist_menu()


## Single-hotkey assist picker (T): a small centered panel mirrored from the
## chassis assist_menu status block. Keyboard W/S navigates, Enter activates,
## T/Esc closes — rows stay clickable when the pointer is free.
func _build_assist_menu() -> void:
	_navigation_label = Label.new()
	_navigation_label.name = "NavigationStatus"
	_navigation_label.position = Vector2(24, 80)
	_navigation_label.custom_minimum_size = Vector2(320, 30)
	_navigation_label.size.x = 320
	_navigation_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_navigation_label.add_theme_font_size_override("font_size", 13)
	_navigation_label.add_theme_color_override("font_color", Color("b6ccd8"))
	var navigation_style := StyleBoxFlat.new()
	navigation_style.bg_color = Color(0.035, 0.065, 0.085, 0.88)
	navigation_style.set_corner_radius_all(6)
	navigation_style.content_margin_left = 12
	navigation_style.content_margin_right = 12
	navigation_style.content_margin_top = 6
	navigation_style.content_margin_bottom = 6
	_navigation_label.add_theme_stylebox_override("normal", navigation_style)
	_navigation_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_navigation_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_navigation_label.add_theme_constant_override("shadow_offset_x", 2)
	_navigation_label.add_theme_constant_override("shadow_offset_y", 2)
	add_child(_navigation_label)
	_assist_menu_panel = PanelContainer.new()
	_assist_menu_panel.name = "AssistMenu"
	_assist_menu_panel.visible = false
	_assist_menu_panel.custom_minimum_size = Vector2(280, 0)
	_assist_menu_panel.set_anchors_preset(Control.PRESET_CENTER)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	_assist_menu_panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	margin.add_child(box)
	# Console chrome: hazard edge, accent tick and a micro label — hidden under
	# the debug theme, which keeps the plain centered dialog.
	_assist_menu_stripe = ColorRect.new()
	_assist_menu_stripe.custom_minimum_size = Vector2(0, 4)
	var stripe_material := ShaderMaterial.new()
	stripe_material.shader = load("res://shaders/hazard_stripes.gdshader")
	stripe_material.set_shader_parameter("scroll_px_s", 18.0)
	_assist_menu_stripe.material = stripe_material
	_assist_menu_stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_assist_menu_stripe)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	box.add_child(head)
	_assist_menu_tick = ColorRect.new()
	_assist_menu_tick.custom_minimum_size = Vector2(4, 16)
	head.add_child(_assist_menu_tick)
	_assist_menu_title = Label.new()
	_assist_menu_title.text = "辅助控制"
	_assist_menu_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_assist_menu_title)
	_assist_menu_micro = Label.new()
	_assist_menu_micro.text = "ASSIST"
	_assist_menu_micro.add_theme_font_size_override("font_size", 10)
	_assist_menu_micro.add_theme_color_override("font_color", GameSkin.MUTED)
	_assist_menu_micro.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(_assist_menu_micro)
	_assist_menu_rows_box = VBoxContainer.new()
	_assist_menu_rows_box.name = "Rows"
	box.add_child(_assist_menu_rows_box)
	_assist_menu_hint = Label.new()
	_assist_menu_hint.text = UIStrings.ASSIST_MENU_HINT_KEYBOARD
	_assist_menu_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_assist_menu_hint.add_theme_font_size_override("font_size", 11)
	box.add_child(_assist_menu_hint)
	add_child(_assist_menu_panel)
	_style_assist_menu()


## Re-apply variant chrome to the assist picker: theme swap, stripe tint,
## title styling, and a row rebuild since rows carry variant-specific styles.
func _style_assist_menu() -> void:
	if _assist_menu_panel == null:
		return
	var console := GameSkin.is_console_variant(_ui_theme)
	var accent := GameSkin.accent_for(_ui_theme)
	_assist_menu_panel.theme = GameSkin.create(_ui_theme)
	_assist_menu_panel.modulate.a = 1.0
	_assist_menu_panel.scale = Vector2.ONE
	_assist_menu_stripe.visible = console
	(_assist_menu_stripe.material as ShaderMaterial).set_shader_parameter("stripe_color", accent)
	_assist_menu_tick.visible = console
	_assist_menu_tick.color = accent
	_assist_menu_micro.visible = console
	_assist_menu_title.add_theme_color_override("font_color", accent if console else GameSkin.PAPER)
	_assist_menu_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if console else HORIZONTAL_ALIGNMENT_CENTER
	_assist_menu_hint.add_theme_color_override("font_color", GameSkin.MUTED if console else GameSkin.PAPER)
	for row in _assist_menu_rows:
		row.queue_free()
	_assist_menu_rows.clear()
	_sync_assist_menu()


## Open pop for the assist picker under console variants: fade plus a small
## elastic scale from the panel centre. Deferred so the panel's laid-out size
## is known before the pivot is set.
func _pop_assist_menu() -> void:
	if _assist_menu_panel == null or not _assist_menu_panel.visible:
		return
	_assist_menu_panel.pivot_offset = _assist_menu_panel.size * 0.5
	_assist_menu_panel.scale = Vector2(0.9, 0.9)
	var pop := _assist_menu_panel.create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	pop.tween_property(_assist_menu_panel, "modulate:a", 1.0, 0.14)
	pop.parallel().tween_property(_assist_menu_panel, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Independent read-only construction guidance; import reuses menu pause ownership.
func _build_dtm() -> void:
	_dtm = DtmPanel.new()
	_dtm.model.sampler.zone = get_node_or_null("../TerrainRoot/VoxelWorkZone") as VoxelWorkZone
	if _excavation_world != null:
		_dtm.model.identity_provider = _excavation_world.get_surface_measurement_identity
	_dtm.presentation = get_node_or_null("../MotionPresentation") as MotionPresentation
	_dtm.visible = false
	add_child(_dtm)
	_dtm.set_theme_variant(_ui_theme)
	var config := ConfigFile.new()
	config.load(preferences_path)
	_dtm.set_chart_style(String(config.get_value(CONFIG_SECTION_UI, "dtm_chart_style", "terrain")))
	_dtm.chart_style_changed.connect(func(style: String) -> void: _save_menu_preference("dtm_chart_style", style))
	_dtm.import_requested.connect(_open_dtm_import)
	_dtm.automatic_requested.connect(func() -> void:
		if BucketGroundInteractionMode.is_passthrough(_product_session.bucket_ground_mode):
			_product_session.request_bucket_ground_mode(BucketGroundInteractionMode.NORMAL)
			await get_tree().physics_frame
			await get_tree().physics_frame
		if _chassis.surface_job.state == "paused":
			_chassis.resume_surface_job()
		elif not _chassis.start_surface_job(_dtm.model.surface, _dtm.model.sampler):
			_dtm.show_error("无法开始自动作业：" + _chassis.surface_job.reason))
	_dtm.automatic_cancelled.connect(func() -> void: _chassis.cancel_surface_job())
	_dtm.digging_mode_requested.connect(func(simple: bool) -> void:
		_chassis.cancel_surface_job()
		_product_session.request_simple_digging(simple)
		_chassis.surface_job.simple_mode = simple)
	_dtm.dump_side_requested.connect(func(right: bool) -> void:
		_chassis.cancel_surface_job()
		_chassis.surface_job.dump_right = right)
	_dtm.urban_trench_requested.connect(_load_automatic_trench)
	_dtm.design_changed.connect(func() -> void: _chassis.cancel_surface_job())
	_dtm.automatic_status = _chassis.surface_job.snapshot
	_dtm.close_requested.connect(func() -> void: _dtm_open = false; _sync_dtm_visibility())
	_build_dtm_menu_entry()
	_dtm_file = FileDialog.new()
	_dtm_file.title = "导入施工目标 · LandXML 米制 TIN"
	_dtm_file.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_dtm_file.access = FileDialog.ACCESS_FILESYSTEM
	_dtm_file.filters = PackedStringArray(["*.xml,*.landxml ; LandXML TIN"])
	_dtm_file.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN
	_dtm_file.min_size = Vector2i(760, 480)
	add_child(_dtm_file)
	var options := HBoxContainer.new()
	_dtm_file.get_vbox().add_child(options)
	_dtm_placement = OptionButton.new()
	_dtm_placement.add_item("平面居中到体素区 · 保留原标高")
	_dtm_placement.add_item("保留原坐标 · E→X / N→Z")
	options.add_child(_dtm_placement)
	var label := Label.new()
	label.text = "高程偏移 (m)"
	options.add_child(label)
	_dtm_height = SpinBox.new()
	_dtm_height.min_value = -100000
	_dtm_height.max_value = 100000
	_dtm_height.step = 0.01
	_dtm_height.custom_minimum_size.x = 130
	options.add_child(_dtm_height)
	_dtm_file.file_selected.connect(func(path: String) -> void:
		_dtm.import_file(path, _dtm_placement.selected == 0, _dtm_height.value)
		_finish_dtm_import())
	_dtm_file.canceled.connect(_finish_dtm_import)


func _load_automatic_trench() -> void:
	var bucket := DtmModel.bucket_state(_dtm.presentation)
	if bucket.is_empty():
		_dtm.show_error("当前附件没有可用铲齿")
		return
	var tooth: Vector3 = bucket.tooth
	var axis: Vector2 = bucket.axis
	var side := Vector2(-axis.y, axis.x)
	var center := Vector2(tooth.x, tooth.z)
	var height := _dtm.model.sampler.height_at(center)
	if not is_finite(height):
		_dtm.show_error("铲斗轴线不在可测量的体素区")
		return
	var xml := '<LandXML><Units><Metric linearUnit="meter"/></Units><Surfaces><Surface name="轴线沟 · 10m · 深1m"><Definition surfType="TIN"><Pnts>'
	for i in 4:
		var p := center + side * float(bucket.width) * (-0.5 if i in [0, 3] else 0.5) - axis * (10.0 if i in [2, 3] else 0.0)
		xml += '<P id="%d">%.6f %.6f %.6f</P>' % [i + 1, p.y, p.x, height - 1.0]
	xml += '</Pnts><Faces><F>1 2 3</F><F>1 3 4</F></Faces></Definition></Surface></Surfaces></LandXML>'
	var parsed := LandXmlSurface.parse(xml)
	if not parsed.error.is_empty():
		_dtm.show_error(parsed.error)
		return
	_chassis.cancel_surface_job()
	_dtm.load_local_surfaces(parsed.surfaces, "当前铲斗轴线向后 10m · 深1m · 正常模式自动回转卸土")


func _build_dtm_menu_entry() -> void:
	_dtm_toggle = Button.new()
	_dtm_toggle.name = "DtmToggle"
	_dtm_toggle.text = "打开 DTM 施工引导 · P"
	_dtm_toggle.tooltip_text = "作业时按 P 打开或收起；面板内可切换 HUD 模式。"
	_advanced_panel.add_child(_dtm_toggle)
	_dtm_toggle.pressed.connect(func() -> void:
		_set_panel_collapsed(true)
		_dtm_open = true
		if _dtm.model.surface == null:
			_dtm.load_demo("pit")
		_sync_dtm_visibility())


func _toggle_dtm() -> void:
	if not _panel_collapsed or _dtm_file.visible:
		return
	_dtm_open = not _dtm_open
	if _dtm_open and _dtm.model.surface == null:
		_dtm.load_demo("pit")
	_sync_dtm_visibility()


func _sync_dtm_visibility() -> void:
	if _dtm == null:
		return
	var assist_open := _chassis != null and _chassis.is_assist_menu_open()
	_dtm.visible = _dtm_open and _panel_collapsed and not assist_open
	_hud.visible = _panel_collapsed and not _dtm.visible
	if _slope_side_view != null and _dtm.visible:
		_slope_side_view.hide()


func _open_dtm_import() -> void:
	_dtm_import_owns_menu = _panel_collapsed
	if _dtm_import_owns_menu:
		_set_panel_collapsed(false)
	_sync_dtm_visibility()
	_dtm_file.popup_centered_ratio(0.75)


func _finish_dtm_import() -> void:
	_dtm_file.hide()
	if _dtm_import_owns_menu:
		_set_panel_collapsed(true)
	_dtm_import_owns_menu = false
	_sync_dtm_visibility()


## Assist guidance view of machine links, terrain and the active target profile.
func _build_slope_side_view() -> void:
	_slope_side_view = SlopeSideView.new()
	_slope_side_view.name = "SlopeSideView"
	_slope_side_view.visible = false
	_slope_side_view.set_theme_variant(_ui_theme)
	_slope_side_view.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	_slope_side_view.offset_left = -380.0
	_slope_side_view.offset_right = -20.0
	_slope_side_view.offset_top = -110.0
	_slope_side_view.offset_bottom = 110.0
	add_child(_slope_side_view)


func _wire_built_menu() -> void:
	(_menu["resume"] as Button).pressed.connect(_on_panel_toggle_pressed)
	var tabs := _menu["tabs"] as TabContainer
	tabs.tab_changed.connect(_on_menu_tab_changed)
	tabs.get_tab_bar().focus_mode = Control.FOCUS_ALL
	_configure_attachment_selector()
	_configure_map_selector()
	_configure_theme_selector()
	_configure_video_selectors()
	var dock := _menu.get("hardware") as Control
	if dock != null:
		dock.resized.connect(_layout_menu)


func _load_ui_theme() -> String:
	var config := ConfigFile.new()
	if config.load(preferences_path) != OK:
		return GameSkin.VARIANT_DEBUG
	var variant := String(config.get_value(CONFIG_SECTION_UI, CONFIG_UI_THEME, GameSkin.VARIANT_DEBUG))
	return variant if variant in GameSkin.VARIANTS else GameSkin.VARIANT_DEBUG


func _configure_theme_selector() -> void:
	var selector := _menu["theme_selector"] as OptionButton
	selector.add_item("界面主题：调试")
	selector.set_item_metadata(0, GameSkin.VARIANT_DEBUG)
	selector.add_item("界面主题：工业重机")
	selector.set_item_metadata(1, GameSkin.VARIANT_INDUSTRIAL)
	selector.add_item("界面主题：三一重工")
	selector.set_item_metadata(2, GameSkin.VARIANT_SANY)
	selector.tooltip_text = "切换界面主题，立即生效并记住选择。工业重机与三一重工主题下驾驶时只保留右下操作提示。"
	_refresh_theme_selector()
	selector.item_selected.connect(_on_ui_theme_selected)


func _refresh_theme_selector() -> void:
	var selector := _menu.get("theme_selector") as OptionButton
	if selector == null:
		return
	for index in range(selector.item_count):
		if String(selector.get_item_metadata(index)) == _ui_theme:
			selector.select(index)
			break


func _on_ui_theme_selected(index: int) -> void:
	var selector := _menu["theme_selector"] as OptionButton
	_apply_ui_theme(String(selector.get_item_metadata(index)))


func _apply_ui_theme(variant: String) -> void:
	if variant not in GameSkin.VARIANTS or variant == _ui_theme:
		_refresh_theme_selector()
		return
	_ui_theme = variant
	var config := ConfigFile.new()
	config.load(preferences_path)
	config.set_value(CONFIG_SECTION_UI, CONFIG_UI_THEME, variant)
	config.save(preferences_path)
	_rebuild_menu_theme()


## Video settings live on their own page and persist next to the theme in
## operator_ui.cfg; applied once at startup (saved values) and live on every
## selection. Window mode maps to exclusive fullscreen / borderless fullscreen
## / windowed; fps limit writes Engine.max_fps (0 = uncapped).
func _apply_saved_video_settings() -> void:
	var config := ConfigFile.new()
	config.load(preferences_path)
	_apply_window_mode(String(config.get_value(CONFIG_SECTION_VIDEO, CONFIG_VIDEO_WINDOW_MODE, WINDOW_MODE_WINDOWED)))
	_apply_fps_limit(int(config.get_value(CONFIG_SECTION_VIDEO, CONFIG_VIDEO_FPS_LIMIT, 60)))


func _configure_video_selectors() -> void:
	var window_selector := _menu.get("window_mode_selector") as OptionButton
	if window_selector != null:
		window_selector.add_item("显示模式：窗口")
		window_selector.set_item_metadata(0, WINDOW_MODE_WINDOWED)
		window_selector.add_item("显示模式：无边框全屏")
		window_selector.set_item_metadata(1, WINDOW_MODE_BORDERLESS)
		window_selector.add_item("显示模式：全屏")
		window_selector.set_item_metadata(2, WINDOW_MODE_FULLSCREEN)
		window_selector.tooltip_text = "窗口 / 无边框全屏 / 独占全屏，立即生效并记住选择。无边框全屏切换应用窗口更顺畅。"
		window_selector.item_selected.connect(_on_window_mode_selected)
	var fps_selector := _menu.get("fps_limit_selector") as OptionButton
	if fps_selector != null:
		fps_selector.add_item("帧率上限：60 FPS")
		fps_selector.set_item_metadata(0, 60)
		fps_selector.add_item("帧率上限：120 FPS")
		fps_selector.set_item_metadata(1, 120)
		fps_selector.add_item("帧率上限：不限制")
		fps_selector.set_item_metadata(2, 0)
		fps_selector.tooltip_text = "限制渲染帧率上限；高于 60 需要高刷新率显示器。"
		fps_selector.item_selected.connect(_on_fps_limit_selected)
	_refresh_video_selectors()


func _refresh_video_selectors() -> void:
	var window_selector := _menu.get("window_mode_selector") as OptionButton
	if window_selector != null:
		var mode := _current_window_mode_id()
		for index in range(window_selector.item_count):
			if String(window_selector.get_item_metadata(index)) == mode:
				window_selector.select(index)
				break
	var fps_selector := _menu.get("fps_limit_selector") as OptionButton
	if fps_selector != null:
		for index in range(fps_selector.item_count):
			if int(fps_selector.get_item_metadata(index)) == Engine.max_fps:
				fps_selector.select(index)
				break


func _current_window_mode_id() -> String:
	match DisplayServer.window_get_mode():
		DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
			return WINDOW_MODE_FULLSCREEN
		DisplayServer.WINDOW_MODE_FULLSCREEN:
			return WINDOW_MODE_BORDERLESS
	return WINDOW_MODE_WINDOWED


func _on_window_mode_selected(index: int) -> void:
	var selector := _menu.get("window_mode_selector") as OptionButton
	var mode_id := String(selector.get_item_metadata(index))
	_apply_window_mode(mode_id)
	_save_video_config(mode_id, Engine.max_fps)


func _apply_window_mode(mode_id: String) -> void:
	# Scene reloads recreate this UI, but keep the OS window. Reapplying
	# WINDOWED restores a maximized window and recenters a manually sized one.
	if mode_id == _current_window_mode_id():
		return
	match mode_id:
		WINDOW_MODE_FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		WINDOW_MODE_BORDERLESS:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		_:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			var screen := DisplayServer.screen_get_position(DisplayServer.window_get_current_screen())
			screen += DisplayServer.screen_get_size() / 2
			DisplayServer.window_set_position(screen - DisplayServer.window_get_size() / 2)


func _on_fps_limit_selected(index: int) -> void:
	var selector := _menu.get("fps_limit_selector") as OptionButton
	var limit := int(selector.get_item_metadata(index))
	_apply_fps_limit(limit)
	_save_video_config(_current_window_mode_id(), limit)


func _apply_fps_limit(limit: int) -> void:
	Engine.max_fps = maxi(limit, 0)


## Persist the requested state, not the observed one: a window manager may
## refuse or defer a mode change, but the user's choice is what reloads.
func _save_video_config(window_mode_id: String, fps_limit: int) -> void:
	var config := ConfigFile.new()
	config.load(preferences_path)
	config.set_value(CONFIG_SECTION_VIDEO, CONFIG_VIDEO_WINDOW_MODE, window_mode_id)
	config.set_value(CONFIG_SECTION_VIDEO, CONFIG_VIDEO_FPS_LIMIT, fps_limit)
	config.save(preferences_path)


## Runtime theme switch: the two variants compose different menu structures
## (dock, header lamp, CAN controls), so the composed UI is torn down and
## rebuilt from the pre-composition scene while gameplay stays paused.
func _rebuild_menu_theme() -> void:
	if _menu_tween != null:
		_menu_tween.kill()
	if _page_tween != null:
		_page_tween.kill()
	if is_instance_valid(_confirmation):
		_confirmation.hide()
	_pending_action = ""
	_pending_model_id = ""
	var stale: Array[Node] = []
	for key in ["root", "hardware"]:
		var node := _menu.get(key) as Node
		if is_instance_valid(node):
			stale.append(node)
	for node in [_panel_toggle_button, _guide_panel, _confirmation]:
		if is_instance_valid(node):
			stale.append(node)
	for node in stale:
		# Detach immediately so the re-instantiated controls keep their exact
		# scene names; queue_free alone would collide until the frame ends.
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		node.queue_free()
	_menu = {}
	_instantiate_menu_controls()
	_bind_controls()
	_connect_controls()
	if _feedback != null:
		_mute_audio_button.set_pressed_no_signal(_feedback.is_muted())
	_apply_dialog_theme()
	_apply_static_copy()
	_configure_model_selector()
	_configure_camera_selector()
	_load_gateway_config()
	_menu = MenuLayout.build(self, _ui_theme)
	_wire_built_menu()
	_build_capture_controls()
	_advanced_panel.visible = true
	_hud.set_theme_variant(_ui_theme)
	if _slope_side_view != null:
		_slope_side_view.set_theme_variant(_ui_theme)
	if _dtm != null:
		_dtm.set_theme_variant(_ui_theme)
		_build_dtm_menu_entry()
	_guide_panel.visible = false
	_layout_menu()
	_set_panel_collapsed(_panel_collapsed)
	_refresh_prompt_copy()
	_sync_test_graphics_toggle()
	_sync_race_mode_toggle()
	_sync_relaxed_assist_toggle()
	_sync_simple_digging_selector()
	_refresh()
	_refresh_model_selector()
	_refresh_capture_status()
	if not _panel_collapsed:
		(_menu["resume"] as Button).grab_focus()


func set_ui_theme_for_test(variant: String) -> void:
	_apply_ui_theme(variant)


func get_ui_theme_for_test() -> String:
	return _ui_theme


func _apply_static_copy() -> void:
	_title_label.text = UIStrings.TITLE
	_automatic_soil_hint.text = UIStrings.SOIL_AUTOMATIC_HINT
	_reset_button.text = UIStrings.BUTTON_RESET
	_mute_audio_button.text = UIStrings.BUTTON_MUTE_AUDIO
	_test_graphics_button.text = UIStrings.BUTTON_TEST_GRAPHICS
	_test_graphics_button.tooltip_text = "Use an untextured black/white terrain grid and hide site dressing."
	_bucket_passthrough_button.tooltip_text = "开启后铲斗可穿透地面，不进行挖土或卸土。切换开关会清空斗内土量和待处理的土方作业。进入训练场时默认开启，进入土方工地时默认关闭。"
	_level_assist_button.tooltip_text = "平地辅助（T 菜单选择）。开启后大臂与铲斗交由系统保持对地高度与角度，W 推远、S 拉近铲斗，回转不受影响；I/K/J/L 在此期间不生效。"
	_slope_assist_button.tooltip_text = "修坡辅助（T 菜单选择）。进入预览后整机冻结，W/S 调坡脚距离、A/D 调坡角，闪烁楔体为将削去的土；T/Enter 确认开坡，Esc 取消；作业中回转与大臂铲斗交由系统，W/S 沿坡面推拉。"
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
	_sync_dtm_visibility()
	if _panel_collapsed:
		_refresh_slew_orientation()
		return
	_menu_visual_time += delta
	(_menu["atmosphere"] as ShaderMaterial).set_shader_parameter("ui_time", _menu_visual_time)
	if GameSkin.is_console_variant(_ui_theme) and _pc001_handshake_lamp != null:
		_pc001_handshake_lamp.modulate.a = 0.72 + 0.28 * (0.5 + 0.5 * sin(_menu_visual_time * 5.0))
	_menu_refresh_elapsed += delta
	if _menu_refresh_elapsed >= 0.2:
		_menu_refresh_elapsed = 0.0
		_refresh_can_status()


func _refresh_slew_orientation() -> void:
	if _hud == null or _hud.orientation_hud == null:
		return
	var presentation := get_node_or_null("../MotionPresentation") as MotionPresentation
	var base := presentation.get_frame_node("base_link") if presentation != null else null
	var upper := presentation.get_frame_node("upper_structure_link") if presentation != null else null
	if not is_instance_valid(base) or not is_instance_valid(upper):
		_hud.orientation_hud.clear_orientation()
		return
	_hud.orientation_hud.set_orientation(
		base.get_global_transform_interpolated().basis,
		upper.get_global_transform_interpolated().basis)


func get_control_for_test(id: String) -> Control:
	# Stable semantic seam; the visual hierarchy may evolve independently.
	return {
		"dtm_toggle": _dtm_toggle,
		"dtm_panel": _dtm,
		"map_selector": _menu.get("map_selector"),
		"bucket_passthrough": _bucket_passthrough_button,
		"level_assist": _level_assist_button,
		"slope_assist": _slope_assist_button,
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
		"video_page": (_menu["tabs"] as TabContainer).get_tab_control(3),
		"window_mode_selector": _menu.get("window_mode_selector"),
		"fps_limit_selector": _menu.get("fps_limit_selector"),
		"relaxed_assist": _relaxed_assist_button,
		"simple_digging": _simple_digging_selector,
		"offzone_soil": _offzone_soil_button,
	}.get(id) as Control


func _input(event: InputEvent) -> void:
	if _dtm_file != null and _dtm_file.visible:
		return # The paused FileDialog owns keyboard/controller input.
	if _panel_collapsed and not _confirmation.visible and event is InputEventKey and event.keycode == KEY_P and event.pressed and not event.echo:
		_toggle_dtm()
		get_viewport().set_input_as_handled()
		return
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
	elif not _panel_collapsed and not _confirmation.visible and event is InputEventJoypadMotion and event.axis == JOY_AXIS_LEFT_Y and absf(event.axis_value) >= 0.3:
		# Left-stick deflection is consumed by the curated focus list; letting
		# it fall through to the engine ui_* actions would double-navigate.
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.keycode == KEY_F8 and event.pressed and not event.echo:
		get_viewport().set_input_as_handled()
		_on_reset_pressed()


## The engine ui_accept/ui_cancel defaults ship without joypad buttons, so
## A confirms and B cancels in menus are bound here once; existing entries
## are kept and only the missing button is appended.
func _ensure_ui_pad_bindings() -> void:
	_bind_joy_button_once("ui_accept", JOY_BUTTON_A)
	_bind_joy_button_once("ui_cancel", JOY_BUTTON_B)


func _bind_joy_button_once(action: String, button_index: JoyButton) -> void:
	for existing in InputMap.action_get_events(action):
		if existing is InputEventJoypadButton and (existing as InputEventJoypadButton).button_index == button_index:
			return
	var event := InputEventJoypadButton.new()
	event.button_index = button_index
	InputMap.action_add_event(action, event)


func _menu_navigation_direction(event: InputEvent) -> int:
	if event is InputEventJoypadButton and event.pressed:
		if event.button_index == JOY_BUTTON_DPAD_DOWN:
			return 1
		if event.button_index == JOY_BUTTON_DPAD_UP:
			return -1
	if event is InputEventJoypadMotion and event.axis == JOY_AXIS_LEFT_Y:
		# One move per deflection: the latch holds until the stick comes back
		# toward center so a full push cannot skip multiple entries.
		if absf(event.axis_value) < 0.3:
			_menu_nav_joy_latch = 0
		elif absf(event.axis_value) >= 0.5:
			var direction := 1 if event.axis_value > 0.0 else -1
			if _menu_nav_joy_latch == direction:
				return 0
			_menu_nav_joy_latch = direction
			return direction
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_DOWN or (event.keycode == KEY_TAB and not event.shift_pressed):
			return 1
		if event.keycode == KEY_UP or (event.keycode == KEY_TAB and event.shift_pressed):
			return -1
	return 0


func _move_menu_focus(direction: int) -> void:
	var tabs := _menu["tabs"] as TabContainer
	var controls: Array[Control] = [_menu["resume"] as Control]
	var nav: Array = _menu.get("nav", [])
	if nav.is_empty():
		controls.append(tabs.get_tab_bar())
	else:
		for item in nav:
			controls.append(item)
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
	# The open menu centers on the viewport in all themes; the dock no longer
	# reserves space beside it. Console variants use a near-fullscreen console.
	var console := GameSkin.is_console_variant(String(_menu.get("variant", "")))
	var extent := Vector2(
		clampf(viewport_size.x - 72.0, 1.0, 1360.0) if console else clampf(viewport_size.x - 56.0, 1.0, 780.0),
		clampf(viewport_size.y - 64.0, 1.0, 820.0) if console else clampf(viewport_size.y - 48.0, 1.0, 700.0)
	)
	_status_panel.offset_left = -extent.x / 2.0
	_status_panel.offset_right = extent.x / 2.0
	_status_panel.offset_top = -extent.y / 2.0
	_status_panel.offset_bottom = extent.y / 2.0
	_panel_toggle_button.position = Vector2(28, viewport_size.y - 70)
	_panel_toggle_button.size = Vector2(160, 42)


func _on_menu_tab_changed(_index: int) -> void:
	if _page_tween != null:
		_page_tween.kill()
	var tabs := _menu["tabs"] as TabContainer
	for index in range(tabs.get_tab_count()):
		var other := tabs.get_tab_control(index)
		other.modulate.a = 1.0
		other.scale = Vector2.ONE
	var page := tabs.get_current_tab_control()
	page.modulate.a = 0.65
	var nav: Array = _menu.get("nav", [])
	if not nav.is_empty():
		page.pivot_offset = Vector2(0.0, page.size.y * 0.5)
		page.scale = Vector2(0.9, 1.0)
		page.modulate.a = 0.0
	_page_tween = create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_page_tween.tween_property(page, "modulate:a", 1.0, 0.16)
	if not nav.is_empty():
		_page_tween.parallel().tween_property(page, "scale:x", 1.0, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	# Navigation keeps controller focus; Down enters the selected page.
	if nav.is_empty():
		tabs.get_tab_bar().grab_focus()
	else:
		for index in nav.size():
			(nav[index] as BaseButton).set_pressed_no_signal(index == tabs.current_tab)
		(nav[tabs.current_tab] as Control).grab_focus()
		var title := _menu.get("page_title") as Label
		if title != null:
			title.text = tabs.get_tab_title(tabs.current_tab)


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
	else:
		_save_menu_preference("quality_profile", requested)
		_save_menu_preference("quality_before_test", _quality_before_test)
		_apply_saved_video_settings()


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
	else:
		_save_menu_preference("bucket_ground_mode", requested)


func _on_level_assist_toggled(enabled: bool) -> void:
	if _product_session == null:
		_sync_level_assist_toggle()
		return
	_product_session.request_level_assist(enabled)
	_save_menu_preference("level_assist", enabled)
	_sync_level_assist_toggle()


func _on_slope_assist_pressed() -> void:
	if _product_session == null:
		_sync_slope_assist_button()
		return
	_product_session.advance_slope_assist()
	_sync_slope_assist_button()


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
	else:
		_save_menu_preference("unlimited_bucket", enabled)


func _on_cutting_diagnostics_toggled(enabled: bool) -> void:
	if _excavation_world != null:
		_excavation_world.set_voxel_diagnostics_enabled(enabled)
		_save_menu_preference("cutting_diagnostics", enabled)
	_sync_cutting_diagnostics_toggle()


func _on_race_mode_toggled(enabled: bool) -> void:
	var config := ConfigFile.new()
	config.load(preferences_path)
	config.set_value(CONFIG_SECTION_UI, "race_mode", enabled)
	config.save(preferences_path)
	if _product_session != null:
		_product_session.request_race_mode(enabled)
	_sync_race_mode_toggle()


func _sync_race_mode_toggle() -> void:
	if _race_mode_button == null:
		return
	_race_mode_button.set_pressed_no_signal(
		_product_session != null and _product_session.race_mode_enabled
	)


func _on_relaxed_assist_toggled(enabled: bool) -> void:
	var config := ConfigFile.new()
	config.load(preferences_path)
	config.set_value(CONFIG_SECTION_UI, "relaxed_assist", enabled)
	config.save(preferences_path)
	if _product_session != null:
		_product_session.request_relaxed_assist(enabled)
	_sync_relaxed_assist_toggle()


func _sync_relaxed_assist_toggle() -> void:
	if _relaxed_assist_button == null:
		return
	_relaxed_assist_button.set_pressed_no_signal(
		_product_session != null and _product_session.relaxed_assist_enabled
	)


## Items are (re)populated on every menu-controls rebuild — the AdvancedPanel
## is re-instantiated by _instantiate_menu_controls, not just reparented.
func _on_offzone_soil_toggled(enabled: bool) -> void:
	var config := ConfigFile.new()
	config.load(preferences_path)
	config.set_value(CONFIG_SECTION_UI, "offzone_soil", enabled)
	config.save(preferences_path)
	if _product_session != null:
		_product_session.request_offzone_soil(enabled)


func _configure_simple_digging_selector() -> void:
	if _simple_digging_selector == null:
		return
	_simple_digging_selector.add_item("简易挖掘：关闭")
	_simple_digging_selector.set_item_metadata(0, ProductSession.SIMPLE_DIGGING_OFF)
	_simple_digging_selector.add_item("简易挖掘：始终生效")
	_simple_digging_selector.set_item_metadata(1, ProductSession.SIMPLE_DIGGING_ALWAYS)
	_simple_digging_selector.add_item("简易挖掘：仅辅助模式")
	_simple_digging_selector.set_item_metadata(2, ProductSession.SIMPLE_DIGGING_ASSIST_ONLY)
	_simple_digging_selector.item_selected.connect(_on_simple_digging_selected)


func _on_simple_digging_selected(index: int) -> void:
	var mode := int(_simple_digging_selector.get_item_metadata(index))
	var config := ConfigFile.new()
	config.load(preferences_path)
	config.set_value(CONFIG_SECTION_UI, "simple_digging", mode)
	config.save(preferences_path)
	if _product_session != null:
		_product_session.request_simple_digging_mode(mode)
	_sync_simple_digging_selector()


func _sync_simple_digging_selector() -> void:
	if _simple_digging_selector == null:
		return
	var mode := (
		_product_session.simple_digging_mode
		if _product_session != null
		else ProductSession.SIMPLE_DIGGING_OFF
	)
	for index in range(_simple_digging_selector.item_count):
		if int(_simple_digging_selector.get_item_metadata(index)) == mode:
			_simple_digging_selector.select(index)
			return


## Persisted race-mode choice is applied once the product session exists; the
## chassis re-applies it to each freshly configured Jolt runtime.
func _load_race_mode() -> void:
	var config := ConfigFile.new()
	if config.load(preferences_path) != OK:
		return
	if _product_session != null and bool(config.get_value(CONFIG_SECTION_UI, "race_mode", false)):
		_product_session.request_race_mode(true)
	_sync_race_mode_toggle()


## Persisted advanced assist options; session forwards them to the chassis
## runtime and the excavation world, both of which re-apply across rebuilds.
func _load_assist_options() -> void:
	var config := ConfigFile.new()
	if config.load(preferences_path) != OK:
		return
	if _product_session != null:
		var offzone := bool(config.get_value(CONFIG_SECTION_UI, "offzone_soil", false))
		_product_session.request_offzone_soil(offzone)
		_offzone_soil_button.set_pressed_no_signal(offzone)
		if bool(config.get_value(CONFIG_SECTION_UI, "relaxed_assist", false)):
			_product_session.request_relaxed_assist(true)
		# Legacy saves stored a bool: true maps to ALWAYS, false to OFF.
		var stored: Variant = config.get_value(
			CONFIG_SECTION_UI, "simple_digging", ProductSession.SIMPLE_DIGGING_OFF
		)
		var digging_mode := (
			ProductSession.SIMPLE_DIGGING_ALWAYS if stored is bool and stored
			else clampi(int(stored), 0, ProductSession.SIMPLE_DIGGING_ASSIST_ONLY)
		)
		if digging_mode != ProductSession.SIMPLE_DIGGING_OFF:
			_product_session.request_simple_digging_mode(digging_mode)
	_sync_relaxed_assist_toggle()
	_sync_simple_digging_selector()


func _sync_cutting_diagnostics_toggle() -> void:
	_cutting_diagnostics_button.disabled = _excavation_world == null or (_performance_capture != null and _performance_capture.recording)
	_cutting_diagnostics_button.set_pressed_no_signal(
		_excavation_world != null and _excavation_world.voxel_diagnostics_enabled
	)


func _build_capture_controls() -> void:
	var group := VBoxContainer.new()
	_advanced_panel.add_child(group)
	if not is_instance_valid(_performance_overlay):
		_performance_overlay = preload("res://scripts/performance_overlay.gd").new()
		_performance_overlay.capture = _performance_capture
		add_child(_performance_overlay)
	var display_toggle := CheckButton.new()
	display_toggle.name = "PerformanceOverlayToggle"
	display_toggle.text = "显示帧率与性能曲线"
	display_toggle.tooltip_text = "右上角显示 FPS、帧时间与 CPU / GPU 耗时。关闭后停止采样；不影响性能录制。"
	group.add_child(display_toggle)
	var config := ConfigFile.new()
	config.load(preferences_path)
	var enabled := bool(config.get_value(CONFIG_SECTION_UI, "performance_overlay", false))
	display_toggle.set_pressed_no_signal(enabled)
	_performance_overlay.set_enabled(enabled)
	display_toggle.toggled.connect(func(value: bool):
		_performance_overlay.set_enabled(value)
		var saved := ConfigFile.new()
		saved.load(preferences_path)
		saved.set_value(CONFIG_SECTION_UI, "performance_overlay", value)
		saved.save(preferences_path)
	)
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
	if _capture_badge == null:
		_capture_badge = Label.new()
		_capture_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_capture_badge.add_theme_color_override("font_shadow_color", Color.BLACK)
		_capture_badge.add_theme_constant_override("shadow_offset_x", 1)
		_capture_badge.add_theme_constant_override("shadow_offset_y", 1)
		add_child(_capture_badge)
		_capture_badge.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
		_capture_badge.offset_left = -350
		_capture_badge.offset_right = -24
		_capture_badge.offset_top = 20
		_capture_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_capture_badge.add_theme_color_override("font_color", GameSkin.accent_for(_ui_theme))
	if _performance_capture != null and not _performance_capture.state_changed.is_connected(_refresh_capture_status):
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
	_model_selector.add_item(UIStrings.model_name("sy135neo"))
	_model_selector.set_item_metadata(2, "sy135neo")
	_model_selector.add_item(UIStrings.model_name("sy80u"))
	_model_selector.set_item_metadata(3, "sy80u")
	_model_selector.add_item(UIStrings.model_name("sy155w"))
	_model_selector.set_item_metadata(4, "sy155w")
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
	_save_menu_preference("camera_mode", _mode)
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
	if _pending_action == "map_switch":
		var catalog := get_node("/root/MapCatalog")
		if not catalog.select_map(_pending_model_id, _active_model_id()):
			_completion_label.text = catalog.last_error
		_pending_action = ""
		_pending_model_id = ""
		return
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
	_refresh_map_selector()
	(_menu["resume"] as Button).grab_focus()


func _configure_attachment_selector() -> void:
	_coupler_selector = _menu.get("coupler_selector") as OptionButton
	_attachment_selector = _menu.get("attachment_selector") as OptionButton
	if _coupler_selector != null:
		_coupler_selector.clear()
		var coupler_ids: Array[String] = []
		if _attachment_rig != null:
			coupler_ids = _attachment_rig.coupler_ids()
		if coupler_ids.is_empty():
			coupler_ids.append("none")
		for index in range(coupler_ids.size()):
			var coupler_id := coupler_ids[index]
			var display := _attachment_rig.coupler_display_name(coupler_id) if _attachment_rig != null else coupler_id
			_coupler_selector.add_item("快换：%s" % display)
			_coupler_selector.set_item_metadata(index, coupler_id)
		_coupler_selector.tooltip_text = "切换快换立即生效；属具列表仅显示当前快换支持的属具，不兼容的属具会自动更换。"
		_coupler_selector.item_selected.connect(_on_coupler_selected)
	if _attachment_selector != null:
		_attachment_selector.tooltip_text = "属具列表仅显示当前快换支持的属具；切换立即生效并清空斗内土量。Steelwrist 旋转器：Q+J/L 倾转 · O+A/D 回转。"
		_attachment_selector.item_selected.connect(_on_tool_selected)
	_refresh_attachment_selector()


## The tool list is scoped to the active coupler: only tools whose
## supported_couplers contains it are shown, so an incompatible combination
## is never selectable. Rebuilt on every refresh (coupler switches repopulate
## it); programmatic rebuilds never fire item_selected.
func _populate_tool_selector() -> void:
	if _attachment_selector == null:
		return
	var coupler_id := _active_coupler_id()
	_attachment_selector.clear()
	var index := 0
	if _attachment_rig != null:
		for tool_id in _attachment_rig.tool_ids():
			if not _attachment_rig.tool_supported_couplers(tool_id).has(coupler_id):
				continue
			_attachment_selector.add_item("属具：%s" % _attachment_rig.tool_display_name(tool_id))
			_attachment_selector.set_item_metadata(index, tool_id)
			index += 1
	if index == 0:
		_attachment_selector.add_item("属具：无可用属具")
		_attachment_selector.set_item_metadata(0, "")


func _refresh_attachment_selector() -> void:
	_ignore_attachment_selection = true
	var coupler_id := _active_coupler_id()
	var tool_id := _active_tool_id()
	if _coupler_selector != null and _attachment_rig != null:
		_coupler_selector.clear()
		for id in _attachment_rig.coupler_ids():
			_coupler_selector.add_item("快换：%s" % _attachment_rig.coupler_display_name(id))
			_coupler_selector.set_item_metadata(_coupler_selector.item_count - 1, id)
	_populate_tool_selector()
	if _coupler_selector != null:
		for index in range(_coupler_selector.item_count):
			if String(_coupler_selector.get_item_metadata(index)) == coupler_id:
				_coupler_selector.select(index)
				break
	if _attachment_selector != null:
		for index in range(_attachment_selector.item_count):
			if String(_attachment_selector.get_item_metadata(index)) == tool_id:
				_attachment_selector.select(index)
				break
	_ignore_attachment_selection = false


func _active_coupler_id() -> String:
	return _product_session.active_coupler_id if _product_session != null else "none"


func _active_tool_id() -> String:
	return _product_session.active_tool_id if _product_session != null else "standard_bucket"


func _on_coupler_selected(index: int) -> void:
	if _ignore_attachment_selection:
		return
	var coupler_id := String(_coupler_selector.get_item_metadata(index))
	if coupler_id == _active_coupler_id():
		return
	var tool_before := _active_tool_id()
	if _product_session != null and _is_local_authority():
		if not _product_session.request_coupler_switch(coupler_id):
			_completion_label.text = "快换切换失败：%s" % String(_product_session.last_error.get("message", coupler_id))
		elif _active_tool_id() != tool_before:
			# The coupler swap forced a tool re-resolution; surface it so the
			# auto-change is visible rather than a silent edit.
			var tool_name := _attachment_rig.tool_display_name(_active_tool_id()) if _attachment_rig != null else _active_tool_id()
			_completion_label.text = "属具已自动更换为：%s" % tool_name
	_refresh_attachment_selector()
	_refresh_prompt_copy()


func _on_tool_selected(index: int) -> void:
	if _ignore_attachment_selection:
		return
	var tool_id := String(_attachment_selector.get_item_metadata(index))
	if tool_id == _active_tool_id():
		return
	if _product_session != null and _is_local_authority():
		if not _product_session.request_tool_switch(tool_id):
			_completion_label.text = "属具切换失败：%s" % String(_product_session.last_error.get("message", tool_id))
	_refresh_attachment_selector()
	_refresh_prompt_copy()


func _on_attachment_changed(_attachment_id: String) -> void:
	_refresh_attachment_selector()
	_refresh_prompt_copy()


func _configure_map_selector() -> void:
	var selector := _menu["map_selector"] as OptionButton
	var catalog := get_node_or_null("/root/MapCatalog")
	selector.add_item("地图：训练场")
	selector.set_item_metadata(0, "training")
	var labels := {"construction": "土方工地", "urban": "市政施工"}
	var index := 1
	for map_id in ["construction", "urban"]:
		var available: bool = catalog != null and catalog.map_available(map_id)
		var label: String = labels[map_id]
		selector.add_item("地图：%s" % label if available else "地图：%s（未安装）" % label)
		selector.set_item_metadata(index, map_id)
		selector.set_item_disabled(index, not available or not _is_local_authority())
		index += 1
	selector.tooltip_text = "切换地图将重新开始作业。土方工地的警戒线内为挖掘土区。"
	selector.item_selected.connect(_on_map_selected)
	_refresh_map_selector()


func _refresh_map_selector() -> void:
	var catalog := get_node_or_null("/root/MapCatalog")
	if catalog != null and _menu.has("map_selector"):
		var selector := _menu["map_selector"] as OptionButton
		for index in selector.item_count:
			if String(selector.get_item_metadata(index)) == catalog.active_map_id:
				selector.select(index)
				return
		selector.select(0)


func _on_map_selected(index: int) -> void:
	var catalog := get_node("/root/MapCatalog")
	var map_id := String((_menu["map_selector"] as OptionButton).get_item_metadata(index))
	_refresh_map_selector()
	if _confirmation.visible or map_id == catalog.active_map_id:
		return
	_pending_action = "map_switch"
	_pending_model_id = map_id
	_confirmation.title = "切换地图"
	_confirmation.dialog_text = "切换地图将清空当前作业与土量，保留所选机型。是否继续？"
	_confirmation.popup_centered()
	_confirmation.get_cancel_button().grab_focus()


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
			_gateway_button.text = "重启 Gateway（异常，请重启）"
			_gateway_button.disabled = false
		_:
			_gateway_button.text = "重启 Gateway（异常，请重启）" \
				if bridge.is_gateway_restart_required() else "重启 Gateway"
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
	var root := _menu["root"] as Control
	var console := GameSkin.is_console_variant(_ui_theme)
	# Console variants keep the root alive through a short fade-out when closing;
	# the panel content still snaps off instantly like a powered-down screen.
	root.visible = not collapsed or (console and changed)
	(_menu["panel"] as Control).visible = not collapsed
	_hud.visible = collapsed
	_panel_toggle_button.visible = collapsed
	_panel_toggle_button.text = "≡  Esc  /  菜单" if console else "Esc  /  菜单"
	_panel_toggle_button.focus_mode = Control.FOCUS_NONE
	_panel_toggle_button.theme = GameSkin.create(_ui_theme)
	var dock := _menu.get("hardware") as Control
	if dock != null:
		dock.visible = collapsed
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
		if is_instance_valid(_close_tween):
			_close_tween.kill()
		if console:
			_boot_menu_industrial()
		else:
			root.modulate.a = 0.0
			var panel := _menu["panel"] as Control
			panel.pivot_offset = panel.size * 0.5
			panel.scale = Vector2(0.965, 0.965)
			_menu_tween = create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
			_menu_tween.tween_property(root, "modulate:a", 1.0, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			_menu_tween.parallel().tween_property(panel, "scale", Vector2.ONE, 0.24).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
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
		if console:
			root.modulate.a = 1.0
			_close_tween = root.create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
			_close_tween.tween_property(root, "modulate:a", 0.0, 0.12)
			_close_tween.tween_callback(_hide_menu_root_if_collapsed)


## Power-on sequence for the industrial console: a fast display flicker,
## an energy scanline sweeping down the plate, then staggered element cascades.
func _boot_menu_industrial() -> void:
	var root := _menu["root"] as Control
	root.modulate.a = 0.0
	_menu_tween = create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_menu_tween.tween_property(root, "modulate:a", 1.0, 0.05)
	_menu_tween.tween_property(root, "modulate:a", 0.45, 0.035)
	_menu_tween.tween_property(root, "modulate:a", 1.0, 0.1)
	var backdrop := _menu.get("backdrop") as Control
	if backdrop != null:
		backdrop.set("scan", -0.08)
		var sweep := backdrop.create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
		sweep.tween_property(backdrop, "scan", 1.08, 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		sweep.tween_callback(func(): backdrop.set("scan", -1.0))
	var boot := _menu.get("boot", {}) as Dictionary
	var delay := 0.09
	for item in boot.get("rail", []):
		_cascade_in(item, delay, 0.0)
		delay += 0.05
	for item in boot.get("right", []):
		_cascade_in(item, delay, 1.0)
		delay += 0.05
	for item in boot.get("fade", []):
		(item as Control).modulate.a = 0.0
		var fade := (item as Control).create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
		fade.tween_interval(delay)
		fade.tween_property(item, "modulate:a", 1.0, 0.22)


func _cascade_in(item: Control, delay: float, pivot_x: float) -> void:
	item.modulate.a = 0.0
	item.pivot_offset = Vector2(item.size.x * pivot_x, item.size.y * 0.5)
	item.scale = Vector2(0.82, 0.82)
	var tween := item.create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.tween_interval(delay)
	tween.tween_property(item, "modulate:a", 1.0, 0.16)
	tween.parallel().tween_property(item, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _hide_menu_root_if_collapsed() -> void:
	if _panel_collapsed and not _menu.is_empty():
		(_menu["root"] as Control).hide()


func set_panel_collapsed_for_test(collapsed: bool) -> void:
	_set_panel_collapsed(collapsed)


func is_panel_collapsed_for_test() -> bool:
	return _panel_collapsed


func _on_audio_muted(pressed: bool) -> void:
	if _feedback != null:
		_feedback.set_muted(pressed)
		_save_menu_preference("audio_muted", pressed)


func _save_menu_preference(key: String, value: Variant) -> void:
	var config := ConfigFile.new()
	config.load(preferences_path)
	config.set_value(CONFIG_SECTION_UI, key, value)
	config.save(preferences_path)


func _load_menu_preferences() -> void:
	var config := ConfigFile.new()
	config.load(preferences_path)
	if _feedback != null:
		_feedback.set_muted(bool(config.get_value(CONFIG_SECTION_UI, "audio_muted", true)))
		_mute_audio_button.set_pressed_no_signal(_feedback.is_muted())
	if _camera != null:
		_camera.set_mode(String(config.get_value(CONFIG_SECTION_UI, "camera_mode", _camera.get_mode())))
	if _visual_quality != null:
		_quality_before_test = String(config.get_value(CONFIG_SECTION_UI, "quality_before_test", "balanced"))
		var quality := String(config.get_value(CONFIG_SECTION_UI, "quality_profile", _visual_quality.profile))
		if VisualQualityController.PROFILES.has(quality):
			_visual_quality.apply_profile(quality)
		_apply_saved_video_settings()
		_sync_test_graphics_toggle()
	if _excavation_world != null:
		# These flags are also consumed when deferred soil initialization builds
		# the authority, so map startup does not require it to exist already.
		_excavation_world.voxel_unlimited_bucket_for_testing = bool(config.get_value(CONFIG_SECTION_UI, "unlimited_bucket", false))
		if _excavation_world.can_set_voxel_unlimited_bucket_for_testing():
			_excavation_world.set_voxel_unlimited_bucket_for_testing(_excavation_world.voxel_unlimited_bucket_for_testing)
		_excavation_world.set_voxel_diagnostics_enabled(bool(config.get_value(CONFIG_SECTION_UI, "cutting_diagnostics", false)))
	if _product_session != null:
		_saved_level_assist = bool(config.get_value(CONFIG_SECTION_UI, "level_assist", false))
		_product_session.request_level_assist(_saved_level_assist)
	_menu_preferences_loaded = true


func show_control_guide() -> void:
	_set_panel_collapsed(false)
	(_menu["tabs"] as TabContainer).current_tab = 1


func _on_guide_closed() -> void:
	(_menu["tabs"] as TabContainer).current_tab = 0
	var config := ConfigFile.new()
	config.load(preferences_path)
	config.set_value(CONFIG_SECTION, CONFIG_GUIDE_DISMISSED, true)
	config.save(preferences_path)


func _guide_was_dismissed() -> bool:
	var config := ConfigFile.new()
	if config.load(preferences_path) != OK:
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
	# The keyboard/gamepad assist picker can change this without a menu click.
	var level := bool(_status.get("level_assist_enabled", false))
	if _menu_preferences_loaded and level != _saved_level_assist:
		_saved_level_assist = level
		_save_menu_preference("level_assist", level)
	_refresh()


func _on_product_model_changed(_model_id: String) -> void:
	_refresh()
	_refresh_prompt_copy()


func _on_gateway_model_changed(_model_id: String) -> void:
	_refresh()


func _on_excavation_changed(status: Dictionary) -> void:
	_refresh_soil(status)
	_refresh_camera_selector()
	_sync_unlimited_bucket_toggle(status)
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
	_sync_level_assist_toggle()
	_sync_slope_assist_button()
	_sync_assist_menu()
	_sync_slope_side_view()
	_sync_unlimited_bucket_toggle()
	_sync_cutting_diagnostics_toggle()


func _terrain_diagnostics_text() -> String:
	if _excavation_world == null:
		return "Terrain: unavailable"
	var terrain_status := (
		_excavation_world.terrain_world.get_status_snapshot()
		if _excavation_world.terrain_world != null
		else {}
	) as Dictionary
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
		_excavation_world.get_bucket_ground_interaction_snapshot()
		if _excavation_world != null
		else {}
	) as Dictionary
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


func _sync_level_assist_toggle() -> void:
	if _level_assist_button == null:
		return
	var status := _product_session.get_status_snapshot() if _product_session != null else {}
	_level_assist_button.set_pressed_no_signal(bool(status.get("level_assist_enabled", false)))


func _sync_slope_assist_button() -> void:
	if _slope_assist_button == null:
		return
	var status := _product_session.get_status_snapshot() if _product_session != null else {}
	var slope := status.get("slope_assist", {}) as Dictionary
	var state := String(slope.get("state", "off"))
	_slope_assist_button.set_pressed_no_signal(state != "off")
	match state:
		"preview":
			_slope_assist_button.text = "修坡 (T) · 预览"
		"active":
			_slope_assist_button.text = "修坡 (T) · 作业"
		_:
			_slope_assist_button.text = "修坡 (T)"


func _sync_assist_menu() -> void:
	if _assist_menu_panel == null:
		return
	var status := _product_session.get_status_snapshot() if _product_session != null else {}
	var menu := status.get("assist_menu", {}) as Dictionary
	var navigation: Dictionary = status.get("navigation", {})
	var navigation_state := String(navigation.get("state", "idle"))
	if _navigation_label != null:
		_navigation_label.visible = navigation_state not in ["idle", "cancelled", "completed"] and not (_product_session._chassis != null and _product_session._chassis.surface_job.active())
		var names := {"arming": "准备", "aligning": "对正方向", "driving": "行驶中", "braking": "停车中", "paused": "已暂停", "completed": "已完成", "failed": "已停止"}
		_navigation_label.text = "自动驾驶  ·  %s  ·  %d/%d  ·  %.1f m" % [names.get(navigation_state, navigation_state), mini(int(navigation.get("index", 0)) + 1, int(navigation.get("count", 0))), int(navigation.get("count", 0)), float(navigation.get("distance_m", 0))]
		var reasons := {"no_progress": "长时间无进展", "unsupported": "失去地面支撑", "invalid_state": "车辆状态无效", "stale_state": "车辆状态未更新", "position_tolerance": "停车或转向后偏离目标，请重新定位后启动"}
		if navigation_state == "failed":
			_navigation_label.text += " · " + String(reasons.get(navigation.get("reason", ""), navigation.get("reason", "")))
	var open := bool(menu.get("open", false))
	var was_open := _assist_menu_panel.visible
	_assist_menu_panel.visible = open
	if not open:
		# Reset any mid-flight open pop so a later debug-variant open or a
		# style rebuild never inherits a frozen half-faded panel.
		_assist_menu_panel.modulate.a = 1.0
		_assist_menu_panel.scale = Vector2.ONE
		return
	if not was_open and GameSkin.is_console_variant(_ui_theme):
		_assist_menu_panel.modulate.a = 0.0
		call_deferred("_pop_assist_menu")
	var console := GameSkin.is_console_variant(_ui_theme)
	var entries := menu.get("entries", []) as Array
	if _assist_menu_rows.size() != entries.size():
		for row in _assist_menu_rows:
			row.queue_free()
		_assist_menu_rows.clear()
		for i in entries.size():
			var row := Button.new()
			row.alignment = HORIZONTAL_ALIGNMENT_LEFT
			# Activation is owned by the chassis picker state (A/Y/Enter);
			# unfocusable rows cannot double-dispatch through ui_accept.
			row.focus_mode = Control.FOCUS_NONE
			if console:
				GameSkin.apply_nav_button(row, GameSkin.accent_for(_ui_theme))
			var index := i
			row.pressed.connect(_on_assist_menu_row_pressed.bind(index))
			_assist_menu_rows_box.add_child(row)
			_assist_menu_rows.append(row)
	var selected := int(menu.get("index", 0))
	var state_names := {"off": "关", "on": "作业中", "preview": "预览", "active": "作业中", "idle": "待机", "arming": "准备", "aligning": "对正", "driving": "行驶中", "braking": "停车中", "paused": "已暂停", "completed": "完成", "failed": "已停止", "cancelled": "已取消"}
	for i in _assist_menu_rows.size():
		var entry := entries[i] as Dictionary
		var row := _assist_menu_rows[i]
		var state := String(entry.get("state", "off"))
		row.disabled = state == "unavailable"
		if state == "unavailable":
			state_names[state] = "仅训练场普通模式"
		row.text = "%d  %s · %s" % [i + 1, String(entry.get("label", "")), state_names.get(state, state)]
		if console:
			# Nav styling carries the selection: accent left bar plus lit text.
			row.set_pressed_no_signal(i == selected)
		elif i == selected:
			row.add_theme_color_override("font_color", GameSkin.accent_for(_ui_theme))
			row.text = "▶ " + row.text
		else:
			row.remove_theme_color_override("font_color")


func _on_assist_menu_row_pressed(index: int) -> void:
	if _product_session != null:
		_product_session.activate_assist_entry(index)
	_sync_assist_menu()


func _sync_slope_side_view() -> void:
	if _slope_side_view == null:
		return
	var status := _product_session.get_status_snapshot() if _product_session != null else {}
	var view := status.get("assist_view", {}) as Dictionary
	var mode := String(view.get("mode", ""))
	_slope_side_view.visible = (mode == "preview" or mode == "active" or mode == "level") and not (_dtm != null and _dtm.visible)
	if _slope_side_view.visible:
		_slope_side_view.set_view(view)


func _sync_unlimited_bucket_toggle(status: Dictionary = {}) -> void:
	if _unlimited_bucket_button == null:
		return
	if status.is_empty():
		status = _excavation_world.get_status_snapshot() if _excavation_world != null else {}
	_unlimited_bucket_button.disabled = not bool(
		status.get("voxel_unlimited_bucket_toggle_available", false)
	)
	_unlimited_bucket_button.set_pressed_no_signal(
		bool(status.get("voxel_unlimited_bucket_for_testing", false))
	)


func _refresh_soil(status: Dictionary = {}) -> void:
	if _excavation_world == null:
		_operation_label.text = "SOIL STATUS UNAVAILABLE"
		_bucket_status_label.text = "Bucket payload unavailable"
		_bucket_fill.value = 0.0
		_bucket_volume_label.text = "Bucket soil: unavailable"
		return
	if status.is_empty():
		status = _excavation_world.get_status_snapshot()
	var selected := status.get("selected_soil_payload", {}) as Dictionary
	if selected.is_empty():
		selected = _excavation_world.get_selected_soil_payload_snapshot()
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
		var chassis_status := _chassis.peek_runtime_snapshot()
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
	var wheeled := _chassis != null and String(_chassis.peek_runtime_snapshot().get("locomotion_mode", "")) == "wheeled"
	if _hud != null:
		_hud.set_wheeled_mode(wheeled)
		_hud.set_prompt_mode(_prompt_mode)
	var tiltrotator_active := _attachment_rig != null and _attachment_rig.is_tiltrotator_active()
	var keyboard_hint := UIStrings.CONTROL_HINT_ATTACHMENT_KEYBOARD if tiltrotator_active else UIStrings.CONTROL_HINT_KEYBOARD
	var gamepad_hint := UIStrings.CONTROL_HINT_ATTACHMENT_GAMEPAD if tiltrotator_active else UIStrings.CONTROL_HINT_GAMEPAD
	_control_hint.text = gamepad_hint if _prompt_mode == "gamepad" else keyboard_hint
	if _assist_menu_hint != null:
		_assist_menu_hint.text = UIStrings.ASSIST_MENU_HINT_GAMEPAD if _prompt_mode == "gamepad" else UIStrings.ASSIST_MENU_HINT_KEYBOARD
	_guide_device_label.text = "当前输入：手柄" if _prompt_mode == "gamepad" else "当前输入：键盘与鼠标"
	_guide_controls_label.text = UIStrings.GUIDE_GAMEPAD if _prompt_mode == "gamepad" else UIStrings.GUIDE_KEYBOARD
	if wheeled:
		if _prompt_mode == "keyboard":
			_control_hint.text = keyboard_hint.replace("R/F、Y/H  履带", "G 前 · V 左 · B 后 · N 右 · 空格刹车")
			_guide_controls_label.text = UIStrings.GUIDE_KEYBOARD.replace("R / F   左履带前进 / 后退     Y / H   右履带前进 / 后退", "G   前进     V   左转     B   后退     N   右转     空格 / Shift   刹车\n松开行驶键自动驻车；转向需要车辆移动。")
		else:
			_control_hint.text = gamepad_hint.replace("扳机与肩键  履带", "RT 前进 · LT 后退 · LB/RB 转向")
			_guide_controls_label.text = UIStrings.GUIDE_GAMEPAD.replace("LT / LB   左履带前进 / 后退\nRT / RB   右履带前进 / 后退", "RT   前进     LT   后退\nLB / RB   左转 / 右转     A   刹车\n松开行驶输入自动驻车。")


func set_prompt_mode_for_test(value: String) -> void:
	_set_prompt_mode(value)


func get_prompt_mode_for_test() -> String:
	return _prompt_mode


func get_soil_generation_key_for_test() -> String:
	return _soil_generation_key

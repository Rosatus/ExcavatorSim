class_name DtmDashboard
extends PanelContainer

signal import_requested
signal close_requested

const Model := preload("res://scripts/dtm_model.gd")
const Surface := preload("res://scripts/landxml_surface.gd")
const View := preload("res://scripts/dtm_view.gd")
const GameSkin := preload("res://scripts/game_ui_theme.gd")

var model := Model.new()
var presentation: MotionPresentation
var surfaces: Array = []
var demo_kind := ""
var views: Array[Control] = []
var controls: Dictionary = {}
var _surface_selector: OptionButton
var _summary: Label
var _status: Label
var _message: Label
var _source: Label
var _elapsed := 0.0
var _bucket: Dictionary = {}
var _demo_width := 0.0
var _expanded := false
var _center_import := true
var _elevation_offset := 0.0
var _generation := -1
var _profile_pending: Array[Dictionary] = []
var _profile_bucket: Dictionary = {}
var _profile_cursor := 49
var _machine_key := ""
var _profile_revision := -1
var _profile_generation := ""
var _profile_sampled_ms := 0
var _profile_has_unknown := true
var _profile_started_ms := 0
var profile_latency_ms := 0
var profile_sample_count := 0
var _draw_revision := -1
var hud_mode := false
var _outer: VBoxContainer
var _title: Label
var _design_row: HBoxContainer
var _charts: VBoxContainer
var _chart_rows: Array[HBoxContainer] = []
var _legend: Label
var _hud_metrics: HBoxContainer
var _hud_values: Array[Label] = []

func _ready() -> void:
	name = "DtmDashboard"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var outer := VBoxContainer.new()
	_outer = outer
	outer.add_theme_constant_override("separation", 9)
	outer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(outer)
	var header := HBoxContainer.new()
	outer.add_child(header)
	var title := Label.new()
	_title = title
	title.text = "DTM  /  施工引导"
	title.add_theme_font_size_override("font_size", 21)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_button(header, "mode", "HUD 模式", func() -> void: set_hud_mode(not hud_mode))
	_button(header, "import", "导入 XML", func() -> void: import_requested.emit())
	_button(header, "expand", "放大", func() -> void:
		_expanded = not _expanded
		controls.expand.text = "还原" if _expanded else "放大"
		layout_dashboard())
	_button(header, "close", "收起", func() -> void: close_requested.emit())
	var row := HBoxContainer.new()
	_design_row = row
	outer.add_child(row)
	_surface_selector = OptionButton.new()
	_surface_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_surface_selector.fit_to_longest_item = false
	_surface_selector.focus_mode = Control.FOCUS_NONE
	_surface_selector.item_selected.connect(_select_surface)
	row.add_child(_surface_selector)
	_button(row, "pit", "示例方坑", func() -> void: load_demo("pit"))
	_button(row, "trench", "单斗宽沟", func() -> void: load_demo("trench"))
	_source = Label.new()
	_source.add_theme_font_size_override("font_size", 11)
	_source.add_theme_color_override("font_color", Color("94aebe"))
	_source.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	outer.add_child(_source)
	_summary = Label.new()
	_summary.add_theme_font_size_override("font_size", 16)
	_summary.custom_minimum_size.y = 28
	outer.add_child(_summary)
	_hud_metrics = HBoxContainer.new()
	_hud_metrics.add_theme_constant_override("separation", 6)
	_hud_metrics.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outer.add_child(_hud_metrics)
	for caption in ["待挖", "待填", "达标"]:
		var card := PanelContainer.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_theme_stylebox_override("panel", GameSkin.box(Color(0.12, 0.13, 0.14, 0.58), 6, 5))
		_hud_metrics.add_child(card)
		var value := Label.new()
		value.text = caption + "\n—"
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		value.add_theme_font_size_override("font_size", 13)
		value.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(value)
		_hud_values.append(value)
	_hud_metrics.hide()
	_message = Label.new()
	_message.add_theme_font_size_override("font_size", 12)
	_message.add_theme_color_override("font_color", Color("ffe49a"))
	_message.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	outer.add_child(_message)
	var charts := VBoxContainer.new()
	_charts = charts
	charts.size_flags_vertical = Control.SIZE_EXPAND_FILL
	charts.add_theme_constant_override("separation", 8)
	charts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outer.add_child(charts)
	for pair in [["iso", "plan"], ["section", "bucket"]]:
		var line := HBoxContainer.new()
		line.size_flags_vertical = Control.SIZE_EXPAND_FILL
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_theme_constant_override("separation", 8)
		charts.add_child(line)
		_chart_rows.append(line)
		for mode in pair:
			var view := View.new()
			view.mode = mode
			view.model = model
			view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			view.size_flags_vertical = Control.SIZE_EXPAND_FILL
			view.size_flags_stretch_ratio = 1.3 if mode == "iso" else 1.0
			line.add_child(view)
			views.append(view)
	var legend := Label.new()
	_legend = legend
	legend.text = "待挖：浅金→橙→珊瑚红  |  待填：浅蓝→蓝→靛紫  |  薄荷绿：±5 cm"
	legend.add_theme_font_size_override("font_size", 12)
	legend.tooltip_text = "差值 = 实测 − 目标。固定色阶：5 / 20 / 60 / 150 / 300 cm；超出 3 m 使用端点颜色。灰色为缺测。"
	outer.add_child(legend)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 11)
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status.add_theme_color_override("font_color", Color("94aebe"))
	outer.add_child(_status)
	set_theme_variant("debug")
	get_viewport().size_changed.connect(layout_dashboard)
	layout_dashboard()

func _button(parent: Control, id: String, text: String, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 13)
	button.pressed.connect(action)
	parent.add_child(button)
	controls[id] = button

func set_theme_variant(variant: String) -> void:
	theme = GameSkin.create(variant)
	_apply_panel_style()
	for view in views:
		view.accent = GameSkin.accent_for(variant)
		view.queue_redraw()

func _apply_panel_style() -> void:
	if hud_mode:
		add_theme_stylebox_override("panel", StyleBoxEmpty.new())
		return
	var box := GameSkin.box(Color(0.035, 0.065, 0.095, 0.97), 12, 14)
	box.border_color = Color("38536a")
	box.set_border_width_all(1)
	add_theme_stylebox_override("panel", box)

func set_hud_mode(enabled: bool) -> void:
	hud_mode = enabled
	controls.mode.text = "浮窗模式" if enabled else "HUD 模式"
	controls.import.visible = not enabled
	controls.expand.visible = not enabled
	_title.text = "DTM" if enabled else "DTM  /  施工引导"
	_title.add_theme_font_size_override("font_size", 16 if enabled else 21)
	for item in [_design_row, _source, _summary, _message, _legend]:
		item.visible = not enabled
	_hud_metrics.visible = enabled
	_outer.add_theme_constant_override("separation", 5 if enabled else 9)
	_charts.add_theme_constant_override("separation", 5 if enabled else 8)
	for i in views.size():
		var destination: Node = _charts if enabled else _chart_rows[i / 2]
		if views[i].get_parent() != destination:
			views[i].reparent(destination, false)
		views[i].set_compact(enabled)
	for row in _chart_rows:
		row.visible = not enabled
	_apply_panel_style()
	_refresh_metrics()
	layout_dashboard()
	call_deferred("layout_dashboard")

func layout_dashboard() -> void:
	var viewport := get_viewport().get_visible_rect().size
	if hud_mode:
		var hud_width := clampf(viewport.x * 0.24, 320, 380)
		position = Vector2(viewport.x - hud_width - 16, 20)
		size = Vector2(hud_width, viewport.y - 40)
		return
	var width := minf(viewport.x - 40, 1250) if _expanded else minf(viewport.x * 0.66, 1000)
	var height := viewport.y - 120
	position = Vector2(viewport.x - width - 20, 80)
	size = Vector2(width, height)

func load_demo(kind: String) -> bool:
	if not is_instance_valid(model.sampler.zone):
		show_error("当前地图没有可用体素作业区")
		return false
	_bucket = Model.bucket_state(presentation)
	var width := float(_bucket.get("width", 0.0))
	if kind == "trench" and width <= 0:
		show_error("当前附件没有有效切削宽度，请安装铲斗")
		return false
	var parsed := Surface.parse(Model.demo_xml(kind, model.sampler.zone.layout.ORIGIN_WORLD, width))
	if not String(parsed.get("error", "")).is_empty():
		show_error(parsed.error)
		return false
	demo_kind = kind
	_demo_width = width
	_center_import = false
	_elevation_offset = 0
	_replace_surfaces(parsed.surfaces)
	_source.text = "训练设计 · 体素区中心 · 底面范围为施工边界 · 不自动挖土"
	return true

func import_file(path: String, center_horizontal: bool, elevation_offset: float) -> bool:
	var parsed := Surface.load_file(path)
	if not String(parsed.get("error", "")).is_empty():
		show_error(parsed.error)
		return false
	if center_horizontal and not is_instance_valid(model.sampler.zone):
		show_error("当前没有体素区，无法居中放置")
		return false
	for value in parsed.surfaces:
		var item: Surface = value
		if not center_horizontal and (absf(item.source_origin.e) > 10000 or absf(item.source_origin.n) > 10000):
			show_error("工程坐标过大，请选择平面居中放置，避免场景精度损失")
			return false
	demo_kind = ""
	_center_import = center_horizontal
	_elevation_offset = elevation_offset
	_replace_surfaces(parsed.surfaces)
	_source.text = "%s · %s · 高程偏移 %+.2f m" % [path.get_file(), "平面居中，保留原标高" if center_horizontal else "原坐标 E→X / N→Z", elevation_offset]
	_source.tooltip_text = path + "\n" + _source.text
	return true

func _replace_surfaces(values: Array) -> void:
	surfaces = values
	_surface_selector.clear()
	for value in surfaces:
		_surface_selector.add_item(value.title if not value.title.is_empty() else "未命名曲面")
	_select_surface(0)

func _select_surface(index: int) -> void:
	var surface: Surface = surfaces[index]
	if _center_import:
		var center: Vector3 = model.sampler.zone.layout.ORIGIN_WORLD
		surface.translation = Vector3(center.x - surface.bounds.get_center().x, float(surface.source_origin.h) + _elevation_offset, center.z - surface.bounds.get_center().z)
	else:
		surface.translation = Vector3(float(surface.source_origin.e), float(surface.source_origin.h) + _elevation_offset, float(surface.source_origin.n))
	model.set_surface(surface)
	_profile_cursor = 49
	_profile_pending.clear()
	for view in views:
		view.profile.clear()
		view.queue_redraw()
	_message.text = "仅作测量引导；挖填量为采样估算。"
	_elapsed = 1.0
	if is_instance_valid(model.sampler.zone):
		var a := surface.world_bounds()
		var zone_bounds: AABB = model.sampler.zone.layout.editable_world_bounds(model.sampler.zone.voxel_scale_m)
		if a.position.x < zone_bounds.position.x or a.end.x > zone_bounds.end.x or a.position.z < zone_bounds.position.z or a.end.z > zone_bounds.end.z or a.position.y < zone_bounds.position.y or a.end.y > zone_bounds.end.y:
			_message.text = "目标部分或全部超出可施工体素范围；请检查坐标 / 高程偏移。"

func show_error(message: String) -> void:
	_message.text = message
	_message.tooltip_text = message

func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	var machine_key := presentation.get_active_model_id() + ":" + presentation.get_active_attachment_id() if is_instance_valid(presentation) else ""
	if machine_key != _machine_key:
		_machine_key = machine_key
		_profile_cursor = 49
		_profile_pending.clear()
		views[3].profile.clear()
		views[3].queue_redraw()
		_elapsed = 1
	_bucket = Model.bucket_state(presentation)
	if demo_kind == "trench" and not is_equal_approx(float(_bucket.get("width", 0)), _demo_width):
		if not load_demo("trench"):
			model.set_surface(null)
	if not is_instance_valid(model.sampler.zone):
		return
	if _generation != model.sampler.zone.readiness.generation:
		_generation = model.sampler.zone.readiness.generation
		model.invalidate()
		_profile_cursor = 49
		_profile_pending.clear()
		for view in views:
			view.profile.clear()
			view.queue_redraw()
		_elapsed = 1
	if not _bucket.is_empty():
		model.focus_xz = Vector2(_bucket.tooth.x, _bucket.tooth.z)
	model.update()
	if _profile_generation != model.current_generation:
		_profile_generation = model.current_generation
		_profile_cursor = 49
		_profile_pending.clear()
		views[3].profile.clear()
		views[3].queue_redraw()
	var data_changed := _draw_revision != model.display_revision
	if data_changed:
		_draw_revision = model.display_revision
		_refresh_profiles()
	_sample_local_profile_step()
	_elapsed += delta
	if _elapsed >= 0.1:
		_elapsed = 0
		_refresh_metrics()
	# Vertical tooth motion does not change the horizontal sampling line.
	# Update its elevation immediately without resampling unchanged terrain.
	if not views[3].profile.is_empty() and not _bucket.is_empty():
		var shown: Dictionary = views[3].profile_bucket
		if shown.tooth.y != _bucket.tooth.y:
			shown = shown.duplicate()
			var tooth: Vector3 = shown.tooth
			tooth.y = _bucket.tooth.y
			shown.tooth = tooth
			views[3].profile_bucket = shown
			views[3].queue_redraw()
	var section_bucket: Dictionary = views[3].profile_bucket if not views[3].profile.is_empty() else {}
	var reference_changed: bool = views[1].profile_bucket != section_bucket
	views[1].profile_bucket = section_bucket
	for i in 2:
		var view := views[i]
		if data_changed or view.bucket != _bucket or (i == 1 and reference_changed):
			view.bucket = _bucket
			view.queue_redraw()

func _refresh_metrics() -> void:
	var clearance := "铲齿：无目标"
	if model.surface != null and not _bucket.is_empty():
		var tooth: Vector3 = _bucket.tooth
		var target := model.surface.height_at(Vector2(tooth.x, tooth.z))
		if is_finite(target):
			var difference := tooth.y - target
			clearance = "铲齿 %+.2f m%s" % [difference, " ↑ 高于目标" if difference > 0 else " ↓ 低于目标"]
		else:
			var bounds := model.surface.world_bounds()
			var nearest := Vector2(clampf(tooth.x, bounds.position.x, bounds.end.x), clampf(tooth.z, bounds.position.z, bounds.end.z))
			clearance = "铲齿：无目标 · 距范围 %.1f m" % Vector2(tooth.x, tooth.z).distance_to(nearest)
	var stats := model.statistics
	if int(stats.get("valid", 0)) > 0:
		_summary.text = "%s   |   挖 %.1f m³   填 %.1f m³   达标 %.0f%%" % [clearance, stats.cut_m3, stats.fill_m3, stats.on_grade * 100]
		_hud_values[0].text = "待挖\n%.1f m³" % stats.cut_m3
		_hud_values[1].text = "待填\n%.1f m³" % stats.fill_m3
		_hud_values[2].text = "达标\n%.0f%%" % (stats.on_grade * 100)
	else:
		_summary.text = clearance + "   |   实测待就绪 · 挖填量 —"
		for i in 3:
			_hud_values[i].text = ["待挖", "待填", "达标"][i] + "\n—"
	var age := (Time.get_ticks_msec() - model.sampled_at_ms) / 1000.0 if model.sampled_at_ms > 0 else 0.0
	_status.text = "实测覆盖 %.0f%% · %.2f m 采样 · %s · SDF 顶表面" % [float(stats.get("coverage", 0)) * 100, maxf(model.cell_size.x, model.cell_size.y), "采样中" if model.sampling else "%.1f s 前更新" % age]
	if bool(stats.get("mixed_revision", false)):
		_status.text += " · 施工中分批测量"
	_status.tooltip_text = _status.text + "\n" + clearance + "\n" + _message.text
	if hud_mode:
		_status.text = "覆盖 %.0f%% · 暖色待挖 / 冷色待填 / 绿达标" % (float(stats.get("coverage", 0)) * 100)

func _refresh_profiles() -> void:
	if model.surface == null:
		views[2].profile.clear()
		views[2].queue_redraw()
		return
	var bounds := model.surface.world_bounds()
	var fixed: Array[Dictionary] = []
	for i in 65:
		var s := bounds.size.z * i / 64.0
		var p := Vector2(bounds.get_center().x, bounds.position.z + s)
		fixed.append({"s": s, "actual": model.cached_height(p), "target": model.surface.height_at(p)})
	views[2].profile = fixed
	views[2].queue_redraw()

func _sample_local_profile_step() -> void:
	if model.surface == null or _bucket.is_empty():
		if not views[3].profile.is_empty():
			views[3].profile.clear()
			views[3].queue_redraw()
		_profile_cursor = 49
		return
	if _profile_cursor >= 49:
		var moved := _profile_bucket.is_empty()
		if not moved:
			var previous: Vector3 = _profile_bucket.tooth
			var current: Vector3 = _bucket.tooth
			moved = Vector2(previous.x, previous.z).distance_to(Vector2(current.x, current.z)) > 0.01 or (_profile_bucket.axis as Vector2).distance_to(_bucket.axis) > 0.003
		var retry_unknown := _profile_has_unknown and Time.get_ticks_msec() - _profile_sampled_ms >= 250
		if not moved and not views[3].profile.is_empty() and _profile_revision == model.current_revision and not retry_unknown:
			return
		_profile_bucket = _bucket.duplicate()
		_profile_revision = model.current_revision
		_profile_cursor = 0
		_profile_pending = []
		_profile_has_unknown = false
		_profile_started_ms = Time.get_ticks_msec()
	var started := Time.get_ticks_usec()
	var tooth: Vector3 = _profile_bucket.tooth
	# A normal 49-point section fits in one frame; slow machines retain a
	# time budget and publish one coherent horizontal position/axis snapshot.
	for count in 49:
		if _profile_cursor >= 49 or (count > 0 and Time.get_ticks_usec() - started >= 1000):
			break
		var s := -3.0 + _profile_cursor * 0.125
		var p: Vector2 = Vector2(tooth.x, tooth.z) + (_profile_bucket.axis as Vector2) * s
		var actual := model.sampler.height_at(p)
		_profile_has_unknown = _profile_has_unknown or not is_finite(actual)
		_profile_pending.append({"s": s, "actual": actual, "target": model.surface.height_at(p)})
		_profile_cursor += 1
		profile_sample_count += 1
	if _profile_cursor >= 49:
		views[3].profile = _profile_pending
		views[3].profile_bucket = _profile_bucket.duplicate()
		views[3].queue_redraw()
		_profile_pending = []
		_profile_sampled_ms = Time.get_ticks_msec()
		profile_latency_ms = _profile_sampled_ms - _profile_started_ms

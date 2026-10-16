class_name DtmDashboard
extends PanelContainer

signal import_requested
signal close_requested
signal chart_style_changed(style: String)
signal automatic_requested
signal automatic_cancelled
signal urban_trench_requested
signal design_changed
signal digging_mode_requested(simple: bool)
signal dump_side_requested(right: bool)
var automatic_status := Callable()
var _automatic_label: Label

const Model := preload("res://scripts/dtm_model.gd")
const Surface := preload("res://scripts/landxml_surface.gd")
const View := preload("res://scripts/dtm_view.gd")
const GameSkin := preload("res://scripts/game_ui_theme.gd")
const PROFILE_POINTS := 49
const PROFILE_STEP_M := 0.125
const FIXED_PROFILE_POINTS := 97

## Continuous difference scale drawn from the same function the charts use.
class Legend extends Control:
	var compact := false
	var voxel := false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_PASS
		custom_minimum_size.y = 34

	func _draw() -> void:
		var font := get_theme_default_font()
		var font_size := 10 if compact else 11
		var bar := Rect2(Vector2(0, 2), Vector2(size.x, 10 if compact else 12))
		var marks := [[-3.0, "填 3m"], [-0.6, "60"], [-0.2, "20"], [0.0, "±5cm"], [0.2, "20"], [0.6, "60"], [3.0, "挖 3m"]]
		if voxel:
			_draw_blocks(bar, font, font_size)
			return
		# Symmetric axis over +/-3 m with a sqrt warp so the near-grade stops
		# get visible width; labels sit at the actual fixed colour stops.
		var steps := 96
		for i in steps:
			var a := lerpf(-1, 1, float(i) / steps)
			var b := lerpf(-1, 1, float(i + 1) / steps)
			var difference := signf(a + b) * pow(absf((a + b) * 0.5), 2.0) * 3.0
			draw_rect(Rect2(bar.position.x + bar.size.x * i / steps, bar.position.y, bar.size.x / steps + 1, bar.size.y), View.difference_color(difference))
		for mark in marks:
			var value: float = mark[0]
			var u := signf(value) * sqrt(absf(value) / 3.0)
			var x := bar.position.x + (u + 1) * 0.5 * bar.size.x
			draw_line(Vector2(x, bar.end.y), Vector2(x, bar.end.y + 3), Color(1, 1, 1, 0.5), 1)
			var text: String = mark[1]
			var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			var at := Vector2(clampf(x - width * 0.5, 0, size.x - width), bar.end.y + 4 + font_size)
			if compact:
				draw_string(font, at + Vector2.ONE, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0, 0, 0, 0.8))
			draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color("c3d3de"))

	## Eleven equal palette blocks (5 fill, grade, 5 cut) matching the stepped
	## colours of the voxel charts; labels sit on the block boundaries.
	func _draw_blocks(bar: Rect2, font: Font, font_size: int) -> void:
		var stops: Array = View.COLOR_STOPS
		var count := 11
		var width := bar.size.x / count
		for b in count:
			var band := b - 5
			var difference: float = 0.0 if band == 0 else signf(band) * (stops[absi(band) - 1] + stops[mini(absi(band), stops.size() - 1)]) * 0.5
			if absi(band) == stops.size():
				difference = signf(band) * stops.back() * 1.5
			var rect := Rect2(bar.position.x + b * width, bar.position.y, width - 2, bar.size.y)
			draw_rect(Rect2(rect.position + Vector2(1, 1), rect.size), Color(0, 0, 0, 0.5))
			draw_rect(rect, View.stepped_color(difference))
			draw_rect(Rect2(rect.position, Vector2(rect.size.x, 2)), Color(1, 1, 1, 0.25))
		var labels := {0: "填", 1: "3m", 3: "60", 4: "20", 5: "±5", 6: "20", 7: "60", 9: "3m", 10: "挖"}
		for b: int in labels:
			var text: String = labels[b]
			var x := bar.position.x + (b + 0.5) * width
			if b in [1, 3, 4]:
				x = bar.position.x + b * width
			elif b in [6, 7, 9]:
				x = bar.position.x + (b + 1) * width
			var text_width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			var at := Vector2(clampf(x - text_width * 0.5, 0, size.x - text_width), bar.end.y + 4 + font_size)
			draw_string(font, at + Vector2.ONE, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0, 0, 0, 0.8))
			draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color("c3d3de"))

var model := Model.new()
var presentation: MotionPresentation
var surfaces: Array = []
var demo_kind := ""
var views: Array[Control] = []
var controls: Dictionary = {}
var hud_mode := false
var chart_style := View.STYLE_TERRAIN
var profile_latency_ms := 0
var profile_sample_count := 0
var _surface_selector: OptionButton
var _summary: Label
var _status: Label
var _message: Label
var _source: Label
var _elapsed := 0.0
var _bucket: Dictionary = {}
var _cutting: Dictionary = {}
var _demo_width := 0.0
var _expanded := false
var _center_import := true
var _elevation_offset := 0.0
var _generation := -1
var _profile_bucket: Dictionary = {}
var _machine_key := "<none>"
var _profile_revision := -1
var _profile_generation := ""
var _profile_sampled_ms := 0
var _profile_has_unknown := true
var _draw_revision := -1
var _outer: VBoxContainer
var _title: Label
var _design_row: HBoxContainer
var _charts: VBoxContainer
var _chart_rows: Array[HBoxContainer] = []
var _legend: Legend
var _hud_metrics: HBoxContainer
var _hud_values: Array[Label] = []
var _hud_captions: Array[Label] = []
var _metric_cards: Array[PanelContainer] = []

func _ready() -> void:
	name = "DtmDashboard"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var outer := VBoxContainer.new()
	_outer = outer
	outer.add_theme_constant_override("separation", 8)
	outer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(outer)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	outer.add_child(header)
	var title := Label.new()
	_title = title
	title.text = "DTM  /  施工引导"
	title.add_theme_font_size_override("font_size", 21)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_button(header, "mode", "HUD 模式", func() -> void: set_hud_mode(not hud_mode))
	_button(header, "style", "方块风", func() -> void:
		set_chart_style(View.STYLE_TERRAIN if chart_style == View.STYLE_VOXEL else View.STYLE_VOXEL)
		chart_style_changed.emit(chart_style))
	controls.style.tooltip_text = "切换示意图主题：平滑地形 / 方块像素。仅改变绘制方式，测量与色阶节点不变。"
	_button(header, "import", "导入 XML", func() -> void: import_requested.emit())
	_button(header, "expand", "放大", func() -> void:
		_expanded = not _expanded
		controls.expand.text = "还原" if _expanded else "放大"
		layout_dashboard())
	_button(header, "close", "收起", func() -> void: close_requested.emit())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
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
	var automatic_row := HBoxContainer.new()
	outer.add_child(automatic_row)
	_button(automatic_row, "urban_trench", "当前轴线沟", func() -> void: urban_trench_requested.emit())
	_button(automatic_row, "automatic", "开始 / 恢复全自动切削", func() -> void: automatic_requested.emit())
	_button(automatic_row, "automatic_stop", "停止自动作业", func() -> void: automatic_cancelled.emit())
	var mode_row := HBoxContainer.new()
	outer.add_child(mode_row)
	var digging_toggle := CheckButton.new()
	digging_toggle.text = "简易挖掘（不卸土）"
	digging_toggle.toggled.connect(func(value: bool) -> void: digging_mode_requested.emit(value))
	mode_row.add_child(digging_toggle)
	controls["simple_digging"] = digging_toggle
	var side := OptionButton.new()
	side.add_item("向右回转 90° 卸土")
	side.add_item("向左回转 90° 卸土")
	side.item_selected.connect(func(index: int) -> void: dump_side_requested.emit(index == 0))
	mode_row.add_child(side)
	controls["dump_side"] = side
	_automatic_label = Label.new()
	_automatic_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_automatic_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_automatic_label.custom_minimum_size.y = 24
	_automatic_label.add_theme_font_size_override("font_size", 12)
	_automatic_label.add_theme_color_override("font_color", Color("94aebe"))
	outer.add_child(_automatic_label)
	_source = Label.new()
	_source.add_theme_font_size_override("font_size", 11)
	_source.add_theme_color_override("font_color", Color("94aebe"))
	_source.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	outer.add_child(_source)
	# Kept for tooltips and tests; the cards below are the primary readout.
	_summary = Label.new()
	_summary.visible = false
	outer.add_child(_summary)
	_hud_metrics = HBoxContainer.new()
	_hud_metrics.add_theme_constant_override("separation", 6)
	_hud_metrics.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outer.add_child(_hud_metrics)
	for caption in ["铲齿 − 目标", "待挖", "待填", "达标"]:
		var card := PanelContainer.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.size_flags_stretch_ratio = 1.35 if caption == "铲齿 − 目标" else 1.0
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_hud_metrics.add_child(card)
		_metric_cards.append(card)
		var stack := VBoxContainer.new()
		stack.add_theme_constant_override("separation", 0)
		stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(stack)
		var label := Label.new()
		label.text = caption
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_color_override("font_color", Color("94aebe"))
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stack.add_child(label)
		_hud_captions.append(label)
		var value := Label.new()
		value.text = "—"
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		value.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		value.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stack.add_child(value)
		_hud_values.append(value)
	# Index 0..2 stay cut / fill / on-grade for existing consumers.
	_hud_values.push_back(_hud_values.pop_front())
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
		line.size_flags_stretch_ratio = 1.15 if pair[0] == "iso" else 1.0
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
			view.size_flags_stretch_ratio = 1.25 if mode in ["iso", "bucket"] else 1.0
			line.add_child(view)
			views.append(view)
	views[0].orientation_changed.connect(func(turn: int) -> void:
		views[1].quarter_turn = turn
		views[1].refresh_orientation())
	views[1].section_changed.connect(_refresh_profiles)
	views[2].section_flipped.connect(func() -> void:
		views[2].section_reversed = not views[2].section_reversed
		_refresh_profiles())
	_legend = Legend.new()
	_legend.tooltip_text = "差值 = 实测 − 目标。固定色阶节点：5 / 20 / 60 / 150 / 300 cm；超出 3 m 使用端点颜色。暖色待挖，冷色待填，薄荷绿 ±5 cm，灰色为缺测。"
	outer.add_child(_legend)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 11)
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status.add_theme_color_override("font_color", Color("b8c9d4"))
	# Readable over bright sky/sand in HUD mode, where no panel backs it.
	_status.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_status.add_theme_constant_override("shadow_offset_x", 1)
	_status.add_theme_constant_override("shadow_offset_y", 1)
	outer.add_child(_status)
	set_theme_variant("debug")
	_apply_density()
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

## Chart rendering theme, independent of the application UI skin.
func set_chart_style(style: String) -> void:
	if style not in View.STYLES:
		return
	chart_style = style
	controls.style.text = "地形风" if style == View.STYLE_VOXEL else "方块风"
	for view in views:
		view.set_style(style)
	_legend.voxel = style == View.STYLE_VOXEL
	_legend.queue_redraw()
	_apply_panel_style()

func _apply_panel_style() -> void:
	var voxel := chart_style == View.STYLE_VOXEL
	if hud_mode:
		add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	else:
		var box := GameSkin.box(Color(0.03, 0.045, 0.06, 0.97) if voxel else Color(0.035, 0.065, 0.095, 0.97), 0 if voxel else 12, 14)
		box.border_color = Color("3a4b5a") if voxel else Color("38536a")
		box.set_border_width_all(2 if voxel else 1)
		add_theme_stylebox_override("panel", box)
	for card in _metric_cards:
		var style := GameSkin.box(Color(0.03, 0.05, 0.07, 0.8) if hud_mode else (Color("10181f") if voxel else Color("13222f")), 0 if voxel else 7, 6 if hud_mode else 8)
		style.border_color = Color(0.6, 0.72, 0.8, 0.2) if hud_mode else (Color("33424f") if voxel else Color("2a4152"))
		style.set_border_width_all(1)
		if voxel:
			# Chunky bottom edge reads like a raised pixel button.
			style.border_width_bottom = 3
			style.border_color = Color("33424f") if not hud_mode else Color(0.5, 0.6, 0.68, 0.35)
		card.add_theme_stylebox_override("panel", style)

func _apply_density() -> void:
	for label in _hud_captions:
		label.add_theme_font_size_override("font_size", 10 if hud_mode else 11)
	for i in _hud_values.size():
		var big := i == 3
		_hud_values[i].add_theme_font_size_override("font_size", (15 if big else 14) if hud_mode else (21 if big else 19))
	_legend.compact = hud_mode
	_legend.custom_minimum_size.y = 28 if hud_mode else 34
	_legend.queue_redraw()

func set_hud_mode(enabled: bool) -> void:
	hud_mode = enabled
	controls.mode.text = "浮窗模式" if enabled else "HUD 模式"
	controls.import.visible = not enabled
	controls.expand.visible = not enabled
	controls.style.visible = not enabled
	controls.close.visible = not enabled
	controls.automatic.get_parent().visible = not enabled
	controls.simple_digging.get_parent().visible = not enabled
	_title.text = "DTM" if enabled else "DTM  /  施工引导"
	_title.add_theme_font_size_override("font_size", 16 if enabled else 21)
	for item in [_design_row, _source, _message]:
		item.visible = not enabled
	_outer.add_theme_constant_override("separation", 5 if enabled else 8)
	_charts.add_theme_constant_override("separation", 5 if enabled else 8)
	for i in views.size():
		var destination: Node = _charts if enabled else _chart_rows[i / 2]
		if views[i].get_parent() != destination:
			views[i].reparent(destination, false)
		views[i].set_compact(enabled)
	for row in _chart_rows:
		row.visible = not enabled
	_apply_panel_style()
	_apply_density()
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

func _current_bucket() -> Dictionary:
	if _cutting.is_empty():
		_cutting = Model.cutting_contract(presentation)
	return Model.bucket_state(presentation, _cutting)

func load_demo(kind: String) -> bool:
	if not is_instance_valid(model.sampler.zone):
		show_error("当前地图没有可用体素作业区")
		return false
	_cutting = Model.cutting_contract(presentation)
	_bucket = _current_bucket()
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

func _clear_profiles(all_views := true) -> void:
	_profile_bucket = {}
	for i in ([2, 3] if all_views else [3]):
		views[i].profile.clear()
		views[i].queue_redraw()

func _select_surface(index: int) -> void:
	design_changed.emit()
	var surface: Surface = surfaces[index]
	if _center_import:
		var center: Vector3 = model.sampler.zone.layout.ORIGIN_WORLD
		surface.translation = Vector3(center.x - surface.bounds.get_center().x, float(surface.source_origin.h) + _elevation_offset, center.z - surface.bounds.get_center().z)
	else:
		surface.translation = Vector3(float(surface.source_origin.e), float(surface.source_origin.h) + _elevation_offset, float(surface.source_origin.n))
	model.set_surface(surface)
	_clear_profiles()
	for view in views:
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

func load_local_surfaces(values: Array, description: String) -> void:
	demo_kind = ""
	_center_import = false
	_elevation_offset = 0
	_replace_surfaces(values)
	_source.text = description

func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	if automatic_status.is_valid():
		var job: Dictionary = automatic_status.call()
		(controls["simple_digging"] as CheckButton).set_pressed_no_signal(bool(job.get("simple_mode", false)))
		var names := {"idle": "未开始", "cancelled": "已停止", "paused": "已暂停", "failed": "失败", "completed": "复测达标", "select": "选择作业点", "lift": "抬斗", "finish_lift": "收尾抬斗", "navigate": "转场", "orient": "朝向校正", "approach": "对准切削点", "cut": "分层切削", "sweep": "收斗精修", "verify": "地表复测"}
		names.merge({"dump_lift": "卸土抬斗", "dump_swing": "回转至卸土区", "dump_open": "倾倒", "dump_close": "收斗", "dump_return": "回转复位"})
		names["cut"] = "连续切削" if bool(job.get("simple_mode", false)) else "挖掘"
		_automatic_label.text = "自动作业  ·  %s  ·  %d / %d" % [names.get(job.state, job.state), int(job.completed), int(job.count)]
		if not bool(job.get("simple_mode", false)):
			_automatic_label.text += "  ·  卸土 %d 次" % int(job.get("dump_cycles", 0))
		if not String(job.reason).is_empty():
			_automatic_label.text += "  ·  " + String(job.reason)
		_automatic_label.tooltip_text = _automatic_label.text
		_automatic_label.add_theme_color_override("font_color", Color("ee9b55") if job.state in ["failed", "paused"] else Color("94aebe"))
	var machine_key := presentation.get_active_model_id() + ":" + presentation.get_active_attachment_id() if is_instance_valid(presentation) else ""
	if machine_key != _machine_key:
		_machine_key = machine_key
		_cutting = {}
		_clear_profiles(false)
		_elapsed = 1
	_bucket = _current_bucket()
	if demo_kind == "trench" and not is_equal_approx(float(_bucket.get("width", 0)), _demo_width):
		if not load_demo("trench"):
			model.set_surface(null)
	if not is_instance_valid(model.sampler.zone):
		return
	if _generation != model.sampler.zone.readiness.generation:
		_generation = model.sampler.zone.readiness.generation
		model.invalidate()
		_clear_profiles()
		_elapsed = 1
	if not _bucket.is_empty():
		model.focus_xz = Vector2(_bucket.tooth.x, _bucket.tooth.z)
	model.update()
	if _profile_generation != model.current_generation:
		_profile_generation = model.current_generation
		_clear_profiles(false)
	if _draw_revision != model.display_revision:
		_draw_revision = model.display_revision
		_refresh_profiles()
		views[0].queue_redraw()
		views[1].queue_redraw()
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
	# Map charts redraw only their marker overlay for machine motion.
	views[0].set_machine(_bucket, {})
	views[1].set_machine(_bucket, section_bucket)

func _refresh_metrics() -> void:
	var clearance := "无目标"
	var clearance_color := Color("c3d3de")
	if model.surface != null and not _bucket.is_empty():
		var tooth: Vector3 = _bucket.tooth
		var target := model.surface.height_at(Vector2(tooth.x, tooth.z))
		if is_finite(target):
			var difference := tooth.y - target
			clearance = "%+.2f m %s" % [difference, "↑" if difference > 0 else "↓"]
			clearance_color = View.difference_color(difference)
		else:
			var bounds := model.surface.world_bounds()
			var nearest := Vector2(clampf(tooth.x, bounds.position.x, bounds.end.x), clampf(tooth.z, bounds.position.z, bounds.end.z))
			clearance = "距范围 %.1f m" % Vector2(tooth.x, tooth.z).distance_to(nearest)
	_hud_values[3].text = clearance
	_hud_values[3].add_theme_color_override("font_color", clearance_color)
	var stats := model.statistics
	var ready := int(stats.get("valid", 0)) > 0
	_hud_values[0].text = "%.1f m³" % stats.cut_m3 if ready else "—"
	_hud_values[1].text = "%.1f m³" % stats.fill_m3 if ready else "—"
	_hud_values[2].text = "%.0f%%" % (stats.on_grade * 100) if ready else "—"
	_hud_values[0].add_theme_color_override("font_color", Model.CUT_TEXT if ready and stats.cut_m3 > 0.05 else Color("e2edf5"))
	_hud_values[1].add_theme_color_override("font_color", Model.FILL_TEXT if ready and stats.fill_m3 > 0.05 else Color("e2edf5"))
	_hud_values[2].add_theme_color_override("font_color", View.GRADE if ready and stats.on_grade >= 0.95 else Color("e2edf5"))
	_summary.text = "铲齿 %s   |   挖 %s   填 %s   达标 %s" % [clearance, _hud_values[0].text, _hud_values[1].text, _hud_values[2].text]
	var age := (Time.get_ticks_msec() - model.sampled_at_ms) / 1000.0 if model.sampled_at_ms > 0 else 0.0
	var coverage := float(stats.get("coverage", 0)) * 100
	_status.text = "实测覆盖 %.0f%% · %.2f m 采样 · SDF 顶表面 · 切削刃中心" % [coverage, maxf(model.cell_size.x, model.cell_size.y)]
	if bool(stats.get("mixed_revision", false)):
		_status.text += " · 施工中分批测量"
	_status.tooltip_text = _status.text + "\n地表更新于 %.1f 秒前" % age + "\n" + _summary.text + "\n" + _message.text
	if hud_mode:
		_status.text = "覆盖 %.0f%%" % coverage

func _refresh_profiles() -> void:
	if model.surface == null:
		views[2].profile.clear()
		views[2].queue_redraw()
		return
	views[1].ensure_section()
	var endpoints: PackedVector2Array = views[1].section_points
	var start := endpoints[1] if views[2].section_reversed else endpoints[0]
	var end := endpoints[0] if views[2].section_reversed else endpoints[1]
	var fixed: Array[Dictionary] = []
	for i in FIXED_PROFILE_POINTS:
		var fraction := i / float(FIXED_PROFILE_POINTS - 1)
		var s := start.distance_to(end) * fraction
		var p := start.lerp(end, fraction)
		fixed.append({"s": s, "actual": model.cached_height(p), "target": model.surface.height_at(p)})
	views[2].profile = fixed
	views[2].queue_redraw()

func _sample_local_profile_step() -> void:
	if model.surface == null or _bucket.is_empty():
		if not views[3].profile.is_empty():
			views[3].profile.clear()
			views[3].queue_redraw()
		_profile_bucket = {}
		return
	var moved := _profile_bucket.is_empty()
	if not moved:
		var previous: Vector3 = _profile_bucket.tooth
		var current: Vector3 = _bucket.tooth
		moved = Vector2(previous.x, previous.z).distance_to(Vector2(current.x, current.z)) > 0.01 or (_profile_bucket.axis as Vector2).distance_to(_bucket.axis) > 0.003
	var retry_unknown := _profile_has_unknown and Time.get_ticks_msec() - _profile_sampled_ms >= 250
	if not moved and not views[3].profile.is_empty() and _profile_revision == model.current_revision and not retry_unknown:
		return
	# One batched SDF read per section (about 0.5 ms for 49 columns) keeps the
	# horizontal position/axis snapshot coherent; no multi-frame partials.
	var started := Time.get_ticks_msec()
	_profile_bucket = _bucket.duplicate()
	_profile_revision = model.current_revision
	var tooth: Vector3 = _profile_bucket.tooth
	var axis: Vector2 = _profile_bucket.axis
	var points := PackedVector2Array()
	for k in PROFILE_POINTS:
		points.append(Vector2(tooth.x, tooth.z) + axis * (-3.0 + k * PROFILE_STEP_M))
	var heights := model.sampler.heights_at(points)
	var section: Array[Dictionary] = []
	_profile_has_unknown = false
	for k in PROFILE_POINTS:
		_profile_has_unknown = _profile_has_unknown or not is_finite(heights[k])
		section.append({"s": -3.0 + k * PROFILE_STEP_M, "actual": heights[k], "target": model.surface.height_at(points[k])})
	profile_sample_count += PROFILE_POINTS
	views[3].profile = section
	views[3].profile_bucket = _profile_bucket.duplicate()
	views[3].queue_redraw()
	_profile_sampled_ms = Time.get_ticks_msec()
	profile_latency_ms = _profile_sampled_ms - started

extends RefCounted

const GameSkin := preload("res://scripts/game_ui_theme.gd")

static func build(ui: CanvasLayer, variant: String = GameSkin.VARIANT_DEBUG) -> Dictionary:
	# Console variants (industrial, sany) share the fullscreen console layout;
	# the palette accent is the only brand-level difference between them.
	var console := GameSkin.is_console_variant(variant)
	var accent := GameSkin.accent_for(variant)
	var backdrop: Control = null
	var panel := ui.get_node("StatusPanel") as PanelContainer
	var old := panel.get_node("Margin/VBox") as VBoxContainer
	var guide := ui.get_node("GuidePanel") as PanelContainer
	var root := Control.new()
	root.name = "MenuRoot"
	ui.add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.theme = GameSkin.create(variant)
	var shade := ColorRect.new()
	shade.name = "Atmosphere"
	var atmosphere := ShaderMaterial.new()
	atmosphere.shader = preload("res://shaders/menu_atmosphere.gdshader")
	atmosphere.set_shader_parameter("fx_strength", 1.0 if console else 0.0)
	shade.material = atmosphere
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(shade)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.reparent(root)
	panel.remove_theme_stylebox_override("panel")
	if console:
		panel.add_theme_stylebox_override("panel", GameSkin.frame_pad())
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	if console:
		backdrop = _Backdrop.new()
		backdrop.name = "IndustrialBackdrop"
		backdrop.accent = accent
		backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
		backdrop.panel = panel
		root.add_child(backdrop)
		root.move_child(backdrop, panel.get_index())
		backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var body := VBoxContainer.new()
	panel.add_child(body)
	body.add_theme_constant_override("separation", 16)
	var title := old.get_node("Title") as Label
	var subtitle := Label.new()
	subtitle.text = "作业已暂停 · 按 Esc 或菜单键返回驾驶"
	subtitle.add_theme_color_override("font_color", GameSkin.MUTED)
	var tabs := TabContainer.new()
	tabs.name = "Pages"
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var nav: Array[Button] = []
	var page_title: Label = null
	var completion_parent: Control = body
	var boot_rail: Array[Control] = []
	var boot_right: Array[Control] = []
	var boot_fade: Array[Control] = []
	var resume := Button.new()
	resume.name = "Resume"
	if console:
		var header := HBoxContainer.new()
		header.add_theme_constant_override("separation", 14)
		body.add_child(header)
		var accent_bar := ColorRect.new()
		accent_bar.color = accent
		accent_bar.custom_minimum_size = Vector2(5, 46)
		header.add_child(accent_bar)
		var titles := VBoxContainer.new()
		titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		titles.add_theme_constant_override("separation", 4)
		header.add_child(titles)
		title.add_theme_font_size_override("font_size", 34)
		var title_font := FontVariation.new()
		title_font.spacing_glyph = 5
		title.add_theme_font_override("font", title_font)
		move(title, titles)
		titles.add_child(subtitle)
		var head_right := VBoxContainer.new()
		head_right.add_theme_constant_override("separation", 6)
		head_right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		header.add_child(head_right)
		var lamp_chip := PanelContainer.new()
		lamp_chip.add_theme_stylebox_override("panel", GameSkin.status_chip())
		head_right.add_child(lamp_chip)
		move(old.get_node("Tools/PC001HandshakeStatus"), lamp_chip)
		ignore_mouse(lamp_chip)
		var micro := Label.new()
		micro.text = "SYS-OPS // REV 2.4"
		micro.add_theme_font_size_override("font_size", 10)
		micro.add_theme_color_override("font_color", GameSkin.MUTED)
		micro.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		head_right.add_child(micro)
		var subtitle_font := FontVariation.new()
		subtitle_font.spacing_glyph = 2
		subtitle.add_theme_font_override("font", subtitle_font)
		var stripes := ColorRect.new()
		stripes.name = "HazardStripes"
		var stripe_material := ShaderMaterial.new()
		stripe_material.shader = preload("res://shaders/hazard_stripes.gdshader")
		stripe_material.set_shader_parameter("stripe_color", accent)
		stripes.material = stripe_material
		stripes.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stripes.custom_minimum_size = Vector2(0, 8)
		body.add_child(stripes)
		var sheen := ColorRect.new()
		sheen.name = "Sheen"
		var sheen_material := ShaderMaterial.new()
		sheen_material.shader = preload("res://shaders/menu_sheen.gdshader")
		sheen_material.set_shader_parameter("tint", accent.lightened(0.35))
		sheen.material = sheen_material
		sheen.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(sheen)
		# Console layout: left navigation rail beside the page content.
		subtitle.text = "作业已暂停 · OPERATIONS CONSOLE"
		var main := HBoxContainer.new()
		main.name = "MainRow"
		main.size_flags_vertical = Control.SIZE_EXPAND_FILL
		main.add_theme_constant_override("separation", 14)
		body.add_child(main)
		var rail := PanelContainer.new()
		rail.name = "NavRail"
		rail.add_theme_stylebox_override("panel", GameSkin.rail_panel())
		rail.custom_minimum_size.x = 220
		rail.size_flags_vertical = Control.SIZE_EXPAND_FILL
		main.add_child(rail)
		var rail_body := VBoxContainer.new()
		rail_body.add_theme_constant_override("separation", 8)
		rail.add_child(rail_body)
		resume.text = "▶  继续驾驶"
		resume.custom_minimum_size.y = 56
		rail_body.add_child(resume)
		GameSkin.apply_primary(resume, accent, GameSkin.on_accent_for(variant))
		boot_rail.append(resume)
		var rail_sep := HSeparator.new()
		rail_body.add_child(rail_sep)
		var nav_titles := ["设备与设置", "操作说明", "高级工具", "视频设置"]
		for index in nav_titles.size():
			var item := Button.new()
			item.name = "Nav%d" % index
			item.text = "0%d   %s" % [index + 1, nav_titles[index]]
			item.custom_minimum_size.y = 48
			GameSkin.apply_nav_button(item, accent)
			var tab_index := index
			item.pressed.connect(func():
				tabs.current_tab = tab_index
				# Re-assert the lit state: toggling an already-active page off
				# would leave no selection lit since current_tab did not change.
				item.set_pressed_no_signal(true)
			)
			rail_body.add_child(item)
			nav.append(item)
			boot_rail.append(item)
		var rail_spacer := Control.new()
		rail_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
		rail_body.add_child(rail_spacer)
		var rail_hint := Label.new()
		rail_hint.text = "LB / RB  翻页"
		rail_hint.add_theme_color_override("font_color", GameSkin.MUTED)
		rail_hint.add_theme_font_size_override("font_size", 11)
		rail_body.add_child(rail_hint)
		boot_rail.append(rail_hint)
		var content := VBoxContainer.new()
		content.name = "PageContent"
		content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		content.add_theme_constant_override("separation", 10)
		main.add_child(content)
		page_title = Label.new()
		page_title.name = "PageTitle"
		page_title.add_theme_font_size_override("font_size", 21)
		page_title.add_theme_color_override("font_color", GameSkin.PAPER)
		var page_font := FontVariation.new()
		page_font.spacing_glyph = 2
		page_title.add_theme_font_override("font", page_font)
		content.add_child(page_title)
		content.add_child(HSeparator.new())
		tabs.tabs_visible = false
		content.add_child(tabs)
		boot_right.append(page_title)
		boot_right.append(tabs)
		body.add_child(HSeparator.new())
		var footer := HBoxContainer.new()
		footer.name = "MenuFooter"
		footer.add_theme_constant_override("separation", 18)
		body.add_child(footer)
		var hints := Label.new()
		hints.text = "A 确认   B 返回   Esc 返回驾驶"
		hints.add_theme_color_override("font_color", GameSkin.MUTED)
		hints.add_theme_font_size_override("font_size", 12)
		footer.add_child(hints)
		boot_fade.append(hints)
		completion_parent = footer
	else:
		title.add_theme_font_size_override("font_size", 30)
		move(title, body)
		body.add_child(subtitle)
		resume.text = "继续驾驶   →"
		resume.custom_minimum_size.y = 48
		body.add_child(resume)
		resume.add_theme_color_override("font_color", GameSkin.ACCENT)
		body.add_child(tabs)
	var settings := page(tabs, "设备与设置")
	var controls := page(tabs, "操作说明")
	var advanced := page(tabs, "高级工具")
	var video := page(tabs, "视频设置")
	settings.add_child(section_heading("当前设备", variant))
	move(old.get_node("Header"), settings)
	var coupler_selector := OptionButton.new()
	coupler_selector.name = "CouplerSelector"
	coupler_selector.custom_minimum_size.y = 42
	settings.add_child(coupler_selector)
	var attachment_selector := OptionButton.new()
	attachment_selector.name = "AttachmentSelector"
	attachment_selector.custom_minimum_size.y = 42
	settings.add_child(attachment_selector)
	var map_selector := OptionButton.new()
	map_selector.name = "MapSelector"
	map_selector.custom_minimum_size.y = 42
	settings.add_child(map_selector)
	settings.add_child(section_heading("界面主题", variant))
	var theme_selector := OptionButton.new()
	theme_selector.name = "ThemeSelector"
	theme_selector.custom_minimum_size.y = 42
	settings.add_child(theme_selector)
	move(old.get_node("Tools/BucketPassthrough"), settings)
	move(old.get_node("CameraRow"), settings)
	move(old.get_node("Tools/MuteAudio"), settings)
	var reset_note := Label.new()
	reset_note.text = "重新开始将清空地形改动和斗内土量。"
	reset_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	reset_note.add_theme_color_override("font_color", GameSkin.MUTED)
	settings.add_child(reset_note)
	var reset_button := old.get_node("Actions/Reset") as Button
	move(reset_button, settings)
	if console:
		GameSkin.apply_danger(reset_button)
	var guide_body := guide.get_node("Margin/VBox")
	for child in guide_body.get_children():
		move(child, controls)
	guide.hide()
	move(old.get_node("ControlHint"), controls)
	move(old.get_node("AutomaticSoilHint"), controls)
	var hardware: PanelContainer = null
	if not console:
		hardware = PanelContainer.new()
		hardware.name = "HardwareDock"
		hardware.theme = root.theme
		ui.add_child(hardware)
		hardware.position = Vector2(28, 28)
		hardware.custom_minimum_size.x = 320
		var hardware_body := VBoxContainer.new()
		hardware.add_child(hardware_body)
		var connection := HBoxContainer.new()
		hardware_body.add_child(connection)
		var tcp := Label.new()
		tcp.text = "TCP / CAN"
		tcp.add_theme_color_override("font_color", GameSkin.MUTED)
		connection.add_child(tcp)
		move(old.get_node("Tools/PC001HandshakeStatus"), connection)
		for key in ["CANOutputToggle", "GatewayRestartButton"]:
			var button := old.get_node("Tools/" + key) as Button
			move(button, hardware_body)
			button.focus_mode = Control.FOCUS_NONE
	var tools := GridContainer.new()
	tools.columns = 2
	advanced.add_child(tools)
	for child in old.get_node("Tools").get_children():
		move(child, tools)
	move(old.get_node("AdvancedPanel"), advanced)
	# Session readouts belong to the advanced menu, not a persistent driving panel.
	for key in ["Operation", "BucketStatus", "BucketFill", "Warning"]:
		move(old.get_node(key), advanced)
	video.add_child(section_heading("显示模式", variant))
	var window_mode_selector := OptionButton.new()
	window_mode_selector.name = "WindowModeSelector"
	window_mode_selector.custom_minimum_size.y = 42
	video.add_child(window_mode_selector)
	video.add_child(section_heading("帧率上限", variant))
	var fps_limit_selector := OptionButton.new()
	fps_limit_selector.name = "FpsLimitSelector"
	fps_limit_selector.custom_minimum_size.y = 42
	video.add_child(fps_limit_selector)
	var completion := old.get_node("Completion") as Control
	move(completion, completion_parent)
	if completion_parent != body:
		completion_parent.move_child(completion, 0)
		completion.add_theme_font_size_override("font_size", 13)
		completion.add_theme_color_override("font_color", GameSkin.MUTED)
	if page_title != null and tabs.get_tab_count() > 0:
		page_title.text = tabs.get_tab_title(0)
	if not nav.is_empty():
		nav[0].set_pressed_no_signal(true)
	old.get_parent().queue_free()
	return {"root": root, "panel": panel, "resume": resume, "tabs": tabs, "hardware": hardware, "atmosphere": atmosphere, "coupler_selector": coupler_selector, "attachment_selector": attachment_selector, "map_selector": map_selector, "theme_selector": theme_selector, "window_mode_selector": window_mode_selector, "fps_limit_selector": fps_limit_selector, "nav": nav, "page_title": page_title, "backdrop": backdrop, "boot": {"rail": boot_rail, "right": boot_right, "fade": boot_fade}, "variant": variant}

static func section_heading(text: String, variant: String) -> Control:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", GameSkin.MUTED)
	if not GameSkin.is_console_variant(variant):
		return label
	label.add_theme_color_override("font_color", GameSkin.PAPER)
	label.add_theme_font_size_override("font_size", 14)
	var font := FontVariation.new()
	font.spacing_glyph = 3
	label.add_theme_font_override("font", font)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var tick := ColorRect.new()
	tick.color = GameSkin.accent_for(variant)
	tick.custom_minimum_size = Vector2(4, 15)
	row.add_child(tick)
	row.add_child(label)
	return row


static func page(tabs: TabContainer, title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	tabs.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	return content

static func move(node: Node, parent: Node) -> void:
	node.reparent(parent)
	if node is Control:
		(node as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if node is Label:
		(node as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

static func ignore_mouse(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		ignore_mouse(child)


## Draws the industrial chrome behind the menu: viewport corner reticles and a
## chamfered machine-plate frame with breathing corner brackets around the panel.
class _Backdrop:
	extends Control
	var panel: Control
	var scan := -1.0
	var accent := Color("efb64d")
	var _t := 0.0

	func _process(delta: float) -> void:
		if not is_visible_in_tree():
			return
		_t += delta
		queue_redraw()

	func _draw() -> void:
		var m := 16.0
		var ret := Color(accent, 0.26)
		var ex := size.x
		var ey := size.y
		for c in [Vector2(m, m), Vector2(ex - m, m), Vector2(ex - m, ey - m), Vector2(m, ey - m)]:
			var dir := Vector2(sign(ex * 0.5 - c.x), sign(ey * 0.5 - c.y))
			draw_rect(Rect2(c, Vector2(20.0 * dir.x, 2.0 * dir.y)).abs(), ret)
			draw_rect(Rect2(c, Vector2(2.0 * dir.x, 20.0 * dir.y)).abs(), ret)
		if panel == null or not panel.is_inside_tree():
			return
		var pr := Rect2(panel.position - position, panel.size).grow(6.0)
		var plate := _chamfer(pr, 22.0, 9.0)
		var shadow := PackedVector2Array()
		for p in plate:
			shadow.append(p + Vector2(0, 9))
		draw_colored_polygon(shadow, Color(0.0, 0.0, 0.0, 0.45))
		draw_colored_polygon(plate, Color(0.042, 0.055, 0.066, 0.965))
		var ring := PackedVector2Array(plate)
		ring.append(plate[0])
		draw_polyline(ring, Color(0.64, 0.70, 0.72, 0.30), 1.4, true)
		var inner := _chamfer(pr.grow(-6.0), 18.0, 7.0)
		inner.append(inner[0])
		draw_polyline(inner, Color(0.64, 0.70, 0.72, 0.09), 1.0, true)
		var bc := Color(accent, 0.30 + 0.45 * (0.5 + 0.5 * sin(_t * 2.4)))
		_corner(pr.position + Vector2(-4, -4), Vector2(1, 1), bc)
		_corner(Vector2(pr.end.x, pr.position.y) + Vector2(4, -4), Vector2(-1, 1), bc)
		_corner(pr.end + Vector2(4, 4), Vector2(-1, -1), bc)
		_corner(Vector2(pr.position.x, pr.end.y) + Vector2(-4, 4), Vector2(1, -1), bc)
		if scan >= -0.08 and scan <= 1.08:
			var vis := 1.0 - clampf(absf(scan - 0.5) * 2.4, 0.0, 1.0)
			var y := pr.position.y + pr.size.y * clampf(scan, 0.0, 1.0)
			draw_rect(Rect2(pr.position.x, y - 26.0, pr.size.x, 52.0), Color(accent, 0.10 * vis))
			draw_rect(Rect2(pr.position.x, y - 10.0, pr.size.x, 20.0), Color(accent, 0.16 * vis))
			draw_rect(Rect2(pr.position.x, y - 1.5, pr.size.x, 3.0), Color(1.0, 0.92, 0.7, 0.85 * vis))

	func _corner(at: Vector2, dir: Vector2, c: Color) -> void:
		draw_rect(Rect2(at, Vector2(18.0 * dir.x, 3.0 * dir.y)).abs(), c)
		draw_rect(Rect2(at, Vector2(3.0 * dir.x, 18.0 * dir.y)).abs(), c)

	func _chamfer(r: Rect2, a: float, b: float) -> PackedVector2Array:
		var x0 := r.position.x
		var y0 := r.position.y
		var x1 := r.end.x
		var y1 := r.end.y
		return PackedVector2Array([
			Vector2(x0 + b, y0), Vector2(x1 - a, y0),
			Vector2(x1, y0 + a), Vector2(x1, y1 - b),
			Vector2(x1 - b, y1), Vector2(x0 + a, y1),
			Vector2(x0, y1 - a), Vector2(x0, y0 + b),
		])

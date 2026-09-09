extends RefCounted

const GameSkin := preload("res://scripts/game_ui_theme.gd")

static func build(ui: CanvasLayer) -> Dictionary:
	var panel := ui.get_node("StatusPanel") as PanelContainer
	var old := panel.get_node("Margin/VBox") as VBoxContainer
	var guide := ui.get_node("GuidePanel") as PanelContainer
	var root := Control.new()
	root.name = "MenuRoot"
	ui.add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.theme = GameSkin.create()
	var shade := ColorRect.new()
	shade.name = "Atmosphere"
	var atmosphere := ShaderMaterial.new()
	atmosphere.shader = preload("res://shaders/menu_atmosphere.gdshader")
	shade.material = atmosphere
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(shade)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.reparent(root)
	panel.remove_theme_stylebox_override("panel")
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	var body := VBoxContainer.new()
	panel.add_child(body)
	body.add_theme_constant_override("separation", 16)
	var title := old.get_node("Title") as Label
	title.add_theme_font_size_override("font_size", 30)
	move(title, body)
	var subtitle := Label.new()
	subtitle.text = "作业已暂停 · 按 Esc 或菜单键返回驾驶"
	subtitle.add_theme_color_override("font_color", GameSkin.MUTED)
	body.add_child(subtitle)
	var resume := Button.new()
	resume.name = "Resume"
	resume.text = "继续驾驶   →"
	resume.custom_minimum_size.y = 48
	resume.add_theme_color_override("font_color", GameSkin.ACCENT)
	body.add_child(resume)
	var tabs := TabContainer.new()
	tabs.name = "Pages"
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(tabs)
	var settings := page(tabs, "设备与设置")
	var controls := page(tabs, "操作说明")
	var advanced := page(tabs, "高级工具")
	var heading := Label.new()
	heading.text = "当前设备"
	heading.add_theme_color_override("font_color", GameSkin.MUTED)
	settings.add_child(heading)
	move(old.get_node("Header"), settings)
	move(old.get_node("CameraRow"), settings)
	move(old.get_node("Tools/MuteAudio"), settings)
	var reset_note := Label.new()
	reset_note.text = "重新开始将清空地形改动和斗内土量。"
	reset_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	reset_note.add_theme_color_override("font_color", GameSkin.MUTED)
	settings.add_child(reset_note)
	move(old.get_node("Actions/Reset"), settings)
	var guide_body := guide.get_node("Margin/VBox")
	for child in guide_body.get_children():
		move(child, controls)
	guide.hide()
	move(old.get_node("ControlHint"), controls)
	move(old.get_node("AutomaticSoilHint"), controls)
	var hardware := PanelContainer.new()
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
	move(old.get_node("Completion"), body)
	old.get_parent().queue_free()
	return {"root": root, "panel": panel, "resume": resume, "tabs": tabs, "hardware": hardware, "atmosphere": atmosphere}

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

class_name ControlInputHUD
extends PanelContainer

const GameSkin := preload("res://scripts/game_ui_theme.gd")
const GROUP_ACTIONS := [
	["operator_swing_left", "operator_swing_right", "operator_arm_extend", "operator_arm_retract"],
	["operator_bucket_curl", "operator_bucket_dump", "operator_boom_lower", "operator_boom_raise"],
	["track_left_forward", "track_left_reverse", "track_right_forward", "track_right_reverse"],
]
const KEY_COPY := ["W", "A", "S", "D", "I", "J", "K", "L", "R", "F", "Y", "H"]
## Pad glyphs are drawn as petals/arrows inside the widgets; PAD_GLYPHS maps
## actions to those arrows for the (hidden) key-label test hooks.
const PAD_COPY := ["↑", "←", "↓", "→", "↑", "←", "↓", "→", "LT", "LB", "RT", "RB"]
const ACTIONS := [
	"operator_arm_extend", "operator_swing_left", "operator_arm_retract", "operator_swing_right",
	"operator_boom_lower", "operator_bucket_curl", "operator_boom_raise", "operator_bucket_dump",
	"track_left_forward", "track_left_reverse", "track_right_forward", "track_right_reverse",
]
## Function captions under each key/stick tile, in ACTIONS order.
const FUNCTION_CAPTIONS := [
	"臂伸", "回左", "臂收", "回右",
	"臂降", "斗收", "臂升", "斗翻",
	"左前进", "左后退", "右前进", "右后退",
]
## D-pad hold-modifier layer shown in gamepad mode. Direction order in the
## cross matches the stick crosses: [up, left, down, right].
const DPAD_TILE_ACTIONS := [
	"pad_layer_dpad_up", "pad_layer_dpad_left",
	"pad_layer_dpad_down", "pad_layer_dpad_right",
]
const DPAD_CAPTIONS := ["双截", "偏摆", "倾旋", "—"]
## While a D-pad modifier is held, the borrowed right-stick tiles (ACTIONS
## indices 4..7 = up/left/down/right) relabel to the layer function. Applied
## in listing order so the tiltrotator layer wins its shared bucket pair.
const PAD_LAYER_OVERRIDES := {
	"pad_layer_dpad_up": {4: "展开", 6: "折叠"},
	"pad_layer_dpad_left": {5: "偏摆左", 7: "偏摆右"},
	"pad_layer_dpad_down": {4: "后倾", 5: "左旋", 6: "前倾", 7: "右旋"},
}
var _prompt_mode := "keyboard"
const WHEEL_ACTIONS := {
	"track_left_forward": "wheel_forward", "track_left_reverse": "wheel_reverse",
	"track_right_forward": "wheel_right", "track_right_reverse": "wheel_left",
}
const TRAVEL_ACTIONS := [
	"track_left_forward", "track_left_reverse",
	"track_right_forward", "track_right_reverse",
]
const WHEEL_CAPTIONS := {"track_left_forward": "前进", "track_left_reverse": "后退",
	"track_right_forward": "右转", "track_right_reverse": "左转"}
const TRACK_CAPTIONS := {"track_left_forward": "左前进", "track_left_reverse": "左后退",
	"track_right_forward": "右前进", "track_right_reverse": "右后退"}
var _wheeled := false
var _captions: Dictionary = {}
var _kb_box: Control
var _pad_box: Control
var _pad_widgets: Array[_PadWidget] = []
## Per-mode registries; _tiles/_keys/_captions alias the active mode's maps.
var _kb_reg := {"tiles": {}, "keys": {}, "captions": {}}
var _pad_reg := {"tiles": {}, "keys": {}, "captions": {}}
var _theme_variant := GameSkin.VARIANT_DEBUG
var _keys: Dictionary = {}
var _tiles: Dictionary = {}
var _title: Label
var _footer: Label
var _divider: HSeparator
var _stripe: ColorRect
var _brackets: Control
var _idle: StyleBoxFlat
var _pressed: StyleBoxFlat

func set_theme_variant(variant: String) -> void:
	if variant == _theme_variant:
		return
	_theme_variant = variant
	if not is_node_ready():
		return
	_apply_variant_styles()
	for action in _tiles:
		_refresh_tile(action)

func _apply_variant_styles() -> void:
	theme = GameSkin.create(_theme_variant)
	var accent := GameSkin.accent_for(_theme_variant)
	if GameSkin.is_console_variant(_theme_variant):
		var panel := GameSkin.box(Color(0.068, 0.088, 0.104, 0.88), 10, 16)
		panel.border_color = Color(0.64, 0.70, 0.72, 0.22)
		panel.set_border_width_all(1)
		panel.shadow_color = Color(0, 0, 0, 0.45)
		panel.shadow_size = 14
		panel.shadow_offset = Vector2(0, 5)
		add_theme_stylebox_override("panel", panel)
		var idle := GameSkin.box(Color("21282e", 0.92), 5, 4)
		idle.border_color = Color(0.62, 0.68, 0.70, 0.20)
		idle.set_border_width_all(1)
		idle.skew = Vector2(0.07, 0)
		_idle = idle
		var pressed := GameSkin.box(accent.darkened(0.08), 5, 4)
		pressed.border_color = accent.lightened(0.25)
		pressed.set_border_width_all(1)
		pressed.shadow_color = Color(accent, 0.35)
		pressed.shadow_size = 8
		pressed.skew = Vector2(0.07, 0)
		_pressed = pressed
	else:
		var debug_panel := GameSkin.box(Color(0.10, 0.135, 0.155, 0.84), 10, 16)
		debug_panel.border_color = Color(accent, 0.22)
		debug_panel.set_border_width_all(1)
		add_theme_stylebox_override("panel", debug_panel)
		_idle = GameSkin.box(Color("293137"), 5, 4)
		_idle.border_color = Color(accent, 0.18)
		_idle.set_border_width_all(1)
		_pressed = GameSkin.box(Color("69522d"), 5, 4)
		_pressed.border_color = accent
		_pressed.set_border_width_all(1)
		_pressed.shadow_color = Color(accent, 0.30)
		_pressed.shadow_size = 7
	for widget in _pad_widgets:
		widget.apply_theme(accent, GameSkin.is_console_variant(_theme_variant))
	_sync_variant_chrome()

## Console chrome: inset corner brackets, an accent title and a divider line.
## Safe to call before or after the content column exists.
func _sync_variant_chrome() -> void:
	var console := GameSkin.is_console_variant(_theme_variant)
	var accent := GameSkin.accent_for(_theme_variant)
	if console and _brackets == null:
		_brackets = _Brackets.new()
		_brackets.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_brackets)
	elif not console and _brackets != null:
		_brackets.queue_free()
		_brackets = null
	if _brackets != null:
		_brackets.set("color", Color(accent, 0.8))
		_brackets.queue_redraw()
		move_child(_brackets, -1)
	if console and _stripe == null and _title != null:
		_stripe = ColorRect.new()
		_stripe.name = "HazardEdge"
		var stripe_material := ShaderMaterial.new()
		stripe_material.shader = load("res://shaders/hazard_stripes.gdshader")
		stripe_material.set_shader_parameter("scroll_px_s", 14.0)
		stripe_material.set_shader_parameter("stripe_color", accent)
		_stripe.material = stripe_material
		_stripe.custom_minimum_size = Vector2(0, 4)
		_stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_title.get_parent().add_child(_stripe)
		_title.get_parent().move_child(_stripe, 0)
	elif not console and _stripe != null:
		_stripe.queue_free()
		_stripe = null
	if _stripe != null:
		(_stripe.material as ShaderMaterial).set_shader_parameter("stripe_color", accent)
	if console and _divider == null and _title != null:
		_divider = HSeparator.new()
		_divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_divider.modulate = Color(accent, 0.45)
		_title.get_parent().add_child(_divider)
		_title.get_parent().move_child(_divider, _title.get_index() + 1)
	elif not console and _divider != null:
		_divider.queue_free()
		_divider = null
	if _title != null:
		_title.add_theme_color_override(
			"font_color", accent if console else GameSkin.PAPER
		)
		_title.add_theme_font_size_override("font_size", 13 if console else 12)
	if _footer != null:
		_footer.add_theme_color_override(
			"font_color", GameSkin.MUTED if console else GameSkin.PAPER
		)

func _refresh_tile(action: String) -> void:
	var tile := _tiles[action] as Control
	var active := bool(tile.get_meta("active", false))
	var accent := GameSkin.accent_for(_theme_variant)
	var on_accent := active and GameSkin.is_console_variant(_theme_variant)
	if tile.has_meta("keycap"):
		(tile as PanelContainer).add_theme_stylebox_override("panel", _pressed if active else _idle)
	elif tile.has_meta("pad_widget"):
		(tile.get_meta("pad_widget") as _PadWidget).queue_redraw()
	var key := _keys[action] as Label
	key.add_theme_color_override(
		"font_color",
		GameSkin.on_accent_for(_theme_variant) if on_accent else accent
	)
	var caption := _captions.get(action) as Label
	if caption != null:
		caption.add_theme_color_override(
			"font_color",
			GameSkin.on_accent_for(_theme_variant) if on_accent else (accent if active else Color(GameSkin.MUTED, 0.85))
		)

func _ready() -> void:
	_apply_variant_styles()
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	add_child(column)
	_title = _label("操纵辅助 · ISO", 12)
	column.add_child(_title)
	var hairline := HSeparator.new()
	hairline.modulate = Color(GameSkin.accent_for(_theme_variant), 0.35)
	hairline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(hairline)
	# Travel keys as a 2x2 keycap grid: forward keys on the top row, reverse
	# below — R/Y over F/H matches keyboard columns, and for pads it stacks
	# the triggers above the bumpers. Shared between prompt modes.
	var tracks := GridContainer.new()
	tracks.name = "Tracks"
	tracks.columns = 2
	tracks.add_theme_constant_override("h_separation", 8)
	tracks.add_theme_constant_override("v_separation", 5)
	column.add_child(tracks)
	for index in [8, 10, 9, 11]:
		tracks.add_child(_key_tile(ACTIONS[index], "", FUNCTION_CAPTIONS[index]))
	var sticks := HBoxContainer.new()
	sticks.name = "Sticks"
	sticks.add_theme_constant_override("separation", 12)
	column.add_child(sticks)
	# Keyboard: classic key-tile crosses (WASD / IJKL).
	_kb_box = HBoxContainer.new()
	_kb_box.add_theme_constant_override("separation", 14)
	sticks.add_child(_kb_box)
	_kb_box.add_child(_kb_cross("回转 / 小臂", "L", ACTIONS.slice(0, 4),
			KEY_COPY.slice(0, 4), FUNCTION_CAPTIONS.slice(0, 4)))
	_kb_box.add_child(_kb_cross("大臂 / 铲斗", "R", ACTIONS.slice(4, 8),
			KEY_COPY.slice(4, 8), FUNCTION_CAPTIONS.slice(4, 8)))
	# Gamepad: drawn widgets — D-pad hold-modifier plus, analog stick gates.
	_pad_box = HBoxContainer.new()
	_pad_box.add_theme_constant_override("separation", 22)
	sticks.add_child(_pad_box)
	_pad_box.add_child(_pad_section("左摇杆", "L", ACTIONS.slice(0, 4), FUNCTION_CAPTIONS.slice(0, 4), false))
	_pad_box.add_child(_pad_section("十字键", "✚", DPAD_TILE_ACTIONS, DPAD_CAPTIONS, true))
	_pad_box.add_child(_pad_section("右摇杆", "R", ACTIONS.slice(4, 8), FUNCTION_CAPTIONS.slice(4, 8), false))
	_footer = _label("", 12)
	column.add_child(_footer)
	set_prompt_mode(_prompt_mode)
	_sync_variant_chrome()
	_ignore_mouse(self)


## Keyboard layout: the classic cross of keycap tiles, letters plus a small
## function caption under each key.
func _kb_cross(header_text: String, center_text: String, direction_actions: Array, glyphs: Array, captions: Array) -> VBoxContainer:
	var section := VBoxContainer.new()
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var header := _label(header_text, 11)
	header.add_theme_color_override("font_color", Color(GameSkin.PAPER, 0.72))
	section.add_child(header)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	section.add_child(grid)
	for cell in range(9):
		var direction: int = {1: 0, 3: 1, 7: 2, 5: 3}.get(cell, -1)
		if direction >= 0:
			grid.add_child(_kb_tile(String(direction_actions[direction]),
					String(glyphs[direction]), String(captions[direction])))
		else:
			var empty := _label(center_text, 12) if cell == 4 else Control.new()
			empty.custom_minimum_size = Vector2(48, 40)
			grid.add_child(empty)
	return section


func _kb_tile(action: String, glyph: String, caption: String) -> PanelContainer:
	var tile := PanelContainer.new()
	tile.custom_minimum_size = Vector2(48, 40)
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tile.set_meta("keycap", true)
	tile.add_theme_stylebox_override("panel", _idle)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 0)
	tile.add_child(content)
	var key := _label(glyph, 15)
	key.add_theme_color_override("font_color", GameSkin.accent_for(_theme_variant))
	content.add_child(key)
	var caption_label := _label(caption, 10)
	caption_label.add_theme_color_override("font_color", Color(GameSkin.MUTED, 0.85))
	content.add_child(caption_label)
	_kb_reg["captions"][action] = caption_label
	_kb_reg["keys"][action] = key
	_kb_reg["tiles"][action] = tile
	return tile


## Gamepad layout: a drawn widget (D-pad plus / stick gate with a tilting
## nub) surrounded by function captions. Anchors are zero-size Controls at
## each petal position so tests keep rect/meta hooks and highlights flow
## through the normal tile pipeline.
func _pad_section(header_text: String, hub_text: String, direction_actions: Array, captions: Array, is_dpad: bool) -> VBoxContainer:
	var section := VBoxContainer.new()
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var header := _label(header_text, 11)
	header.add_theme_color_override("font_color", Color(GameSkin.PAPER, 0.72))
	section.add_child(header)
	var widget := _PadWidget.new()
	widget.is_dpad = is_dpad
	widget.hub_text = hub_text
	widget.custom_minimum_size = Vector2(148, 116)
	widget.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for action in direction_actions:
		widget.axis_actions.append(String(action))
	widget.apply_theme(GameSkin.accent_for(_theme_variant), GameSkin.is_console_variant(_theme_variant))
	_pad_widgets.append(widget)
	var anchor_pos := [Vector2(0.50, 0.16), Vector2(0.14, 0.50),
			Vector2(0.50, 0.84), Vector2(0.86, 0.50)]
	for index in 4:
		var action := String(direction_actions[index])
		var anchor := Control.new()
		anchor.anchor_left = anchor_pos[index].x
		anchor.anchor_right = anchor_pos[index].x
		anchor.anchor_top = anchor_pos[index].y
		anchor.anchor_bottom = anchor_pos[index].y
		anchor.set_meta("pad_widget", widget)
		widget.add_child(anchor)
		widget.anchors.append(anchor)
		var caption := _label(String(captions[index]), 10)
		caption.add_theme_color_override("font_color", Color(GameSkin.MUTED, 0.85))
		widget.add_child(caption)
		widget.captions.append(caption)
		# Hidden glyph label keeps the _keys test hook; petals carry the
		# drawn direction arrow instead of text.
		var key := _label(String(PAD_GLYPHS.get(action, "")), 11)
		key.visible = false
		widget.add_child(key)
		_pad_reg["tiles"][action] = anchor
		_pad_reg["keys"][action] = key
		_pad_reg["captions"][action] = caption
	section.add_child(widget)
	return section


const PAD_GLYPHS := {"operator_arm_extend": "↑", "operator_swing_left": "←",
	"operator_arm_retract": "↓", "operator_swing_right": "→",
	"operator_boom_lower": "↑", "operator_bucket_curl": "←",
	"operator_boom_raise": "↓", "operator_bucket_dump": "→",
	"pad_layer_dpad_up": "↑", "pad_layer_dpad_left": "←",
	"pad_layer_dpad_down": "↓", "pad_layer_dpad_right": "→"}


## Travel keys and shoulder buttons stay as discrete keycap tiles, shared by
## both prompt modes.
func _key_tile(action: String, glyph: String, caption: String) -> PanelContainer:
	var tile := PanelContainer.new()
	tile.custom_minimum_size = Vector2(52, 38)
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tile.set_meta("keycap", true)
	tile.add_theme_stylebox_override("panel", _idle)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 0)
	tile.add_child(content)
	var key := _label(glyph, 15)
	key.add_theme_color_override("font_color", GameSkin.accent_for(_theme_variant))
	content.add_child(key)
	var caption_label := _label(caption, 10)
	caption_label.add_theme_color_override("font_color", Color(GameSkin.MUTED, 0.85))
	content.add_child(caption_label)
	for reg in [_kb_reg, _pad_reg]:
		reg["captions"][action] = caption_label
		reg["keys"][action] = key
		reg["tiles"][action] = tile
	return tile

func _label(copy: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = copy
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	return label

func set_prompt_mode(mode: String) -> void:
	_prompt_mode = mode
	var reg := _kb_reg if mode == "keyboard" else _pad_reg
	_tiles = reg["tiles"]
	_keys = reg["keys"]
	_captions = reg["captions"]
	if _kb_box != null:
		_kb_box.visible = mode == "keyboard"
	if _pad_box != null:
		_pad_box.visible = mode == "gamepad"
	if _keys.is_empty():
		return
	# Travel keycaps are shared; their glyph labels follow the active mode.
	# Slots are [left fwd, left rev, right fwd, right rev]; pads read
	# LT/LB/RT/RB tracked or RT drive / LT reverse / RB/LB steer wheeled.
	var travel: Array = (["R", "F", "Y", "H"] if mode == "keyboard" else ["LT", "LB", "RT", "RB"])
	if _wheeled:
		travel = ["G", "B", "N", "V"] if mode == "keyboard" else ["RT", "LT", "RB", "LB"]
	for index in 4:
		(_keys[TRAVEL_ACTIONS[index]] as Label).text = travel[index]
	_footer.text = "1–5 切换视角 · C 复位" if mode == "keyboard" else "View 循环视角 · R3 复位 · Y 辅助 · 按住十字键+右摇杆 属具层"
	if _wheeled and mode == "keyboard":
		_footer.text += " · 空格刹车 · Shift 漂移"
	elif _wheeled:
		_footer.text += " · A 漂移"

func _process(_delta: float) -> void:
	refresh_input_state_for_test()

func refresh_input_state_for_test() -> void:
	for action in _tiles:
		var input_action: String = WHEEL_ACTIONS.get(action, action) if _wheeled else action
		var active := InputMap.has_action(input_action) and Input.is_action_pressed(input_action)
		var tile := _tiles[action] as Control
		if bool(tile.get_meta("active", not active)) != active:
			tile.set_meta("active", active)
			_refresh_tile(action)
			if active and GameSkin.is_console_variant(_theme_variant) and is_inside_tree():
				var pop := tile.get_meta("pop") as Tween
				if is_instance_valid(pop):
					pop.kill()
				tile.pivot_offset = tile.size * 0.5
				tile.scale = Vector2(0.88, 0.88)
				var tween := create_tween()
				tween.tween_property(tile, "scale", Vector2.ONE, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
				tile.set_meta("pop", tween)
	for widget in _pad_widgets:
		if widget.is_dpad or widget.axis_actions.size() != 4:
			continue
		var tilt := Vector2.ZERO
		var registered := true
		for axis_action in widget.axis_actions:
			if not InputMap.has_action(axis_action):
				registered = false
				break
		if registered:
			tilt = Vector2(
				Input.get_axis(widget.axis_actions[1], widget.axis_actions[3]),
				Input.get_axis(widget.axis_actions[0], widget.axis_actions[2]))
		if tilt != widget.tilt:
			widget.tilt = tilt
			widget.queue_redraw()
	_sync_layer_captions()


## While a D-pad modifier is held, the borrowed right-stick tiles relabel to
## the layer's functions so the operator sees what the stick now drives.
func _sync_layer_captions() -> void:
	var overrides := {}
	for pad_action in ["pad_layer_dpad_up", "pad_layer_dpad_left", "pad_layer_dpad_down"]:
		if InputMap.has_action(pad_action) and Input.is_action_pressed(pad_action):
			for tile_index in PAD_LAYER_OVERRIDES[pad_action]:
				overrides[int(tile_index)] = PAD_LAYER_OVERRIDES[pad_action][tile_index]
	for reg in [_kb_reg, _pad_reg]:
		var captions: Dictionary = reg["captions"]
		for index in range(8):
			var label := captions.get(ACTIONS[index]) as Label
			if label != null:
				label.text = String(overrides.get(index, FUNCTION_CAPTIONS[index]))

func is_action_highlighted_for_test(action: String) -> bool:
	return _tiles.has(action) and bool((_tiles[action] as Control).get_meta("active", false))

func _ignore_mouse(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_ignore_mouse(child)


## Drawn gamepad widget. D-pad renders as a plus silhouette with a pressed
## arm highlight; sticks render as an octagonal gate with four direction
## petals and a nub that tilts with live axis input. Direction captions sit
## around the widget edges; anchors are invisible Controls at the petal
## positions carrying the highlight metadata.
class _PadWidget:
	extends Control
	const DIRS := [Vector2(0, -1), Vector2(-1, 0), Vector2(0, 1), Vector2(1, 0)]
	var is_dpad := false
	var hub_text := ""
	var anchors: Array[Control] = []       # order: up, left, down, right
	var captions: Array[Label] = []        # same order, laid out around the ring
	var axis_actions: Array[String] = []   # same order
	var tilt := Vector2.ZERO
	var _plate := Color("242d33", 0.92)
	var _arm := Color("2e3840", 0.95)
	var _border := Color("efb64d", 0.30)
	var _active := Color("efb64d", 0.95)
	var _accent := Color("efb64d")
	var _text := Color("e8e4da")

	func apply_theme(accent: Color, console: bool) -> void:
		_accent = accent
		if console:
			_plate = Color("1b2228", 0.94)
			_arm = Color("2a343c", 0.95)
			_border = Color(accent, 0.35)
			_active = accent
			_text = GameSkin.PAPER
		else:
			_plate = Color("242d33", 0.92)
			_arm = Color("2e3840", 0.95)
			_border = Color(accent, 0.30)
			_active = Color("a97f35", 0.95)
			_text = GameSkin.PAPER
		queue_redraw()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			_layout_captions()

	## Captions orbit the drawn gate at a uniform gap, independent of widget
	## aspect — edge-anchored labels left right/bottom visibly farther out.
	func _layout_captions() -> void:
		var center := size * 0.5
		var ring := minf(size.x, size.y) * 0.32 * 1.18 + 9.0
		for index in range(minf(captions.size(), 4)):
			var cap := captions[index]
			var cs := cap.get_minimum_size()
			var pos: Vector2 = center + DIRS[index] * ring - cs * 0.5
			pos.x = clampf(pos.x, 0.0, maxf(0.0, size.x - cs.x))
			pos.y = clampf(pos.y, 0.0, maxf(0.0, size.y - cs.y))
			cap.position = pos
			cap.size = cs

	func _draw() -> void:
		var center := size * 0.5
		var gate := minf(size.x, size.y) * 0.32
		if is_dpad:
			_draw_dpad(center, gate)
		else:
			_draw_stick(center, gate)

	func _pressed(index: int) -> bool:
		return index < anchors.size() and bool(anchors[index].get_meta("active", false))

	func _draw_stick(center: Vector2, gate: float) -> void:
		var ring := gate * 1.18
		var oct := PackedVector2Array()
		for k in range(8):
			var a := TAU * k / 8.0 + PI / 8.0
			oct.append(center + Vector2(cos(a), sin(a)) * ring)
		draw_colored_polygon(oct, _plate)
		var loop := PackedVector2Array(oct)
		loop.append(oct[0])
		draw_polyline(loop, _border, 1.2)
		# Direction petals between hub and gate; pressed petals take accent.
		for index in range(4):
			var dir: Vector2 = DIRS[index]
			var angle: float = dir.angle()
			var half := 0.40
			var r_in := gate * 0.46
			var r_out := gate * 0.96
			var petal := PackedVector2Array([
				center + Vector2.from_angle(angle - half) * r_in,
				center + Vector2.from_angle(angle - half) * r_out,
				center + Vector2.from_angle(angle + half) * r_out,
				center + Vector2.from_angle(angle + half) * r_in,
			])
			draw_colored_polygon(petal, _active if _pressed(index) else _arm)
			var tip: Vector2 = center + dir * (gate * 0.78)
			var side: Vector2 = dir.orthogonal()
			var chevron := PackedVector2Array([
				tip + dir * 5.0, tip - dir * 3.0 + side * 4.0, tip - dir * 3.0 - side * 4.0])
			draw_colored_polygon(chevron, Color("10151a") if _pressed(index) else Color(_accent, 0.75))
		# Nub tilts with live axis input, like a real stick head.
		var nub_pos := center + tilt.limit_length(1.0) * (gate * 0.34)
		var nub_r := gate * 0.40
		draw_circle(nub_pos + Vector2(0, 2), nub_r, Color(0, 0, 0, 0.4))
		draw_circle(nub_pos, nub_r, Color("151c22", 0.98))
		draw_arc(nub_pos, nub_r, 0.0, TAU, 24, _border, 1.2)
		_draw_hub_text(nub_pos, nub_r)

	func _draw_dpad(center: Vector2, gate: float) -> void:
		var arm_w := gate * 0.62
		var arm_len := gate * 1.02
		var vbar := Rect2(center.x - arm_w / 2, center.y - arm_len, arm_w, arm_len * 2)
		var hbar := Rect2(center.x - arm_len, center.y - arm_w / 2, arm_len * 2, arm_w)
		draw_rect(vbar, _plate)
		draw_rect(hbar, _plate)
		var plus := PackedVector2Array([
			vbar.position, Vector2(vbar.end.x, vbar.position.y),
			Vector2(vbar.end.x, hbar.position.y), hbar.position + Vector2(hbar.size.x, 0),
			Vector2(hbar.end.x, hbar.end.y), Vector2(vbar.end.x, hbar.end.y),
			vbar.position + Vector2(vbar.size.x, vbar.size.y), Vector2(vbar.position.x, vbar.end.y),
			Vector2(vbar.position.x, hbar.end.y), Vector2(hbar.position.x, hbar.end.y),
			Vector2(hbar.position.x, hbar.position.y), Vector2(vbar.position.x, hbar.position.y),
		])
		var closed := PackedVector2Array(plus)
		closed.append(plus[0])
		draw_polyline(closed, _border, 1.2)
		var arm_rects := [
			Rect2(vbar.position, Vector2(arm_w, arm_len)),
			Rect2(hbar.position, Vector2(arm_len, arm_w)),
			Rect2(Vector2(vbar.position.x, center.y), Vector2(arm_w, arm_len)),
			Rect2(Vector2(center.x, hbar.position.y), Vector2(arm_len, arm_w)),
		]
		for index in range(4):
			var rect: Rect2 = arm_rects[index].grow(-1.5)
			if _pressed(index):
				draw_rect(rect, _active, true)
			else:
				draw_rect(rect, _arm, true)
			var tip: Vector2 = center + DIRS[index] * (arm_len - arm_w * 0.30)
			var side: Vector2 = DIRS[index].orthogonal()
			var chevron := PackedVector2Array([
				tip + DIRS[index] * 5.0, tip - DIRS[index] * 3.0 + side * 4.0,
				tip - DIRS[index] * 3.0 - side * 4.0])
			draw_colored_polygon(chevron, Color("10151a") if _pressed(index) else Color(_accent, 0.75))
		# A real D-pad has no center nub — just the joined plus silhouette.
		draw_rect(Rect2(center.x - arm_w / 2, center.y - arm_w / 2, arm_w, arm_w), _plate)

	func _draw_hub_text(pos: Vector2, radius: float) -> void:
		var font := ThemeDB.fallback_font
		var font_size := int(radius * 1.1)
		var text_size := font.get_string_size(hub_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		draw_string(font, pos + Vector2(-text_size.x * 0.5, text_size.y * 0.35),
				hub_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, _text)


class _Brackets:
	extends Control
	const TICK := 12.0
	const THICK := 2.0
	var color := Color("efb64d", 0.8)
	func _ready() -> void:
		resized.connect(queue_redraw)
	func _draw() -> void:
		var s := size
		draw_rect(Rect2(0, 0, TICK, THICK), color)
		draw_rect(Rect2(0, 0, THICK, TICK), color)
		draw_rect(Rect2(s.x - TICK, 0, TICK, THICK), color)
		draw_rect(Rect2(s.x - THICK, 0, THICK, TICK), color)
		draw_rect(Rect2(0, s.y - THICK, TICK, THICK), color)
		draw_rect(Rect2(0, s.y - TICK, THICK, TICK), color)
		draw_rect(Rect2(s.x - TICK, s.y - THICK, TICK, THICK), color)
		draw_rect(Rect2(s.x - THICK, s.y - TICK, THICK, TICK), color)

func set_wheeled_mode(value: bool) -> void:
	_wheeled = value
	var copy: Dictionary = WHEEL_CAPTIONS if value else TRACK_CAPTIONS
	for action in TRAVEL_ACTIONS:
		var label := _captions.get(action) as Label
		if label != null:
			label.text = copy[action]
	if _footer != null:
		set_prompt_mode(_prompt_mode)

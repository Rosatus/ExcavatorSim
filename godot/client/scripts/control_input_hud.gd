class_name ControlInputHUD
extends PanelContainer

const GameSkin := preload("res://scripts/game_ui_theme.gd")
const GROUP_ACTIONS := [
	["operator_swing_left", "operator_swing_right", "operator_arm_extend", "operator_arm_retract"],
	["operator_bucket_curl", "operator_bucket_dump", "operator_boom_lower", "operator_boom_raise"],
	["track_left_forward", "track_left_reverse", "track_right_forward", "track_right_reverse"],
]
const KEY_COPY := ["W", "A", "S", "D", "I", "J", "K", "L", "R", "F", "Y", "H"]
const PAD_COPY := ["L ↑", "L ←", "L ↓", "L →", "R ↑", "R ←", "R ↓", "R →", "LT", "LB", "RT", "RB"]
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
const DPAD_GLYPHS := ["↑", "←", "↓", "→"]
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
var _dpad_section: Control
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
	if GameSkin.is_console_variant(_theme_variant):
		var accent := GameSkin.accent_for(_theme_variant)
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
		add_theme_stylebox_override("panel", GameSkin.box(Color(0.10, 0.135, 0.155, 0.84), 10, 16))
		_idle = GameSkin.box(Color("293137"), 5, 4)
		_pressed = GameSkin.box(Color("69522d"), 5, 4)
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
	var tile := _tiles[action] as PanelContainer
	var active := bool(tile.get_meta("active", false))
	tile.add_theme_stylebox_override("panel", _pressed if active else _idle)
	var key := _keys[action] as Label
	key.add_theme_color_override(
		"font_color",
		GameSkin.on_accent_for(_theme_variant) if (active and GameSkin.is_console_variant(_theme_variant)) else GameSkin.accent_for(_theme_variant)
	)

func _ready() -> void:
	_apply_variant_styles()
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	add_child(column)
	_title = _label("操纵辅助 · ISO", 12)
	column.add_child(_title)
	# Travel keys as a 2x2 grid: forward keys on the top row, reverse keys
	# below — R/Y over F/H matches keyboard columns, and for pads it stacks
	# the triggers above the bumpers.
	var tracks := GridContainer.new()
	tracks.name = "Tracks"
	tracks.columns = 2
	tracks.add_theme_constant_override("h_separation", 6)
	tracks.add_theme_constant_override("v_separation", 4)
	column.add_child(tracks)
	for index in [8, 10, 9, 11]:
		tracks.add_child(_action_tile(ACTIONS[index], "", FUNCTION_CAPTIONS[index]))
	var sticks := HBoxContainer.new()
	sticks.name = "Sticks"
	sticks.add_theme_constant_override("separation", 10)
	column.add_child(sticks)
	# D-pad hold-modifier cross; only meaningful on a gamepad, hidden
	# otherwise. Each direction shows the layer it arms.
	_dpad_section = _cross_section("十字键 层", "✚", DPAD_TILE_ACTIONS, DPAD_GLYPHS, DPAD_CAPTIONS)
	_dpad_section.visible = false
	sticks.add_child(_dpad_section)
	sticks.add_child(_cross_section("回转 / 小臂", "L", ACTIONS.slice(0, 4), [], FUNCTION_CAPTIONS.slice(0, 4)))
	sticks.add_child(_cross_section("大臂 / 铲斗", "R", ACTIONS.slice(4, 8), [], FUNCTION_CAPTIONS.slice(4, 8)))
	_footer = _label("", 12)
	column.add_child(_footer)
	set_prompt_mode(_prompt_mode)
	_sync_variant_chrome()
	_ignore_mouse(self)


## One directional cross: cells 1/3/7/5 hold up/left/down/right tiles,
## center shows the cluster glyph.
func _cross_section(header_text: String, center_text: String, direction_actions: Array, glyphs: Array, captions: Array) -> VBoxContainer:
	var section := VBoxContainer.new()
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section.add_child(_label(header_text, 13))
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	section.add_child(grid)
	for cell in range(9):
		var direction: int = {1: 0, 3: 1, 7: 2, 5: 3}.get(cell, -1)
		if direction >= 0:
			var glyph: String = glyphs[direction] if direction < glyphs.size() else ""
			var caption: String = captions[direction] if direction < captions.size() else ""
			grid.add_child(_action_tile(String(direction_actions[direction]), glyph, caption))
		else:
			var empty := _label(center_text, 12) if cell == 4 else Control.new()
			empty.custom_minimum_size = Vector2(48, 32)
			grid.add_child(empty)
	return section


func _action_tile(action: String, glyph: String, caption: String) -> PanelContainer:
	var tile := PanelContainer.new()
	tile.custom_minimum_size = Vector2(48, 32)
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tile.add_theme_stylebox_override("panel", _idle)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 2)
	tile.add_child(content)
	var key := _label(glyph, 15)
	key.add_theme_color_override("font_color", GameSkin.accent_for(_theme_variant))
	content.add_child(key)
	var caption_label := _label(caption, 11)
	content.add_child(caption_label)
	_captions[action] = caption_label
	_keys[action] = key
	_tiles[action] = tile
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
	if _keys.is_empty():
		return
	var copy: Array = (KEY_COPY if mode == "keyboard" else PAD_COPY).duplicate()
	if _wheeled:
		# Tiles sit in track slots: [forward, reverse, right, left].
		# Keyboard G/B/N/V; pad RT drives, LT reverses, RB/LB steer.
		var travel := ["G", "B", "N", "V"] if mode == "keyboard" else ["RT", "LT", "RB", "LB"]
		for index in 4:
			copy[index + 8] = travel[index]
	for index in range(ACTIONS.size()):
		(_keys[ACTIONS[index]] as Label).text = copy[index]
	if _dpad_section != null:
		_dpad_section.visible = mode == "gamepad"
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
		var tile := _tiles[action] as PanelContainer
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
	_sync_layer_captions()


## While a D-pad modifier is held, the borrowed right-stick tiles relabel to
## the layer's functions so the operator sees what the stick now drives.
func _sync_layer_captions() -> void:
	var overrides := {}
	for pad_action in ["pad_layer_dpad_up", "pad_layer_dpad_left", "pad_layer_dpad_down"]:
		if InputMap.has_action(pad_action) and Input.is_action_pressed(pad_action):
			for tile_index in PAD_LAYER_OVERRIDES[pad_action]:
				overrides[int(tile_index)] = PAD_LAYER_OVERRIDES[pad_action][tile_index]
	for index in range(8):
		var label := _captions.get(ACTIONS[index]) as Label
		if label != null:
			label.text = String(overrides.get(index, FUNCTION_CAPTIONS[index]))

func is_action_highlighted_for_test(action: String) -> bool:
	return _tiles.has(action) and bool((_tiles[action] as Control).get_meta("active", false))

func _ignore_mouse(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_ignore_mouse(child)


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

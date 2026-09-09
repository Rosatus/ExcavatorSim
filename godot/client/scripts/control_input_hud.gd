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
var _prompt_mode := "keyboard"
var _keys: Dictionary = {}
var _tiles: Dictionary = {}
var _footer: Label
var _idle: StyleBoxFlat
var _pressed: StyleBoxFlat

func _ready() -> void:
	theme = GameSkin.create()
	add_theme_stylebox_override("panel", GameSkin.box(Color(0.10, 0.135, 0.155, 0.84), 10, 16))
	_idle = GameSkin.box(Color("293137"), 5, 4)
	_pressed = GameSkin.box(Color("69522d"), 5, 4)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	add_child(column)
	var title := _label("操纵辅助 · ISO", 12)
	column.add_child(title)
	var tracks := HBoxContainer.new()
	tracks.name = "Tracks"
	column.add_child(tracks)
	for index in range(8, 12):
		tracks.add_child(_tile(index, ["左前进", "左后退", "右前进", "右后退"][index - 8]))
	var sticks := HBoxContainer.new()
	sticks.name = "Sticks"
	column.add_child(sticks)
	for side in range(2):
		var stick := VBoxContainer.new()
		stick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sticks.add_child(stick)
		stick.add_child(_label("回转 / 小臂" if side == 0 else "大臂 / 铲斗", 13))
		var grid := GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", 4)
		grid.add_theme_constant_override("v_separation", 4)
		stick.add_child(grid)
		for cell in range(9):
			var direction: int = {1: 0, 3: 1, 7: 2, 5: 3}.get(cell, -1)
			if direction >= 0:
				grid.add_child(_tile(side * 4 + direction))
			else:
				var empty := _label("L" if side == 0 else "R", 12) if cell == 4 else Control.new()
				empty.custom_minimum_size = Vector2(48, 32)
				grid.add_child(empty)
	_footer = _label("", 12)
	column.add_child(_footer)
	set_prompt_mode(_prompt_mode)
	_ignore_mouse(self)

func _tile(index: int, caption: String = "") -> PanelContainer:
	var tile := PanelContainer.new()
	tile.custom_minimum_size = Vector2(48, 32)
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tile.add_theme_stylebox_override("panel", _idle)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 2)
	tile.add_child(content)
	var key := _label("", 15)
	key.add_theme_color_override("font_color", GameSkin.ACCENT)
	content.add_child(key)
	if not caption.is_empty():
		content.add_child(_label(caption, 11))
	_keys[ACTIONS[index]] = key
	_tiles[ACTIONS[index]] = tile
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
	var copy := KEY_COPY if mode == "keyboard" else PAD_COPY
	for index in range(ACTIONS.size()):
		(_keys[ACTIONS[index]] as Label).text = copy[index]
	_footer.text = "1–5 切换视角 · C 复位" if mode == "keyboard" else "十字键 切换视角 · R3 复位"

func _process(_delta: float) -> void:
	refresh_input_state_for_test()

func refresh_input_state_for_test() -> void:
	for action in _tiles:
		var active := InputMap.has_action(action) and Input.is_action_pressed(action)
		var tile := _tiles[action] as PanelContainer
		if bool(tile.get_meta("active", not active)) != active:
			tile.set_meta("active", active)
			tile.add_theme_stylebox_override("panel", _pressed if active else _idle)

func is_action_highlighted_for_test(action: String) -> bool:
	return _tiles.has(action) and bool((_tiles[action] as Control).get_meta("active", false))

func _ignore_mouse(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_ignore_mouse(child)

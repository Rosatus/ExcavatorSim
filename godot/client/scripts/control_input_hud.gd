class_name ControlInputHUD
extends PanelContainer

const ACTION_TILE_PATHS := {
	"motion_arm_positive": NodePath("Margin/VBox/Sticks/LeftStick/Grid/W"),
	"motion_swing_negative": NodePath("Margin/VBox/Sticks/LeftStick/Grid/A"),
	"motion_arm_negative": NodePath("Margin/VBox/Sticks/LeftStick/Grid/S"),
	"motion_swing_positive": NodePath("Margin/VBox/Sticks/LeftStick/Grid/D"),
	"motion_boom_positive": NodePath("Margin/VBox/Sticks/RightStick/Grid/I"),
	"motion_bucket_negative": NodePath("Margin/VBox/Sticks/RightStick/Grid/J"),
	"motion_boom_negative": NodePath("Margin/VBox/Sticks/RightStick/Grid/K"),
	"motion_bucket_positive": NodePath("Margin/VBox/Sticks/RightStick/Grid/L"),
	"track_left_forward": NodePath("Margin/VBox/Tracks/LeftTrack/Keys/R"),
	"track_left_reverse": NodePath("Margin/VBox/Tracks/LeftTrack/Keys/F"),
	"track_right_forward": NodePath("Margin/VBox/Tracks/RightTrack/Keys/Y"),
	"track_right_reverse": NodePath("Margin/VBox/Tracks/RightTrack/Keys/H"),
}
const KEY_TILE_PATHS := {
	KEY_W: NodePath("Margin/VBox/Sticks/LeftStick/Grid/W"),
	KEY_A: NodePath("Margin/VBox/Sticks/LeftStick/Grid/A"),
	KEY_S: NodePath("Margin/VBox/Sticks/LeftStick/Grid/S"),
	KEY_D: NodePath("Margin/VBox/Sticks/LeftStick/Grid/D"),
	KEY_I: NodePath("Margin/VBox/Sticks/RightStick/Grid/I"),
	KEY_J: NodePath("Margin/VBox/Sticks/RightStick/Grid/J"),
	KEY_K: NodePath("Margin/VBox/Sticks/RightStick/Grid/K"),
	KEY_L: NodePath("Margin/VBox/Sticks/RightStick/Grid/L"),
	KEY_R: NodePath("Margin/VBox/Tracks/LeftTrack/Keys/R"),
	KEY_F: NodePath("Margin/VBox/Tracks/LeftTrack/Keys/F"),
	KEY_Y: NodePath("Margin/VBox/Tracks/RightTrack/Keys/Y"),
	KEY_H: NodePath("Margin/VBox/Tracks/RightTrack/Keys/H"),
}

const IDLE_BACKGROUND := Color(0.075, 0.105, 0.135, 0.88)
const IDLE_BORDER := Color(0.25, 0.43, 0.55, 0.9)
const IDLE_TEXT := Color(0.78, 0.85, 0.9, 1.0)
const ACTIVE_BACKGROUND := Color(0.08, 0.55, 0.32, 0.96)
const ACTIVE_BORDER := Color(0.42, 1.0, 0.68, 1.0)
const ACTIVE_TEXT := Color(0.95, 1.0, 0.97, 1.0)

var _tiles: Dictionary = {}
var _idle_style: StyleBoxFlat
var _active_style: StyleBoxFlat


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_idle_style = _make_tile_style(IDLE_BACKGROUND, IDLE_BORDER)
	_active_style = _make_tile_style(ACTIVE_BACKGROUND, ACTIVE_BORDER)
	_set_mouse_ignore_recursive(self)
	_refresh_action_tiles()
	refresh_input_state_for_test()


func _process(_delta: float) -> void:
	refresh_input_state_for_test()


func refresh_input_state_for_test() -> void:
	_refresh_action_tiles()
	for action in _tiles:
		var active := InputMap.has_action(action) and Input.is_action_pressed(action)
		_set_tile_active(_tiles[action] as PanelContainer, active)


func is_action_highlighted_for_test(action: String) -> bool:
	var tile := _tiles.get(action) as PanelContainer
	return tile != null and bool(tile.get_meta("input_active", false))


func get_action_tile_for_test(action: String) -> PanelContainer:
	_refresh_action_tiles()
	return _tiles.get(action) as PanelContainer


func _refresh_action_tiles() -> void:
	var next_tiles := {}
	for action in ACTION_TILE_PATHS:
		var tile_path := ACTION_TILE_PATHS[action] as NodePath
		if InputMap.has_action(action):
			for event in InputMap.action_get_events(action):
				if event is InputEventKey:
					var keycode := (event as InputEventKey).physical_keycode
					if KEY_TILE_PATHS.has(keycode):
						tile_path = KEY_TILE_PATHS[keycode] as NodePath
						break
		var tile := get_node_or_null(tile_path) as PanelContainer
		if tile != null:
			next_tiles[action] = tile
	if next_tiles == _tiles:
		return
	for tile in _tiles.values():
		_set_tile_active(tile as PanelContainer, false)
	_tiles = next_tiles
	for tile in _tiles.values():
		_set_tile_active(tile as PanelContainer, false)


func _set_tile_active(tile: PanelContainer, active: bool) -> void:
	if bool(tile.get_meta("input_active", not active)) == active:
		return
	tile.set_meta("input_active", active)
	tile.add_theme_stylebox_override("panel", _active_style if active else _idle_style)
	var label := tile.get_child(0) as Label if tile.get_child_count() > 0 else null
	if label != null:
		label.add_theme_color_override("font_color", ACTIVE_TEXT if active else IDLE_TEXT)


func _set_mouse_ignore_recursive(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_set_mouse_ignore_recursive(child)


func _make_tile_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(5)
	style.content_margin_left = 3.0
	style.content_margin_top = 3.0
	style.content_margin_right = 3.0
	style.content_margin_bottom = 3.0
	return style

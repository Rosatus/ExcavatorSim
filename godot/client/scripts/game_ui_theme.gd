extends RefCounted

const INK := Color("15191d")
const PAPER := Color("f2eee5")
const MUTED := Color("a8afb3")
const ACCENT := Color("efb64d")

static func box(color: Color, radius: int = 8, padding: int = 14) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(padding)
	return style

static func create() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = 17
	for kind in ["Label", "Button", "OptionButton", "CheckButton", "LineEdit", "TabContainer", "TabBar"]:
		theme.set_color("font_color", kind, PAPER)
		theme.set_color("font_hover_color", kind, PAPER)
		theme.set_color("font_focus_color", kind, PAPER)
		theme.set_color("font_pressed_color", kind, ACCENT)
		theme.set_color("font_disabled_color", kind, Color("636b70"))
	for kind in ["Button", "OptionButton", "CheckButton", "LineEdit"]:
		theme.set_stylebox("normal", kind, box(Color("252c31")))
		theme.set_stylebox("hover", kind, box(Color("343d43")))
		theme.set_stylebox("pressed", kind, box(Color("41423a")))
		theme.set_stylebox("disabled", kind, box(Color("1e2428")))
		var focus := box(Color(0, 0, 0, 0))
		focus.border_color = ACCENT
		focus.set_border_width_all(2)
		theme.set_stylebox("focus", kind, focus)
	var surface := box(Color(0.10, 0.135, 0.155, 0.90), 12, 22)
	surface.border_color = Color(0.66, 0.74, 0.77, 0.18)
	surface.set_border_width_all(1)
	surface.shadow_color = Color(0.005, 0.012, 0.018, 0.25)
	surface.shadow_size = 16
	surface.shadow_offset = Vector2(0, 6)
	theme.set_stylebox("panel", "PanelContainer", surface)
	for kind in ["TabContainer", "TabBar"]:
		theme.set_stylebox("tab_selected", kind, box(Color("353c40"), 6, 14))
		theme.set_stylebox("tab_unselected", kind, box(Color("191f23"), 6, 14))
		theme.set_color("font_selected_color", kind, ACCENT)
		theme.set_color("font_unselected_color", kind, MUTED)
	theme.set_stylebox("panel", "TabContainer", box(Color(0, 0, 0, 0), 0, 12))
	theme.set_stylebox("background", "ProgressBar", box(Color("30383d"), 3, 0))
	theme.set_stylebox("fill", "ProgressBar", box(ACCENT, 3, 0))
	theme.set_constant("separation", "VBoxContainer", 12)
	theme.set_constant("separation", "HBoxContainer", 12)
	return theme

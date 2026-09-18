extends RefCounted

const VARIANT_DEBUG := "debug"
const VARIANT_INDUSTRIAL := "industrial"
const VARIANT_SANY := "sany"
const VARIANTS: Array[String] = [VARIANT_DEBUG, VARIANT_INDUSTRIAL, VARIANT_SANY]

const INK := Color("15191d")
const PAPER := Color("f2eee5")
const MUTED := Color("a8afb3")
const ACCENT := Color("efb64d")
const ACCENT_SANY := Color("e82e24")
const DANGER := Color("ff8a7a")

## Console variants share the industrial layout and chrome; only the palette
## accent differs (amber industrial, SANY brand red for the SANY theme).
static func is_console_variant(variant: String) -> bool:
	return variant == VARIANT_INDUSTRIAL or variant == VARIANT_SANY


static func accent_for(variant: String) -> Color:
	return ACCENT_SANY if variant == VARIANT_SANY else ACCENT


## Lettering that sits directly on the accent plate: the amber plate takes dark
## ink, while the SANY red plate needs paper white to stay readable.
static func on_accent_for(variant: String) -> Color:
	return PAPER if variant == VARIANT_SANY else INK

static func box(color: Color, radius: int = 8, padding: int = 14) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(padding)
	return style


static func create(variant: String = VARIANT_DEBUG) -> Theme:
	if is_console_variant(variant):
		return _create_industrial(accent_for(variant), on_accent_for(variant))
	return _create_debug()


static func _create_debug() -> Theme:
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


static func _create_industrial(accent: Color, on_accent: Color) -> Theme:
	var theme := Theme.new()
	theme.default_font_size = 17
	for kind in ["Label", "Button", "OptionButton", "CheckButton", "LineEdit", "TabContainer", "TabBar", "PopupMenu", "TooltipLabel"]:
		theme.set_color("font_color", kind, PAPER)
		theme.set_color("font_hover_color", kind, PAPER)
		theme.set_color("font_focus_color", kind, PAPER)
		theme.set_color("font_disabled_color", kind, Color("5a636a"))
	for kind in ["Button", "OptionButton", "LineEdit"]:
		theme.set_color("font_pressed_color", kind, on_accent)
	theme.set_color("font_pressed_color", "CheckButton", PAPER)
	theme.set_color("font_pressed_color", "Label", accent)

	# Buttons, dropdowns and text fields: dark steel plate with a lit edge.
	for kind in ["Button", "OptionButton", "LineEdit"]:
		var normal := box(Color("21282e"), 6, 12)
		normal.border_color = Color(0.62, 0.68, 0.70, 0.16)
		normal.set_border_width_all(1)
		var hover := box(Color("2c353c"), 6, 12)
		hover.border_color = Color(accent, 0.55)
		hover.set_border_width_all(1)
		var pressed := box(accent.darkened(0.10), 6, 12)
		pressed.border_color = accent.lightened(0.15)
		pressed.set_border_width_all(1)
		var disabled := box(Color("181d21"), 6, 12)
		theme.set_stylebox("normal", kind, normal)
		theme.set_stylebox("hover", kind, hover)
		theme.set_stylebox("pressed", kind, pressed)
		theme.set_stylebox("disabled", kind, disabled)
		theme.set_stylebox("focus", kind, _focus_ring(accent))
	# Toggle switches stay borderless; their icons carry the state.
	for kind in ["CheckButton"]:
		var hover := box(Color("2c353c", 0.55), 6, 8)
		var focus := _focus_ring(accent)
		theme.set_stylebox("normal", kind, box(Color(0, 0, 0, 0), 6, 8))
		theme.set_stylebox("hover", kind, hover)
		theme.set_stylebox("pressed", kind, box(Color("3a444c", 0.7), 6, 8))
		theme.set_stylebox("disabled", kind, box(Color(0, 0, 0, 0), 6, 8))
		theme.set_stylebox("focus", kind, focus)

	# Panel surfaces: smoked glass with a steel rim and a heavy shadow.
	var surface := box(Color(0.068, 0.088, 0.104, 0.94), 10, 22)
	surface.border_color = Color(0.64, 0.70, 0.72, 0.24)
	surface.set_border_width_all(1)
	surface.shadow_color = Color(0.0, 0.0, 0.0, 0.5)
	surface.shadow_size = 20
	surface.shadow_offset = Vector2(0, 8)
	theme.set_stylebox("panel", "PanelContainer", surface)
	theme.set_stylebox("panel", "AcceptDialog", surface)

	# Tabs: selected page gets an accent under-bar, unselected stays quiet.
	var tab_sel := box(Color("262b24"), 6, 14)
	tab_sel.border_color = accent
	tab_sel.border_width_bottom = 3
	var tab_hover := box(Color("232a30"), 6, 14)
	for kind in ["TabContainer", "TabBar"]:
		theme.set_stylebox("tab_selected", kind, tab_sel)
		theme.set_stylebox("tab_unselected", kind, box(Color("181d22"), 6, 14))
		theme.set_stylebox("tab_hovered", kind, tab_hover)
		theme.set_color("font_selected_color", kind, accent)
		theme.set_color("font_unselected_color", kind, MUTED)
		theme.set_color("font_hovered_color", kind, PAPER)
	theme.set_stylebox("panel", "TabContainer", box(Color(0, 0, 0, 0), 0, 12))

	# Scrollbars, separators, progress, dropdown popups, tooltips, text fields.
	for kind in ["VScrollBar", "HScrollBar"]:
		theme.set_stylebox("scroll", kind, box(Color("14191d"), 3, 0))
		theme.set_stylebox("scroll_focus", kind, box(Color("14191d"), 3, 0))
		theme.set_stylebox("grabber", kind, box(Color("49545c"), 3, 0))
		theme.set_stylebox("grabber_highlight", kind, box(Color("5d6a73"), 3, 0))
		theme.set_stylebox("grabber_pressed", kind, box(accent.darkened(0.15), 3, 0))
	var separator := box(Color(0.55, 0.60, 0.62, 0.35), 0, 0)
	theme.set_stylebox("separator", "HSeparator", separator)
	theme.set_stylebox("separator", "VSeparator", separator)
	var bar_bg := box(Color("242c32"), 4, 0)
	bar_bg.border_color = Color(0.62, 0.68, 0.70, 0.16)
	bar_bg.set_border_width_all(1)
	theme.set_stylebox("background", "ProgressBar", bar_bg)
	theme.set_stylebox("fill", "ProgressBar", box(accent, 4, 0))
	var popup := box(Color("1b2126", 0.98), 6, 6)
	popup.border_color = Color(0.62, 0.68, 0.70, 0.28)
	popup.set_border_width_all(1)
	popup.shadow_color = Color(0, 0, 0, 0.5)
	popup.shadow_size = 12
	theme.set_stylebox("panel", "PopupMenu", popup)
	theme.set_stylebox("hover", "PopupMenu", box(Color("31383e"), 4, 4))
	theme.set_color("font_hover_color", "PopupMenu", PAPER)
	theme.set_color("font_accelerator_color", "PopupMenu", MUTED)
	theme.set_color("font_disabled_color", "PopupMenu", Color("5a636a"))
	theme.set_color("font_separator_color", "PopupMenu", MUTED)
	var tip := box(Color("161c20", 0.97), 6, 8)
	tip.border_color = Color(0.62, 0.68, 0.70, 0.3)
	tip.set_border_width_all(1)
	theme.set_stylebox("panel", "TooltipPanel", tip)
	theme.set_color("caret_color", "LineEdit", accent)
	theme.set_color("font_placeholder_color", "LineEdit", Color("69727a"))
	theme.set_color("selection_color", "LineEdit", Color(accent, 0.3))

	# Procedural icons: toggle pills and the dropdown chevron.
	theme.set_icon("checked", "CheckButton", _toggle_icon(true, false, accent))
	theme.set_icon("unchecked", "CheckButton", _toggle_icon(false, false, accent))
	theme.set_icon("checked_disabled", "CheckButton", _toggle_icon(true, true, accent))
	theme.set_icon("unchecked_disabled", "CheckButton", _toggle_icon(false, true, accent))
	theme.set_icon("checked", "CheckBox", _toggle_icon(true, false, accent))
	theme.set_icon("unchecked", "CheckBox", _toggle_icon(false, false, accent))
	theme.set_icon("arrow", "OptionButton", _chevron_icon(accent))
	theme.set_icon("option_arrow", "PopupMenu", _chevron_icon(accent))

	theme.set_constant("separation", "VBoxContainer", 12)
	theme.set_constant("separation", "HBoxContainer", 12)
	return theme


static func _focus_ring(accent: Color = ACCENT) -> StyleBoxFlat:
	var focus := box(Color(0, 0, 0, 0), 6, 12)
	focus.border_color = accent
	focus.set_border_width_all(2)
	focus.shadow_color = Color(accent, 0.30)
	focus.shadow_size = 10
	return focus


## Primary call-to-action styling (resume / confirm): accent plate, on-accent ink.
static func apply_primary(button: Button, accent: Color = ACCENT, on_accent: Color = INK) -> void:
	var normal := box(accent, 6, 12)
	normal.border_color = accent.lightened(0.2)
	normal.set_border_width_all(1)
	normal.shadow_color = Color(accent, 0.28)
	normal.shadow_size = 12
	var hover := box(accent.lightened(0.10), 6, 12)
	hover.border_color = accent.lightened(0.3)
	hover.set_border_width_all(1)
	hover.shadow_color = Color(accent, 0.45)
	hover.shadow_size = 16
	var pressed := box(accent.darkened(0.16), 6, 12)
	pressed.border_color = accent
	pressed.set_border_width_all(1)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("focus", _focus_ring(accent))
	button.add_theme_color_override("font_color", on_accent)
	button.add_theme_color_override("font_hover_color", on_accent)
	button.add_theme_color_override("font_focus_color", on_accent)
	button.add_theme_color_override("font_pressed_color", on_accent)


## Destructive action styling: quiet red lettering on the regular button plate.
static func apply_danger(button: Button) -> void:
	button.add_theme_color_override("font_color", DANGER)
	button.add_theme_color_override("font_hover_color", Color("ffa89b"))
	var hover := box(Color("352a28"), 6, 12)
	hover.border_color = Color(DANGER, 0.5)
	hover.set_border_width_all(1)
	button.add_theme_stylebox_override("hover", hover)


## Slim status pill used for the in-menu connection lamp (industrial variant).
static func status_chip() -> StyleBoxFlat:
	var chip := box(Color("181e23", 0.9), 12, 8)
	chip.border_color = Color(0.62, 0.68, 0.70, 0.20)
	chip.set_border_width_all(1)
	return chip


## Left-rail surface for the industrial console layout (industrial variant).
static func rail_panel() -> StyleBoxFlat:
	var rail := box(Color(0.048, 0.062, 0.075, 0.62), 8, 12)
	rail.border_color = Color(0.62, 0.68, 0.70, 0.18)
	rail.border_width_right = 1
	return rail


## Rail navigation item: quiet plate, accent left bar and lettering when active.
static func apply_nav_button(button: Button, accent: Color = ACCENT) -> void:
	var normal := box(Color("171d22", 0.7), 6, 10)
	normal.border_color = Color(0, 0, 0, 0)
	normal.border_width_left = 3
	var hover := box(Color("242d34"), 6, 10)
	hover.border_color = Color(accent, 0.4)
	hover.border_width_left = 3
	var active := box(Color("252e36"), 6, 10)
	active.border_color = accent
	active.border_width_left = 3
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", active)
	button.add_theme_stylebox_override("focus", _focus_ring(accent))
	button.add_theme_color_override("font_color", MUTED)
	button.add_theme_color_override("font_hover_color", PAPER)
	button.add_theme_color_override("font_pressed_color", accent)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.toggle_mode = true


## Transparent padded stylebox: the industrial panel's visible frame is drawn
## by the MenuRoot backdrop (chamfered plate), so the container only insets content.
static func frame_pad() -> StyleBoxFlat:
	return box(Color(0, 0, 0, 0), 0, 30)


## Icons are supersampled 4x then downscaled so the linear texture filter sees
## smooth alpha edges instead of hard pixel steps (prevents blurry UI icons).
static func _toggle_icon(on: bool, disabled := false, accent: Color = ACCENT) -> ImageTexture:
	const SS := 4
	var w := 46 * SS
	var h := 26 * SS
	var r := h / 2.0
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var track := accent if on else Color("39434b")
	var knob := accent.darkened(0.82) if on else Color("aeb8bf")
	if disabled:
		track.a = 0.35
		knob.a = 0.35
	for y in h:
		for x in w:
			var inside := (x >= r and x <= w - r) \
				or Vector2(x, y).distance_to(Vector2(r, r)) <= r \
				or Vector2(x, y).distance_to(Vector2(w - r, r)) <= r
			if inside:
				img.set_pixel(x, y, track)
	var knob_center := Vector2(w - r, r) if on else Vector2(r, r)
	var knob_r := r - 3.0 * SS
	for y in h:
		for x in w:
			if Vector2(x, y).distance_to(knob_center) <= knob_r:
				img.set_pixel(x, y, knob)
	img.resize(46, 26, Image.INTERPOLATE_LANCZOS)
	return ImageTexture.create_from_image(img)


static func _chevron_icon(accent: Color = ACCENT) -> ImageTexture:
	const SS := 4
	var img := Image.create(12 * SS, 8 * SS, false, Image.FORMAT_RGBA8)
	for y in 8 * SS:
		for x in 12 * SS:
			if absf(x - 5.5 * SS) <= 5.5 * SS - y * 0.75:
				img.set_pixel(x, y, accent)
	img.resize(12, 8, Image.INTERPOLATE_LANCZOS)
	return ImageTexture.create_from_image(img)

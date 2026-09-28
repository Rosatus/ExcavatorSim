extends Control
## Read-only top view: chassis forward is always up; clockwise is screen-right.
const GameSkin := preload("res://scripts/game_ui_theme.gd")
var angle := 0.0
var available := false
var wheeled := false
var accent := GameSkin.accent_for(GameSkin.VARIANT_DEBUG)

func _init() -> void:
	size = Vector2(152, 184)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_orientation(base: Basis, upper: Basis) -> void:
	# Cancel the whole chassis attitude, including pitch/roll on sloped ground.
	# Both semantic frames share their zero basis, including +Z-forward models.
	var relative := base.orthonormalized().inverse() * upper.orthonormalized()
	var next := wrapf(-atan2(relative.z.x, relative.z.z), -PI, PI)
	if not available or not is_equal_approx(next, angle):
		angle = next
		available = true
		queue_redraw()

func clear_orientation() -> void:
	if available:
		available = false
		queue_redraw()

func _draw() -> void:
	var center := Vector2(76, 78)
	var ink := Color(0.035, 0.05, 0.06, 0.8)
	var muted := Color(GameSkin.PAPER, 0.65)
	# No backing plate; dark strokes keep fine lines readable over bright soil.
	draw_arc(center, 57, 0, TAU, 96, ink, 4, true)
	draw_arc(center, 57, 0, TAU, 96, Color(GameSkin.PAPER, 0.3), 1, true)
	for i in 4:
		var dir := Vector2.UP.rotated(i * PI / 2)
		draw_line(center + dir * 54, center + dir * 60, muted, 1.5, true)
	_text("下车前方", 11, Vector2(76, 10), GameSkin.PAPER)
	for side in [-1, 1]:
		if wheeled:
			for end in [-1, 1]:
				_tread(Rect2(center + Vector2(side * 25 - 6, end * 22 - 10), Vector2(12, 20)))
		else:
			_tread(Rect2(center + Vector2(side * 25 - 6, -33), Vector2(12, 66)))
	draw_line(center + Vector2(-19, 0), center + Vector2(19, 0), muted, 2, true)
	draw_colored_polygon(PackedVector2Array([center + Vector2(0, -47), center + Vector2(-4, -41), center + Vector2(4, -41)]), GameSkin.PAPER)
	if available:
		if absf(angle) > 0.001:
			var start := -PI / 2
			var finish := start + angle
			draw_arc(center, 57, minf(start, finish), maxf(start, finish), 64, ink, 6, true)
			draw_arc(center, 57, minf(start, finish), maxf(start, finish), 64, accent, 3, true)
		var tip := center + Vector2.UP.rotated(angle) * 57
		draw_circle(tip, 3, accent)
		draw_set_transform(center, angle)
		var arrow := PackedVector2Array([Vector2(0, -34), Vector2(12, 12), Vector2(0, 6), Vector2(-12, 12)])
		draw_colored_polygon(arrow, accent)
		arrow.append(arrow[0])
		draw_polyline(arrow, ink, 2, true)
		draw_set_transform(Vector2.ZERO)
	var degrees := int(round(absf(rad_to_deg(angle))))
	_text("%d°" % degrees if available else "—", 23, Vector2(76, 163), GameSkin.PAPER)
	var caption := "上车朝向"
	if available:
		caption = "同向" if degrees == 0 else ("反向" if degrees == 180 else ("右转" if angle > 0 else "左转"))
	_text(caption, 11, Vector2(76, 181), muted)

func _tread(rect: Rect2) -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.07, 0.09, 0.10, 0.68)
	box.border_color = Color(GameSkin.PAPER, 0.65)
	box.set_border_width_all(1)
	box.set_corner_radius_all(4)
	draw_style_box(box, rect)

func _text(copy: String, font_size: int, baseline: Vector2, color: Color) -> void:
	var font := get_theme_default_font()
	var pos := baseline - Vector2(font.get_string_size(copy, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x / 2, 0)
	draw_string_outline(font, pos, copy, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 4, Color(0.025, 0.035, 0.045, 0.9))
	draw_string(font, pos, copy, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

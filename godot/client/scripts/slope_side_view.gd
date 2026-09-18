class_name SlopeSideView
extends Control

## 2D machine-guidance display for the slope assist: the cabin-facing profile
## plane seen from the side — chassis silhouette, boom/arm/bucket link figure,
## sampled terrain line, target profile line, cut-region fill and the tooth's
## live offset from the target. Fed by the session status snapshot
## (slope_assist.view); the owner toggles visibility, drawing is stateless.

const PANEL_BG := Color(0.07, 0.08, 0.1, 0.85)
const TERRAIN_COLOR := Color(0.62, 0.5, 0.32)
const CUT_FILL := Color(0.9, 0.35, 0.15, 0.35)
const TARGET_COLOR := Color(0.4, 0.85, 1.0)
const LINK_COLOR := Color(0.88, 0.9, 0.95)
const CHASSIS_COLOR := Color(0.55, 0.58, 0.65)
const TOOTH_COLOR := Color(1.0, 0.8, 0.2)
const TEXT_COLOR := Color(0.9, 0.92, 0.95)
const MARGIN := 14.0
const FONT_SIZE := 13

var _view: Dictionary = {}
var _font: Font


func _ready() -> void:
	custom_minimum_size = Vector2(360, 220)
	_font = get_theme_default_font()
	mouse_filter = MOUSE_FILTER_IGNORE
	clip_contents = true


func set_view(view: Dictionary) -> void:
	_view = view
	queue_redraw()


## World position projected into the profile plane: x = signed distance along
## the profile axis from the anchor, y = world height.
static func project_to_plane(origin_xz: Vector2, axis: Vector2, world_pos: Vector3) -> Vector2:
	return Vector2((Vector2(world_pos.x, world_pos.z) - origin_xz).dot(axis), world_pos.y)


func _draw() -> void:
	if _view.is_empty():
		return
	var origin_xz: Vector2 = _view.get("origin_xz", Vector2.ZERO)
	var axis: Vector2 = _view.get("axis", Vector2.RIGHT)
	var toe_s := float(_view.get("toe_s", 0.0))
	var toe_h := float(_view.get("toe_h", 0.0))
	var grade := float(_view.get("grade", 0.0))
	var s_min := float(_view.get("s_min", 0.0))
	var s_max := float(_view.get("s_max", 0.0))
	var joints := _view.get("joints", {}) as Dictionary
	var tooth: Vector3 = _view.get("tooth", Vector3.ZERO)
	var terrain := _view.get("terrain", PackedVector2Array()) as PackedVector2Array
	var target_h := func(s: float) -> float:
		return toe_h + (grade * (s - toe_s) if s > toe_s else 0.0)
	# Collect the link figure in plane coordinates: swing pivot marks the
	# rotation column, the work joints chain to the tooth.
	var link_pts := PackedVector2Array()
	var names := ["swing_joint", "boom_joint", "arm_joint", "bucket_joint"]
	var pivots := {}
	for name in names:
		var pivot: Vector3 = joints.get(name, Vector3.ZERO)
		pivots[name] = project_to_plane(origin_xz, axis, pivot)
	var tooth_pt := project_to_plane(origin_xz, axis, tooth)
	for name in names:
		link_pts.append(pivots[name])
	link_pts.append(tooth_pt)
	# Content bounds over machine + terrain + target extents.
	var lo := Vector2(-4.5, -2.0)
	var hi := Vector2(4.5, 2.0)
	for pt in link_pts:
		lo = lo.min(pt)
		hi = hi.max(pt)
	for pt in terrain:
		lo = lo.min(pt)
		hi = hi.max(pt)
	lo = lo.min(Vector2(s_min, target_h.call(s_min)))
	hi = hi.max(Vector2(s_max, target_h.call(s_max)))
	# The chassis box hangs behind the swing pivot and reaches forward to the
	# upper↔boom pin — outside the link/terrain extents — so it must join the
	# content bounds or it draws past the panel's left edge.
	var sp: Vector2 = pivots["swing_joint"]
	var boom_sp: Vector2 = pivots["boom_joint"]
	var box_top := maxf(sp.y + 0.8, boom_sp.y + 0.35)
	lo = lo.min(sp + Vector2(-3.6, -1.3))
	hi = hi.max(Vector2(boom_sp.x + 0.4, box_top + 0.4))
	var span := (hi - lo).max(Vector2(1.0, 1.0))
	var draw_area := size - Vector2(MARGIN, MARGIN) * 2.0
	var scale := minf(draw_area.x / span.x, draw_area.y / span.y)
	var to_px := func(p: Vector2) -> Vector2:
		return Vector2(
			MARGIN + (p.x - lo.x) * scale + (draw_area.x - span.x * scale) * 0.5,
			size.y - MARGIN - (p.y - lo.y) * scale - (draw_area.y - span.y * scale) * 0.5
		)
	draw_rect(Rect2(Vector2.ZERO, size), PANEL_BG)
	# Cut fill: terrain cells above the target inside the reachable band.
	for i in range(terrain.size() - 1):
		var a := terrain[i]
		var b := terrain[i + 1]
		if a.x < s_min or b.x > s_max or a.y <= target_h.call(a.x) or b.y <= target_h.call(b.x):
			continue
		draw_colored_polygon(
			PackedVector2Array([to_px.call(a), to_px.call(b), to_px.call(Vector2(b.x, target_h.call(b.x))), to_px.call(Vector2(a.x, target_h.call(a.x)))]),
			CUT_FILL
		)
	if terrain.size() >= 2:
		var px := PackedVector2Array()
		for pt in terrain:
			px.append(to_px.call(pt))
		draw_polyline(px, TERRAIN_COLOR, 2.0)
	# Target profile: flat bench up to the toe, grade beyond — drawn over the
	# full view width so the bench reads as a plane, not a segment.
	var view_s0 := lo.x
	var view_s1 := hi.x
	var knee := clampf(toe_s, view_s0, view_s1)
	var target_px := PackedVector2Array()
	target_px.append(to_px.call(Vector2(view_s0, toe_h)))
	if knee > view_s0:
		target_px.append(to_px.call(Vector2(knee, toe_h)))
	target_px.append(to_px.call(Vector2(view_s1, target_h.call(view_s1))))
	draw_polyline(target_px, TARGET_COLOR, 2.5)
	# Reachable band markers on the target surface.
	for s_mark in [s_min, s_max]:
		var p0: Vector2 = to_px.call(Vector2(s_mark, target_h.call(s_mark)))
		draw_line(p0 + Vector2(0, -4), p0 + Vector2(0, 4), TARGET_COLOR, 1.5)
	# Measurement anchors: the title's d spans s=0 (the profile anchor, the
	# tooth position at confirm) to the toe knee, and θ is the grade's lean
	# off the bench — both need on-canvas marks or they float free of the
	# drawing.
	var knee_px: Vector2 = to_px.call(Vector2(knee, target_h.call(knee)))
	if toe_s > 0.05:
		var anchor_px: Vector2 = to_px.call(Vector2(0.0, target_h.call(0.0)))
		var dim_off := Vector2(0.0, -10.0)
		draw_line(anchor_px + Vector2(0, -5), anchor_px + Vector2(0, 5), TEXT_COLOR, 1.5)
		draw_line(anchor_px + dim_off, knee_px + dim_off, TEXT_COLOR, 1.0)
		draw_line(anchor_px + dim_off + Vector2(0, -3), anchor_px + dim_off + Vector2(0, 3), TEXT_COLOR, 1.0)
		draw_line(knee_px + dim_off + Vector2(0, -3), knee_px + dim_off + Vector2(0, 3), TEXT_COLOR, 1.0)
		_draw_text((anchor_px + knee_px) * 0.5 + dim_off + Vector2(-4.0, -4.0), "d")
	# Theta arc at the toe knee: bench direction sweeps into the grade.
	var px_ang := atan2(-grade, 1.0)
	if absf(px_ang) > 0.03 and knee > view_s0 and knee < view_s1:
		var arc_pts := PackedVector2Array()
		for i in range(9):
			var a := lerpf(0.0, px_ang, float(i) / 8.0)
			arc_pts.append(knee_px + Vector2(cos(a), sin(a)) * 22.0)
		draw_polyline(arc_pts, TARGET_COLOR, 1.5)
	draw_circle(knee_px, 3.0, TOOTH_COLOR)
	# Chassis box: one rectangle enclosing undercarriage, upper structure and
	# the upper↔boom pin — the link dots landing inside it are the pin
	# indicators. Facing arrow above the box points down-range.
	_draw_plane_rect(
		to_px, sp + Vector2(-3.5, -1.2), Vector2(boom_sp.x + 0.3, box_top), CHASSIS_COLOR, false, 2.0
	)
	var chassis := PackedVector2Array()
	var arrow_base: Vector2 = to_px.call(Vector2(sp.x - 0.9, box_top + 0.25))
	chassis.append(arrow_base + Vector2(14, 0))
	chassis.append(arrow_base + Vector2(-5, -7))
	chassis.append(arrow_base + Vector2(-5, 7))
	draw_colored_polygon(chassis, CHASSIS_COLOR)
	# Link figure and tooth marker.
	var link_px := PackedVector2Array()
	for pt in link_pts:
		link_px.append(to_px.call(pt))
	draw_polyline(link_px, LINK_COLOR, 3.0)
	for pt in link_pts:
		draw_circle(to_px.call(pt), 3.0, LINK_COLOR)
	var tooth_px: Vector2 = to_px.call(tooth_pt)
	draw_circle(tooth_px, 5.0, TOOTH_COLOR)
	# Tooth offset from the target surface, the number the operator steers by
	# — a dimension stub from the tooth down to the design line, labeled at
	# its midpoint so the text rides the measurement it belongs to.
	var tooth_err := float(_view.get("tooth_err", 0.0))
	var target_at_tooth: Vector2 = to_px.call(Vector2(tooth_pt.x, target_h.call(tooth_pt.x)))
	draw_line(tooth_px, target_at_tooth, TOOTH_COLOR, 2.0)
	var title := ""
	match String(_view.get("mode", "")):
		"level":
			title = "平地作业 · 目标高 %+.2fm" % toe_h
		_:
			title = "修坡%s · d=%.1fm θ=%+.0f° 削土=%.2fm³" % [
				"预览" if String(_view.get("mode", "")) == "preview" else "作业",
				float(_view.get("distance_m", toe_s)),
				float(_view.get("angle_deg", 0.0)),
				float(_view.get("volume_m3", 0.0)),
			]
	_draw_text(Vector2(MARGIN, MARGIN + 4), title)
	_draw_text(tooth_px.lerp(target_at_tooth, 0.5) + Vector2(10.0, 4.0), "%+dcm" % roundi(tooth_err * 100.0))


func _draw_text(pos: Vector2, text: String) -> void:
	if _font == null:
		return
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE, TEXT_COLOR)


## Plane-space rect through the y-flipped view transform: p_lo is the
## lower-left and p_hi the upper-right corner in (s,h) coordinates.
func _draw_plane_rect(
	to_px: Callable, p_lo: Vector2, p_hi: Vector2, color: Color, filled: bool, width: float = -1.0
) -> void:
	var a: Vector2 = to_px.call(p_lo)
	var b: Vector2 = to_px.call(p_hi)
	draw_rect(Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)), (a - b).abs()), color, filled, width)

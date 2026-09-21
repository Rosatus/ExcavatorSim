class_name SlopeSideView
extends Control

## 2D machine-guidance display for the slope assist: the cabin-facing profile
## plane seen from the side — chassis silhouette, boom/arm/bucket link figure,
## sampled terrain line, target profile line, cut-region fill and the tooth's
## live offset from the target. Fed by the session status snapshot
## (slope_assist.view); the owner toggles visibility; the viewport is latched per operation.

const GameSkin := preload("res://scripts/game_ui_theme.gd")

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
const TRACK_BOTTOM_OFFSET_M := 1.05

var _view: Dictionary = {}
var _font: Font
var _camera_world := Vector3.ZERO
var _camera_valid := false
var _camera_mode := ""

var _variant := GameSkin.VARIANT_DEBUG


func _ready() -> void:
	custom_minimum_size = Vector2(360, 220)
	_font = get_theme_default_font()
	mouse_filter = MOUSE_FILTER_IGNORE
	clip_contents = true
	visibility_changed.connect(func() -> void:
		if not is_visible_in_tree():
			_camera_valid = false
	)


## Theme hook: console variants reframe the panel as a chamfered instrument
## plate; the semantic guidance colors (terrain, target, tooth) never change.
func set_theme_variant(variant: String) -> void:
	if variant == _variant:
		return
	_variant = variant
	queue_redraw()


func set_view(view: Dictionary) -> void:
	_view = view
	var mode := String(view.get("mode", ""))
	if view.is_empty():
		_camera_valid = false
	elif not _camera_valid or mode != _camera_mode:
		_camera_world = (view.get("joints", {}) as Dictionary).get("swing_joint", Vector3.ZERO)
		_camera_valid = true
	_camera_mode = mode
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
	var knee_w := float(_view.get("knee_w", 0.0))
	# Same smooth-relu the tracked SlopeProfile uses at the toe knee — the
	# drawn line is the surface the tooth actually follows.
	var target_h := func(s: float) -> float:
		var x := s - toe_s
		if knee_w > 0.0 and x > -knee_w and x < knee_w:
			var u := x + knee_w
			return toe_h + grade * u * u / (4.0 * knee_w)
		return toe_h + grade * maxf(x, 0.0)
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
	# Fixed world reference cancels the tooth-relative snapshot origin.
	# Joint motion and terrain changes must never pan or zoom the viewport.
	var bounds := view_bounds()
	var lo := bounds.position
	var hi := bounds.end
	var sp: Vector2 = pivots["swing_joint"]
	var span := (hi - lo).max(Vector2(1.0, 1.0))
	# Leave a dedicated header strip; tall work equipment never crosses text.
	var draw_area := size - Vector2(MARGIN * 2.0, MARGIN + 36.0)
	var scale := minf(draw_area.x / span.x, draw_area.y / span.y)
	var to_px := func(p: Vector2) -> Vector2:
		return Vector2(
			MARGIN + (p.x - lo.x) * scale + (draw_area.x - span.x * scale) * 0.5,
			size.y - MARGIN - (p.y - lo.y) * scale - (draw_area.y - span.y * scale) * 0.5
		)
	var console := GameSkin.is_console_variant(_variant)
	var accent := GameSkin.accent_for(_variant)
	if console:
		# Instrument plate: rounded steel slab, double rim and a header band
		# behind the title line.
		var plate := _rounded_poly(Rect2(Vector2(1.5, 1.5), size - Vector2(3.0, 3.0)), 10.0)
		draw_colored_polygon(plate, Color(0.048, 0.062, 0.075, 0.94))
		var plate_ring := PackedVector2Array(plate)
		plate_ring.append(plate[0])
		draw_polyline(plate_ring, Color(0.64, 0.70, 0.72, 0.30), 1.2, true)
		var rim := _rounded_poly(Rect2(Vector2(5.0, 5.0), size - Vector2(10.0, 10.0)), 7.0)
		rim.append(rim[0])
		draw_polyline(rim, Color(0.64, 0.70, 0.72, 0.10), 1.0, true)
		draw_rect(Rect2(6.0, 6.0, size.x - 12.0, 22.0), Color(0.02, 0.028, 0.034, 0.6))
		draw_rect(Rect2(6.0, 28.0, size.x - 12.0, 1.0), Color(accent, 0.45))
		draw_rect(Rect2(9.0, 10.0, 3.0, 15.0), accent)
		# Faint metre grid under the guidance drawing.
		var grid_c := Color(0.72, 0.76, 0.80, 0.05)
		var g0 := int(floorf(lo.y))
		var g1 := int(ceilf(hi.y))
		if g1 - g0 <= 32:
			for h_i in range(g0, g1 + 1):
				draw_line(to_px.call(Vector2(lo.x, h_i)), to_px.call(Vector2(hi.x, h_i)), grid_c, 1.0)
		var s0 := int(floorf(lo.x))
		var s1 := int(ceilf(hi.x))
		if s1 - s0 <= 48:
			for s_i in range(s0, s1 + 1):
				draw_line(to_px.call(Vector2(s_i, lo.y)), to_px.call(Vector2(s_i, hi.y)), grid_c, 1.0)
	else:
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
	var steps := 48
	for i in range(steps + 1):
		var s_i := lerpf(view_s0, view_s1, float(i) / steps)
		target_px.append(to_px.call(Vector2(s_i, target_h.call(s_i))))
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
	if absf(toe_s) > 0.05:
		var anchor_px: Vector2 = to_px.call(Vector2(0.0, target_h.call(0.0)))
		# The knee's smoothed-relax height differs slightly from the anchor's,
		# so a point-to-point dimension line would lean with the profile. Keep
		# the dimension strictly horizontal with vertical end ticks instead.
		var dim_y := minf(anchor_px.y, knee_px.y) - 10.0
		draw_line(anchor_px + Vector2(0, -5), anchor_px + Vector2(0, 5), TEXT_COLOR, 1.5)
		draw_line(Vector2(anchor_px.x, dim_y), Vector2(knee_px.x, dim_y), TEXT_COLOR, 1.0)
		draw_line(Vector2(anchor_px.x, dim_y - 3), Vector2(anchor_px.x, dim_y + 3), TEXT_COLOR, 1.0)
		draw_line(Vector2(knee_px.x, dim_y - 3), Vector2(knee_px.x, dim_y + 3), TEXT_COLOR, 1.0)
		_draw_text(Vector2((anchor_px.x + knee_px.x) * 0.5 - 4.0, dim_y - 4.0), "d")
	# Theta arc at the toe knee: bench direction sweeps into the grade.
	var px_ang := atan2(-grade, 1.0)
	if absf(px_ang) > 0.03 and knee > view_s0 and knee < view_s1:
		var arc_pts := PackedVector2Array()
		for i in range(9):
			var a := lerpf(0.0, px_ang, float(i) / 8.0)
			arc_pts.append(knee_px + Vector2(cos(a), sin(a)) * 22.0)
		draw_polyline(arc_pts, TARGET_COLOR, 1.5)
	draw_circle(knee_px, 3.0, TOOTH_COLOR)
	_draw_machine(to_px, machine_symbol_pivot(sp, terrain), link_pts, scale)
	var tooth_px: Vector2 = to_px.call(tooth_pt)
	# Tooth offset from the target surface, the number the operator steers by
	# — a dimension stub from the tooth down to the design line; the value
	# itself rides the title line as a labeled field, not floating text.
	var tooth_err := float(_view.get("tooth_err", 0.0))
	var target_at_tooth: Vector2 = to_px.call(Vector2(tooth_pt.x, target_h.call(tooth_pt.x)))
	draw_line(tooth_px, target_at_tooth, TOOTH_COLOR, 2.0)
	var err_cm := roundi(tooth_err * 100.0)
	var title := ""
	match String(_view.get("mode", "")):
		"level":
			title = "平地作业 · 目标高 %+.2fm · 齿尖 %+dcm" % [toe_h, err_cm]
		_:
			title = "修坡%s · d=%.1fm θ=%+.0f° 削土=%.2fm³ · 齿尖 %+dcm" % [
				"预览" if String(_view.get("mode", "")) == "preview" else "作业",
				float(_view.get("distance_m", toe_s)),
				float(_view.get("angle_deg", 0.0)),
				float(_view.get("volume_m3", 0.0)),
				err_cm,
			]
	_draw_text(Vector2(MARGIN, MARGIN + 4), title, accent if console else TEXT_COLOR)


func view_bounds() -> Rect2:
	var anchor := project_to_plane(
		_view.get("origin_xz", Vector2.ZERO), _view.get("axis", Vector2.RIGHT), _camera_world
	)
	return Rect2(anchor + Vector2(-5.0, -5.0), Vector2(17.0, 12.0))


static func machine_symbol_pivot(pivot: Vector2, terrain: PackedVector2Array) -> Vector2:
	# Place the schematic's tread on the actual ground below the machine,
	# not a fixed distance below its (model-dependent) slew-joint height.
	# The target grade can intentionally differ from the supporting ground.
	for index in range(terrain.size() - 1):
		var a := terrain[index]
		var b := terrain[index + 1]
		if b.x <= a.x or pivot.x < a.x or pivot.x > b.x:
			continue
		var ground := lerpf(a.y, b.y, (pivot.x - a.x) / (b.x - a.x))
		return Vector2(pivot.x, ground + TRACK_BOTTOM_OFFSET_M)
	return pivot


func _draw_machine(to_px: Callable, pivot: Vector2, links: PackedVector2Array, pixels_per_m: float) -> void:
	# Rigid side elevation: centered tracks, separate counterweight and cab.
	var track_a: Vector2 = to_px.call(pivot + Vector2(-1.8, -0.45))
	var track_b: Vector2 = to_px.call(pivot + Vector2(1.8, -TRACK_BOTTOM_OFFSET_M))
	var track := _rounded_poly(Rect2(track_a, track_b - track_a), 0.3 * pixels_per_m)
	draw_colored_polygon(track, Color(LINK_COLOR, 0.06))
	track.append(track[0])
	draw_polyline(track, CHASSIS_COLOR, 1.5, true)
	draw_line(to_px.call(pivot + Vector2(-1.35, -0.75)), to_px.call(pivot + Vector2(1.35, -0.75)), Color(CHASSIS_COLOR, 0.45), 1.0, true)
	var shapes := [
		PackedVector2Array([Vector2(-1.65, -0.25), Vector2(-1.65, 0.35), Vector2(-1.4, 0.55), Vector2(-0.4, 0.55), Vector2(-0.4, -0.25)]),
		PackedVector2Array([Vector2(-0.3, -0.25), Vector2(-0.3, 1.35), Vector2(0.55, 1.35), Vector2(0.9, 0.85), Vector2(0.9, -0.25)]),
	]
	for shape: PackedVector2Array in shapes:
		var outline := PackedVector2Array()
		for point in shape:
			outline.append(to_px.call(pivot + point))
		draw_colored_polygon(outline, Color(LINK_COLOR, 0.07))
		outline.append(outline[0])
		draw_polyline(outline, LINK_COLOR, 1.5, true)
	draw_line(to_px.call(pivot + Vector2(-1.75, -0.3)), to_px.call(pivot + Vector2(1.05, -0.3)), CHASSIS_COLOR, 1.5, true)
	var work := PackedVector2Array()
	for index in range(1, links.size()):
		work.append(to_px.call(links[index]))
	if work.size() >= 2:
		draw_polyline(work, LINK_COLOR, 2.5, true)
		for index in range(work.size() - 1):
			draw_circle(work[index], 2.5, PANEL_BG)
			draw_circle(work[index], 2.5, LINK_COLOR, false, 1.0, true)
		var pin := work[-2]
		var tip := work[-1]
		var bucket := bucket_outline(pin, tip, to_px.call(pivot))
		if bucket.size() >= 3:
			draw_colored_polygon(bucket, Color(LINK_COLOR, 0.12))
			draw_polyline(bucket, LINK_COLOR, 1.5, true)
		draw_circle(work[-1], 5.0, Color(TOOTH_COLOR, 0.15))
		draw_circle(work[-1], 3.0, TOOTH_COLOR)


static func bucket_outline(pin: Vector2, tip: Vector2, machine: Vector2) -> PackedVector2Array:
	var axis := tip - pin
	if axis.length_squared() < 0.0001:
		return PackedVector2Array()
	var outward := Vector2(-axis.y, axis.x).normalized()
	var away := pin.lerp(tip, 0.5) - machine
	if outward.dot(away) < 0.0:
		outward = -outward
	# A smooth bowl on the far side of the pin-to-tooth chord. Endpoints
	# remain the measured joint and tooth; only the schematic back is curved.
	var depth := minf(axis.length() * 0.55, 10.0)
	var outline := PackedVector2Array()
	for index in range(17):
		var t := float(index) / 16.0
		outline.append(pin.lerp(tip, t) + outward * depth * sin(PI * t))
	outline[0] = pin
	outline[-1] = tip
	return outline


func _draw_text(pos: Vector2, text: String, color: Color = TEXT_COLOR) -> void:
	if _font == null:
		return
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE, color)


## Closed polygon outline of a rounded rect: each corner gets a 90° arc of
## six segments, walked clockwise in screen space (y down).
static func _rounded_poly(r: Rect2, radius: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var x0 := r.position.x
	var y0 := r.position.y
	var x1 := r.end.x
	var y1 := r.end.y
	var corners := [
		[Vector2(x0 + radius, y0 + radius), PI],
		[Vector2(x1 - radius, y0 + radius), -PI / 2.0],
		[Vector2(x1 - radius, y1 - radius), 0.0],
		[Vector2(x0 + radius, y1 - radius), PI / 2.0],
	]
	for c in corners:
		var center: Vector2 = c[0]
		var a0: float = c[1]
		for j in range(7):
			var a := a0 + (PI / 2.0) * float(j) / 6.0
			pts.append(center + Vector2(cos(a), sin(a)) * radius)
	return pts


## Plane-space rect through the y-flipped view transform: p_lo is the
## lower-left and p_hi the upper-right corner in (s,h) coordinates.
func _draw_plane_rect(
	to_px: Callable, p_lo: Vector2, p_hi: Vector2, color: Color, filled: bool, width: float = -1.0
) -> void:
	var a: Vector2 = to_px.call(p_lo)
	var b: Vector2 = to_px.call(p_hi)
	draw_rect(Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)), (a - b).abs()), color, filled, width)

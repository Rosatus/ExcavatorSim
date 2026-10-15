class_name DtmView
extends Control

## One DTM chart. Static content (design TIN, measured surface, sections) is
## drawn by this Control and cached as meshes per published model revision;
## machine markers live on a child overlay so tooth motion redraws only the
## overlay, never the map meshes, grid or labels.

const TARGET := Color("62d9e8")
const SOIL := Color("d9b98b")
const SOIL_BODY := Color("5a4632")
const CUT := Color("ee9b55")
const FILL := Color("648ff0")
const GRADE := Color("55edb0")
const TOOTH := Color("ffe49a")
const MUTED := Color("8298ab")
const TEXT := Color("e2edf5")
const GRID := Color("223646")
const UNKNOWN := Color("425061")
const UNKNOWN_DARK := Color("323d4a")
const SOIL_LIGHT := Color("8a6a48")
const SOIL_DARK := Color("6d5238")
const STYLE_TERRAIN := "terrain"
const STYLE_VOXEL := "voxel"
const STYLES := [STYLE_TERRAIN, STYLE_VOXEL]
const COLOR_STOPS := [0.05, 0.20, 0.60, 1.50, 3.0]
const CUT_PALETTE := [Color("fff1a6"), Color("ffd24a"), Color("ff952e"), Color("f45c43"), Color("cc3560")]
const FILL_PALETTE := [Color("b4ecff"), Color("58cfff"), Color("3797fa"), Color("5964ef"), Color("8551cf")]
const NICE_STEPS := [0.05, 0.1, 0.2, 0.25, 0.5, 1.0, 2.0, 2.5, 5.0, 10.0, 20.0, 25.0, 50.0, 100.0]
const ISO_X := 0.8660254
const ISO_Y := 0.38
const TITLES := {"iso": "01  /  2.5D 实测地表", "plan": "02  /  俯视 · 挖填偏差", "section": "03  /  施工纵断面 A—A′", "bucket": "04  /  铲齿跟随垂向截面"}

var mode := "iso"
## Chart look: smooth "terrain" surfaces or the stepped block "voxel" theme.
## Both styles share the same measurement data and fixed metre colour stops.
var style := STYLE_TERRAIN
var model: DtmModel
var bucket: Dictionary = {}
var profile: Array[Dictionary] = []
var profile_bucket: Dictionary = {}
var accent := TARGET
var compact := false
var last_draw_usec := 0
var mesh_build_count := 0
var overlay: Control

var _surface_mesh: ArrayMesh
var _vertices := PackedVector3Array()
var _colors := PackedColorArray()
var _indices := PackedInt32Array()
var _contour_mesh: ArrayMesh
var _target_mesh: ArrayMesh
var _target_surface: RefCounted
var _target_mode := ""
var _cells_revision := -1
var _map_low := 0.0
var _map_high := 0.0
var _plot := Rect2()
var _center := Vector3.ZERO
var _scale := 1.0
var _height_min := 0.0
var _height_max := 1.0
var _distance_min := 0.0
var _distance_max := 1.0
var _voxel_q := 0.125
static var _frames := {}
static var _dot_texture: ImageTexture

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	custom_minimum_size = Vector2(200, 120)
	overlay = Control.new()
	overlay.name = "Overlay"
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.draw.connect(_draw_overlay)
	add_child(overlay)

func set_compact(enabled: bool) -> void:
	compact = enabled
	custom_minimum_size = Vector2(200, 100 if enabled else 120)
	queue_redraw()

func set_style(value: String) -> void:
	if value not in STYLES or value == style:
		return
	style = value
	# Geometry differs per style, so cached meshes are rebuilt on next draw.
	_cells_revision = -1
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED if style == STYLE_VOXEL else CanvasItem.TEXTURE_REPEAT_PARENT_NODE
	queue_redraw()
	if overlay != null:
		overlay.queue_redraw()

## Machine state for map charts. Only the overlay is invalidated.
func set_machine(value: Dictionary, section: Dictionary) -> void:
	if value == bucket and section == profile_bucket:
		return
	bucket = value
	profile_bucket = section
	if overlay != null:
		overlay.queue_redraw()

static func difference_color(difference: float) -> Color:
	if not is_finite(difference):
		return UNKNOWN
	if absf(difference) <= DtmModel.TOLERANCE_M:
		return GRADE
	# Fixed metre-based stops preserve meaning while digging; no frame-wise
	# normalization. Extra contrast near grade makes the last passes readable.
	var magnitude := absf(difference)
	var stops := COLOR_STOPS
	var palette := CUT_PALETTE if difference > 0 else FILL_PALETTE
	for i in range(1, stops.size()):
		if magnitude <= stops[i]:
			return (palette[i - 1] as Color).lerp(palette[i], inverse_lerp(stops[i - 1], stops[i], magnitude))
	return palette.back()

## Discrete band colour for the voxel theme: one flat colour per fixed stop
## interval, so block tiles read like a retro palette instead of a gradient.
static func stepped_color(difference: float) -> Color:
	if not is_finite(difference):
		return UNKNOWN
	var magnitude := absf(difference)
	if magnitude <= DtmModel.TOLERANCE_M:
		return GRADE
	var palette := CUT_PALETTE if difference > 0 else FILL_PALETTE
	for i in range(1, COLOR_STOPS.size()):
		if magnitude <= COLOR_STOPS[i]:
			return (palette[i - 1] as Color).lerp(palette[i], 0.5)
	return palette.back()

## Index of the stepped band: -5..-1 fill, 0 grade, 1..5 cut.
static func stepped_band(difference: float) -> int:
	var magnitude := absf(difference)
	if magnitude <= DtmModel.TOLERANCE_M:
		return 0
	var band := COLOR_STOPS.size()
	for i in range(1, COLOR_STOPS.size()):
		if magnitude <= COLOR_STOPS[i]:
			band = i
			break
	return band if difference > 0 else -band

static func nice_step(span: float, max_ticks: int) -> float:
	for step in NICE_STEPS:
		if span / step <= max_ticks:
			return step
	return pow(10.0, ceil(log(span / max_ticks) / log(10.0)))

static func grid_step_for(extent: Vector3) -> float:
	var needed := maxf(maxf(extent.x, extent.z) / 20.0, 1.0)
	return pow(10.0, ceil(log(needed) / log(10.0)))

static func clip_segment(a: Vector2, b: Vector2, rect: Rect2) -> PackedVector2Array:
	var delta := b - a
	var p := [-delta.x, delta.x, -delta.y, delta.y]
	var q := [a.x - rect.position.x, rect.end.x - a.x, a.y - rect.position.y, rect.end.y - a.y]
	var lo := 0.0
	var hi := 1.0
	for i in 4:
		if absf(p[i]) < 0.0000001:
			if q[i] < 0:
				return PackedVector2Array()
			continue
		var ratio: float = q[i] / p[i]
		if p[i] < 0:
			lo = maxf(lo, ratio)
		else:
			hi = minf(hi, ratio)
		if lo > hi:
			return PackedVector2Array()
	return PackedVector2Array([a + delta * lo, a + delta * hi])

static func _frame_box(is_compact: bool, voxel := false) -> StyleBoxFlat:
	var key := "%s:%s" % [is_compact, voxel]
	if not _frames.has(key):
		var box := StyleBoxFlat.new()
		# HUD cards sit over bright sand and sky: a dark, mostly opaque plate
		# keeps the linework legible without a full outer panel.
		if voxel:
			box.bg_color = Color(0.04, 0.05, 0.07, 0.84) if is_compact else Color("0b1118")
			box.border_color = Color("31404f")
			box.set_border_width_all(2)
			box.set_corner_radius_all(0)
		else:
			box.bg_color = Color(0.035, 0.055, 0.075, 0.78) if is_compact else Color("0e1a25")
			box.border_color = Color(0.62, 0.74, 0.82, 0.22) if is_compact else Color("263b4c")
			box.set_border_width_all(1)
			box.set_corner_radius_all(8)
		_frames[key] = box
	return _frames[key]

## 6 px tile with one dim pixel: a dot-matrix backdrop for the voxel plot.
static func _dots() -> ImageTexture:
	if _dot_texture == null:
		var image := Image.create(6, 6, false, Image.FORMAT_RGBA8)
		image.fill(Color(0, 0, 0, 0))
		image.set_pixel(0, 0, Color(1, 1, 1, 1))
		_dot_texture = ImageTexture.create_from_image(image)
	return _dot_texture

func _text(item: CanvasItem, at: Vector2, text: String, color := TEXT, font_size := 12, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	var font := get_theme_default_font()
	if compact:
		item.draw_string(font, at + Vector2.ONE, text, align, width, font_size, Color(0, 0, 0, 0.8))
	item.draw_string(font, at, text, align, width, font_size, color)

func _draw() -> void:
	var draw_started := Time.get_ticks_usec()
	var voxel := style == STYLE_VOXEL
	draw_style_box(_frame_box(compact, voxel), Rect2(Vector2.ZERO, size))
	if voxel:
		_draw_pixel_corners()
		var top := 9.0 if compact else 16.0
		draw_rect(Rect2(Vector2(9, top + 3), Vector2(6, 6)), accent, false, 2.0)
	else:
		draw_line(Vector2(12, 9 if compact else 15), Vector2(12, 22 if compact else 30), accent, 2)
	_text(self, Vector2(21, 21 if compact else 28), TITLES.get(mode, mode), TEXT, 12 if compact else 14)
	_plot = Rect2(Vector2(36 if compact else 46, 30 if compact else 44), Vector2(maxf(size.x - (48 if compact else 62), 1), maxf(size.y - (50 if compact else 76), 1)))
	if voxel:
		draw_texture_rect(_dots(), _plot, true, Color(0.55, 0.68, 0.78, 0.13))
	if model == null or model.surface == null:
		_text(self, Vector2(22, size.y * 0.55), "导入 LandXML 或选择训练设计", MUTED)
		return
	if mode in ["iso", "plan"]:
		_draw_map()
	else:
		_draw_profile()
	last_draw_usec = Time.get_ticks_usec() - draw_started

## Stepped L brackets in the accent colour on every frame corner.
func _draw_pixel_corners() -> void:
	var u := 3.0
	var color := Color(accent, 0.85)
	for corner in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
		var sx := 1.0 if corner.x == 0 else -1.0
		var sy := 1.0 if corner.y == 0 else -1.0
		var origin := Vector2(corner.x * size.x - (u if corner.x == 1 else 0.0), corner.y * size.y - (u if corner.y == 1 else 0.0))
		for k in 3:
			draw_rect(Rect2(origin + Vector2(sx * k * u, 0), Vector2(u, u)), color)
			draw_rect(Rect2(origin + Vector2(0, sy * k * u), Vector2(u, u)), color)

# --- map charts --------------------------------------------------------------

func _project(p: Vector3) -> Vector2:
	var local := p - _center
	if mode == "plan":
		return _plot.get_center() + Vector2(local.x, -local.z) * _scale
	return _plot.get_center() + Vector2((local.x - local.z) * ISO_X, (local.x + local.z) * ISO_Y - local.y) * _scale

func _local_vertex(local: Vector3) -> Vector3:
	if mode == "plan":
		return Vector3(local.x, -local.z, 0)
	return Vector3((local.x - local.z) * ISO_X, (local.x + local.z) * ISO_Y - local.y, 0)

func _draw_map() -> void:
	var bounds := model.surface.world_bounds()
	if _cells_revision != model.display_revision:
		_rebuild_cells()
	var low := _map_low
	var high := _map_high
	_center = bounds.get_center()
	_center.y = (low + high) * 0.5
	if mode == "plan":
		_scale = minf(_plot.size.x / maxf(bounds.size.x + 1, 2), _plot.size.y / maxf(bounds.size.z + 1, 2))
	else:
		_scale = minf(_plot.size.x / maxf((bounds.size.x + bounds.size.z) * ISO_X + 1, 2), _plot.size.y / maxf((bounds.size.x + bounds.size.z) * ISO_Y + high - low + 1, 2))
	var transform := Transform2D(Vector2(_scale, 0), Vector2(0, _scale), _project(model.surface.translation))
	_ensure_target_mesh()
	if mode == "iso":
		# Ghosted design: full strength beneath the surface, faint on top, so it
		# reads both under remaining soil and above over-excavation.
		draw_mesh(_target_mesh, null, transform, Color(TARGET, 0.75))
		if _surface_mesh != null:
			draw_mesh(_surface_mesh, null, transform)
		draw_mesh(_target_mesh, null, transform, Color(TARGET, 0.3 if style == STYLE_VOXEL else 0.22))
	else:
		if _surface_mesh != null:
			draw_mesh(_surface_mesh, null, transform)
		if _contour_mesh != null:
			draw_mesh(_contour_mesh, null, transform, Color(0.02, 0.04, 0.06, 0.8) if style == STYLE_VOXEL else Color(0.02, 0.05, 0.07, 0.55))
		var grid_step := grid_step_for(bounds.size)
		for ix in range(floori(bounds.position.x / grid_step), ceili(bounds.end.x / grid_step) + 1):
			var x := ix * grid_step
			draw_line(_project(Vector3(x, low, bounds.position.z)), _project(Vector3(x, low, bounds.end.z)), Color(GRID, 0.8), 1)
		for iz in range(floori(bounds.position.z / grid_step), ceili(bounds.end.z / grid_step) + 1):
			var z := iz * grid_step
			draw_line(_project(Vector3(bounds.position.x, low, z)), _project(Vector3(bounds.end.x, low, z)), Color(GRID, 0.8), 1)
		draw_mesh(_target_mesh, null, transform, Color(TARGET, 0.6))
		var cx := bounds.get_center().x
		var a := _project(Vector3(cx, low, bounds.position.z))
		var b := _project(Vector3(cx, low, bounds.end.z))
		draw_dashed_line(a, b, TEXT, 1, 5)
		_text(self, a + Vector2(4, 12), "A", TEXT, 10)
		_text(self, b + Vector2(4, -2), "A′", TEXT, 10)
		if not compact:
			_text(self, Vector2(size.x - 58, 52), "+Z ↑", MUTED, 11)
			_text(self, Vector2(size.x - 58, 67), "+X →", MUTED, 11)
	var footer := ""
	if style == STYLE_VOXEL:
		footer = "方块层高 %s · 青线：目标 TIN · 分档色：偏差" % _length_label(_voxel_q) if mode == "iso" else "台阶等高 %s · A—A′ 纵断面 · 黄虚线 铲齿截面" % _contour_label()
	else:
		footer = "青色网线：目标 TIN · 色块：实测偏差 · 灰：缺测" if mode == "iso" else "等高线 %s · A—A′ 纵断面 · 黄虚线 铲齿截面" % _contour_label()
	_text(self, Vector2(12, size.y - 7 if compact else size.y - 12), footer, MUTED, 10 if compact else 11)
	overlay.queue_redraw()

func _contour_label() -> String:
	return _length_label(_contour_interval())

static func _length_label(value: float) -> String:
	return "—" if value <= 0 else ("%.0f cm" % (value * 100) if value < 1 else "%.1f m" % value)

func _contour_interval() -> float:
	var span := _map_high - _map_low
	return 0.0 if span < 0.08 else nice_step(span, 10)

func _ensure_target_mesh() -> void:
	# Unique TIN edges as one line mesh; shared edges are drawn once so the
	# internal diagonal is not brighter than the perimeter.
	if _target_surface == model.surface and _target_mode == mode and _target_mesh != null:
		return
	_target_surface = model.surface
	_target_mode = mode
	_target_mesh = ArrayMesh.new()
	var vertices := PackedVector3Array()
	for vertex in model.surface.vertices:
		vertices.append(_local_vertex(vertex))
	var indices := PackedInt32Array()
	var edges := {}
	for face in model.surface.faces:
		for pair in [Vector2i(face.x, face.y), Vector2i(face.y, face.z), Vector2i(face.z, face.x)]:
			var key := Vector2i(mini(pair.x, pair.y), maxi(pair.x, pair.y))
			if not edges.has(key):
				edges[key] = true
				indices.append_array(PackedInt32Array([key.x, key.y]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	_target_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)

func _rebuild_cells() -> void:
	_cells_revision = model.display_revision
	mesh_build_count += 1
	var bounds := model.surface.world_bounds()
	_map_low = bounds.position.y
	_map_high = bounds.end.y
	_surface_mesh = null
	_contour_mesh = null
	if model.is_empty():
		return
	var g := model.grid_size
	var n := g.x * g.y
	var targets := model.targets
	var actuals := model.actuals
	# Display height: measurement where known, otherwise the design (grey).
	var heights := PackedFloat32Array()
	heights.resize(n)
	for i in n:
		var target := targets[i]
		var actual := actuals[i]
		if is_finite(actual) and is_finite(target):
			_map_low = minf(_map_low, actual)
			_map_high = maxf(_map_high, actual)
			heights[i] = actual
		else:
			heights[i] = target
	# Shared corner heights make one continuous surface instead of tiles.
	var stride := g.x + 1
	var corners := PackedFloat32Array()
	corners.resize(stride * (g.y + 1))
	for cz in g.y + 1:
		for cx in stride:
			var total := 0.0
			var count := 0
			for z in range(maxi(cz - 1, 0), mini(cz + 1, g.y)):
				for x in range(maxi(cx - 1, 0), mini(cx + 1, g.x)):
					var h := heights[z * g.x + x]
					if is_finite(h):
						total += h
						count += 1
			corners[cz * stride + cx] = total / count if count > 0 else NAN
	_vertices = PackedVector3Array()
	_colors = PackedColorArray()
	_indices = PackedInt32Array()
	if style == STYLE_VOXEL:
		if mode == "iso":
			_build_voxel_iso(heights)
		else:
			_build_voxel_plan(heights)
	elif mode == "iso":
		_build_iso(heights, corners)
	else:
		_build_plan(heights, corners)
		_build_contours(heights)
	_surface_mesh = _mesh_from(_vertices, Mesh.PRIMITIVE_TRIANGLES, _colors, _indices)

# --- voxel theme map builders -------------------------------------------------

func _cell_world(x: float, z: float, h: float) -> Vector3:
	return Vector3(model.grid_origin.x + x * model.cell_size.x, h, model.grid_origin.y + z * model.cell_size.y) - model.surface.translation

func _flat_quad(x0: float, z0: float, x1: float, z1: float, h: float, color: Color) -> void:
	_quad([_cell_world(x0, z0, h), _cell_world(x1, z0, h), _cell_world(x1, z1, h), _cell_world(x0, z1, h)], [color, color, color, color])

func _voxel_level_height(span: float) -> float:
	# About 16 visible layers over the relief, never thinner than 5 cm.
	return maxf(nice_step(maxf(span, 0.05), 16), 0.05)

func _build_voxel_iso(heights: PackedFloat32Array) -> void:
	var g := model.grid_size
	var q := _voxel_level_height(_map_high - _map_low)
	_voxel_q = q
	var levels := PackedFloat32Array()
	levels.resize(heights.size())
	for i in heights.size():
		levels[i] = roundf(heights[i] / q) * q if is_finite(heights[i]) else NAN
	var base_y := (floorf(_map_low / q) - 2.0) * q
	_map_low = base_y
	# Painter's order towards the +X+Z viewer; each column is a stepped block
	# with a coloured cap, strata walls and a bevelled top.
	for s in g.x + g.y - 1:
		for x in range(maxi(0, s - g.y + 1), mini(g.x, s + 1)):
			var z := s - x
			var i := z * g.x + x
			var h := levels[i]
			if not is_finite(h):
				continue
			var color := stepped_color(model.actuals[i] - model.targets[i])
			color.a = 1.0
			var east := levels[i + 1] if x < g.x - 1 else NAN
			var south := levels[i + g.x] if z < g.y - 1 else NAN
			var east_floor: float = east if is_finite(east) else base_y
			var south_floor: float = south if is_finite(south) else base_y
			if east_floor < h:
				_voxel_wall(Vector2(x + 1, z), Vector2(x + 1, z + 1), east_floor, h, q, color, 0.74)
			if south_floor < h:
				_voxel_wall(Vector2(x, z + 1), Vector2(x + 1, z + 1), south_floor, h, q, color, 0.56)
			_flat_quad(x, z, x + 1, z + 1, h, _shaded(color, 0.8))
			_flat_quad(x + 0.16, z + 0.16, x + 0.84, z + 0.84, h, _shaded(color, 1.06))

func _voxel_wall(a: Vector2, b: Vector2, lo: float, hi: float, q: float, cap: Color, shade: float) -> void:
	# A cap band in the cell colour, then world-aligned strata so stripes line
	# up across neighbouring blocks. Tall walls merge layers to bound quads.
	var cap_bottom := maxf(hi - q * 0.5, lo)
	var cap_color := _shaded(cap, shade * 0.86)
	_quad([_cell_world(a.x, a.y, hi), _cell_world(b.x, b.y, hi), _cell_world(b.x, b.y, cap_bottom), _cell_world(a.x, a.y, cap_bottom)], [cap_color, cap_color, cap_color, cap_color])
	var layer := q * maxf(1.0, ceilf((cap_bottom - lo) / q / 24.0))
	var top := cap_bottom
	while top > lo + 0.0001:
		var k := floorf((top - 0.0001) / layer)
		var bottom := maxf(k * layer, lo)
		var color := _shaded(SOIL_LIGHT if posmod(int(k), 2) == 0 else SOIL_DARK, shade)
		_quad([_cell_world(a.x, a.y, top), _cell_world(b.x, b.y, top), _cell_world(b.x, b.y, bottom), _cell_world(a.x, a.y, bottom)], [color, color, color, color])
		top = bottom

func _build_voxel_plan(heights: PackedFloat32Array) -> void:
	var g := model.grid_size
	var interval := _contour_interval()
	var span := maxf(_map_high - _map_low, 0.001)
	var line_vertices := PackedVector3Array()
	var gap := 0.07
	for z in g.y:
		for x in g.x:
			var i := z * g.x + x
			if not is_finite(heights[i]):
				continue
			var measured := is_finite(model.actuals[i])
			var color := stepped_color(model.actuals[i] - model.targets[i])
			color.a = 1.0 if measured else 0.6
			# Terraced brightness: one flat step per contour band, a gentle
			# relief cue that keeps every tile inside its colour band.
			var shade := 0.95
			if measured:
				var terrace := floorf((heights[i] - _map_low) / interval) * interval if interval > 0 else heights[i] - _map_low
				shade = 0.86 + 0.22 * clampf(terrace / span, 0, 1)
			# Screen-up is +Z: light rim on the upper edge, shadow on the lower.
			_flat_quad(x + gap, z + gap, x + 1 - gap, z + 1 - gap, 0, _shaded(color, shade))
			_flat_quad(x + gap, z + 0.78, x + 1 - gap, z + 1 - gap, 0, _shaded(color, shade * 1.2))
			_flat_quad(x + gap, z + gap, x + 1 - gap, z + 0.2, 0, _shaded(color, shade * 0.72))
			if interval <= 0 or not measured:
				continue
			# Stair contours run along tile edges where the height band changes.
			var band := floorf(heights[i] / interval)
			if x < g.x - 1 and is_finite(model.actuals[i + 1]) and floorf(heights[i + 1] / interval) != band:
				line_vertices.append(_local_vertex(_cell_world(x + 1, z, 0)))
				line_vertices.append(_local_vertex(_cell_world(x + 1, z + 1, 0)))
			if z < g.y - 1 and is_finite(model.actuals[i + g.x]) and floorf(heights[i + g.x] / interval) != band:
				line_vertices.append(_local_vertex(_cell_world(x, z + 1, 0)))
				line_vertices.append(_local_vertex(_cell_world(x + 1, z + 1, 0)))
	_contour_mesh = _mesh_from(line_vertices, Mesh.PRIMITIVE_LINES)

func _corner_world(cx: int, cz: int, h: float) -> Vector3:
	return Vector3(model.grid_origin.x + cx * model.cell_size.x, h, model.grid_origin.y + cz * model.cell_size.y) - model.surface.translation

func _cell_shade(c00: float, c10: float, c01: float, c11: float, light: Vector3) -> float:
	var sx := ((c10 + c11) - (c00 + c01)) / (2.0 * model.cell_size.x)
	var sz := ((c01 + c11) - (c00 + c10)) / (2.0 * model.cell_size.y)
	return clampf(0.55 + 0.55 * Vector3(-sx, 1.0, -sz).normalized().dot(light), 0.45, 1.12)

func _quad(points: Array, colors: Array) -> void:
	var base := _vertices.size()
	for i in 4:
		_vertices.append(_local_vertex(points[i]))
		_colors.append(colors[i])
	_indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))

func _shaded(color: Color, shade: float) -> Color:
	return Color(minf(color.r * shade, 1), minf(color.g * shade, 1), minf(color.b * shade, 1), color.a)

func _build_iso(heights: PackedFloat32Array, corners: PackedFloat32Array) -> void:
	var g := model.grid_size
	var stride := g.x + 1
	var light := Vector3(-0.45, 0.8, 0.4).normalized()
	var base_y := _map_low - maxf((_map_high - _map_low) * 0.25, 0.35)
	_map_low = base_y
	# Painter's order: the viewer sits at +X+Z, so draw by increasing x + z.
	for s in g.x + g.y - 1:
		for x in range(maxi(0, s - g.y + 1), mini(g.x, s + 1)):
			var z := s - x
			var i := z * g.x + x
			if not is_finite(heights[i]):
				continue
			var c00 := corners[z * stride + x]
			var c10 := corners[z * stride + x + 1]
			var c01 := corners[(z + 1) * stride + x]
			var c11 := corners[(z + 1) * stride + x + 1]
			var color := difference_color(model.actuals[i] - model.targets[i])
			color.a = 1.0
			var shaded := _shaded(color, _cell_shade(c00, c10, c01, c11, light))
			_quad([_corner_world(x, z, c00), _corner_world(x + 1, z, c10), _corner_world(x + 1, z + 1, c11), _corner_world(x, z + 1, c01)], [shaded, shaded, shaded, shaded])
			# Skirt walls on the two viewer-facing design edges give the block
			# its volume: soil strata from the surface down to a common base.
			if x == g.x - 1 or not is_finite(heights[i + 1]):
				_wall(x + 1, z, x + 1, z + 1, c10, c11, base_y, 0.62)
			if z == g.y - 1 or not is_finite(heights[i + g.x]):
				_wall(x, z + 1, x + 1, z + 1, c01, c11, base_y, 0.46)

func _wall(ax: int, az: int, bx: int, bz: int, ha: float, hb: float, base_y: float, shade: float) -> void:
	var top := _shaded(SOIL, shade)
	var bottom := _shaded(SOIL_BODY, shade)
	_quad([_corner_world(ax, az, ha), _corner_world(bx, bz, hb), _corner_world(bx, bz, base_y), _corner_world(ax, az, base_y)], [top, top, bottom, bottom])

func _build_plan(heights: PackedFloat32Array, corners: PackedFloat32Array) -> void:
	var g := model.grid_size
	var stride := g.x + 1
	# Hillshade lit from screen top-left (-X, +Z) exposes the dug shape.
	var light := Vector3(-0.5, 0.7, 0.5).normalized()
	for z in g.y:
		for x in g.x:
			var i := z * g.x + x
			if not is_finite(heights[i]):
				continue
			var color := difference_color(model.actuals[i] - model.targets[i])
			var shade := 0.85
			if is_finite(model.actuals[i]):
				shade = _cell_shade(corners[z * stride + x], corners[z * stride + x + 1], corners[(z + 1) * stride + x], corners[(z + 1) * stride + x + 1], light)
			else:
				color.a = 0.55
			var shaded := _shaded(color, shade)
			_quad([_corner_world(x, z, 0), _corner_world(x + 1, z, 0), _corner_world(x + 1, z + 1, 0), _corner_world(x, z + 1, 0)], [shaded, shaded, shaded, shaded])

func _build_contours(heights: PackedFloat32Array) -> void:
	var interval := _contour_interval()
	if interval <= 0:
		return
	var g := model.grid_size
	var vertices := PackedVector3Array()
	var t := model.surface.translation
	# Marching squares between measured cell centres; flat squares cost one
	# min/max test and saddles pair crossings in edge order.
	for z in g.y - 1:
		for x in g.x - 1:
			var i := z * g.x + x
			if not (is_finite(model.actuals[i]) and is_finite(model.actuals[i + 1]) and is_finite(model.actuals[i + g.x]) and is_finite(model.actuals[i + g.x + 1])):
				continue
			var v := [heights[i], heights[i + 1], heights[i + g.x + 1], heights[i + g.x]]
			var lo: float = minf(minf(v[0], v[1]), minf(v[2], v[3]))
			var hi: float = maxf(maxf(v[0], v[1]), maxf(v[2], v[3]))
			var p := [Vector2(x + 0.5, z + 0.5), Vector2(x + 1.5, z + 0.5), Vector2(x + 1.5, z + 1.5), Vector2(x + 0.5, z + 1.5)]
			for k in range(ceili(lo / interval), floori(hi / interval) + 1):
				var level := k * interval + 0.00001
				var crossings: Array[Vector2] = []
				for e in 4:
					var a: float = v[e]
					var b: float = v[(e + 1) % 4]
					if (a - level) * (b - level) < 0:
						crossings.append((p[e] as Vector2).lerp(p[(e + 1) % 4], (level - a) / (b - a)))
				for c in range(0, crossings.size() - 1, 2):
					for point in [crossings[c], crossings[c + 1]]:
						var world := Vector3(model.grid_origin.x + point.x * model.cell_size.x, 0, model.grid_origin.y + point.y * model.cell_size.y) - t
						vertices.append(_local_vertex(world))
	if vertices.is_empty():
		return
	_contour_mesh = _mesh_from(vertices, Mesh.PRIMITIVE_LINES)

func _mesh_from(vertices: PackedVector3Array, primitive: Mesh.PrimitiveType, colors := PackedColorArray(), indices := PackedInt32Array()) -> ArrayMesh:
	if vertices.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	if not colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = colors
	if not indices.is_empty():
		arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(primitive, arrays)
	return mesh

func _draw_overlay() -> void:
	if model == null or model.surface == null or not (mode in ["iso", "plan"]):
		return
	if mode == "plan" and not profile_bucket.is_empty():
		var tooth: Vector3 = profile_bucket.tooth
		var axis: Vector2 = profile_bucket.axis
		var reach := Vector3(axis.x, 0, axis.y) * 3.0
		var line := clip_segment(_project(tooth - reach), _project(tooth + reach), _plot)
		if line.size() == 2:
			overlay.draw_dashed_line(line[0], line[1], Color(TOOTH, 0.8), 1.5, 4)
	if bucket.is_empty():
		return
	var tooth: Vector3 = bucket.tooth
	var marker := _project(tooth)
	if not _plot.has_point(marker):
		return
	if style == STYLE_VOXEL:
		_draw_voxel_marker(tooth, marker)
		return
	if mode == "iso":
		# Plumb line to the design surface gives the 2.5D view a depth cue.
		var target := model.surface.height_at(Vector2(tooth.x, tooth.z))
		if is_finite(target):
			var foot := _project(Vector3(tooth.x, target, tooth.z))
			var line := clip_segment(marker, foot, _plot)
			if line.size() == 2:
				overlay.draw_dashed_line(line[0], line[1], Color(TOOTH, 0.7), 1, 3)
			overlay.draw_arc(foot, 4, 0, TAU, 16, Color(TARGET, 0.9), 1.5, true)
	var axis: Vector2 = bucket.axis
	var side := Vector3(-axis.y, 0, axis.x) * float(bucket.width) * 0.5
	overlay.draw_line(_project(tooth - side), _project(tooth + side), Color(0, 0, 0, 0.6), 4, true)
	overlay.draw_line(_project(tooth - side), _project(tooth + side), TOOTH, 2, true)
	overlay.draw_circle(marker, 5, Color(0, 0, 0, 0.55))
	overlay.draw_circle(marker, 4, TOOTH)
	overlay.draw_arc(marker, 9, 0, TAU, 24, TOOTH, 1, true)

## Pixel reticle: square brackets, a stepped plumb line and a blocky blade.
func _draw_voxel_marker(tooth: Vector3, marker: Vector2) -> void:
	var dark := Color(0, 0, 0, 0.6)
	if mode == "iso":
		var target := model.surface.height_at(Vector2(tooth.x, tooth.z))
		if is_finite(target):
			var foot := _project(Vector3(tooth.x, target, tooth.z))
			var line := clip_segment(marker, foot, _plot)
			if line.size() == 2:
				var length := line[0].distance_to(line[1])
				var direction := (line[1] - line[0]) / maxf(length, 0.001)
				var t := 4.0
				while t < length:
					overlay.draw_rect(Rect2((line[0] + direction * t).floor() - Vector2.ONE, Vector2(2, 2)), Color(TOOTH, 0.8))
					t += 5.0
			overlay.draw_rect(Rect2(foot.floor() - Vector2(3, 3), Vector2(6, 6)), TARGET, false, 2.0)
	var axis: Vector2 = bucket.axis
	var side := Vector3(-axis.y, 0, axis.x) * float(bucket.width) * 0.5
	var a := _project(tooth - side)
	var b := _project(tooth + side)
	overlay.draw_line(a, b, dark, 5)
	overlay.draw_line(a, b, TOOTH, 3)
	for end in [a, b]:
		overlay.draw_rect(Rect2(end.floor() - Vector2(2, 2), Vector2(4, 4)), TOOTH)
	var c := marker.floor()
	overlay.draw_rect(Rect2(c - Vector2(3, 3), Vector2(6, 6)), dark)
	overlay.draw_rect(Rect2(c - Vector2(2, 2), Vector2(4, 4)), TOOTH)
	for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		# Each bracket arm points back towards the tooth.
		var at: Vector2 = c + corner * 8 - Vector2(1, 1)
		overlay.draw_rect(Rect2(Vector2(at.x - (3 if corner.x > 0 else 0), at.y), Vector2(5, 2)), TOOTH)
		overlay.draw_rect(Rect2(Vector2(at.x, at.y - (3 if corner.y > 0 else 0)), Vector2(2, 5)), TOOTH)

# --- section charts ----------------------------------------------------------

func _profile_project(s: float, h: float) -> Vector2:
	return Vector2(_plot.position.x + (s - _distance_min) / (_distance_max - _distance_min) * _plot.size.x, _plot.end.y - (h - _height_min) / (_height_max - _height_min) * _plot.size.y)

func _clamped(s: float, h: float) -> Vector2:
	var point := _profile_project(s, h)
	point.y = clampf(point.y, _plot.position.y, _plot.end.y)
	return point

## Vertical bands between two curves; clamping both bounds to the plot is the
## exact clip for such regions, and indexed triangles avoid triangulation.
func _band(tops: PackedVector2Array, bottoms: PackedVector2Array, colors: PackedColorArray) -> void:
	if tops.size() < 2:
		return
	var points := PackedVector2Array()
	var vertex_colors := PackedColorArray()
	var indices := PackedInt32Array()
	for i in tops.size():
		points.append(tops[i])
		points.append(bottoms[i])
		vertex_colors.append(colors[i])
		vertex_colors.append(colors[i])
		if i > 0:
			var k := 2 * i
			indices.append_array(PackedInt32Array([k - 2, k - 1, k, k, k - 1, k + 1]))
	RenderingServer.canvas_item_add_triangle_array(get_canvas_item(), indices, points, vertex_colors)

func _polyline(points: PackedVector2Array, color: Color, width: float) -> void:
	if points.size() < 2:
		return
	var inside := true
	for point in points:
		if not _plot.grow(0.5).has_point(point):
			inside = false
			break
	if inside:
		draw_polyline(points, color, width, true)
		return
	for i in range(1, points.size()):
		var line := clip_segment(points[i - 1], points[i], _plot)
		if line.size() == 2:
			draw_line(line[0], line[1], color, width, true)

func _draw_profile() -> void:
	if profile.is_empty():
		_text(self, Vector2(22, size.y * 0.55), "等待有效铲齿与实测地表", MUTED)
		return
	_distance_min = profile.front().s
	_distance_max = profile.back().s
	if _distance_max - _distance_min < 0.001:
		_distance_max = _distance_min + 1
	if mode == "bucket" and not profile_bucket.is_empty():
		_height_min = profile_bucket.tooth.y - 2.5
		_height_max = profile_bucket.tooth.y + 2.5
	else:
		var bounds := model.surface.world_bounds()
		var surface_y: float = model.sampler.zone.layout.INITIAL_SURFACE_Y if is_instance_valid(model.sampler.zone) else bounds.end.y
		_height_min = minf(bounds.position.y, surface_y)
		_height_max = maxf(bounds.end.y, surface_y)
		for point in profile:
			if is_finite(point.actual):
				_height_min = minf(_height_min, point.actual)
				_height_max = maxf(_height_max, point.actual)
		var pad := maxf((_height_max - _height_min) * 0.12, 0.3)
		_height_min -= pad
		_height_max += pad
	var label_size := 9 if compact else 10
	var step := nice_step(_height_max - _height_min, 4 if compact else 6)
	for k in range(ceili(_height_min / step), floori(_height_max / step) + 1):
		var h := k * step
		var y := _profile_project(_distance_min, h).y
		draw_line(Vector2(_plot.position.x, y), Vector2(_plot.end.x, y), Color(0.7, 0.8, 0.88, 0.16) if compact else GRID, 1)
		_text(self, Vector2(2, y + 4), "%.2f" % h if step < 0.1 else "%.1f" % h, MUTED, label_size, HORIZONTAL_ALIGNMENT_RIGHT, _plot.position.x - 5)
	var s_step := nice_step(_distance_max - _distance_min, 6 if compact else 10)
	for k in range(ceili(_distance_min / s_step), floori(_distance_max / s_step) + 1):
		var x := _profile_project(k * s_step, _height_min).x
		draw_line(Vector2(x, _plot.end.y), Vector2(x, _plot.end.y - 4), MUTED, 1)
	if style == STYLE_VOXEL:
		_draw_voxel_profile(step * 0.5)
	else:
		_draw_smooth_profile()
	if mode == "bucket" and not profile_bucket.is_empty():
		var point := _profile_project(0, profile_bucket.tooth.y)
		if style == STYLE_VOXEL:
			# Blocky arrow: three shrinking rows of pixels pointing at the tooth.
			var p := point.floor()
			draw_dashed_line(Vector2(p.x, _plot.position.y), Vector2(p.x, _plot.end.y), Color(TOOTH, 0.35), 2, 4)
			for row in 3:
				var w := 14.0 - row * 5.0
				draw_rect(Rect2(p + Vector2(-w * 0.5 - 1, -12 + row * 4 - 1), Vector2(w + 2, 5)), Color(0, 0, 0, 0.5))
			for row in 3:
				var w := 14.0 - row * 5.0
				draw_rect(Rect2(p + Vector2(-w * 0.5, -12 + row * 4), Vector2(w, 3)), TOOTH)
		else:
			draw_dashed_line(Vector2(point.x, _plot.position.y), Vector2(point.x, _plot.end.y), Color(TOOTH, 0.35), 1, 4)
			draw_colored_polygon(PackedVector2Array([point + Vector2(-8, -11), point + Vector2(8, -11), point]), Color(0, 0, 0, 0.5))
			draw_colored_polygon(PackedVector2Array([point + Vector2(-7, -10), point + Vector2(7, -10), point]), TOOTH)
	var ends := ["机身侧", "外伸 →"] if mode == "bucket" else ["A", "A′"]
	_text(self, Vector2(_plot.position.x + 4, _plot.position.y + 12), ends[0], MUTED, label_size)
	_text(self, Vector2(_plot.position.x, _plot.position.y + 12), ends[1], MUTED, label_size, HORIZONTAL_ALIGNMENT_RIGHT, _plot.size.x - 4)
	var suffix := "铲齿 s=0" if mode == "bucket" else "中心线 +Z"
	_text(self, Vector2(12, size.y - 7 if compact else size.y - 12), "标高 m · 刻度 %s m · %.1f → %.1f m · %s" % [str(s_step), _distance_min, _distance_max, suffix], MUTED, 10 if compact else 11)

func _draw_smooth_profile() -> void:
	# Measured ground as a solid body, then the signed difference band.
	var runs: Array = [[]]
	for point in profile:
		if is_finite(point.actual):
			(runs.back() as Array).append(point)
		elif not (runs.back() as Array).is_empty():
			runs.append([])
	for run: Array in runs:
		var tops := PackedVector2Array()
		var bottoms := PackedVector2Array()
		var colors := PackedColorArray()
		for point in run:
			tops.append(_clamped(point.s, point.actual))
			bottoms.append(Vector2(tops[-1].x, _plot.end.y))
			colors.append(Color(SOIL_BODY, 0.55))
		_band(tops, bottoms, colors)
	var band_tops := PackedVector2Array()
	var band_bottoms := PackedVector2Array()
	var band_colors := PackedColorArray()
	for i in profile.size():
		var p := profile[i]
		if not (is_finite(p.actual) and is_finite(p.target)):
			_band(band_tops, band_bottoms, band_colors)
			band_tops.clear()
			band_bottoms.clear()
			band_colors.clear()
			continue
		var d: float = p.actual - p.target
		if not band_tops.is_empty():
			var q := profile[i - 1]
			var dq: float = q.actual - q.target
			if d * dq < 0:
				var t := dq / (dq - d)
				var crossing := _clamped(lerpf(q.s, p.s, t), lerpf(q.target, p.target, t))
				band_tops.append(crossing)
				band_bottoms.append(crossing)
				band_colors.append(Color(GRADE, 0.6))
		band_tops.append(_clamped(p.s, p.actual))
		band_bottoms.append(_clamped(p.s, p.target))
		band_colors.append(Color(difference_color(d), 0.6))
	_band(band_tops, band_bottoms, band_colors)
	for channel in ["target", "actual"]:
		var line := PackedVector2Array()
		for point in profile:
			if is_finite(point[channel]):
				line.append(_profile_project(point.s, point[channel]))
			else:
				_polyline(line, SOIL if channel == "actual" else TARGET, 2)
				line.clear()
		_polyline(line, SOIL if channel == "actual" else TARGET, 2)

## Accumulates axis-aligned rects for one batched triangle-array submit.
var _rect_points := PackedVector2Array()
var _rect_colors := PackedColorArray()
var _rect_indices := PackedInt32Array()

func _push_rect(x0: float, y0: float, x1: float, y1: float, color: Color) -> void:
	if y1 - y0 < 0.5 or x1 - x0 < 0.5:
		return
	var base := _rect_points.size()
	_rect_points.append_array(PackedVector2Array([Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(x0, y1)]))
	_rect_colors.append_array(PackedColorArray([color, color, color, color]))
	_rect_indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))

## Section as pixel columns: strata soil body, a stepped colour block for the
## signed difference and staircase design/ground edges. All columns go to the
## GPU as one triangle array.
func _draw_voxel_profile(strata: float) -> void:
	_rect_points = PackedVector2Array()
	_rect_colors = PackedColorArray()
	_rect_indices = PackedInt32Array()
	var n := profile.size()
	var column := _plot.size.x / maxf(n - 1, 1)
	var gap := 1.0 if column >= 4 else 0.0
	var top_y := _plot.position.y
	var bottom_y := _plot.end.y
	var stairs: Array[PackedVector2Array] = [PackedVector2Array()]
	for i in n:
		var p := profile[i]
		var cx := _profile_project(p.s, _height_min).x
		var x0 := roundf(clampf(cx - column * 0.5, _plot.position.x, _plot.end.x))
		var x1 := roundf(clampf(cx + column * 0.5, _plot.position.x, _plot.end.x)) - gap
		var has_target := is_finite(p.target)
		var ty := roundf(clampf(_profile_project(p.s, p.target).y, top_y, bottom_y)) if has_target else NAN
		var stair: PackedVector2Array = stairs.back()
		if has_target:
			# Staircase design line: horizontal treads joined by risers.
			if not stair.is_empty() and stair[-1].y != ty:
				stair.append(Vector2(x0, stair[-1].y))
			stair.append(Vector2(x0, ty))
			stair.append(Vector2(x1 + gap, ty))
			stairs[-1] = stair
		elif not stair.is_empty():
			stairs.append(PackedVector2Array())
		if not is_finite(p.actual):
			_push_rect(x0, roundf(bottom_y - 3), x1, bottom_y, UNKNOWN)
			continue
		var ay := roundf(clampf(_profile_project(p.s, p.actual).y, top_y, bottom_y))
		# Strata bands sit at fixed world elevations, so they stay put while
		# the surface above them is dug away.
		var k := mini(floori(p.actual / strata), ceili(_height_max / strata))
		var y := ay
		while y < bottom_y:
			# Clamp after snapping: rounding a fractional bottom down would
			# otherwise leave y below bottom_y forever once strata are offscreen.
			var next := clampf(roundf(_profile_project(p.s, k * strata).y), top_y, bottom_y)
			_push_rect(x0, y, x1, next, Color(SOIL_LIGHT if posmod(k, 2) == 0 else SOIL_DARK, 0.62))
			y = maxf(y, next)
			k -= 1
		if has_target:
			var d: float = p.actual - p.target
			var color := stepped_color(d)
			if stepped_band(d) == 0:
				_push_rect(x0, ty - 1, x1, ty + 2, GRADE)
			else:
				_push_rect(x0, minf(ay, ty), x1, maxf(ay, ty), Color(color, 0.82))
		_push_rect(x0, ay, x1, ay + 2, SOIL.lightened(0.15))
	if not _rect_indices.is_empty():
		RenderingServer.canvas_item_add_triangle_array(get_canvas_item(), _rect_indices, _rect_points, _rect_colors)
	for stair in stairs:
		if stair.size() >= 2:
			draw_polyline(stair, Color(0, 0, 0, 0.5), 4)
			draw_polyline(stair, TARGET, 2)

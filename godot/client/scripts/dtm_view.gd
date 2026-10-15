class_name DtmView
extends Control

const TARGET := Color("62d9e8")
const SOIL := Color("d9b98b")
const CUT := Color("ee9b55")
const FILL := Color("648ff0")
const GRADE := Color("55edb0")
const TOOTH := Color("ffe49a")
const MUTED := Color("8298ab")
const TEXT := Color("e2edf5")
const COLOR_STOPS := [0.05, 0.20, 0.60, 1.50, 3.0]
const CUT_PALETTE := [Color("fff1a6"), Color("ffd24a"), Color("ff952e"), Color("f45c43"), Color("cc3560")]
const FILL_PALETTE := [Color("b4ecff"), Color("58cfff"), Color("3797fa"), Color("5964ef"), Color("8551cf")]
const CELL_CORNERS := [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
var mode := "iso"
var model: DtmModel
var bucket: Dictionary = {}
var profile: Array[Dictionary] = []
var profile_bucket: Dictionary = {}
var accent := TARGET
var compact := false
var last_draw_usec := 0
var _target_mesh: ArrayMesh
var _target_surface: RefCounted
var _cells_mesh: ArrayMesh
var _cells_revision := -1
var _map_low := 0.0
var _map_high := 0.0
var mesh_build_count := 0

var _plot := Rect2()
var _center := Vector3.ZERO
var _scale := 1.0
var _height_min := 0.0
var _height_max := 1.0
var _distance_min := 0.0
var _distance_max := 1.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	custom_minimum_size = Vector2(200, 120)

func set_compact(enabled: bool) -> void:
	compact = enabled
	custom_minimum_size = Vector2(200, 100 if enabled else 120)
	queue_redraw()

static func difference_color(difference: float) -> Color:
	if not is_finite(difference):
		return Color("425061")
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

func _text(at: Vector2, text: String, color := TEXT, font_size := 12) -> void:
	if compact:
		draw_string(get_theme_default_font(), at + Vector2.ONE, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0, 0, 0, 0.8))
	draw_string(get_theme_default_font(), at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _draw() -> void:
	var draw_started := Time.get_ticks_usec()
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.14, 0.15, 0.16, 0.42) if compact else Color("101d29")
	box.border_color = Color(0.65, 0.72, 0.76, 0.2) if compact else Color("294052")
	box.set_border_width_all(1)
	box.set_corner_radius_all(9)
	draw_style_box(box, Rect2(Vector2.ZERO, size))
	var titles := {"iso": "01  /  2.5D 正交总览", "plan": "02  /  俯视 · 挖填偏差", "section": "03  /  施工纵断面 A—A", "bucket": "04  /  铲齿跟随垂向截面"}
	draw_line(Vector2(12, 9 if compact else 16), Vector2(12, 22 if compact else 30), accent, 2)
	_text(Vector2(21, 21 if compact else 28), titles.get(mode, mode), TEXT, 12 if compact else 14)
	_plot = Rect2(Vector2(34 if compact else 42, 30 if compact else 47), Vector2(maxf(size.x - (46 if compact else 60), 1), maxf(size.y - (49 if compact else 79), 1)))
	if model == null or model.surface == null:
		_text(Vector2(22, size.y * 0.55), "导入 LandXML 或选择训练设计", MUTED)
		return
	if mode in ["iso", "plan"]:
		_draw_map()
	else:
		_draw_profile()
	last_draw_usec = Time.get_ticks_usec() - draw_started

func _project(p: Vector3) -> Vector2:
	var local := p - _center
	if mode == "plan":
		return _plot.get_center() + Vector2(local.x, -local.z) * _scale
	return _plot.get_center() + Vector2((local.x - local.z) * 0.8660254, (local.x + local.z) * 0.38 - local.y) * _scale

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
		_scale = minf(_plot.size.x / maxf((bounds.size.x + bounds.size.z) * 0.866 + 1, 2), _plot.size.y / maxf((bounds.size.x + bounds.size.z) * 0.38 + high - low + 1, 2))
	# Bounded work even for survey files spanning millions of metres.
	var grid_step := grid_step_for(bounds.size)
	if mode == "iso":
		_draw_target_surface() # Opaque measured blocks cover the design edges.
	if _cells_mesh != null:
		draw_mesh(_cells_mesh, null, Transform2D(Vector2(_scale, 0), Vector2(0, _scale), _project(model.surface.translation)))
	if mode == "plan":
		_draw_target_surface()
		for ix in range(floori(bounds.position.x / grid_step), ceili(bounds.end.x / grid_step) + 1):
			var x := ix * grid_step
			draw_line(_project(Vector3(x, low, bounds.position.z)), _project(Vector3(x, low, bounds.end.z)), Color("233747"), 1)
		for iz in range(floori(bounds.position.z / grid_step), ceili(bounds.end.z / grid_step) + 1):
			var z := iz * grid_step
			draw_line(_project(Vector3(bounds.position.x, low, z)), _project(Vector3(bounds.end.x, low, z)), Color("233747"), 1)
		if not profile_bucket.is_empty():
			var tooth: Vector3 = profile_bucket.tooth
			var axis: Vector2 = profile_bucket.axis
			var reach := Vector3(axis.x, 0, axis.y) * 3.0
			var line := clip_segment(_project(tooth - reach), _project(tooth + reach), _plot)
			if line.size() == 2:
				draw_dashed_line(line[0], line[1], Color(TOOTH, 0.45), 1.0, 3)
		var cx := bounds.get_center().x
		draw_dashed_line(_project(Vector3(cx, low, bounds.position.z)), _project(Vector3(cx, low, bounds.end.z)), TEXT, 1, 5)
		_text(Vector2(size.x - 60, 53), "+Z ↑", MUTED)
		_text(Vector2(size.x - 60, 69), "+X →", MUTED)
	if not bucket.is_empty():
		var tooth: Vector3 = bucket.tooth
		var marker := _project(tooth)
		if _plot.has_point(marker):
			draw_circle(marker, 5, TOOTH)
			draw_arc(marker, 9, 0, TAU, 24, TOOTH, 1, true)
			var axis: Vector2 = bucket.axis
			var side := Vector3(-axis.y, 0, axis.x) * float(bucket.width) * 0.5
			draw_line(_project(tooth - side), _project(tooth + side), TOOTH, 2, true)
	_text(Vector2(12, size.y - 7 if compact else size.y - 12), "青色三角网：目标 · 色块：实测" if mode == "iso" else "白虚线 A—A · 浅黄虚线 铲齿截面", MUTED, 10 if compact else 11)

func _rebuild_cells() -> void:
	_cells_revision = model.display_revision
	mesh_build_count += 1
	var bounds := model.surface.world_bounds()
	_map_low = bounds.position.y
	_map_high = bounds.end.y
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var half := model.cell_size * (0.5 if mode == "plan" else 0.39)
	for sample in model.samples:
		if is_finite(sample.actual):
			_map_low = minf(_map_low, sample.actual)
			_map_high = maxf(_map_high, sample.actual)
		if not is_finite(sample.target):
			continue
		var p: Vector2 = sample.xz
		var height: float = sample.actual if is_finite(sample.actual) and mode == "iso" else sample.target
		var color := difference_color(sample.actual - sample.target)
		color.a = 0.48 if mode == "plan" else 1.0
		var base := vertices.size()
		for corner in CELL_CORNERS:
			var local := Vector3(p.x + corner.x * half.x, height, p.y + corner.y * half.y) - model.surface.translation
			vertices.append(Vector3(local.x, -local.z, 0) if mode == "plan" else Vector3((local.x - local.z) * 0.8660254, (local.x + local.z) * 0.38 - local.y, 0))
			colors.append(color)
		indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	_cells_mesh = null
	if vertices.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	_cells_mesh = ArrayMesh.new()
	_cells_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

func _draw_target_surface() -> void:
	# Cache unique TIN edges in a single line mesh; shared edges are drawn
	# once so the internal diagonal is not brighter than the perimeter.
	if _target_surface != model.surface:
		_target_surface = model.surface
		_target_mesh = ArrayMesh.new()
		var vertices := PackedVector3Array()
		for vertex in model.surface.vertices:
			vertices.append(Vector3(vertex.x, -vertex.z, 0) if mode == "plan" else Vector3((vertex.x - vertex.z) * 0.8660254, (vertex.x + vertex.z) * 0.38 - vertex.y, 0))
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
	var origin := _project(model.surface.translation)
	draw_mesh(_target_mesh, null, Transform2D(Vector2(_scale, 0), Vector2(0, _scale), origin), Color(TARGET, 0.7))

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

func _profile_line(a: Vector2, b: Vector2, color: Color) -> void:
	var line := clip_segment(a, b, _plot)
	if line.size() == 2:
		draw_line(line[0], line[1], color, 2, true)

func _profile_fill(poly: PackedVector2Array, color: Color) -> void:
	var contained := true
	for point in poly:
		if not _plot.has_point(point):
			contained = false
			break
	if contained:
		draw_colored_polygon(poly, Color(color, 0.28))
		return
	var rect := PackedVector2Array([_plot.position, Vector2(_plot.end.x, _plot.position.y), _plot.end, Vector2(_plot.position.x, _plot.end.y)])
	for clipped in Geometry2D.intersect_polygons(poly, rect):
		if clipped.size() >= 3:
			draw_colored_polygon(clipped, Color(color, 0.28))

func _profile_project(s: float, h: float) -> Vector2:
	return Vector2(_plot.position.x + (s - _distance_min) / (_distance_max - _distance_min) * _plot.size.x, _plot.end.y - (h - _height_min) / (_height_max - _height_min) * _plot.size.y)

func _draw_profile() -> void:
	if profile.is_empty():
		_text(Vector2(22, size.y * 0.55), "等待有效铲齿与实测地表", MUTED)
		return
	_distance_min = profile.front().s
	_distance_max = profile.back().s
	var bounds := model.surface.world_bounds()
	_height_min = minf(bounds.position.y - 0.5, model.sampler.zone.layout.INITIAL_SURFACE_Y - 0.5)
	_height_max = maxf(bounds.end.y + 0.5, model.sampler.zone.layout.INITIAL_SURFACE_Y + 0.5)
	if mode == "bucket" and not profile_bucket.is_empty():
		_height_min = profile_bucket.tooth.y - 2.5
		_height_max = profile_bucket.tooth.y + 2.5
	for i in 5:
		var h := lerpf(_height_min, _height_max, i / 4.0)
		var at := _profile_project(_distance_min, h)
		draw_line(at, Vector2(_plot.end.x, at.y), Color("294052"), 1)
		_text(Vector2(4, at.y + 4), "%.1f" % h, MUTED, 10)
	for i in range(1, profile.size()):
		var a := profile[i - 1]
		var b := profile[i]
		if is_finite(a.actual) and is_finite(b.actual) and is_finite(a.target) and is_finite(b.target):
			var da: float = a.actual - a.target
			var db: float = b.actual - b.target
			if da * db < 0:
				var t := da / (da - db)
				var crossing := _profile_project(lerpf(a.s, b.s, t), lerpf(a.target, b.target, t))
				_profile_fill(PackedVector2Array([_profile_project(a.s, a.actual), crossing, _profile_project(a.s, a.target)]), difference_color(da))
				_profile_fill(PackedVector2Array([crossing, _profile_project(b.s, b.actual), _profile_project(b.s, b.target)]), difference_color(db))
			elif absf(da) + absf(db) > 0.00001:
				_profile_fill(PackedVector2Array([_profile_project(a.s, a.actual), _profile_project(b.s, b.actual), _profile_project(b.s, b.target), _profile_project(a.s, a.target)]), difference_color((da + db) * 0.5))
		for channel in ["actual", "target"]:
			if is_finite(a[channel]) and is_finite(b[channel]):
				_profile_line(_profile_project(a.s, a[channel]), _profile_project(b.s, b[channel]), SOIL if channel == "actual" else TARGET)
	if mode == "bucket" and not profile_bucket.is_empty():
		var point := _profile_project(0, profile_bucket.tooth.y)
		draw_dashed_line(Vector2(point.x, _plot.position.y), Vector2(point.x, _plot.end.y), Color(TOOTH, 0.3), 1, 4)
		draw_colored_polygon(PackedVector2Array([point + Vector2(-7, -10), point + Vector2(7, -10), point]), TOOTH)

	var suffix := " · 铲齿 s=0" if mode == "bucket" else " · 中心线"
	_text(Vector2(12, size.y - 7 if compact else size.y - 12), "标高 m · %.1f → %.1f m%s" % [_distance_min, _distance_max, suffix], MUTED, 10 if compact else 11)

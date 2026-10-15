class_name DtmModel
extends RefCounted

const Surface := preload("res://scripts/landxml_surface.gd")
const Sampler := preload("res://scripts/dtm_surface_sampler.gd")
const TOLERANCE_M := 0.05
const SAMPLES_PER_FRAME := 96
const SAMPLE_BUDGET_USEC := 1500

var surface: Surface
var sampler := Sampler.new()
var samples: Array[Dictionary] = []
var statistics: Dictionary = {}
var grid_size := Vector2i.ZERO
var cell_size := Vector2.ZERO
var sampled_at_ms := 0
var sampled_revision := -1
var sampling := false
var identity_provider := Callable()
var display_revision := 0
var focus_xz := Vector2.ZERO
var _order: Array[int] = []
var _last_publish_ms := 0
var current_revision := -1
var current_generation := ""
var _cursor := 0
var _generation := ""
var _revision := -1
var _next_refresh_ms := 0

func set_surface(value: Surface) -> void:
	surface = value
	invalidate()

func invalidate() -> void:
	samples.clear()
	_order.clear()
	statistics.clear()
	_cursor = 0
	sampling = false
	sampled_at_ms = 0
	sampled_revision = -1
	_revision = -1
	_next_refresh_ms = 0
	display_revision += 1

func update() -> void:
	if surface == null or not is_instance_valid(sampler.zone):
		return
	var identity: Dictionary = identity_provider.call() if identity_provider.is_valid() else {}
	var generation := "%s:%s:%s" % [sampler.zone.readiness.generation, identity.get("world_generation", -1), identity.get("authority_generation", -1)]
	var revision: int = int(identity.get("data_revision", sampler.zone.readiness.revision))
	if generation != _generation:
		invalidate()
		_generation = generation
		current_generation = generation
		current_revision = revision
		return
	current_generation = generation
	current_revision = revision
	if not sampling:
		if sampled_at_ms > 0 and sampled_revision == revision and float(statistics.get("coverage", 0)) == 1.0:
			return
		# Changed terrain never waits behind the missing-data retry timer.
		if sampled_revision == revision and Time.get_ticks_msec() < _next_refresh_ms:
			return
		_revision = revision
		var bounds := surface.world_bounds()
		grid_size = Vector2i(clampi(ceili(bounds.size.x / 0.25), 1, 48), clampi(ceili(bounds.size.z / 0.25), 1, 48))
		cell_size = Vector2(bounds.size.x / grid_size.x, bounds.size.z / grid_size.y)
		if samples.is_empty():
			for z in grid_size.y:
				for x in grid_size.x:
					var p := Vector2(bounds.position.x + (x + 0.5) * cell_size.x, bounds.position.z + (z + 0.5) * cell_size.y)
					samples.append({"xz": p, "target": NAN, "actual": NAN, "target_ready": false})
		_order.clear()
		# A small local tile first, then a linear sweep. No per-sweep O(n log n)
		# sort or repeated TIN queries for an unchanged design.
		var fx := clampi(floori((focus_xz.x - bounds.position.x) / cell_size.x), 0, grid_size.x - 1)
		var fz := clampi(floori((focus_xz.y - bounds.position.z) / cell_size.y), 0, grid_size.y - 1)
		var priority := {}
		for z in range(maxi(0, fz - 3), mini(grid_size.y, fz + 4)):
			for x in range(maxi(0, fx - 3), mini(grid_size.x, fx + 4)):
				var index := z * grid_size.x + x
				priority[index] = true
				_order.append(index)
		for i in samples.size():
			if not priority.has(i):
				_order.append(i)
		_cursor = 0
		sampling = true
	var started := Time.get_ticks_usec()
	for count in SAMPLES_PER_FRAME:
		if count > 0 and Time.get_ticks_usec() - started >= SAMPLE_BUDGET_USEC:
			break
		if _cursor >= _order.size():
			break
		var value := samples[_order[_cursor]]
		if not value.target_ready:
			value.target = surface.height_at(value.xz)
			value.target_ready = true
		value.actual = sampler.height_at(value.xz) if is_finite(value.target) else NAN
		_cursor += 1
	var complete := _cursor >= _order.size()
	var now := Time.get_ticks_msec()
	if complete or _cursor <= SAMPLES_PER_FRAME or now - _last_publish_ms >= 50:
		display_revision += 1
		_last_publish_ms = now
	if complete:
		statistics = summarize(samples, cell_size.x * cell_size.y)
		statistics["mixed_revision"] = revision != _revision
		sampled_revision = _revision
		sampled_at_ms = now
		sampling = false
		_next_refresh_ms = now + 250

static func summarize(values: Array[Dictionary], area: float) -> Dictionary:
	var cut := 0.0
	var fill := 0.0
	var valid := 0
	var designed := 0
	var on_grade := 0
	for value in values:
		if not is_finite(value.target):
			continue
		designed += 1
		if not is_finite(value.actual):
			continue
		valid += 1
		var difference: float = value.actual - value.target
		cut += maxf(difference, 0) * area
		fill += maxf(-difference, 0) * area
		if absf(difference) <= TOLERANCE_M:
			on_grade += 1
	return {"cut_m3": cut, "fill_m3": fill, "valid": valid, "designed": designed, "coverage": float(valid) / maxi(designed, 1), "on_grade": float(on_grade) / maxi(valid, 1), "area_m2": valid * area}

func cached_height(p: Vector2) -> float:
	if surface == null or samples.is_empty():
		return NAN
	var bounds := surface.world_bounds()
	var x := floori((p.x - bounds.position.x) / cell_size.x)
	var z := floori((p.y - bounds.position.z) / cell_size.y)
	if x < 0 or z < 0 or x >= grid_size.x or z >= grid_size.y:
		return NAN
	return float(samples[z * grid_size.x + x].actual)

static func bucket_state(presentation: MotionPresentation) -> Dictionary:
	if not is_instance_valid(presentation):
		return {}
	var cutting: Dictionary = presentation.get_soil_contract().get("proxies", {}).get("cutting_edge", {})
	var center: Array = cutting.get("center_godot", [])
	var frame := presentation.get_soil_frame_node(String(cutting.get("frame", "bucket_link")))
	if frame == null or center.size() != 3:
		return {}
	var tooth := frame.global_transform * Vector3(float(center[0]), float(center[1]), float(center[2]))
	var upper := presentation.get_frame_node("upper_structure_link")
	var axis := Vector2(0, 1)
	if upper != null:
		# Asset forward axes differ. Use the physical upper-to-tooth direction,
		# independent of curl and of the chassis heading while slewing.
		var outward := tooth - upper.global_position
		var projected := Vector2(outward.x, outward.z)
		if projected.length_squared() > 0.0001:
			axis = projected.normalized()
		else:
			return {} # Vertical/undefined section, not an invented heading.
	return {"tooth": tooth, "width": float(cutting.get("half_width_m", 0.0)) * 2.0, "axis": axis}

static func demo_xml(kind: String, center: Vector3, bucket_width: float) -> String:
	# A design floor footprint, not a terrain edit. Walls are the footprint
	# boundary; a vertical wall cannot be represented by a heightfield TIN.
	var width := 6.0 if kind == "pit" else bucket_width
	var length := 6.0 if kind == "pit" else 12.0
	var depth := 1.5 if kind == "pit" else 1.0
	var name := "中心方坑 6×6 m · 深 1.5 m" if kind == "pit" else "中心沟槽 %.2f×12 m · 深 1 m" % width
	var xml := '<?xml version="1.0" encoding="UTF-8"?><LandXML version="1.2"><Units><Metric linearUnit="meter"/></Units><Surfaces><Surface name="%s"><Definition surfType="TIN"><Pnts>' % name
	var corners := [Vector2(-width, -length), Vector2(width, -length), Vector2(width, length), Vector2(-width, length)]
	for i in 4:
		var p: Vector2 = corners[i] * 0.5
		xml += '<P id="%d">%.6f %.6f %.6f</P>' % [i + 1, center.z + p.y, center.x + p.x, center.y - depth]
	return xml + '</Pnts><Faces><F>1 2 3</F><F>1 3 4</F></Faces></Definition></Surface></Surfaces></LandXML>'

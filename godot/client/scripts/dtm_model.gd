class_name DtmModel
extends RefCounted

const Surface := preload("res://scripts/landxml_surface.gd")
const Sampler := preload("res://scripts/dtm_surface_sampler.gd")
const TOLERANCE_M := 0.05
const MAX_GRID := 48
const TARGET_SPACING_M := 0.25
const SAMPLES_PER_FRAME := 192
const SAMPLE_BUDGET_USEC := 1500
const FOCUS_RADIUS := 3
const CUT_TEXT := Color("ffb35c")
const FILL_TEXT := Color("7fb6ff")

var surface: Surface
var sampler := Sampler.new()
## Row-major grid (index = z * grid_size.x + x). NAN = no target / unknown.
var targets := PackedFloat32Array()
var actuals := PackedFloat32Array()
var statistics: Dictionary = {}
var grid_size := Vector2i.ZERO
var cell_size := Vector2.ZERO
var grid_origin := Vector2.ZERO
var sampled_at_ms := 0
var sampled_revision := -1
var sampling := false
var identity_provider := Callable()
var display_revision := 0
var focus_xz := Vector2.ZERO
var current_revision := -1
var current_generation := ""
var _rows_with_target := PackedByteArray()
## Each job is Vector3i(row, first column, end column), sampled as one batch.
var _jobs: Array[Vector3i] = []
var _cursor := 0
var _last_publish_ms := 0
var _generation := ""
var _revision := -1
var _next_refresh_ms := 0

func set_surface(value: Surface) -> void:
	surface = value
	invalidate()

func invalidate() -> void:
	targets = PackedFloat32Array()
	actuals = PackedFloat32Array()
	_rows_with_target = PackedByteArray()
	_jobs.clear()
	statistics.clear()
	_cursor = 0
	sampling = false
	sampled_at_ms = 0
	sampled_revision = -1
	_revision = -1
	_next_refresh_ms = 0
	display_revision += 1

func is_empty() -> bool:
	return actuals.is_empty()

func cell_center(index: int) -> Vector2:
	return grid_origin + Vector2((index % grid_size.x + 0.5) * cell_size.x, (index / grid_size.x + 0.5) * cell_size.y)

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
		if actuals.is_empty():
			_allocate_grid()
		_plan_jobs()
		_cursor = 0
		sampling = true
	var started := Time.get_ticks_usec()
	var first_frame := _cursor == 0
	var sampled := 0
	# Whole job batches: one SDF copy per row run. Always finish at least one.
	while _cursor < _jobs.size() and sampled < SAMPLES_PER_FRAME:
		if sampled > 0 and Time.get_ticks_usec() - started >= SAMPLE_BUDGET_USEC:
			break
		sampled += _run_job(_jobs[_cursor])
		_cursor += 1
	var complete := _cursor >= _jobs.size()
	var now := Time.get_ticks_msec()
	if complete or first_frame or now - _last_publish_ms >= 50:
		display_revision += 1
		_last_publish_ms = now
	if complete:
		statistics = summarize(targets, actuals, cell_size.x * cell_size.y)
		statistics["mixed_revision"] = revision != _revision
		sampled_revision = _revision
		sampled_at_ms = now
		sampling = false
		_next_refresh_ms = now + 250

func _allocate_grid() -> void:
	var bounds := surface.world_bounds()
	grid_size = Vector2i(clampi(ceili(bounds.size.x / TARGET_SPACING_M), 1, MAX_GRID), clampi(ceili(bounds.size.z / TARGET_SPACING_M), 1, MAX_GRID))
	cell_size = Vector2(bounds.size.x / grid_size.x, bounds.size.z / grid_size.y)
	grid_origin = Vector2(bounds.position.x, bounds.position.z)
	var count := grid_size.x * grid_size.y
	targets.resize(count)
	targets.fill(NAN)
	actuals.resize(count)
	actuals.fill(NAN)
	_rows_with_target.resize(grid_size.y)
	_rows_with_target.fill(0)

func _plan_jobs() -> void:
	# The working face first (a 7x7 tile as short row runs), then full rows.
	# Rows with no design target after their first pass are skipped forever.
	_jobs.clear()
	var fx := clampi(floori((focus_xz.x - grid_origin.x) / cell_size.x), 0, grid_size.x - 1)
	var fz := clampi(floori((focus_xz.y - grid_origin.y) / cell_size.y), 0, grid_size.y - 1)
	var x0 := maxi(0, fx - FOCUS_RADIUS)
	var x1 := mini(grid_size.x, fx + FOCUS_RADIUS + 1)
	var z0 := maxi(0, fz - FOCUS_RADIUS)
	var z1 := mini(grid_size.y, fz + FOCUS_RADIUS + 1)
	for z in range(z0, z1):
		if _rows_with_target[z] != 2:
			_jobs.append(Vector3i(z, x0, x1))
	for z in grid_size.y:
		if _rows_with_target[z] == 2:
			continue
		if z < z0 or z >= z1:
			_jobs.append(Vector3i(z, 0, grid_size.x))
			continue
		# Focus rows: only the remainder outside the tile already queued.
		if x0 > 0:
			_jobs.append(Vector3i(z, 0, x0))
		if x1 < grid_size.x:
			_jobs.append(Vector3i(z, x1, grid_size.x))

func _run_job(job: Vector3i) -> int:
	var row_base := job.x * grid_size.x
	if _rows_with_target[job.x] == 0:
		# Target heights depend only on the design: query each row once.
		var any := false
		for x in grid_size.x:
			var target := surface.height_at(cell_center(row_base + x))
			targets[row_base + x] = target
			any = any or is_finite(target)
		_rows_with_target[job.x] = 1 if any else 2
	if _rows_with_target[job.x] == 2:
		return 0
	var points := PackedVector2Array()
	var indices := PackedInt32Array()
	for x in range(job.y, job.z):
		var index := row_base + x
		if is_finite(targets[index]):
			points.append(cell_center(index))
			indices.append(index)
	var heights := sampler.heights_at(points)
	for i in indices.size():
		actuals[indices[i]] = heights[i]
	return points.size()

static func summarize(target_values: PackedFloat32Array, actual_values: PackedFloat32Array, area: float) -> Dictionary:
	var cut := 0.0
	var fill := 0.0
	var valid := 0
	var designed := 0
	var on_grade := 0
	for i in target_values.size():
		var target := target_values[i]
		if not is_finite(target):
			continue
		designed += 1
		var actual := actual_values[i]
		if not is_finite(actual):
			continue
		valid += 1
		var difference := actual - target
		cut += maxf(difference, 0) * area
		fill += maxf(-difference, 0) * area
		if absf(difference) <= TOLERANCE_M:
			on_grade += 1
	return {"cut_m3": cut, "fill_m3": fill, "valid": valid, "designed": designed, "coverage": float(valid) / maxi(designed, 1), "on_grade": float(on_grade) / maxi(valid, 1), "area_m2": valid * area}

## Bilinear between measured cell centres; falls back to the nearest cell at
## gaps so a section line never invents values across unknown data.
func cached_height(p: Vector2) -> float:
	if surface == null or actuals.is_empty():
		return NAN
	var gx := (p.x - grid_origin.x) / cell_size.x
	var gz := (p.y - grid_origin.y) / cell_size.y
	var nx := floori(gx)
	var nz := floori(gz)
	if nx < 0 or nz < 0 or nx >= grid_size.x or nz >= grid_size.y:
		return NAN
	var x0 := clampi(floori(gx - 0.5), 0, grid_size.x - 1)
	var z0 := clampi(floori(gz - 0.5), 0, grid_size.y - 1)
	var x1 := mini(x0 + 1, grid_size.x - 1)
	var z1 := mini(z0 + 1, grid_size.y - 1)
	var a := actuals[z0 * grid_size.x + x0]
	var b := actuals[z0 * grid_size.x + x1]
	var c := actuals[z1 * grid_size.x + x0]
	var d := actuals[z1 * grid_size.x + x1]
	if not (is_finite(a) and is_finite(b) and is_finite(c) and is_finite(d)):
		return actuals[nz * grid_size.x + nx]
	var tx := clampf(gx - 0.5 - x0, 0, 1)
	var tz := clampf(gz - 0.5 - z0, 0, 1)
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), tz)
## The soil contract is deep-copied on every read; callers polling each frame
## should cache this per machine/attachment and pass it to bucket_state.
static func cutting_contract(presentation: MotionPresentation) -> Dictionary:
	if not is_instance_valid(presentation):
		return {}
	return presentation.get_soil_contract().get("proxies", {}).get("cutting_edge", {})

static func bucket_state(presentation: MotionPresentation, cutting: Dictionary = {}) -> Dictionary:
	if not is_instance_valid(presentation):
		return {}
	if cutting.is_empty():
		cutting = cutting_contract(presentation)
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

class_name SurfaceJobPlanner
extends RefCounted

## World-space cutting cells grouped into bucket-width lanes and station spans.
## Unknown measurements invalidate the plan; fill cells never become work.
const TOLERANCE := 0.08
const MAX_CELLS := 20000

static func build(surface: LandXmlSurface, measure: Callable, origin: Vector3,
		axis: Vector3, bucket_width: float, reach: float, span := 1.0) -> Dictionary:
	if surface == null or not measure.is_valid() or not origin.is_finite() or not axis.is_finite() or not is_finite(bucket_width) or bucket_width <= 0 or not is_finite(reach) or reach <= 0 or not is_finite(span) or span <= 0:
		return {"error": "无效作业面或设备几何"}
	axis.y = 0
	if axis.length_squared() < 0.5:
		return {"error": "作业轴线不可用"}
	axis = axis.normalized()
	# Anchor lanes to the design, not tiny chassis yaw changes after driving.
	# Choose a design edge closest to the requested working direction.
	var aligned := axis
	var alignment := -1.0
	for face in surface.faces:
		for pair in [Vector2i(face.x, face.y), Vector2i(face.y, face.z), Vector2i(face.z, face.x)]:
			var edge: Vector3 = surface.vertices[pair.y] - surface.vertices[pair.x]
			edge.y = 0
			if edge.length_squared() < 0.000001:
				continue
			edge = edge.normalized()
			var score := absf(edge.dot(axis))
			if score > alignment:
				alignment = score
				aligned = edge if edge.dot(axis) >= 0 else -edge
	axis = aligned
	var side := Vector3(-axis.z, 0, axis.x)
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for vertex in surface.vertices:
		var offset: Vector3 = vertex + surface.translation - origin
		var p := Vector2(offset.dot(side), offset.dot(axis))
		low = low.min(p)
		high = high.max(p)
	var lanes := maxi(1, ceili((high.x - low.x) / bucket_width - 0.0001))
	var rows := maxi(1, ceili((high.y - low.y) / 0.2 - 0.0001))
	if lanes * rows > MAX_CELLS:
		return {"error": "作业面过大，请分区"}
	var lane_width := (high.x - low.x) / lanes
	var row_length := (high.y - low.y) / rows
	var stations: Dictionary = {}
	var verification := PackedVector3Array()
	var initial_heights := PackedFloat32Array()
	var cut_volume := 0.0
	for lane in lanes:
		for row in rows:
			var lateral := low.x + (lane + 0.5) * lane_width
			var along := high.y - (row + 0.5) * row_length
			var point := origin + side * lateral + axis * along
			var xz := Vector2(point.x, point.z)
			var target := surface.height_at(xz)
			if not is_finite(target):
				continue
			var actual := -INF
			# Subdivide each full bucket lane: its center alone cannot certify
			# the grade of the shoulders. Keep the samples for final remeasurement.
			var across := maxi(1, ceili(lane_width / 0.1))
			for k in across:
				var sample_point := point + side * (lane_width * ((k + 0.5) / across - 0.5))
				var sample_xz := Vector2(sample_point.x, sample_point.z)
				var sample_target := surface.height_at(sample_xz)
				if not is_finite(sample_target) or absf(sample_target - target) > TOLERANCE * 0.5:
					return {"error": "当前切削单元需要连续且横向平整的目标面，请缩小分区"}
				var measured: float = measure.call(sample_xz)
				if not is_finite(measured):
					return {"error": "作业面存在缺测或超出体素区"}
				actual = maxf(actual, measured)
				sample_point.y = sample_target
				verification.append(sample_point)
				initial_heights.append(measured)
			if not is_finite(actual):
				return {"error": "作业面存在缺测或超出体素区"}
			if actual - target <= TOLERANCE:
				continue
			var group := floori((high.y - along) / span)
			var key := Vector2i(lane, group)
			if not stations.has(key):
				var station := origin + side * lateral + axis * (high.y - group * span - reach)
				stations[key] = {"position": station, "axis": axis, "vertices": [], "complete": false,
					"retreat_row": group if lanes > 1 else -1}
			point.y = target
			stations[key].vertices.append({"target": point, "initial_height": actual, "lane_width": lane_width})
			cut_volume += (actual - target) * lane_width * row_length
	if verification.is_empty():
		return {"error": "没有可覆盖的施工单元，请检查目标范围与铲斗宽度"}
	# Every visible triangle must be represented, including narrow islands
	# missed by lane centers. Reject unsupported partitioning instead of
	# silently completing an incomplete plan.
	for face in surface.faces:
		var center: Vector3 = (surface.vertices[face.x] + surface.vertices[face.y] + surface.vertices[face.z]) / 3.0 + surface.translation
		var represented := false
		for p in verification:
			if Vector2(p.x - center.x, p.z - center.z).length() <= 0.2:
				represented = true
				break
		if not represented:
			return {"error": "目标包含无法覆盖的狭窄或离散三角面，请分区"}
	return {"stations": stations.values(), "verification": verification, "initial_heights": initial_heights, "cut_volume": cut_volume, "error": ""}

## Existing fill deficits are outside a cut-only job. Any additional loss
## below either the design or an already-low initial surface is still overcut.
static func grade_accepted(target: float, initial: float, measured: float) -> bool:
	return is_finite(target) and is_finite(initial) and is_finite(measured) \
		and measured <= target + TOLERANCE \
		and measured >= minf(target, initial) - TOLERANCE

static func nearest(stations: Array, position: Vector3) -> int:
	var best := -1
	var distance := INF
	# Wide cuts remove chassis support. Finish the far row before retreating
	# into the next one; nearest-neighbour selection applies within that row.
	var accessible_row := 2147483647
	for station in stations:
		if not bool(station.complete) and int(station.get("retreat_row", -1)) >= 0:
			accessible_row = mini(accessible_row, int(station.retreat_row))
	for index in stations.size():
		if bool(stations[index].complete):
			continue
		if int(stations[index].get("retreat_row", -1)) >= 0 and int(stations[index].retreat_row) != accessible_row:
			continue
		var p: Vector3 = stations[index].position
		var candidate := Vector2(p.x - position.x, p.z - position.z).length_squared()
		if candidate < distance:
			distance = candidate
			best = index
	return best

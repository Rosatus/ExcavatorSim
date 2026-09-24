extends RefCounted

## Transaction-local surface routing. Only incoming material moves; the sampled
## ground is immutable. Every parcel starts at the source column and can leave
## a column only across a downhill edge at the repose angle. No remote minimum
## can receive material without a continuous traversable path from the source.
const INITIAL_RADIUS := 8
const MAX_RADIUS := 128
const PARCEL_VOLUME_VOXELS := 0.125
const MAX_ROUTE_STEPS := 200000
const NEIGHBORS := [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1),
	Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]


static func plan(
	heights: PackedFloat64Array, side: int, source: Vector2, volume: float, slope: float
) -> Dictionary:
	if side < 3 or heights.size() != side * side or not source.is_finite() \
			or not is_finite(volume) or volume <= 0.0 or not is_finite(slope) or slope <= 0.0:
		return {}
	var sx := roundi(source.x)
	var sz := roundi(source.y)
	if sx < 0 or sz < 0 or sx >= side or sz >= side:
		return {}
	var start := sz * side + sx
	if not is_finite(heights[start]):
		return {}
	var surface := heights.duplicate()
	var additions := PackedFloat64Array()
	additions.resize(heights.size())
	var remaining := volume
	var steps := 0
	var cursor := start
	while remaining > 0.000000001 and steps < MAX_ROUTE_STEPS:
		steps += 1
		var x := cursor % side
		var z := cursor / side
		# We need the missing neighbours before deciding whether this parcel
		# can stop. The caller grows the domain and reruns this disposable plan.
		if x <= 1 or z <= 1 or x >= side - 2 or z >= side - 2:
			return {"boundary_active": true}
		var lowest := INF
		var next := -1
		for offset in NEIGHBORS:
			var neighbor: int = (z + offset.y) * side + x + offset.x
			var distance := 1.0 if offset.x == 0 or offset.y == 0 else sqrt(2.0)
			var threshold := surface[neighbor] + slope * distance
			if threshold < lowest:
				lowest = threshold
				next = neighbor
		if next >= 0 and surface[cursor] >= lowest - 0.000000001:
			cursor = next
			continue
		# Stop on supporting terrain until its repose capacity is consumed.
		# Bounded parcels keep alternative downhill routes responsive as the
		# receiving surface rises; no predetermined rim retention percentage.
		var added := minf(remaining, minf(PARCEL_VOLUME_VOXELS, lowest - surface[cursor]))
		surface[cursor] += added
		additions[cursor] += added
		remaining -= added
		cursor = start
	return {"additions": additions, "volume_voxels": volume - remaining,
		"boundary_active": false, "route_steps": steps, "budget_limited": remaining > 0.000000001}

class_name SoilDepositSurface
extends RefCounted

## A disposable surface plan, never a second terrain or a persistent pile ledger.
## Heights and volumes are in voxel units. The caller samples the current SDF
## again for every commit so excavation cannot resurrect an old pile.
const GRID_RADIUS := 8
const GRID_SIZE := GRID_RADIUS * 2 + 1
const GRID_STEP := 3
const SOLVE_STEPS := 18


static func plan(heights: PackedFloat32Array, volume: float, slope: float) -> Dictionary:
	if heights.size() != GRID_SIZE * GRID_SIZE or volume <= 0.0:
		return {}
	var costs := PackedFloat32Array()
	costs.resize(heights.size())
	var low := INF
	var ceiling := INF
	for z in GRID_SIZE:
		for x in GRID_SIZE:
			var i := z * GRID_SIZE + x
			var distance := Vector2(x - GRID_RADIUS, z - GRID_RADIUS).length() * GRID_STEP
			# Rounded apex, with the same asymptotic angle of repose.
			var radial := sqrt(distance * distance + 1.0) - 1.0
			costs[i] = heights[i] + slope * radial
			low = minf(low, costs[i])
			if x <= 1 or z <= 1 or x >= GRID_SIZE - 2 or z >= GRID_SIZE - 2:
				ceiling = minf(ceiling, costs[i])
	if not is_finite(low) or not is_finite(ceiling) or ceiling <= low:
		return {}
	var high := minf(ceiling, low + volume / float(GRID_STEP * GRID_STEP) + 1.0)
	for iteration in SOLVE_STEPS:
		var middle := (low + high) * 0.5
		var used := 0.0
		for i in costs.size():
			used += maxf(0.0, middle - costs[i]) * GRID_STEP * GRID_STEP
		if used > volume:
			high = middle
		else:
			low = middle
	var additions := PackedFloat32Array()
	additions.resize(heights.size())
	var accepted := 0.0
	for i in costs.size():
		additions[i] = maxf(0.0, low - costs[i])
		accepted += additions[i] * GRID_STEP * GRID_STEP
	return {"additions": additions, "volume_voxels": accepted}


static func interpolate(values: PackedFloat32Array, x: int, z: int) -> float:
	var gx := clampi(x / GRID_STEP, 0, GRID_SIZE - 2)
	var gz := clampi(z / GRID_STEP, 0, GRID_SIZE - 2)
	var tx := clampf(float(x - gx * GRID_STEP) / GRID_STEP, 0.0, 1.0)
	var tz := clampf(float(z - gz * GRID_STEP) / GRID_STEP, 0.0, 1.0)
	var i := gz * GRID_SIZE + gx
	return lerpf(lerpf(values[i], values[i + 1], tx),
		lerpf(values[i + GRID_SIZE], values[i + GRID_SIZE + 1], tx), tz)

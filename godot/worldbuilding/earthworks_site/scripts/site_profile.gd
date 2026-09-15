extends RefCounted

const REGION_SIZE := 64
const VOXEL_SCALE := 0.25
const VOXEL_BOUNDS := AABB(Vector3(0, -64, 0), Vector3(256, 80, 256))
const EDITABLE_BOUNDS := AABB(Vector3(3, -12, 3), Vector3(58, 16, 58))
const CENTER := Vector2(32, 32)
const ROAD_WIDTH := 9.0
const CORNER_RADIUS := 15.0


static func road_distance(p: Vector2) -> float:
	# Rounded square center line, enclosing the complete voxel cell.
	var q := (p - CENTER).abs() - Vector2(32, 32)
	return absf(Vector2(maxf(q.x, 0), maxf(q.y, 0)).length() + minf(maxf(q.x, q.y), 0) - CORNER_RADIUS)


static func is_road(p: Vector2) -> bool:
	return road_distance(p) <= ROAD_WIDTH * 0.5 or (absf(p.x + 15) < 4.5 and p.y >= 64)


static func hard_height(p: Vector2) -> float:
	if is_road(p):
		return 0.0
	var edge := maxf(absf(p.x - 32), absf(p.y - 32))
	var berm := smoothstep(78.0, 96.0, edge) * (4.5 + 1.3 * sin(p.x * 0.067) * cos(p.y * 0.053))
	var drainage := -0.45 * exp(-pow((p.x - 108) / 1.25, 2)) * (1.0 - smoothstep(60, 80, absf(p.y - 32)))
	return berm + drainage


static func soil_height(p: Vector2) -> float:
	# Flat protected perimeter joins hard terrain at zero. Raised northern face.
	var across := smoothstep(6, 16, p.x) * (1.0 - smoothstep(48, 58, p.x))
	var along := smoothstep(4, 10, p.y) * (1.0 - smoothstep(25, 33, p.y))
	return across * along * (2.8 + 0.17 * sin(p.x * 0.3) * cos(p.y * 0.21))


static func surface_role(p: Vector2) -> int:
	if is_road(p):
		return 0
	if (p.x < -24 and p.y > 0 and p.y < 60) or (p.x > 89 and p.y > -10 and p.y < 70):
		return 2
	if maxf(absf(p.x - 32), absf(p.y - 32)) > 70:
		return 3
	return 1



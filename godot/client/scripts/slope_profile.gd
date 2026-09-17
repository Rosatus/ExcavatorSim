class_name SlopeProfile
extends RefCounted

## Piecewise target surface for the slope-grade assist, defined in the
## vertical plane through the cabin-facing direction: a horizontal bench at
## the slope-toe height on the machine side (s < toe_s) and a straight
## grade beyond it. The profile is anchored at confirm time — tooth
## horizontal position is the origin, the chassis facing projection is the
## axis, and the toe height is sampled terrain — so the tracked frame does
## not rotate with later chassis settling.

var origin_xz := Vector2.ZERO
var axis := Vector2.RIGHT
var toe_s := 0.0
var toe_height := 0.0
var grade := 0.0
var angle_deg := 0.0


## tooth_world: bucket reference point at anchor time. axis_world: cabin
## facing direction (projected to horizontal here). distance_m: horizontal
## offset of the slope toe ahead of the tooth. angle_deg: signed slope
## angle — positive rises away from the machine, negative descends.
## toe_height_m: terrain height sampled at the toe point.
static func create(
	tooth_world: Vector3,
	axis_world: Vector3,
	distance_m: float,
	angle_deg: float,
	toe_height_m: float
) -> SlopeProfile:
	var profile := SlopeProfile.new()
	profile.origin_xz = Vector2(tooth_world.x, tooth_world.z)
	var flat := Vector2(axis_world.x, axis_world.z)
	profile.axis = flat.normalized() if flat.length() > 0.001 else Vector2.RIGHT
	profile.toe_s = maxf(distance_m, 0.0)
	profile.toe_height = toe_height_m
	profile.grade = tan(deg_to_rad(angle_deg))
	profile.angle_deg = angle_deg
	return profile


## Signed along-axis coordinate of a world position.
func along(world_pos: Vector3) -> float:
	return (Vector2(world_pos.x, world_pos.z) - origin_xz).dot(axis)


## World-space unit axis (horizontal) for Jacobian projection.
func axis_world() -> Vector3:
	return Vector3(axis.x, 0.0, axis.y)


## Target surface height at along-axis coordinate s: flat bench at toe
## height on the machine side, grade beyond the toe.
func height_at(s: float) -> float:
	return toe_height + grade * (s - toe_s) if s >= toe_s else toe_height


## Surface grade dh/ds at s — zero on the bench so the feedforward term
## hands a flat target to the same machinery that drives level grading.
func grade_at(s: float) -> float:
	return grade if s >= toe_s else 0.0


## Toe point in world space (for preview visuals and diagnostics).
func toe_world() -> Vector3:
	var toe_xz := origin_xz + axis * toe_s
	return Vector3(toe_xz.x, toe_height, toe_xz.y)


func describe() -> Dictionary:
	return {
		"origin_xz": origin_xz,
		"axis": axis,
		"toe_s": toe_s,
		"toe_height": toe_height,
		"grade": grade,
	}

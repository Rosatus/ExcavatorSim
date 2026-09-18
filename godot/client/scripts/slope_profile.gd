class_name SlopeProfile
extends RefCounted

## Piecewise target surface for the slope-grade assist, defined in the
## vertical plane through the cabin-facing direction: a horizontal bench at
## the slope-toe height on the machine side (s < toe_s) and a straight
## grade beyond it. The profile anchors at confirm time (tooth horizontal
## position = origin, cabin facing = axis, toe height = sampled terrain)
## and then RE-ANCHORS every tick onto the live upper forward + swing
## pivot, so the tracked surface rides with the machine while the
## undercarriage repositions along the slope.
##
## The toe kink is optionally rounded by knee_blend_m: height/grade stay
## C1-continuous across the toe so the assist's grade feedforward ramps
## instead of stepping — crossing the toe no longer kicks the tooth off
## the surface through its own momentum.

var origin_xz := Vector2.ZERO
var axis := Vector2.RIGHT
var toe_s := 0.0
var toe_height := 0.0
var grade := 0.0
var angle_deg := 0.0
## Half-width of the smooth relu rounding the bench->grade knee. 0 keeps
## the sharp piecewise surface (tests and the level assist build profiles
## this way); the runtime sets it from assist profile params.
var knee_blend_m := 0.0
## Machine-relative anchor: the origin sits (_anchor_s ahead, _anchor_t
## beside) the swing pivot in the axis frame — the invariant reanchor()
## re-imposes on the current heading.
var _anchor_s := 0.0
var _anchor_t := 0.0
var _anchor_captured := false


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


## Record the machine-relative anchor once: the origin's (forward, lateral)
## offset from the swing pivot in the current axis frame.
func capture_anchor(pivot_xz: Vector2) -> void:
	var rel := origin_xz - pivot_xz
	_anchor_s = rel.dot(axis)
	_anchor_t = rel.dot(Vector2(-axis.y, axis.x))
	_anchor_captured = true


## Re-impose the captured anchor on the live upper forward and swing pivot:
## the tracked surface translates/yaws with the machine so repositioning
## the undercarriage along the slope keeps the assist meaningful. Profiles
## that never got a captured anchor self-capture on the first call.
func reanchor(axis_now: Vector3, pivot_xz: Vector2) -> void:
	var flat := Vector2(axis_now.x, axis_now.z)
	if flat.length() < 0.001:
		return
	if not _anchor_captured:
		capture_anchor(pivot_xz)
	axis = flat.normalized()
	var perp := Vector2(-axis.y, axis.x)
	origin_xz = pivot_xz + axis * _anchor_s + perp * _anchor_t


## Signed along-axis coordinate of a world position.
func along(world_pos: Vector3) -> float:
	return (Vector2(world_pos.x, world_pos.z) - origin_xz).dot(axis)


## World-space unit axis (horizontal) for Jacobian projection.
func axis_world() -> Vector3:
	return Vector3(axis.x, 0.0, axis.y)


## Target surface height at along-axis coordinate s: flat bench at toe
## height on the machine side, grade beyond the toe — C1-rounded inside
## ±knee_blend_m of the toe when blending is on.
func height_at(s: float) -> float:
	return toe_height + grade * _rise(s - toe_s)


## Surface grade dh/ds at s — zero on the bench so the feedforward term
## hands a flat target to the same machinery that drives level grading;
## blended profiles ramp the grade across the knee instead of stepping it.
func grade_at(s: float) -> float:
	return grade * _rise_slope(s - toe_s)


## Smooth relu: 0 below -w, x above +w, quadratic blend between — C1 at
## both joints, max deviation from the sharp corner = w/4 at x = 0.
func _rise(x: float) -> float:
	if knee_blend_m <= 0.0:
		return maxf(x, 0.0)
	if x <= -knee_blend_m:
		return 0.0
	if x >= knee_blend_m:
		return x
	var u := x + knee_blend_m
	return u * u / (4.0 * knee_blend_m)


## Derivative of _rise: 0 -> 1 ramp across the blend band.
func _rise_slope(x: float) -> float:
	if knee_blend_m <= 0.0:
		return 1.0 if x >= 0.0 else 0.0
	if x <= -knee_blend_m:
		return 0.0
	if x >= knee_blend_m:
		return 1.0
	return (x + knee_blend_m) / (2.0 * knee_blend_m)


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

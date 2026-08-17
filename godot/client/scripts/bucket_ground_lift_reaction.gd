class_name BucketGroundLiftReaction
extends RefCounted

## Presentation-side support response. It never edits terrain, payload, or the
## authoritative locomotion state; it only produces a bounded local offset.

const DEAD_ZONE_M := 0.025
const MAX_PENETRATION_M := 0.45
const MAX_HEAVE_M := 0.22
const MAX_PITCH_RAD := 0.12
const MAX_ROLL_RAD := 0.10
const HEAVE_GAIN := 0.70
const ANGLE_GAIN := 0.24
const RESPONSE_HZ := 9.0
const RELEASE_HZ := 6.0
const MAX_HEAVE_SPEED_MPS := 1.2
const MAX_ANGLE_SPEED_RADPS := 1.2

var enabled := true
var model_id := ""
var generation := -1
var target_heave_m := 0.0
var target_pitch_rad := 0.0
var target_roll_rad := 0.0
var heave_m := 0.0
var pitch_rad := 0.0
var roll_rad := 0.0
var last_classification := "inactive"
var last_reason := "uninitialized"
var _half_width_m := 1.0
var _half_length_m := 1.0


static func classify_contact(
	penetration_m: float,
	penetration_delta_m: float,
	movement_world: Vector3,
	terrain_normal_world: Vector3,
	cutting_direction_world: Vector3,
	opening_normal_world: Vector3,
	was_supporting: bool
) -> Dictionary:
	if (
		not is_finite(penetration_m)
		or not is_finite(penetration_delta_m)
		or not movement_world.is_finite()
		or not terrain_normal_world.is_finite()
		or not cutting_direction_world.is_finite()
		or not opening_normal_world.is_finite()
		or terrain_normal_world.length_squared() < 0.5
		or cutting_direction_world.length_squared() < 0.5
		or opening_normal_world.length_squared() < 0.5
	):
		return {"eligible": false, "classification": "invalid"}
	if penetration_m <= DEAD_ZONE_M:
		return {"eligible": false, "classification": "none"}
	var normal := terrain_normal_world.normalized()
	var movement_length := movement_world.length()
	var cutting_window := movement_length > 0.001 and movement_world.normalized().dot(cutting_direction_world.normalized()) > 0.12
	var normal_opposes_motion := movement_world.dot(normal) < -0.0005 or penetration_delta_m > 0.001
	var adverse_bucket_angle := cutting_direction_world.normalized().dot(-normal) < 0.9
	var outside_dump_window := opening_normal_world.normalized().dot(-normal) < 0.75
	var eligible := (
		not cutting_window
		and adverse_bucket_angle
		and outside_dump_window
		and (normal_opposes_motion or was_supporting)
	)
	return {
		"eligible": eligible,
		"classification": "support" if eligible else ("cutting_window" if cutting_window else "contact"),
	}


func configure(parameters: Dictionary) -> bool:
	var width := float(parameters.get("support_left_offset_m", 1.0))
	var right := float(parameters.get("support_right_offset_m", 1.0))
	var front := float(parameters.get("support_front_offset_m", 1.0))
	var rear := float(parameters.get("support_rear_offset_m", 1.0))
	if not [width, right, front, rear].all(func(value: float) -> bool: return is_finite(value) and value > 0.0):
		return false
	_half_width_m = maxf(0.5, 0.5 * (width + right))
	_half_length_m = maxf(0.5, 0.5 * (front + rear))
	reset()
	return true


func reset() -> void:
	target_heave_m = 0.0
	target_pitch_rad = 0.0
	target_roll_rad = 0.0
	heave_m = 0.0
	pitch_rad = 0.0
	roll_rad = 0.0
	model_id = ""
	generation = -1
	last_classification = "inactive"
	last_reason = "reset"


func clear_target() -> void:
	target_heave_m = 0.0
	target_pitch_rad = 0.0
	target_roll_rad = 0.0
	last_classification = "inactive"
	last_reason = "disabled"


func submit_contact(contact: Dictionary, base_transform: Transform3D) -> void:
	target_heave_m = 0.0
	target_pitch_rad = 0.0
	target_roll_rad = 0.0
	last_classification = "inactive"
	last_reason = "invalid_contact"
	if not enabled or not bool(contact.get("eligible", false)):
		return
	var penetration := float(contact.get("penetration_m", 0.0))
	var point: Variant = contact.get("point_world", Vector3.ZERO)
	if not is_finite(penetration) or not point is Vector3 or not (point as Vector3).is_finite():
		return
	var contact_generation := int(contact.get("authority_generation", -1))
	var contact_model := String(contact.get("model_id", ""))
	if contact_generation < 0 or contact_model.is_empty():
		last_reason = "identity_missing"
		return
	if generation >= 0 and contact_generation != generation:
		last_reason = "generation_mismatch"
		return
	if not model_id.is_empty() and contact_model != model_id:
		last_reason = "model_mismatch"
		return
	generation = contact_generation
	model_id = contact_model
	penetration = clampf(penetration - DEAD_ZONE_M, 0.0, MAX_PENETRATION_M)
	if penetration <= 0.0:
		last_reason = "dead_zone"
		return
	var local_point := base_transform.affine_inverse() * (point as Vector3)
	if not local_point.is_finite():
		last_reason = "point_transform_invalid"
		return
	var lateral_ratio := clampf(local_point.x / _half_width_m, -1.0, 1.0)
	var longitudinal_ratio := clampf(local_point.z / _half_length_m, -1.0, 1.0)
	target_heave_m = minf(MAX_HEAVE_M, penetration * HEAVE_GAIN)
	# A rear contact lifts the machine while pitching its nose down; a lateral
	# contact rolls toward the opposite side. The signs are local-frame stable.
	target_pitch_rad = clampf(-longitudinal_ratio * penetration * ANGLE_GAIN, -MAX_PITCH_RAD, MAX_PITCH_RAD)
	target_roll_rad = clampf(lateral_ratio * penetration * ANGLE_GAIN, -MAX_ROLL_RAD, MAX_ROLL_RAD)
	last_classification = "support"
	last_reason = String(contact.get("reason", "rear_support"))


func step_fixed(delta: float) -> Transform3D:
	if delta <= 0.0 or not is_finite(delta):
		return _as_transform()
	var active := absf(target_heave_m) > 0.0 or absf(target_pitch_rad) > 0.0 or absf(target_roll_rad) > 0.0
	var weight := 1.0 - exp(-(RESPONSE_HZ if active else RELEASE_HZ) * delta)
	var max_heave_step := MAX_HEAVE_SPEED_MPS * delta
	var max_angle_step := MAX_ANGLE_SPEED_RADPS * delta
	var bounded_weight := clampf(weight, 0.0, 1.0)
	var desired_heave := lerpf(heave_m, target_heave_m, bounded_weight)
	var desired_pitch := lerpf(pitch_rad, target_pitch_rad, bounded_weight)
	var desired_roll := lerpf(roll_rad, target_roll_rad, bounded_weight)
	# Exponential smoothing sets the response shape; the final move_toward is
	# the strict per-step velocity bound.
	heave_m = move_toward(heave_m, desired_heave, max_heave_step)
	pitch_rad = move_toward(pitch_rad, desired_pitch, max_angle_step)
	roll_rad = move_toward(roll_rad, desired_roll, max_angle_step)
	return _as_transform()


func get_status_snapshot() -> Dictionary:
	return {
		"enabled": enabled,
		"classification": last_classification,
		"reason": last_reason,
		"model_id": model_id,
		"authority_generation": generation,
		"target_heave_m": target_heave_m,
		"target_pitch_deg": rad_to_deg(target_pitch_rad),
		"target_roll_deg": rad_to_deg(target_roll_rad),
		"heave_m": heave_m,
		"pitch_deg": rad_to_deg(pitch_rad),
		"roll_deg": rad_to_deg(roll_rad),
	}


func _as_transform() -> Transform3D:
	return Transform3D(Basis.from_euler(Vector3(pitch_rad, 0.0, roll_rad)), Vector3(0.0, heave_m, 0.0))

extends "res://scripts/guided_profile_stage.gd"
class_name BucketLevelAssist

## Flat-ground end-effector assist (modulator): while enabled the stage owns
## boom/arm/bucket outright — operator boom and bucket input is overridden —
## and the arm channel is reinterpreted as the bucket reference point's
## horizontal speed (W pushes out along the radial direction, S pulls in).
## The tracked surface is the latched horizontal plane through the tooth:
## _surface_target returns the stored height with zero grade. All solve,
## feasibility, and block-classification mechanics live in
## GuidedProfileStage + AssistRateSolver; this file only declares the
## latchable scalar height reference.

var _height_ref := 0.0


func configure(_descriptor: Dictionary, _soil_contract: Dictionary, params: Dictionary) -> bool:
	stage_name = "bucket_level"
	flag_prefix = "level_assist"
	writes_mask = MASK_WORK_EQUIPMENT
	exclusive_group = "terminal_surface"
	return super.configure(_descriptor, _soil_contract, params)


## The surface is the horizontal plane at the latched height — grade zero.
func _surface_target(_ctx: RefCounted) -> Dictionary:
	return {"height": _height_ref, "grade": 0.0}


func _latch_payload(ctx: RefCounted) -> void:
	_height_ref = ctx.bucket_ref_world.y
	if relaxed_attitude:
		_height_ref = (ctx.surface_contact(ctx.up).point as Vector3).y


## Bounded drift: the stored height follows the measured pose within the
## error window so genuinely infeasible tasks degrade instead of sticking.
func _clamp_refs(ctx: RefCounted) -> void:
	_height_ref = clampf(
		_height_ref,
		ctx.bucket_ref_world.y - max_height_error_m,
		ctx.bucket_ref_world.y + max_height_error_m,
	)


func set_height_ref_m(value: float) -> void:
	if is_finite(value):
		_height_ref = value


func get_status_snapshot() -> Dictionary:
	var snapshot := super.get_status_snapshot()
	snapshot["height_ref_m"] = _height_ref
	return snapshot

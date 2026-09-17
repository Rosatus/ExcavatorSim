extends "res://scripts/guided_profile_stage.gd"
class_name SlopeGradeAssist

const Profile := preload("res://scripts/slope_profile.gd")

## Slope-finishing end-effector assist (modulator): while enabled the stage
## owns swing/boom/arm/bucket outright — swing is silenced so the tracked
## vertical plane stays fixed, boom/bucket are overridden, and the arm
## channel is reinterpreted as along-axis translation (W climbs the grade
## away, S descends toward and past the toe onto the flat bench). The
## tracked surface is a SlopeProfile confirmed through apply_params; all
## solve/feasibility/block mechanics are inherited from GuidedProfileStage.

var _profile: Profile


func configure(_descriptor: Dictionary, _soil_contract: Dictionary, params: Dictionary) -> bool:
	stage_name = "slope_grade"
	flag_prefix = "slope_assist"
	writes_mask = MASK_WORK_EQUIPMENT | MASK_SWING
	exclusive_group = "terminal_surface"
	return super.configure(_descriptor, _soil_contract, params)


## The confirm step injects the frozen profile built from the preview
## parameters. Without one the stage refuses to enable — tracking nothing
## would just fight the operator.
func apply_params(params: Dictionary) -> bool:
	var profile := params.get("profile") as Profile
	if profile == null:
		return false
	_profile = profile
	return true


func set_enabled(value: bool) -> void:
	if value and _profile == null:
		return
	# A confirmed profile is single-use — but only an actual enabled->disabled
	# transition consumes it. Mutual exclusion calls set_enabled(false) on
	# siblings that were never on, and that must not eat a freshly injected
	# profile before its own enable lands.
	if not value and enabled:
		_profile = null
	super.set_enabled(value)


func _surface_target(_ctx: RefCounted) -> Dictionary:
	if _profile == null:
		return {"height": _ctx.bucket_ref_world.y, "grade": 0.0}
	var s := _profile.along(_ctx.bucket_ref_world)
	return {"height": _profile.height_at(s), "grade": _profile.grade_at(s)}


## The task frame is the frozen profile plane — the live outward direction
## could drift with chassis settling and would slowly rotate the surface.
func _intent_axis(_ctx: RefCounted) -> Vector3:
	return _profile.axis_world() if _profile != null else _ctx.horizontal


## Swing is claimed in writes_mask and held at zero every tick — including
## the deadband path — so the profile plane cannot rotate mid-pass.
func _extra_locked_channels() -> Array:
	return [0]


func get_status_snapshot() -> Dictionary:
	var snapshot := super.get_status_snapshot()
	snapshot["profile"] = _profile.describe() if _profile != null else {}
	return snapshot

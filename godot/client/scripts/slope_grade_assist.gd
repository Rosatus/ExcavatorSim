extends "res://scripts/guided_profile_stage.gd"
class_name SlopeGradeAssist

const Profile := preload("res://scripts/slope_profile.gd")

## Slope-finishing end-effector assist (modulator): while enabled the stage
## owns swing/boom/arm/bucket outright — swing is silenced so the slew stays
## put, boom/bucket are overridden, and the arm channel is reinterpreted as
## along-axis translation (W climbs the grade away, S descends toward and
## past the toe onto the flat bench). The tracked surface is a SlopeProfile
## confirmed through apply_params and re-anchored onto the live upper
## forward + swing pivot every tick — the undercarriage may reposition or
## yaw mid-assist and the surface follows the current heading. All
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


## Re-anchor the confirmed profile onto the live heading before the solve:
## the surface rides with the machine so the operator can drive or yaw the
## undercarriage along the slope and keep grading on the current upper
## forward. Runs every enabled tick — deadband included — so the side-view
## and soil mark track the machine continuously.
func step(ctx: RefCounted, commands: Vector4) -> Dictionary:
	if _profile != null and ctx.joint_pivot_world.has("swing_joint"):
		var pivot := ctx.joint_pivot_world["swing_joint"] as Vector3
		_profile.reanchor(ctx.horizontal, Vector2(pivot.x, pivot.z))
	return super.step(ctx, commands)


func _surface_target(_ctx: RefCounted) -> Dictionary:
	if _profile == null:
		return {"height": _ctx.bucket_ref_world.y, "grade": 0.0}
	var s := _profile.along(_ctx.bucket_ref_world)
	return {"height": _profile.height_at(s), "grade": _profile.grade_at(s)}


## The task frame is the profile plane — re-anchored above to the live
## upper forward, so it equals ctx.horizontal while self-consistent with
## the surface the Jacobian rows are built from.
func _intent_axis(_ctx: RefCounted) -> Vector3:
	return _profile.axis_world() if _profile != null else _ctx.horizontal


## Swing is claimed in writes_mask and held at zero every tick — including
## the deadband path — so the slew does not rotate the profile plane
## mid-pass; chassis yaw still carries it via the re-anchor.
func _extra_locked_channels() -> Array:
	return [0]


func get_status_snapshot() -> Dictionary:
	var snapshot := super.get_status_snapshot()
	snapshot["profile"] = _profile.describe() if _profile != null else {}
	return snapshot

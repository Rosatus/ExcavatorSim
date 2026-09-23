class_name RaceWheeledLocomotionState
extends WheeledLocomotionState
## Race-mode wheel solver. Suspension rays, the shared friction circle and
## wheel-inertia coupling are unchanged; the runtime supplies an overlaid
## parameter set and this class adds a post-step arcade assist pass
## (speed-squared downforce and a deadbanded attitude hold) plus a handbrake
## drift mode: rear tires surrender lateral grip while a steer-driven yaw-rate
## tracker holds a controllable slide, arcade-racing style.
## Assist keys consumed here (all optional): drift_rear_lateral_grip (residual
## rear lateral fraction at full drift), drift_brake_n (handbrake bite per rear
## wheel), drift_yaw_rate_rad_s (steer-to-yaw authority while sliding),
## drift_slip_limit_rad (yaw assist fades out past it so the car catches
## itself), drift_engage_mps, drift_engage_s, drift_release_s.

var assist: Dictionary = {}
var assist_telemetry: Dictionary = {}
var _drift_input := 0.0
var _drift_level := 0.0

func configure_race(settings: Dictionary, stations: Array, assist_params: Dictionary) -> bool:
	assist = assist_params.duplicate(true)
	assist_telemetry.clear()
	_drift_input = 0.0
	_drift_level = 0.0
	return configure(settings, stations)

func reset() -> void:
	super.reset()
	assist_telemetry.clear()
	_drift_input = 0.0
	_drift_level = 0.0

func set_drift(value: float) -> void:
	_drift_input = clampf(value, 0.0, 1.0) if is_finite(value) else 0.0

func step(body: RigidBody3D, delta: float, terrain_mask: int = 1, accept_hit: Callable = Callable()) -> Dictionary:
	# Handbrake bites fast but releases gently so grip returns progressively.
	var ramp := float(assist.get("drift_engage_s", 0.1)) if _drift_input > _drift_level else float(assist.get("drift_release_s", 0.3))
	_drift_level = move_toward(_drift_level, _drift_input, delta / maxf(ramp, 0.01))
	var snapshot := super.step(body, delta, terrain_mask, accept_hit)
	if not snapshot.is_empty():
		var grounded := int(snapshot.get("contact_count", 0)) > 0
		var speed := float(snapshot.get("speed_mps", 0.0))
		var slip := _slip_angle(body)
		var target_yaw: Variant = null
		if _drift_level > 0.0 and grounded and speed > float(assist.get("drift_engage_mps", 5.0)):
			var limit := float(assist.get("drift_slip_limit_rad", 0.75))
			var fade := clampf((limit * 1.5 - absf(slip)) / maxf(limit * 0.5, 0.01), 0.0, 1.0)
			target_yaw = -_command.z * float(assist.get("drift_yaw_rate_rad_s", 1.0)) * _drift_level * fade
		assist_telemetry = RaceMotionAssist.apply(body, assist, target_yaw, delta, grounded)
		assist_telemetry["drift"] = _drift_level
		assist_telemetry["slip_angle_rad"] = slip
	return snapshot

## The base solver already applied full lateral grip; the drift pass gives a
## share of it back on rear (unsteered) wheels and adds a handbrake bite that
## opposes travel. Steering geometry and front grip stay untouched, so
## counter-steer keeps authority while the rear steps out.
func _step_wheel(body: RigidBody3D, wheel: Dictionary, angle: float, speed: float, driven_count: int, dt: float, mask: int, accept_hit: Callable) -> Dictionary:
	var sample := super._step_wheel(body, wheel, angle, speed, driven_count, dt, mask, accept_hit)
	if _drift_level <= 0.001 or wheel.steered or not bool(sample.get("grounded", false)):
		return sample
	var normal: Vector3 = sample["normal_world"]
	var forward := (body.global_basis * (Basis(Vector3.UP, -angle) * Vector3.FORWARD)).slide(normal).normalized()
	var right := forward.cross(normal).normalized()
	var point: Vector3 = sample["point_world"]
	var tire: Vector2 = sample["tire_force_n"]
	var keep := lerpf(1.0, clampf(float(assist.get("drift_rear_lateral_grip", 0.35)), 0.0, 1.0), _drift_level)
	var correction := right * (-tire.y * (1.0 - keep))
	var v_long := _point_velocity(body, point).dot(forward)
	if absf(v_long) > 0.3:
		correction += forward * (-signf(v_long) * float(assist.get("drift_brake_n", 16000.0)) * _drift_level)
	body.apply_force(correction, point - body.global_position)
	sample["tire_force_n"] = Vector2(tire.x, tire.y * keep)
	return sample

func _slip_angle(body: RigidBody3D) -> float:
	var local_v: Vector3 = body.global_transform.basis.inverse() * body.linear_velocity
	return atan2(local_v.x, -local_v.z) if local_v.length() > 0.5 else 0.0

class_name WheeledLocomotionState
extends RefCounted
## Force-only wheel solver. Jolt exclusively integrates the chassis pose.
## Coordinates: +Y up, -Z forward, +X right; positive steer turns right.
## Each wheel declares a body-local suspension mount and an independent radius.

const DEFAULTS := {
	"wheelbase_m": 2.8, "max_speed_mps": 8.0, "max_reverse_speed_mps": 3.0,
	"max_steer_degrees": 34.0, "steer_rate_degrees_s": 75.0,
	"steering_lateral_accel_mps2": 4.0, "drive_force_n": 6000.0,
	"brake_force_n": 14000.0, "rolling_resistance": 0.018,
	"friction": 0.85, "suspension_travel_m": 0.35,
	"spring_n_m": 70000.0, "damper_n_s_m": 6500.0,
	"max_load_n": 40000.0, "wheel_inertia_kg_m2": 18.0
}
var configured := false
var last_error := ""
var parameters: Dictionary = {}
var wheels: Array[Dictionary] = []
var steer_angle_rad := 0.0
var _command := Vector3.ZERO
var _snapshot: Dictionary = {}

func configure(settings: Dictionary, stations: Array) -> bool:
	configured = false
	last_error = ""
	parameters = DEFAULTS.duplicate(true)
	for key in settings:
		if not parameters.has(key):
			return _reject("unknown wheel parameter: " + String(key))
		var value: Variant = settings[key]
		if not (value is float or value is int) or not is_finite(float(value)) or float(value) <= 0.0:
			return _reject("wheel parameter must be finite and positive: " + String(key))
		parameters[key] = float(value)
	if parameters.max_steer_degrees >= 80.0:
		return _reject("max_steer_degrees must be below 80")
	wheels.clear()
	if stations.size() < 2 or stations.size() > 16:
		return _reject("expected 2 to 16 wheel stations")
	for item in stations:
		if not item is Dictionary:
			return _reject("wheel must be a dictionary")
		var mount: Variant = item.get("mount", null)
		var radius: Variant = item.get("radius_m", null)
		if not mount is Vector3 or not mount.is_finite():
			return _reject("wheel mount must be a finite Vector3")
		if not (radius is float or radius is int) or not is_finite(float(radius)) or float(radius) < 0.05:
			return _reject("wheel radius must be >= 0.05 m")
		for flag in ["steered", "driven"]:
			if not item.get(flag, false) is bool:
				return _reject("wheel flags must be boolean")
		if absf(mount.x * tan(deg_to_rad(parameters.max_steer_degrees))) >= parameters.wheelbase_m * 0.95:
			return _reject("wheel track too wide for steering radius")
		wheels.append({"mount": mount, "radius_m": float(radius), "steered": item.get("steered", false),
			"driven": item.get("driven", false), "omega": 0.0, "roll": 0.0})
	configured = true
	reset()
	return true

func _reject(message: String) -> bool:
	last_error = message
	wheels.clear()
	_snapshot.clear()
	return false

func set_commands(throttle: float, brake: float, steer: float) -> void:
	_command = Vector3(clampf(throttle, -1.0, 1.0), clampf(brake, 0.0, 1.0), clampf(steer, -1.0, 1.0)) if Vector3(throttle, brake, steer).is_finite() else Vector3(0, 1, 0)

func reset() -> void:
	_command = Vector3.ZERO
	steer_angle_rad = 0.0
	_snapshot.clear()
	for wheel in wheels:
		wheel.omega = 0.0
		wheel.roll = 0.0

func get_status_snapshot() -> Dictionary:
	return _snapshot.duplicate(true)

## accept_hit optionally rejects stale/unowned terrain before any support force.
func step(body: RigidBody3D, delta: float, terrain_mask: int = 1, accept_hit: Callable = Callable()) -> Dictionary:
	if not configured or body == null or not body.is_inside_tree() or not is_finite(delta) or delta <= 0.0 or delta > 0.1:
		return {}
	var speed := body.linear_velocity.dot(-body.global_basis.z.normalized())
	var max_angle := deg_to_rad(parameters.max_steer_degrees)
	# Speed-sensitive steering reduces high-speed rollover demand, but never edits yaw.
	var speed_limit := atan(parameters.steering_lateral_accel_mps2 * parameters.wheelbase_m / maxf(speed * speed, 0.01))
	steer_angle_rad = move_toward(steer_angle_rad, _command.z * minf(max_angle, speed_limit), deg_to_rad(parameters.steer_rate_degrees_s) * delta)
	var driven_count := 0
	for wheel in wheels:
		if wheel.driven:
			driven_count += 1
	var samples: Array[Dictionary] = []
	var contact_count := 0
	for wheel in wheels:
		var angle := steering_for_wheel(wheel.mount.x) if wheel.steered else 0.0
		var sample := _step_wheel(body, wheel, angle, speed, driven_count, delta, terrain_mask, accept_hit)
		contact_count += 1 if sample.grounded else 0
		samples.append(sample)
	_snapshot = {"configured": true, "speed_mps": speed, "steer_angle_rad": steer_angle_rad,
		"wheels": samples, "contact_count": contact_count, "body_transform": body.global_transform}
	return _snapshot

func steering_for_wheel(local_x: float) -> float:
	# Positive right steering requires a negative Godot Y rotation for -Z forward.
	var curvature := tan(steer_angle_rad) / float(parameters.wheelbase_m)
	return atan(float(parameters.wheelbase_m) * curvature / (1.0 - local_x * curvature))

func _step_wheel(body: RigidBody3D, wheel: Dictionary, angle: float, speed: float, driven_count: int, dt: float, mask: int, accept_hit: Callable) -> Dictionary:
	var radius: float = wheel.radius_m
	var travel: float = parameters.suspension_travel_m
	var up := body.global_basis.y.normalized()
	var mount: Vector3 = body.global_transform * wheel.mount
	var query := PhysicsRayQueryParameters3D.create(mount, mount - up * (travel + radius), mask, [body.get_rid()])
	var hit := body.get_world_3d().direct_space_state.intersect_ray(query) if up.dot(Vector3.UP) > 0.2 else {}
	if not hit.is_empty() and accept_hit.is_valid():
		hit = accept_hit.call(hit)
	var brake: float = _command.y
	var throttle: float = _command.x
	# Direction change first brakes actual travel; no instantaneous reversal.
	if throttle * speed < -0.15:
		brake = maxf(brake, absf(throttle))
		throttle = 0.0
	var max_speed: float = parameters.max_speed_mps if throttle >= 0.0 else parameters.max_reverse_speed_mps
	var drive: float = parameters.drive_force_n * throttle * clampf((max_speed - absf(speed)) / maxf(max_speed * 0.2, 0.1), 0.0, 1.0) / maxi(driven_count, 1) if wheel.driven else 0.0
	var inertia: float = parameters.wheel_inertia_kg_m2
	var brake_torque: float = brake * parameters.brake_force_n * radius / wheels.size()
	var omega: float = float(wheel.omega) + drive * radius / inertia * dt
	var before_brake := omega
	omega = move_toward(omega, 0.0, brake_torque / inertia * dt)
	var remaining_brake := maxf(0.0, brake_torque / inertia * dt - absf(before_brake - omega))
	var length := travel
	var load := 0.0
	var slip := 0.0
	var tire_force := Vector2.ZERO
	var grounded := false
	if not hit.is_empty():
		var normal: Vector3 = hit.normal
		if normal.dot(up) > 0.35:
			var point: Vector3 = hit.position
			length = clampf(mount.distance_to(point) - radius, 0.0, travel)
			var other := hit.collider as RigidBody3D
			var velocity := _point_velocity(body, point)
			if other != null:
				velocity -= _point_velocity(other, point)
			load = clampf(parameters.spring_n_m * (travel - length) - parameters.damper_n_s_m * velocity.dot(normal), 0.0, parameters.max_load_n)
			grounded = load > 0.01
			var forward := (body.global_basis * (Basis(Vector3.UP, -angle) * Vector3.FORWARD)).slide(normal).normalized()
			var right := forward.cross(normal).normalized()
			var v_long := velocity.dot(forward)
			var v_side := velocity.dot(right)
			var mass_per_wheel := body.mass / float(wheels.size())
			var rolling_torque: float = parameters.rolling_resistance * load * radius
			omega = move_toward(omega, 0.0, rolling_torque / inertia * dt)
			# Implicit contact impulse couples tire inertia and ground speed. The shared
			# friction circle limits braking AND cornering, preserving actual sliding.
			var desired_long := (omega * radius - v_long) / (dt * (radius * radius / inertia + 1.0 / mass_per_wheel))
			# A locked brake has no wheel-inertia freedom: stop slip within the same budget.
			if brake > 0.0 and absf(omega) < 0.01:
				desired_long = -v_long * mass_per_wheel / dt
				desired_long = clampf(desired_long, -brake_torque / radius, brake_torque / radius)
			tire_force = Vector2(desired_long, -v_side * mass_per_wheel / maxf(dt, 0.04))
			var mu: float = parameters.friction
			if hit.collider is CollisionObject3D and hit.collider.has_meta("wheel_friction"):
				var surface_mu: Variant = hit.collider.get_meta("wheel_friction")
				if (surface_mu is float or surface_mu is int) and is_finite(float(surface_mu)):
					mu *= clampf(float(surface_mu), 0.0, 2.0)
			tire_force = tire_force.limit_length(mu * load)
			omega -= tire_force.x * radius / inertia * dt
			omega = move_toward(omega, 0.0, remaining_brake)
			slip = (omega * radius - v_long) / maxf(absf(v_long), 0.5)
			var force := normal * load + forward * tire_force.x + right * tire_force.y
			body.apply_force(force, point - body.global_position)
			if other != null and not other.freeze:
				other.apply_force(-force, point - other.global_position)
	# Small bearing drag prevents numerically eternal airborne spin; no air traction.
	wheel.omega = move_toward(omega, 0.0, 0.03 * dt)
	wheel.roll = wrapf(float(wheel.roll) + float(wheel.omega) * dt, -PI, PI)
	return {"grounded": grounded, "steer_angle_rad": angle, "roll_angle_rad": wheel.roll,
		"angular_speed_rad_s": wheel.omega, "suspension_length_m": length,
		"compression_m": travel - length, "load_n": load, "slip_ratio": slip,
		"tire_force_n": tire_force, "center_local": wheel.mount - Vector3.UP * length,
		"point_world": hit.get("position", mount - up * (travel + radius)),
		"normal_world": hit.get("normal", up), "support_source": hit.get("support_source", "physics"),
		"collider_name": String(hit.collider.name) if hit.get("collider") is Node else "ground"}

func _point_velocity(body: RigidBody3D, point: Vector3) -> Vector3:
	return body.linear_velocity + body.angular_velocity.cross(point - body.global_transform * body.center_of_mass)

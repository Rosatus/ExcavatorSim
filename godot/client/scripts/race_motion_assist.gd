class_name RaceMotionAssist
extends RefCounted
## Race-mode arcade assists applied after a locomotion solver step. Additive
## forces/torques on the chassis body only; solver state is never mutated.
## Recognized assist keys (all optional, non-positive disables each feature):
##   downforce_n_per_m_s2 / max_downforce_n — speed-squared aero downforce
##   yaw_assist_gain_nm_s_per_rad / max_yaw_assist_torque_nm — yaw-rate tracking
##   attitude_deadband_deg — tilt the hold ignores (keeps slopes believable)
##   attitude_stiffness_nm_per_rad / attitude_damping_nm_s_per_rad
##   max_attitude_torque_nm — shared clamp for the attitude torque
static func apply(
	body: RigidBody3D,
	assist: Dictionary,
	target_yaw_rate: Variant,
	delta: float,
	grounded := true
) -> Dictionary:
	var applied := {"downforce_n": 0.0, "yaw_torque_nm": 0.0, "attitude_torque_nm": 0.0}
	if body == null or assist.is_empty() or delta <= 0.0 or not is_finite(delta):
		return applied
	var up := body.global_basis.y.normalized()
	var downforce := (
		float(assist.get("downforce_n_per_m_s2", 0.0))
		* body.linear_velocity.length_squared()
	)
	var max_downforce := float(assist.get("max_downforce_n", 0.0))
	if max_downforce > 0.0:
		downforce = minf(downforce, max_downforce)
	if downforce > 0.0:
		body.apply_central_force(-up * downforce)
		applied["downforce_n"] = downforce
	# Yaw assist tracks the commanded yaw rate like a driving aid; only the
	# spin about body-up is corrected, slope pitch is untouched.
	var yaw_gain := float(assist.get("yaw_assist_gain_nm_s_per_rad", 0.0))
	var max_yaw := float(assist.get("max_yaw_assist_torque_nm", 0.0))
	if grounded and yaw_gain > 0.0 and (target_yaw_rate is float or target_yaw_rate is int):
		var yaw_error := float(target_yaw_rate) - body.angular_velocity.dot(up)
		var yaw_torque := clampf(yaw_error * yaw_gain, -max_yaw, max_yaw)
		if absf(yaw_torque) > 1.0:
			body.apply_torque(up * yaw_torque)
			applied["yaw_torque_nm"] = yaw_torque
	# Attitude hold: deadbanded stiffness toward world-up plus pitch/roll rate
	# damping, so jumps and curb hits settle without fighting ordinary slopes.
	var stiffness := float(assist.get("attitude_stiffness_nm_per_rad", 0.0))
	var damping := float(assist.get("attitude_damping_nm_s_per_rad", 0.0))
	var max_torque := float(assist.get("max_attitude_torque_nm", 0.0))
	if max_torque > 0.0 and (stiffness > 0.0 or damping > 0.0):
		var tilt_axis := up.cross(Vector3.UP)
		var tilt := up.angle_to(Vector3.UP)
		var torque := Vector3.ZERO
		var deadband := deg_to_rad(float(assist.get("attitude_deadband_deg", 0.0)))
		if tilt > deadband and tilt_axis.length_squared() > 0.001:
			torque += tilt_axis.normalized() * (tilt - deadband) * stiffness
		var tilt_rate := body.angular_velocity - up * body.angular_velocity.dot(up)
		torque -= tilt_rate * damping
		if torque.length() > max_torque:
			torque = torque.normalized() * max_torque
		if torque.length() > 1.0:
			body.apply_torque(torque)
			applied["attitude_torque_nm"] = torque.length()
	return applied

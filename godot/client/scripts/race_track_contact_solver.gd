class_name RaceTrackContactSolver
extends TrackContactSolver
## Race-mode tracked solver. The contact sweep, support loads and Coulomb
## traction are identical to the base solver; only the parameter values differ
## (the runtime feeds an overlaid dictionary) plus a post-step arcade assist
## pass: yaw-rate tracking toward the commanded differential and a deadbanded
## attitude hold so the machine stays composed at speed.

var assist: Dictionary = {}
var assist_telemetry: Dictionary = {}

func configure_race(tracks: Dictionary, dynamics: Dictionary, assist_params: Dictionary) -> void:
	assist = assist_params.duplicate(true)
	assist_telemetry.clear()
	configure(tracks, dynamics)

func reset() -> void:
	super.reset()
	assist_telemetry.clear()

func step(body: RigidBody3D, commands: Vector2, delta: float, terrain_mask: int, accept_hit: Callable) -> Dictionary:
	var sign_forward := 1.0 if _tracks.get("local_forward_axis", "-Z") == "+Z" else -1.0
	var forward := body.global_basis.z.normalized() * sign_forward
	var forward_speed := absf(body.linear_velocity.dot(forward))
	var belt := float(_tracks.get("max_belt_speed_m_s", 0.0))
	var gauge := maxf(float(_tracks.get("gauge_m", 0.0)), 0.1)
	# Tank-style steering weight: the outside belt cannot run faster than its
	# limit, so rotation authority collapses as center speed approaches it.
	# Turns must scrub speed before the machine can rotate harder.
	var raw_yaw := (commands.y - commands.x) * belt / gauge
	var capacity := maxf(
		(belt - forward_speed) * 2.0 / gauge * float(assist.get("yaw_capacity_scale", 0.6)),
		float(assist.get("yaw_capacity_floor_rad_s", 0.8))
	)
	var target_yaw := clampf(raw_yaw, -capacity, capacity)
	# The raw differential is itself a huge yaw moment; at speed a tank cannot
	# cash it, so cap the belt gap at what the outside track can physically
	# deliver. The outside belt keeps its demand while the inside belt folds
	# toward it — speed bleeds through the slowing inside track instead of
	# both belts slamming into reverse, and the arc tightens as the machine
	# slows — slow in, rotate, power out.
	var scaled_commands := commands
	var steer_shrink := 1.0
	if forward_speed > float(assist.get("steer_soften_mps", 4.0)) and absf(raw_yaw) > capacity:
		var allowed := capacity * gauge / maxf(belt, 0.1)
		var gap := commands.x - commands.y
		var outer := maxf(commands.x, commands.y)
		# Demand beyond capacity becomes inside-track braking: real tanks rotate
		# by dragging the inner belt, which is also where the cornering speed
		# bleed actually comes from. Floored so the belt never slams into a full
		# reversal while the machine is still moving fast.
		var extra := (absf(gap) - allowed) * float(assist.get("turn_inner_brake_scale", 0.3))
		var inner := outer - minf(absf(gap), allowed) - minf(extra, absf(gap))
		inner = maxf(inner, float(assist.get("turn_inner_brake_floor", -0.3)))
		steer_shrink = minf(absf(gap), allowed) / maxf(absf(gap), 0.001)
		scaled_commands = Vector2(outer, inner) if gap > 0.0 else Vector2(inner, outer)
	# Asking for more rotation than the belts can deliver makes the tracks give
	# up a slice of grip: the loaded outside belt scrubs and speed bleeds off.
	# The dip scales with speed so a standstill pivot keeps full bite.
	var excess := maxf(0.0, absf(raw_yaw) - capacity) * clampf(forward_speed / maxf(belt, 0.1), 0.0, 1.0)
	var grip_keep := 1.0 - minf(
		excess * float(assist.get("turn_grip_loss_per_rad_s", 0.08)),
		float(assist.get("turn_grip_loss_max", 0.3))
	)
	var saved_friction := 0.0
	if grip_keep < 1.0:
		saved_friction = float(_tracks["friction"])
		_tracks["friction"] = saved_friction * grip_keep
	var output := super.step(body, scaled_commands, delta, terrain_mask, accept_hit)
	if grip_keep < 1.0:
		_tracks["friction"] = saved_friction
	var left: Dictionary = output.get("left", {})
	var right: Dictionary = output.get("right", {})
	var grounded := int(left.get("contact_count", 0)) + int(right.get("contact_count", 0)) > 0
	# Cornering scrub: demanding rotation while moving costs forward speed the
	# way real belts burning sideways grip do. Fades with both demand and speed.
	var demand := clampf(absf(raw_yaw) * gauge / maxf(belt, 0.1) * 0.5, 0.0, 1.0)
	var turn_drag := (
		float(assist.get("turn_drag_n", 40000.0))
		* demand
		* clampf(forward_speed / maxf(belt, 0.1), 0.0, 1.0)
	)
	if grounded and turn_drag > 1.0 and body.linear_velocity.length_squared() > 0.25:
		body.apply_central_force(-body.linear_velocity.normalized() * turn_drag)
	assist_telemetry = RaceMotionAssist.apply(body, assist, target_yaw, delta, grounded)
	assist_telemetry["yaw_capacity_rad_s"] = capacity
	assist_telemetry["turn_grip"] = grip_keep
	assist_telemetry["steer_shrink"] = steer_shrink
	assist_telemetry["turn_drag_n"] = turn_drag
	return output

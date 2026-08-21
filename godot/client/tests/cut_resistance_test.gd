extends SceneTree

## Focused contract for the saturating cutting-resistance load: dig-direction
## work-equipment commands slow with engagement, flooring at MIN_CUT_SPEED_SCALE
## — resistance only ever slows a stroke, never stalls it — while retraction
## and swing keep full authority so the operator can always back out.

const RIG_MODEL := "sy205"
const TICK := 1.0 / 60.0
const SETTLE_TICKS := 240

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var descriptor := PhysicsRigDescriptor.load_for_model(RIG_MODEL)
	if descriptor == null:
		return _fail("rig descriptor loads")
	var articulation := KinematicArticulationState.new()
	if not articulation.configure(descriptor.to_dictionary(), Transform3D.IDENTITY):
		return _fail("articulation configures")

	var boom_base := _drive(articulation, "boom_joint", -1.0, 0.0)
	if boom_base >= 0.0:
		failures.append("boom dig command drives negative velocity: %.4f" % boom_base)
	var swing_base := _drive(articulation, "swing_joint", -1.0, 0.0)
	if swing_base >= 0.0:
		failures.append("swing command drives negative velocity: %.4f" % swing_base)
	var retract_base := _drive(articulation, "boom_joint", 1.0, 0.0)
	if retract_base <= 0.0:
		failures.append("boom retract command drives positive velocity: %.4f" % retract_base)

	var boom_loaded := _drive(articulation, "boom_joint", -1.0, 1.0)
	var floor_expected := boom_base * KinematicArticulationState.MIN_CUT_SPEED_SCALE
	if absf(boom_loaded - floor_expected) > absf(boom_base) * 0.05 + 0.001:
		failures.append(
			"full engagement floors dig velocity at MIN_CUT_SPEED_SCALE: %.4f vs %.4f" % [boom_loaded, floor_expected]
		)

	var boom_half := _drive(articulation, "boom_joint", -1.0, 0.5)
	var half_expected := boom_base * lerpf(1.0, KinematicArticulationState.MIN_CUT_SPEED_SCALE, 0.5)
	if absf(boom_half - half_expected) > absf(boom_base) * 0.05 + 0.001:
		failures.append(
			"half engagement scales dig velocity: %.4f vs %.4f" % [boom_half, half_expected]
		)

	var retract_loaded := _drive(articulation, "boom_joint", 1.0, 1.0)
	if absf(retract_loaded - retract_base) > absf(retract_base) * 0.02 + 0.001:
		failures.append("retraction ignores cut engagement: %.4f vs %.4f" % [retract_loaded, retract_base])

	var swing_loaded := _drive(articulation, "swing_joint", -1.0, 1.0)
	if absf(swing_loaded - swing_base) > absf(swing_base) * 0.02 + 0.001:
		failures.append("swing stays exempt from cut engagement: %.4f vs %.4f" % [swing_loaded, swing_base])

	if failures.is_empty():
		print("cut_resistance_test: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _drive(
	articulation: KinematicArticulationState,
	joint_name: String,
	command: float,
	engagement: float
) -> float:
	articulation.reset_motion(Transform3D.IDENTITY)
	articulation.neutral_armed = true
	articulation.set_cut_resistance(engagement)
	var commands := Vector4.ZERO
	match joint_name:
		"swing_joint":
			commands.x = command
		"boom_joint":
			commands.y = command
		"arm_joint":
			commands.z = command
		"bucket_joint":
			commands.w = command
	articulation.set_commands(commands, Engine.get_physics_frames() + 1)
	# The stroke runs until the joint ramps onto its velocity plateau; peak
	# magnitude is the settled actuator speed before any limit softening.
	var peak := 0.0
	var direction := 1.0
	for _tick_index in SETTLE_TICKS:
		var proposal := articulation.propose_step(TICK, Transform3D.IDENTITY, true)
		if proposal.is_empty():
			failures.append("proposal unavailable while driving %s" % joint_name)
			return 0.0
		articulation.accept_step(proposal, 1.0)
		for state_value in articulation.joint_states():
			var state := state_value as Dictionary
			if String(state.get("name", "")) == joint_name:
				var velocity := float(state.get("velocity_rad_s", 0.0))
				if absf(velocity) > peak:
					peak = absf(velocity)
					direction = signf(velocity)
	return direction * peak


func _fail(message: String) -> void:
	push_error("cut_resistance_test failed: %s" % message)
	quit(1)

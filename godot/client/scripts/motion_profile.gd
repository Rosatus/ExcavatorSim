class_name MotionProfile
extends RefCounted

const TAIL_LAG_PRODUCT := 0.7

## Shared time-optimal approach laws for automatic positioning.
##
## A pure P law saturates far away and then decays exponentially, so it is
## slow on long moves and still overshoots when actuator lag is ignored. These
## helpers command the fastest rate that can still be braked to rest at the
## target: a constant-deceleration envelope sqrt(2 a d), shortened by the
## distance the plant travels during its response lag, blended into a linear
## tail near zero so the command stays continuous and chatter-free.


## Signed desired rate toward `error` (target - current). `rate` is the
## measured rate in the same units; motion toward the target consumes the
## remaining braking distance during `lag_s`.
static func approach_rate(error: float, rate: float, max_rate: float, accel: float, linear_gain: float, lag_s := 0.0) -> float:
	var distance := absf(error)
	if distance <= 0.0 or max_rate <= 0.0:
		return 0.0
	var direction := signf(error)
	var closing := maxf(rate * direction, 0.0)
	var brake_distance := maxf(distance - closing * lag_s, 0.0)
	# Inside the linear tail a closing speed of k*d consumes k*lag*d of the
	# remaining distance; with k*lag >= 1 the command collapses to zero and
	# the approach stutters. Bound the tail gain so the lag stays honoured.
	var gain := minf(linear_gain, TAIL_LAG_PRODUCT / lag_s) if lag_s > 0.0 else linear_gain
	var speed := minf(max_rate, minf(sqrt(2.0 * maxf(accel, 0.0) * brake_distance), gain * distance))
	return direction * speed


## Time-optimal position target for a joint driven through the
## KinematicArticulationState command chain (velocity ceiling, acceleration
## and jerk limits). Returns the desired joint velocity this tick. The braking
## distance includes the jerk-limited acceleration reversal, so arrival is
## reached at ~zero velocity instead of overshooting and settling back.
static func joint_rate(error: float, velocity: float, accel_max: float, jerk_max: float, max_rate: float, linear_gain: float, delta: float) -> float:
	var accel := maxf(accel_max, 0.001) * 0.8
	var jerk := maxf(jerk_max, 0.001)
	# Time to build full deceleration from coasting plus one sample of delay.
	var lag := accel / jerk + delta
	return approach_rate(error, velocity, max_rate, accel, linear_gain, lag)
# Calibrate Jolt chassis posture and longitudinal response

## Goal

Make the standalone Jolt excavator enter a visually level supported pose for
both SY135 and SY205, then provide believable forward/reverse inertia and
smooth emergency braking without reintroducing the previous whole-machine
rocking loop.

## Background And Evidence

- `TrackedChassisController._authoritative_spawn_transform()` currently derives
  spawn height from the lowest compound shape and terrain height, but does not
  align chassis pitch/roll to the sampled surface normal.
- `JoltChassisTrackRuntime` uses the descriptor chassis COM/inertia and a single
  dynamic body. Upper/boom/arm/bucket body entries are not separate dynamic
  masses, so their descriptor COM values must not be treated as runtime gravity
  contributors.
- Track support is applied at distributed contact points while drive and brake
  forces are constrained by measured support load and friction. Current braking
  tests only assert that speed is lower after a fixed window; they do not bound
  peak pitch or stop time.
- The archived chassis stabilization work already established support ownership,
  hull hysteresis, heightfield fallback, and attitude stabilization. This child
  must preserve those contracts.

## Requirements

### R1. Model-specific initial posture

- Diagnose rigid-body posture separately from GLB visual rest-pose offset.
- On reset, activation, and model switch, establish a bounded upright pose
  relative to the authoritative `TerrainState` normal before movement is armed.
- Keep the existing single Jolt chassis writer and neutral re-arm lifecycle.
- Use explicit model descriptor calibration values or a bounded one-time
  settling correction; do not add a second per-frame transform writer.
- Preserve terrain clearance and avoid initial hull penetration on flat and mild
  uneven ground.

### R2. Believable longitudinal response

- Preserve measured-support-load friction limits and per-model belt-speed caps.
- Tune acceleration/coast/braking response independently for SY135 and SY205;
  do not solve perceived inertia by arbitrarily changing mass alone.
- Shape brake effort over fixed ticks so command release cannot create a single
  large force impulse or visible pitch snap.
- Permit a small, bounded forward pitch during hard braking when caused by
  support load transfer, but prevent repeated bounce, sign reversal, or yaw snap.
- Reverse direction through a bounded zero-crossing rather than an instantaneous
  velocity flip.

### R3. Telemetry and regression coverage

- Record posture error, terrain-normal alignment, support loads, realized speed,
  slip/saturation, acceleration time, brake stop time/distance, peak pitch angle,
  and peak pitch angular rate.
- Add focused tests for reset/model switch, neutral re-arm, straight acceleration,
  coast, hard braking, reverse transition, and partial-support traction.
- Keep no-Python standalone operation and the Python gateway boundary unchanged.

## Acceptance Criteria

- [ ] After reset on flat ground, each model's chassis up axis is within 2 degrees
      of the sampled terrain normal and the lowest chassis point is within 0.02 m
      of configured ground clearance, with no initial penetration.
- [ ] On a mild slope, reset posture follows the terrain normal within 3 degrees
      without oscillating hull/probe ownership.
- [ ] Neutral input is required after reset/model switch; no movement occurs
      before re-arm.
- [ ] Straight travel reaches at least 65% of each configured belt-speed target
      within the descriptor acceleration window and does not rely on velocity
      clamp quality flags.
- [ ] Releasing straight commands produces monotonic speed reduction, no reverse
      overshoot, no yaw snap, and reaches below 0.05 m/s within a bounded stop
      window defined per model.
- [ ] Hard braking may produce a single bounded forward pitch response, but peak
      pitch angle/rate and sustained RMS remain below the regression thresholds;
      there is no repeating front/rear bounce.
- [ ] SY135 and SY205 pass the focused Godot headless test and live no-Python
      reset/travel/brake smoke.

## Out Of Scope

- Terrain3D deformation, terrain material/dressing, bucket excavation, dynamic
  soil parcels, hydraulic cylinders, individual track links, or Python pose
  authority.
- Production mass-property calibration; descriptor values remain provisional
  gameplay tuning evidence.

## Decision Summary

- Recommended implementation order: posture diagnosis/calibration first, then
  longitudinal response and brake shaping, then combined regression tuning.
- Recommended first experiment: compare current COM/compound geometry with a
  zero longitudinal COM-offset diagnostic while logging body-vs-visual pitch;
  only retain a COM change if it improves both models without harming support.

# Technical Design

## Authority And Boundaries

`JoltChassisTrackRuntime` remains the sole dynamic chassis pose writer in the
`jolt_authoritative` profile. `TrackedChassisController` may materialize/reset
the body and copy the post-step snapshot to `ChassisMotionRoot`; presentation
nodes never correct the rigid-body pose. `TerrainState` remains the logical
surface authority and Python remains an optional gateway.

## Phase 1: Posture Calibration

1. Add diagnostic telemetry that distinguishes:
   - rigid-body up vector and pitch/roll;
   - imported visual root/rest orientation;
   - sampled terrain normal;
   - lowest compound-shape clearance and probe support distribution.
2. On reset/activation, compute the terrain-normal-aligned basis from the
   authoritative heightfield. Apply only at the spawn/reset transform boundary,
   then let Jolt settle under the existing support solver.
3. If the level pose still has a model-specific bias, add explicit bounded
   descriptor posture offsets (pitch/roll) or a short startup calibration window.
   The correction expires before normal command processing and cannot write the
   pose every frame.
4. Keep hull collision hysteresis and attitude PD as runtime stabilizers; do not
   use a stronger PD gain to conceal a wrong spawn basis or visual offset.

## Phase 2: Longitudinal Response

- Keep drive/brake limits derived from current per-probe support loads.
- Add a fixed-tick force-effort slew or acceleration envelope for drive and
  brake commands. The envelope must be sign-aware: releasing command reduces
  effort smoothly, while reverse requires crossing near-zero speed first.
- Tune `traction_response_n_per_m_s`, `brake_force_n`, `linear_damp`, and any
  new effort-slew fields per rig. Do not change chassis mass/inertia unless the
  diagnostic proves a body-level property is the cause.
- Preserve COM-height traction and differential yaw torque from the stabilization
  child. Any brake-induced pitch is an emergent bounded support response, not a
  separate pose animation.

## Telemetry Contract

Extend the post-step snapshot/test projection with finite values for:

```text
posture_error_rad
terrain_normal_alignment_deg
lowest_clearance_m
forward_speed_m_s
acceleration_time_s
brake_stop_time_s
brake_stop_distance_m
peak_pitch_angle_rad
peak_pitch_rate_rad_s
left/right_support_load_n
left/right_slip_ratio
left/right_saturated
```

Runtime status remains latest-value telemetry; it is not sent as authoritative
pose or terrain data to Python.

## Compatibility And Rollback

- Existing descriptor fields remain valid; new tuning fields are required only
  when the versioned rig schema is incremented, with no cross-model fallback.
- If posture calibration fails or terrain identity is unavailable, retain the
  current bounded spawn fallback and report a quality flag; do not block static
  startup.
- If response tuning regresses pivot or slope behavior, disable only the new
  effort-slew path through a temporary descriptor flag while retaining the
  stabilized support solver. Remove the flag before child completion if unused.

## Risks

- Terrain-normal alignment can make a slope entry look correct while changing
  track contact count; acceptance must check both posture and support ownership.
- Excessive brake smoothing can feel floaty; tune against stop time/distance and
  not only peak pitch.
- A visual GLB offset can be mistaken for rigid-body pitch; diagnostics must
  report both frames before changing physics descriptors.

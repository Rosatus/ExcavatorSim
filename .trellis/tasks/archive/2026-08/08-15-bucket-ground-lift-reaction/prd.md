# Bucket ground lift reaction

## Goal

When the bucket rear/shell is driven into the terrain in a supporting direction,
produce a convincing bounded chassis heave/pitch/roll reaction instead of treating
the bucket as visually passing through an immovable excavator.

## Requirements

- Depend on the completed chassis pose owner and automatic bucket-contact
  classifier; do not introduce a separate terrain or contact authority.
- Distinguish cutting-edge excavation from rear/shell support using the model's
  validated bucket proxy, contact normal, bucket motion, opening direction, and
  penetration against the authoritative terrain surface.
- Apply the MVP reaction as a stable, damped, bounded offset on
  `ChassisMotionRoot`: heave plus pitch/roll around a documented support polygon.
- Combine support offset with track terrain-following without double-writing nodes
  or feeding visual displacement back into its own penetration calculation.
- Ignore stale Jolt collision; fall back to coarse terrain probing. Collision
  impulses may inform presentation but cannot directly become an unbounded force.
- Release support smoothly when contact or actuator motion stops. Clamp penetration,
  lift height, tilt, velocities, and invalid/non-finite inputs.
- Reset all reaction state on world reset, reconnect, model switch, disabled feature,
  or authority generation change.
- Keep Python feedback optional for this milestone. Reuse the latest-value bucket
  load/contact telemetry if useful, but do not claim full Python chassis dynamics.

## Out Of Scope

- A free-flyer URDF, full excavator rigid-body mass distribution, track-ground force
  solver, hydraulic force limits, tipping/rollover, or arbitrary airborne motion.

## Acceptance Criteria

- [x] Rear/shell contact at supporting angles yields bounded lift/tilt; cutting-edge
      excavation and non-supporting contact do not trigger false lift.
- [x] Support remains stable and visually bounded with Jolt hints enabled or disabled;
      exact pose equality is not required.
- [x] The reaction composes with stationary, moving, pivoting, and sloped chassis
      states without transform double writes or cumulative drift.
- [x] Release is smooth and all offsets clear on reset/reconnect/model switch.
- [x] No visual/support transform feeds back into terrain volume, bucket inventory,
      Python joint pose, or the next raw penetration measurement.
- [x] Standalone tests cover classification, clamps, damping, lifecycle, both models,
      and Godot MCP live checks confirm convincing contact from several angles.

## Notes

The user explicitly accepts a visual-only fallback. This plan chooses that bounded
kinematic MVP because the current project has no dynamic chassis body or force model.

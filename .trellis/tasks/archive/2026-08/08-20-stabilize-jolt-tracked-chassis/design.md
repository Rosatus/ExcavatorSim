# Technical Design

## Support And Traction Ownership

`JoltChassisTrackRuntime` retains one `RigidBody3D`. Each track has bounded support probes distributed along its length. A probe hit supplies:

- contact position and terrain normal;
- suspension compression and compression velocity;
- clamped spring-damper normal force;
- local point longitudinal/lateral velocity;
- friction budget derived from that probe's normal force.

The per-probe force is:

```text
support = clamp(k * compression - c * compression_rate, 0, max_support)
longitudinal = clamp(speed_error * response, +/- friction * support)
lateral = clamp(-lateral_speed * resistance * skid_scale, +/- friction * support)
```

The suspension velocity is measured at the probe relative to the rigid body's
custom center of mass. Positive compression velocity adds damping support;
extension removes it. Reversing that sign creates positive feedback and is
forbidden.

Vertical support remains applied at each probe. Because the product uses one
provisional whole-machine rigid body rather than a resolved undercarriage,
longitudinal and lateral traction are applied at center-of-mass height. The
left/right offset is converted to an explicit yaw torque, preserving skid-steer
response without turning ordinary acceleration or braking into an exaggerated
pitch impulse.

A bounded PD attitude term aligns the chassis up axis with the smoothed average
support normal. It represents the omitted rigid undercarriage/load equalization,
not a second pose writer.

## Hull Collision

- Keep a simplified compound hull for startup recovery, obstacle impact and rollover safety.
- Release ordinary terrain collision only after both tracks have carried a stable load for several fixed ticks; restore it only after a lower, delayed loss threshold.
- Do not disable collision with non-terrain obstacles.
- Spawn/rest height is computed from support rest length rather than a few-centimeter box clearance.
- When an identity-valid collider ray temporarily misses, derive a bounded support sample from the same authoritative `TerrainState` heightfield so collision-mask restoration cannot occur only after the body has already crossed the surface.

## Skid Steer

- Compute straight/arc/pivot intent from left/right commands.
- Blend `skid_scale` from normal lateral resistance toward a configured pivot value as commands become opposite and symmetric.
- Use opposing longitudinal contact forces as the primary yaw moment.
- Replace the current saturated yaw torque with either no assist or a small PD correction capped below the natural traction moment.
- Clamp body speed only as a safety limit; target tracking should come from forces, not repeated hard clipping.

## Descriptor Additions

Model-specific track dynamics should include explicit fields such as:

- support rest length, stiffness, damping, and maximum force;
- maximum extension/compression and probe radius/shape;
- straight and pivot lateral-resistance scales;
- longitudinal response and brake response;
- optional yaw assist gain/cap;
- target linear/angular safety limits.

## Telemetry And Tests

Expose per-side and aggregate support load, compression, realized belt speed, slip, saturation, heave velocity, and roll/pitch rate. Tests compare realized values to descriptor targets rather than fixed tiny motion thresholds.

## Rollback

Keep the old force mode behind a temporary descriptor/runtime switch until both models pass. Remove the switch before parent completion if no rollback consumer remains.

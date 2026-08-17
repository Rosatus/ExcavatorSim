# Jolt Chassis And Track Authority

## Goal

Make a Jolt dynamic chassis the sole chassis pose/velocity authority in the new
profile, with convincing independent left/right crawler traction and terrain
support for SY205 and SY135 while work equipment remains frozen safely.

## Dependency

Requires the accepted contracts and local Jolt probe evidence from
`08-17-authority-contract-shadow-state`.

## Requirements

- Spawn a model-specific chassis body from validated physics descriptors; visual
  GLBs remain followers and dynamic concave visual meshes are forbidden.
- Use several contact/traction points per track with bounded longitudinal force,
  braking, coast, lateral resistance, slip, and differential yaw.
- Preserve four independent track actions and external command safety semantics.
- Use a terrain collider whose applied generation/revision participates in the
  physics snapshot; stale/unavailable terrain must stop activation or use an
  explicitly designed safe test surface, never invent a hidden authority.
- Disable direct chassis transform writes from `TrackedLocomotionState` and Python
  presentation only in the Jolt-authoritative profile.
- Freeze the upper/work equipment in a documented safe pose for this phase.
- Reset, disconnect, focus loss, model switch, invalid rig, or profile exit must
  stop forces and rebuild/clear body state deterministically enough for safety.

## Acceptance Criteria

- [ ] SY205 and SY135 accelerate, coast, brake, reverse, arc, and pivot from actual
      Jolt chassis state with bounded speed and slip.
- [ ] Chassis rests stably on flat/slope/uneven terrain, climbs a bounded obstacle,
      and does not tunnel or gain unbounded energy in the acceptance scenes.
- [ ] Exactly one chassis writer exists in Jolt mode; disabling the old kinematic
      controller cannot change the dynamic body pose.
- [ ] Contact/track telemetry reports tick, terrain revision, contact count, speed,
      slip, saturation, and quality.
- [ ] Lifecycle and model-switch tests leave no body, force, contact, or stale
      collider state behind.

## Out Of Scope

- Moving boom/arm/bucket joints, excavation terrain mutation, individual track
  shoes, rollover damage, or changing the default product profile.


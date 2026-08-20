# Stabilize Jolt tracked chassis

## Goal

Make SY205 and SY135 travel and skid-steer smoothly at a useful fraction of their configured belt speed without whole-machine jitter, while retaining the approved single dynamic Jolt chassis and simplified maintainable dynamics.

## Confirmed Problems

- The dynamic chassis boxes physically contact the concave terrain while independent track probes apply traction and lateral resistance.
- Traction limits use an estimated whole-machine `mass * gravity` budget rather than the normal load measured at each active support point.
- Counter-rotation combines opposing track forces, high lateral resistance, real box friction, and an additional yaw torque controller.
- Existing tests only prove tiny displacement/rotation and permit behavior that feels nearly stationary.

## Requirements

- Track probes become the coherent flat-ground support and traction source through bounded spring-damper normal forces.
- The chassis hull remains available for obstacles/rollover safety but must not be a second continuous load-bearing terrain surface.
- Longitudinal traction and braking limits must derive from measured support load and configured friction.
- Pivot demand must smoothly reduce lateral skid resistance; differential traction is the primary yaw source.
- A low-gain yaw assist may remain only if tests show it improves target tracking without oscillation.
- Commands, lifecycle/focus gating, model identity, truth snapshots, payload slowdown, and bucket support-wrench boundaries remain unchanged.
- Both model rig files receive explicit versioned tuning values; provisional physics values are not presented as production calibration.

## Acceptance Criteria

- [ ] Straight travel reaches at least 65% of configured belt-speed target after the acceleration window on flat ground.
- [ ] Counter-rotation reaches at least 45% of the configured differential yaw-rate target without sustained oscillation.
- [ ] Straight, arc, and pivot tests bound chassis heave and roll/pitch angular-rate RMS over a sustained command window.
- [ ] Releasing commands brakes smoothly without visible bouncing or yaw snap.
- [ ] Uneven or partial support reduces available traction instead of applying the full theoretical force budget.
- [ ] SY205 and SY135 pass lifecycle, reset, model-switch, truth, and no-Python standalone tests.
- [ ] Godot MCP live smoke confirms the excavator no longer visibly shakes during straight travel or pivot.

## Out of Scope

- Individual links/shoes, sprockets, rollers, suspension joints, deformable tracks, or production terramechanics.
- Dynamic work-equipment bodies or hydraulic simulation.
- Terrain deformation or bucket-soil behavior changes.

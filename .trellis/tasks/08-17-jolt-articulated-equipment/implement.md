# Implementation Plan

## Phase A: Descriptor And Rest-Frame Contract

- [ ] Add explicit converted body rest transforms and parent/child joint anchors to
      both versioned physics rigs; refresh catalog hashes and provenance.
- [ ] Tighten schema and `PhysicsRigDescriptor` validation for unique names, exact
      topology, unit axes, finite ordered limits, frame ownership, anchors,
      collision policy, and model/rig identity.
- [ ] Add descriptor-negative and rig-to-manifest rest/axis parity tests for SY205
      and SY135 before constructing any runtime body.

## Phase B: Complete Jolt Rig Ownership

- [ ] Refactor `JoltChassisTrackRuntime` from `_body` to a five-body registry while
      preserving the Phase 1 chassis/track API and single-owner teardown.
- [ ] Create slew plus boom/arm/bucket joints, collision filtering, mass/inertia,
      COM, damping, limits, and finite-state guards from the selected descriptor.
- [ ] Subscribe the controller to authority changes and rebuild the entire rig on
      reset, authority epoch, model, or profile change; require neutral input before
      applying post-rebuild effort.

## Phase C: Actuation And Payload

- [ ] Route the four accepted operator axes and command identity into the runtime.
- [ ] Implement target shaping, acceleration/jerk limits, damping, effort/load
      saturation, holding, limit anticipation, and invalid-input disarm.
- [ ] Add one tick-boundary bucket payload mass/local-COM adapter with identity,
      clamps, and rebuild/reset clearing.

## Phase D: Shared Snapshot, Visuals, And Truth

- [ ] Capture one immutable post-step snapshot for five bodies, four joints,
      contacts, payload, terrain, model/rig identity, epoch, tick, and quality.
- [ ] Make `MotionPresentation` consume that snapshot in Jolt mode; preserve the
      Python path only in `python_kinematic`.
- [ ] Drive the SY205 passive four-bar after physical arm/bucket pose without adding
      physical bodies or a closed loop.
- [ ] Make `SimulationTruthPublisher` serialize the runtime snapshot directly;
      remove Phase 1 frozen body/joint placeholders and quality flags.
- [ ] Disable the legacy bucket-ground lift writer in Jolt-authoritative mode while
      leaving terrain mutation for Phase 3.

## Phase E: Verification And Tuning

- [ ] Test each joint in both directions and at limits for both models, including
      rest-frame parity and target-versus-actual-versus-effort telemetry.
- [ ] Test mixed-axis motion, load slowdown/holding, chassis reaction, SY205 passive
      linkage invariants, and long-run energy/finite bounds.
- [ ] Test reset, disconnect, authority epoch, failed descriptor, model switch,
      profile rollback, neutral re-arm, and zero residual bodies/joints.
- [ ] Run `pixi run verify`, `pixi run backend-smoke`, the full Godot standalone
      matrix, and Godot AI MCP live operation for SY205 and SY135; record fixed-step,
      solver, and rebuild metrics.
- [ ] Update model, visual, client-boundary, runtime-profile, truth, and test docs
      without changing the default from `python_kinematic`.

## Risk And Rollback Points

- Descriptor/anchor parity is the first gate. Do not tune actuators on an inferred
  or visually misaligned chain.
- Keep a working checkpoint after Phase B's passive finite chain before adding
  motors and payload coupling.
- Disable `jolt_authoritative` and destroy the entire rig on any unrecoverable
  validation/solver failure. Never fall back per body or per joint.

## Rollback Point

Disable the articulated Jolt profile and destroy the entire rig on a new authority
epoch. Do not fall back per joint.

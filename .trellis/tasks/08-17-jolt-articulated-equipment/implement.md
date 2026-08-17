# Implementation Plan

- [ ] Complete validated body/joint/collision/actuator descriptors for both models.
- [ ] Extend PhysicsRig with upper, boom, arm, bucket bodies and four DOFs.
- [ ] Implement actuator target shaping, limits, damping, effort/load saturation,
      holding, and invalid-input safety.
- [ ] Add payload mass/COM adapter with tick-boundary identity and clamps.
- [ ] Add Jolt-mode visual adapter and preserve passive four-bar as visual-only.
- [ ] Publish target/actual/effort/body truth through the shared snapshot contract.
- [ ] Add isolated joint, multi-axis, loaded, chassis-reaction, lifecycle, model
      parity, and long-run stability tests.
- [ ] Run full gates and Godot MCP live operation for both models; record tuning and
      fixed-tick/solver metrics.
- [ ] Update model/visual/client authority specs while preserving legacy profile.

## Rollback Point

Disable the articulated Jolt profile and destroy the entire rig on a new authority
epoch. Do not fall back per joint.


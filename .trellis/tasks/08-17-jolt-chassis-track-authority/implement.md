# Implementation Plan

- [ ] Add validated chassis/track physics descriptors and provenance for both models.
- [ ] Build the isolated dynamic chassis rig, collision layers, safe spawn/reset,
      and visual follower adapter.
- [ ] Implement distributed track contact/traction and command safety integration.
- [ ] Gate old `TrackedChassisController` transform writes by authority profile and
      add runtime single-writer assertions.
- [ ] Integrate terrain collider identity and safe activation/failure behavior.
- [ ] Publish chassis/track truth through the Phase 0 snapshot contract.
- [ ] Add headless tests for motion cases, slopes/obstacles, clamps, invalid values,
      terrain identity, lifecycle, both models, and energy/speed bounds.
- [ ] Run standalone matrix and Godot MCP live handling/tuning scenes; record fixed
      tick costs and tuning values with evidence status.
- [ ] Update frontend authority and model contract specs without changing default.

## Rollback Point

Disable `jolt_authoritative` selection and destroy the chassis rig. Legacy tracked
locomotion remains available in its explicit profile until Phase 5.


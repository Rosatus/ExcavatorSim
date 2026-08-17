# Implementation Plan

- [ ] Audit every chassis/joint/contact/terrain/payload writer and add Jolt-profile
      single-authority assertions/tests.
- [ ] Change product launcher/config/UI defaults to Jolt authority and keep explicit
      legacy launch/profile selection.
- [ ] Remove/bypass obsolete duplicate Jolt-mode kinematic/visual/pose/contact paths.
- [ ] Complete cross-layer lifecycle, model/profile switch, gateway loss, stale
      transport/collider, invalid rig, and rollback tests.
- [ ] Establish and pass fixed-step/render/network/queue/memory/soak budgets on the
      Windows target for both models and representative excavation scenarios.
- [ ] Run full backend, smoke, Godot matrix, MCP live, compatibility, and release
      candidate gates.
- [ ] Update architecture, source-of-truth specs, protocol/version docs, README,
      start commands, operator diagnostics, migration guide, and rollback guide.
- [ ] Perform final parent acceptance review before archiving this child/parent.

## Rollback Point

Revert only the default profile/launcher selection and start a fresh explicit
`python_kinematic` session. Do not hot-switch an established Jolt world.


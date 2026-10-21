# Implementation Plan

- [x] Audit every chassis/joint/contact/terrain/payload writer and add Jolt-profile
      single-authority assertions/tests.
- [x] Change product launcher/config/UI defaults to Jolt authority and keep explicit
      legacy launch/profile selection.
- [x] Remove/bypass obsolete duplicate Jolt-mode kinematic/visual/pose/contact paths.
- [x] Complete cross-layer lifecycle, model/profile switch, gateway loss, stale
      transport/collider, invalid rig, and rollback tests.
- [ ] Establish and pass fixed-step/render/network/queue/memory/soak budgets on the
      Windows target for both models and representative excavation scenarios.
- [x] Run full backend, smoke, Godot matrix, MCP live, compatibility, and release
      candidate gates.
- [x] Update architecture, source-of-truth specs, protocol/version docs, README,
      start commands, operator diagnostics, migration guide, and rollback guide.
- [x] Perform final parent acceptance review before archiving this child/parent.

## Rollback Point

Revert only the default profile/launcher selection and start a fresh explicit
`python_kinematic` session. Do not hot-switch an established Jolt world.

## Validation Evidence

- Backend: `pixi run verify` passed with 170 tests; gateway+legacy production
  smoke passed.
- Godot: 4.7.1 standalone matrix passed 18/18. SY205/SY135 peak fixed steps in
  the chassis test remained below 0.7 ms; bucket query median/p95 remained below
  0.3 ms in the measured run.
- Godot AI MCP: default SY205 session reached `ready`, exposed one
  `JoltChassisTrackRuntime/AuthoritativeChassisBody`, moved about 1.68 m under a
  120-frame dual-track command, and streamed bounded sensor history to the
  gateway with zero reported drops.
- Deferred release evidence: a longer two-model render/network/memory soak with
  representative loaded excavation. The repository has no integrated harness for
  this gate yet; it remains unchecked and moves to the parent release acceptance.

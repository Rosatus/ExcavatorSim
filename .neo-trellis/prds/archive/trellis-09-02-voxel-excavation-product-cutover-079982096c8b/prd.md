# Voxel excavation product cutover

## Goal

Integrate Jolt traversal and scene UX, complete performance/manual acceptance, remove obsolete heightfield excavation paths, and update product documentation.

## Requirements

- Depend on accepted and archived foundation, cutting, and soil-cycle children.
- Make voxel excavation the product-default and ultimately sole mutable soil
  path while Terrain3D remains hard surrounding terrain.
- Complete Jolt travel, parking, support, collision-lag gating, bucket work near
  tracks, reset, pause, model-switch, teardown, and generation transitions.
- Expose useful operator/advanced status for edit backlog, mesh/collision
  readiness, rejected operations, bucket mass/fill, and conservation.
- Preserve Bucket Pass semantics, non-soil machine controls, Gateway/Python/CAN
  contracts, and project visual quality profiles.
- Complete one stable full-scope automated gate and focused human acceptance.
- Only after human acceptance, delete obsolete heightfield excavation solvers,
  active/loose/parcel ownership, duplicate terrain collider paths, obsolete
  switches, tests, and documentation.
- Update notices, architecture, specs, and packaging provenance to match the
  actual Voxel Tools product dependency and authority.

## Acceptance Criteria

- [ ] The full user journey—spawn, enter, traverse, park, cut, fill, dump,
  settle, compact, re-dig, reset, and repeat—works for both models without
  fall-through, seam snagging, stale-state resurrection, or visible stalls.
- [ ] Automated authority/lifecycle/seam/Jolt/both-model/conservation tests pass,
  followed by one stable full Godot matrix and one representative performance
  gate because shared product authority changes.
- [ ] Gateway/Python protocols, CAN encoding/sending, and non-soil input/motion
  behavior are unchanged by the cutover.
- [ ] Human Forward+ review explicitly accepts visual cleanliness, alignment,
  machine and soil interaction feel, traversal, material/seam appearance, and
  sustained subjective smoothness.
- [ ] Product code exposes one voxel excavation authority and contains no live
  heightfield cutting/loose-material fallback or double collider in the zone.
- [ ] Documentation and notices accurately describe Voxel Tools as the mutable
  soil implementation and Terrain3D as immutable surroundings.

## Out of scope

- New persistence, networking, hardware, CAN, or Gateway features.
- Whole-world voxel conversion or multiple work zones.
- New soil physics beyond the accepted child-task implementation.
- Release package creation unless separately requested during finishing.

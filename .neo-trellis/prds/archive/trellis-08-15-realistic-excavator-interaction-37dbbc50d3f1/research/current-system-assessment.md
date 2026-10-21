# Current System Assessment

> Historical assessment from 2026-08-15. Its Python-joint, local-locomotion, and
> direct visual-lift boundaries were superseded by the archived 08-17 hybrid Jolt
> roadmap. Use `final-acceptance-gap.md` and `docs/architecture/engineering.md`
> for implementation decisions. The notes below are retained only as lineage for
> the three completed 08-15 children.

## Existing Boundaries

- Python owns four upper-structure joints; current motion schemas do not contain
  track or chassis state.
- `TerrainState` owns stable height plus loose depth. `BucketSoilState` owns a local
  scalar volume, currently with a global `0.35 m3` constant.
- Dig/Deposit are deterministic manual product/test seams. They queue fixed-step
  commands using a point proxy; there is no production bucket collider or swept
  cutting edge.
- Terrain3D and the Jolt terrain collider consume accepted snapshots and do not own
  deformation. Soil GPU particles consume change events and do not own volume.
- `MotionPresentation` already applies the Python base transform. Local locomotion
  therefore needs a distinct parent root to avoid double-writing that node.

## Planning Consequences

1. Establish a local chassis coordinate frame before deriving bucket trajectories.
2. Replace manual production commands with continuous swept geometry and local
   dynamic-soil presentation while retaining direct queue APIs for tests.
3. Reuse the automatic contact classifier for support reaction, but keep the first
   lift implementation bounded and visual/kinematic.
4. Treat latest-value payload feedback to Python as an explicit versioned protocol
   exception to the current no-writeback boundary, not an incidental transport field.
5. Keep the current stable/loose field as a coarse persistent shape and avoid a full
   terrain mesh/collider rebuild for every local material update.

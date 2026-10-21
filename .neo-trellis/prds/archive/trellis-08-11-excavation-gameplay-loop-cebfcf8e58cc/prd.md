# Excavation gameplay loop

## Goal

Deliver the first local excavation interaction in Godot. The accepted Python pose
is used only to derive a configurable bucket contact proxy; Godot owns the
deterministic soil edit and bucket inventory for this profile.

## Requirements

- Keep `TerrainState` as the only local terrain authority. Add a focused
  `BucketSoilState`/`ExcavationWorld` layer rather than a second terrain store.
- Use explicit algorithm/version constants, a monotonic local command sequence,
  and a fixed-step queue. Invalid, duplicate, stale-generation, non-contact and
  over-capacity commands must be mutation-free.
- A cut samples the bucket tooth proxy against the terrain surface, removes a
  bounded brush depth, and increases bucket volume by the exact removed grid
  volume. A deposit requires dump clearance, adds bounded loose depth, and
  decreases bucket volume by the exact deposited volume. Volume stays in
  `[0, 0.35 m^3]`.
- Reset/pose clear/authority generation changes clear bucket volume, pending
  commands, contact history and optional collider work.
- Add an optional generation-gated static heightfield collider adapter. It is
  disabled by default and must fail open: missing/disabled/failing local physics
  cannot stop terrain edits or motion presentation and never writes to Python.
- Provide a small scene/UI seam for explicit dig and deposit requests while
  retaining test seams that do not require a live WebSocket or physics engine.
- Do not change Python wire schemas, motion authority, replay, GLB asset bytes,
  or introduce dynamic rigid-body authority in this milestone.

## Acceptance Criteria

- [x] Same seed, pose/contact sequence and command sequence produce identical
  terrain snapshot bytes/digest, terrain revision and bucket volume.
- [x] Cut/deposit conserve volume within one Float32 cell-area operation and
  reject invalid, stale, non-contact and capacity-underflow/overflow requests
  without changing state.
- [x] Reset advances the local generation, restores baseline/zero inventory and
  rejects old queued contact/collider work.
- [x] The optional collider builds a current generation when enabled and a
  disabled or intentionally unavailable collider leaves the excavation path
  operational.
- [x] Godot scene smoke and `pixi run verify` remain green; no local state is
  sent back to Python.

## Notes

- Contact offsets are explicit configuration because the supplied GLB has no
  authoritative teeth/collision markers. Visual meshes remain presentation-only.

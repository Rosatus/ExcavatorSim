# Design — excavation gameplay loop

## State ownership

`BucketSoilState` is a pure `RefCounted` local gameplay state. It references the
existing `TerrainState` but does not duplicate its height layers. It owns only
bucket volume, contact history, operation sequence and pending commands. The
`ExcavationWorld` node adapts scene/motion inputs to this state and forwards
copied terrain snapshots to derived render/collider nodes.

The bucket proxy is three explicit local points configured on `ExcavationWorld`
(left/center/right tooth offsets). A command contains the world-space previous
and current center tooth, a generation, and a fixed operation sequence. No
visual mesh bounds or physics callback is authoritative.

## Fixed-step operation

At each `step_fixed`, commands are sorted by sequence and rejected unless their
generation matches the current terrain generation. A cut requires the current
tooth to be inside the grid and no higher than sampled surface plus the contact
tolerance. A bounded negative radial brush is preflighted with
`TerrainState.estimate_brush_volume`; if capacity is insufficient the command is
rejected before mutation. A deposit requires dump clearance and positive bucket
inventory; its positive brush depth is scaled by the requested grid volume so
the actual added volume is exactly removed from inventory.

Terrain revision remains owned by `TerrainState`. Bucket volume changes only by
the measured grid-cell volume returned by the same deterministic brush model.
The result dictionary is diagnostic/local UI data and is never serialized to
Python.

## Optional collider

`TerrainCollider` is a derived `Node3D` with `enabled=false` by default. When
enabled it creates a `StaticBody3D` and one heightfield chunk from a copied
snapshot. Rebuilds are generation/revision gated and replace the shape only
after successful construction. A missing `HeightMapShape3D`, disabled physics,
or any build error records `available=false` and leaves the mesh/interaction
path untouched. Chunk metadata is retained so later milestones can split the
heightfield without changing the gameplay contract.

## Lifecycle

`ExcavationWorld.reset_for_test` resets terrain then bucket state and invalidates
collider work. `on_motion_pose_cleared` and `on_authority_generation_changed`
call the same local reset without touching Python. UI buttons call explicit
`request_dig`/`request_deposit`; test seams call world-space methods directly.

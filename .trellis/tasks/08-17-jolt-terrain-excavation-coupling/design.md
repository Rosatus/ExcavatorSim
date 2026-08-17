# Design

## Contact To Soil Flow

```text
Jolt contact/sweep at physics tick
  -> immutable contact summary (rig + terrain identity)
  -> soil interaction classifier
  -> one TerrainCommitScheduler/BucketSoilState transaction
  -> payload mass/COM adapter for a later safe tick
  -> copied renderer/Terrain3D/collider/effect updates
```

Jolt supplies contact geometry and physical reaction. The soil classifier owns the
semantic decision and volume. Neither Jolt penetration nor Terrain3D height edits
directly mutate logical terrain.

## Collider Transaction

Prepare a new static collider from a copied accepted terrain snapshot. Switch the
applied revision only at a controlled tick boundary, invalidate old manifolds, bound
penetration recovery, and include the applied revision in every contact summary.
Edits produced this tick become eligible for a later collider revision, preventing
recursive same-tick self-feedback.

## Bucket Proxies

Use separate convex primitives/compound shapes for cutting edge, cavity/shell, and
rear support. Descriptor evidence distinguishes observed, declared, derived, and
tuned dimensions. The existing soil proxy contracts remain comparison fixtures,
not unquestioned physics truth.

## Payload And Effects

BucketSoilState produces mass/local COM/fill from conserved occupancy. The physics
payload adapter applies a bounded next-tick update. Hero clods and particles consume
events but cannot feed terrain, payload, or contact authority.

## Rollback

Disable contact-to-soil coupling and return to the explicit legacy excavation/profile
path on a new authority epoch. Never keep Jolt body reaction while applying a second
heuristic chassis lift in the same profile.


# Technical Design

## State Ownership

`BucketSoilState` remains the capacity and conservation owner. Add a transfer ledger with states:

```text
terrain_loose -> activated_dynamic -> world_parcel -> bucket_candidate
bucket_candidate -> bucket_captured -> dumped_world -> settled -> terrain_loose
```

Each parcel carries transfer ID, volume, mass, model/generation identity, state, and a Jolt body handle. The ledger owns volume even when the visual body is temporarily unavailable.

## Shovel Active Zone

Extend the model soil contract with cutting edge, cutting direction, lip/opening plane, cavity bounds, and shell plate shapes. `ExcavationWorld` keeps the current query-only sweep for terrain evidence. A valid cut requires:

- cutting-edge evidence on the current collider identity;
- motion entering the surface;
- forward/downward cutting direction;
- no stale/initial-overlap query evidence.

The terrain transaction removes the accepted active-zone volume and hands it to the parcel manager instead of calling `_add_occupancy` directly.

## Moving Bucket Shell

Create one parcel-only `AnimatableBody3D` per active excavator model, with convex thin plates for bottom, back, and sides. Update its transform from the accepted bucket FK every fixed tick. The shell:

- collides with the dynamic parcel layer;
- does not collide with Terrain3D/TerrainCollider or chassis;
- has an open lip so gravity can release parcels;
- is rebuilt on model/generation changes, not each frame.

This gives parcels real collision surfaces without introducing a dynamic bucket body or allowing bucket/terrain solver impulses to reintroduce chassis jitter.

## Parcel Pool

- Quality budgets: 32 low, 64 balanced, 96 high, absolute cap 128.
- Each body has a volume tag and approximating sphere/convex shape. The body is a visual/physical carrier, not an independent mass-authority writer.
- Large cut volume may be represented by a small number of larger parcels plus a non-body aggregate remainder.
- Bodies use CCD or conservative spawn offsets, sleep quickly, and are recycled only after settlement, timeout, or generation clear.

## Capture And Release

- A candidate is captured when its center and swept bounds cross the lip into the cavity, it is moving with the shell within a tolerance, and the bucket has capacity.
- Capture has a short hysteresis window to prevent lip chatter. Rejected parcels remain world-dynamic.
- Captured parcels contribute to bucket volume and COM; the fill surface is generated from the aggregate and aligned to world gravity, not cavity-local Y.
- Dump/spill transitions captured parcels to world-dynamic at the opening position. Initial velocity is bucket opening point velocity plus bounded jitter; gravity is the only sustained vertical acceleration.
- Parcels contacting loose terrain below a speed/angle threshold for a settle window merge into a batched deposit brush. The body is then recycled.

## Visual Layers

1. Captured parcels/aggregate inside the cavity for silhouette and contact.
2. Coarse gravity-aligned fill surface for bulk volume that has no active body representation.
3. GPU fines/dust for cut and dump atmosphere. Fines never write ledger volume.

## Failure Handling

- If parcel allocation fails, keep the removed volume in a bounded aggregate remainder and expose a quality flag; never lose it or silently credit it to the bucket.
- If terrain patch commit fails, keep the parcel transfer pending and retry/rollback atomically.
- If model/generation changes, freeze and recycle all bodies, clear candidate transfers, and rebuild the shell from the new contract.


# Design — bucket parcel interaction realism

## Ownership and data flow

`BucketSoilState` remains the only bucket-inventory owner and `TerrainState`
remains the only terrain authority. Accepted cuts create bounded physical
parcel carriers without crediting the bucket. Cavity capture progressively
credits `BucketSoilState`; dump/spill removes that occupancy exactly once and
creates guarded parcels at the opening.

Grounded parcels use `queue_parcel_deposit_volume`, not the ordinary bucket
deposit command. The parcel-specific command may add loose terrain but cannot
read or remove bucket occupancy because that material already left the ledger
or came directly from a cut. Its result carries the command sequence and
terrain transfer ID. `SoilParcelPool` freezes the matching body while pending
and recycles it only after that exact transfer commits; rejection releases the
body for retry. Missing or delayed results retain that identity indefinitely so
a late commit cannot be followed by a duplicate retry. Partial acceptance
resizes the physical remainder.

## Bucket barrier and capture

One `AnimatableBody3D` owns four overlapping `BoxShape3D` plates in cavity-local
space: floor at -Y, back at +Z, sides at ±X, with +Y open. The barrier uses only
the machine collision layer. Pooled parcel bodies reapply configured layers and
masks after setup because `_ready()` can create them before their production
configuration arrives. Continuous collision detection and overlapping closed
seams prevent small fast parcels escaping at floor/wall corners.

The barrier follows the accepted cavity transform every fixed tick. Model
activation updates all plate positions and sizes in place from the new cavity
contract. Capture freezes a slow contained parcel at its cavity-local point for
about 0.18 seconds while its remaining volume, mass, mesh, and collider shrink
together. If capacity stalls, the remainder unfreezes as a physical overflow
body and may retry only after capacity becomes available.

## Directional spray and lifecycle

Each accepted cut exposes fixed-tick tooth velocity. Parcel launch velocity is
that stroke velocity plus bounded world-up spread. If every fixed body is busy,
accepted cut volume accumulates in one bounded-memory aggregate backlog and
drains into the next free carriers; an authoritative parcel is never stolen.
Reset, authority generation change, model activation, and feature clear recycle
the pool and clear pending cut/settle identity. Visual/physical parcel state
never gates analytic cutting.

## Compatibility and rollback

The change is Godot-local and adds no protocol field. Ordinary debug/manual
bucket deposit semantics remain unchanged. Rollback can remove the barrier and
parcel-specific deposit entry point without changing TerrainState, Jolt chassis,
or Python compatibility profiles, but would restore the known pass-through and
double-debit defects.

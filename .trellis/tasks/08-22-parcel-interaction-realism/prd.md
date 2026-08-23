# Bucket parcel interaction realism

## Goal

Remove the three sources of awkward bucket-parcel interaction and close the
verification tails left by the transport task: parcels currently fly straight
through the bucket walls (work equipment is pure kinematic transforms with no
collision), captured chunks vanish instantly mid-air, and cut spray is an
isotropic puff instead of directional spoil.

## Requirements

### R1. Open-mouthed bucket barrier

- A kinematic `AnimatableBody3D` barrier owned by `SoilParcelPool` mirrors
  the cavity frame every fixed tick: floor plate at -Y, back plate at +Z
  (rear-support side, opposite the teeth), two side plates at ±X, mouth
  (+Y) left open so dumping pours freely.
- Barrier lives on the machine collision layer so existing parcel masks hit
  it; no other system masks machine, so support probes, sweeper queries, and
  the chassis hull are unaffected.
- Plate sizes derive from the cavity contract half-extents plus thickness.

### R2. Progressive absorption

- Capturing a parcel no longer teleports its volume into the ledger: the
  parcel enters an absorbing state that transfers volume over ~0.18 s while
  the mesh/collider shrink proportionally, so chunks visibly melt into the
  carried load.
- If capacity fills mid-absorption, the remainder stops absorbing and rests
  physically against the shell walls as visible heaped overflow.

### R3. Directional cut spray

- Cut events carry tooth velocity ((current - previous) / fixed dt) and the
  pool biases spawn spread upward so soil lifts out of the ground along the
  stroke instead of popping isotropically.

### R4. Verification tails

- Volume conservation: released pour volume equals accepted settle deposits;
  occupancy decreases exactly once per poured volume.
- Gameplay/release-candidate suites stop encoding the superseded
  "bucket is always empty" semantics; carry/spill/dump expectations point to
  the parcel pipeline instead of contradicting it.

## Acceptance Criteria

- [x] Parcels thrown at the bucket rest against shell walls instead of
      passing through; the mouth stays passable.
- [x] Capture is visually gradual; overflow parcels remain as physical heap.
- [x] Digging spray lifts directionally with the stroke.
- [x] Conservation assertion passes; gameplay/M7 suites green with updated
      semantics; full matrix green.

## Out of Scope

- Per-plate shell geometry from GLB meshes; boxes approximate the cavity.
- Parcel-vs-parcel collision or angle-of-repose heaps above the heightfield.

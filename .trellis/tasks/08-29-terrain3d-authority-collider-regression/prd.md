# Terrain3D authority and collider regression

## Goal

Prove that native Terrain3D presentation is observationally equivalent to the
fallback for gameplay truth, soil conservation, payload, and Jolt terrain use.

## Dependencies

Phases 0–2 must be completed. Phase 2 must expose stable native/fallback
selection and applied snapshot diagnostics.

## Requirements

- Run identical fixed command sequences under native and fallback presentation
  for both SY205 and SY135.
- Compare `TerrainState` stable/loose bytes and digest, generation/revision,
  selected soil ledger compartments/totals/invariants, bucket payload mass/COM/
  fill, fixed-tick outcomes, Jolt truth identity, and accepted transforms.
- Keep Terrain3D collision mode zero in production tests. Prove chassis and
  bucket query hits come only from the project `TerrainCollider`, with logical
  heightfield fallback on miss/stale/unavailable identity.
- Exercise startup, cut, carry, spill/dump, settle, repeated excavation,
  locomotion, reset, reconnect, model switch, Test Grid, and native failure.
- Presentation quality/material/dressing changes must not affect command cadence,
  accepted volume, payload, terrain, or Jolt motion.
- Any divergence is a stop condition; do not normalize it away with loose visual
  tolerances or change gameplay to match Terrain3D.

## Acceptance Criteria

- [ ] Native and fallback produce byte-identical terrain layers/digest and equal
  terrain identity for the same deterministic command sequence.
- [ ] Selected soil ledger totals, transaction identities, conservation/invariant
  results, and bucket payload are equal within existing domain tolerances.
- [ ] Jolt truth, accepted chassis/articulation outcome, track contact provenance,
  and bucket query/support identity retain their existing contract.
- [ ] Terrain3D collision remains disabled; no Terrain3D collision object is an
  accepted chassis/bucket query source.
- [ ] Native failure or Test Grid transition changes only presentation and does
  not rotate authority/material generation or interrupt fixed-tick behavior.
- [ ] Both models and full reset/model-switch lifecycle pass the equivalence suite.

## Out of Scope

- Product default cutover, native collision enablement, geotechnical calibration,
  visual tuning, or changes to soil/Jolt truth contracts.

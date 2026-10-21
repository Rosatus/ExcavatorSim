# Soil authority migration evidence

## Automated migration result

- Product default: `active_patch`.
- Clean-boundary modes: `legacy`, `shadow`, `active_patch`.
- Product writers by stage:
  - legacy/shadow: legacy owns cut, bucket entry, release, and settlement;
  - active_patch: conservative authority owns all four stages.
- A requested mode never changes the selected live generation. Active runtime
  failure pauses writes and requests legacy for the next reset.
- Active mode does not step/reconcile `BucketSoilState` and does not invoke
  parcel capture, release, or terrain-settlement callbacks. Patch
  representatives replace parcel hero clods in this mode.

## Expected comparison deltas

| Comparison | Expected result | Classification |
|---|---|---|
| legacy vs shadow product terrain | Same product digest/revision | expected: shadow isolation |
| shadow vs active product terrain | Active changes product digest/revision | expected: selected writer cutover |
| legacy cut before parcel capture | Bucket remains empty | expected: compatibility transport |
| active opening flux | Conservative bucket ledger becomes nonzero | expected: full-bucket lifecycle |
| low vs high representative count | Different | expected: presentation/performance quality |
| low vs high accepted displacement/opening flux | Equal within `1e-5 m³` | expected: quality is not authority |
| selected payload/Jolt/truth | One selected ledger identity | expected: no mass addition |

No unexplained material or identity delta remained after the automated journeys.

## Executed gates

- `soil_authority_migration_test.gd`: generation lock, double-owner rejection,
  runtime-fault pause, next-generation fallback, product-backed terrain write,
  safe detach, and active lifecycle identity passed.
- `soil_interaction_authority_test.gd`: SY205 and SY135 shadow plus active
  cut/scoop/carry/dump/settle journeys passed; low/high logical volume matched;
  shadow product terrain stayed unchanged; active product terrain changed;
  active and shadow 20-cycle runs stayed inside
  `max(1e-5 m³, 0.5% bucket capacity)` with zero invariant failures.
- `offline_product_test.gd`: default active selection, selected payload, strict
  active truth, boundary-only legacy fallback, and restoration to active passed.
- Legacy analytic, parcel, gameplay, and release-candidate compatibility tests
  passed when explicitly selecting legacy.
- Active-patch CPU benchmark passed:
  - low: p95 `1.230 ms`, 120 representatives;
  - balanced: p95 `3.192 ms`, 216 representatives;
  - high: p95 `5.710 ms`, 366 representatives.
- Godot standalone matrix passed through every script before the one legacy
  release-candidate assumption was found; that scenario was pinned to legacy,
  then `release_candidate_test.gd` and the final `offline_product_test.gd`
  passed directly.
- `pixi run verify`: 175 backend tests plus lint, mypy, provenance, and
  standalone path verification passed.

## Deferred human gate

Per the user's direction to prioritize code and avoid repeated assistant visual
inspection, no subjective screenshot/video review was performed here. One human
operator review of carry readability, dumping, pile formation, grading, and
60-FPS feel for both models is transferred to
`08-24-product-experience-validation`; it remains the release/promotion gate,
not a reason to add another material writer.

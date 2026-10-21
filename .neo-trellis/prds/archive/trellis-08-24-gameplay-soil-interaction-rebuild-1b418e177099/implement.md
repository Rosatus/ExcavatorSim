# Implementation plan

This parent owns requirements and final integration. Implementation happens in
five independently checked children.

1. [ ] `08-24-full-bucket-soil-tool-contract`
       - Add SY205/SY135 semantic tool descriptors and validated local proxies.
       - Compose fixed-step swept regions from accepted bucket poses.
       - Publish shadow-only interaction classification and debug evidence.
2. [ ] `08-24-local-active-soil-patch-prototype`
       - Extend/wrap the persistent field with material/compaction contracts.
       - Prototype fixed-budget active conversion, flow, pile, and settle.
       - Benchmark candidate implementation paths and select the simplest one
         meeting balanced/low fallback budgets.
3. [ ] `08-24-conservative-soil-material-lifecycle`
       - Introduce the sole fixed-tick transfer authority and journal.
       - Connect full-tool cut/push/grade, bucket entry/carry/spill/dump, and
         conservative patch-to-terrain settlement.
       - Keep legacy ownership intact behind mode selection.
4. [ ] `08-24-game-feel-digging-response`
       - Derive normalized interaction phases and intensity.
       - Apply safe bounded work-equipment speed reduction and expose stable
         presentation telemetry; do not add hydraulic simulation.
5. [ ] `08-24-soil-authority-migration-validation`
       - Run shadow comparisons and cut over only at generation boundaries.
       - Convert legacy parcels to visual-only hero clods in primary mode.
       - Close two-model conservation, lifecycle, performance, visual, fallback,
         and regression gates; retain compatibility fallback after archive.

## Required dependency order

```text
full-bucket tool contract ----┐
                              +-> conservative lifecycle -> game feel -> migration
local active patch prototype -┘
```

The first two children may be implemented independently after their plans are
approved. The conservative lifecycle requires both contracts. Visual polish may
consume only versioned read-only snapshots and should integrate after the
lifecycle/response schemas stabilize.

## Global validation

- Focused deterministic tests for every new state owner and model descriptor.
- Real offline SY205/SY135 dig → carry → dump → settle journeys with no debug
  credit and with material-conservation assertions.
- Repeated push/back-drag/grade and 20-cycle material soak.
- Legacy/shadow/active mode lifecycle and rollback matrix.
- Low/balanced/high 1920×1080 evidence, balanced 60 FPS trace, and explicit
  active-soil CPU/GPU/memory budgets.
- Godot standalone matrix, offline product/release-candidate tests,
  `pixi run verify`, Trellis validation, provenance, `git diff --check`, and
  human side-by-side visual review.

## Risk and rollback points

- Never enable old parcel credit/debit/deposit together with the new authority.
- Change ownership only on reset/model/authority generation boundaries.
- Preserve TerrainCommitScheduler as the persistent-field write gateway and
  keep render/collider latency presentation-only.
- Keep one valid terrain presentation when Terrain3D or the active visual path
  fails.
- Do not delete legacy compatibility behavior in this parent; deletion requires
  a later stability decision backed by shipped/soak evidence.

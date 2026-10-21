# Local active soil patch prototype

## Goal and user value

Prove that a bounded soil region near the bucket can visibly separate, flow,
pile, and settle while preserving the persistent terrain contract and the
balanced-profile frame budget.

## Requirements

- Extend or wrap the persistent field with material preset and game-level
  compaction while preserving stable/loose height, generation, revision, dirty
  rectangles, snapshots, and the scheduler single-writer boundary.
- Implement a configurable 3–5 m active patch with fixed per-profile budgets for
  cells/representatives, neighbors/constraints, substeps, memory, and tick time.
- Convert explicit persistent volume into patch material and conservatively
  rasterize sleeping/evicted material back as loose terrain.
- Demonstrate gravity, floor/bucket-proxy collision, lateral displacement,
  pile formation, and angle-of-repose-like settling suitable for game visuals.
- Run only in shadow/prototype mode: legacy analytic/parcel state remains product
  authority and the prototype cannot credit/debit the bucket.
- Benchmark the simplest viable CPU grid/particle implementation and, only if
  needed, a Godot compute implementation. Select and document the production
  path plus low/fallback behavior.

## Acceptance criteria

- [ ] A repeatable cut-volume injection forms dynamic soil, a visible pile, and
      a settled persistent-field update with conserved aggregate volume within
      documented quantization tolerance.
- [ ] Moving/rotating bucket proxies visibly push and contain active material;
      disabling the prototype leaves legacy product snapshots unchanged.
- [ ] Repeated patch move/evict/reactivate cycles do not leak representatives,
      duplicate material, leave seams, or lose generation identity.
- [ ] Loose, compact, sand-like, and damp/cohesive presets are visually
      distinguishable without claiming calibrated geotechnical behavior.
- [ ] Balanced 1920×1080 sustains 60 FPS on the development machine with the
      selected active patch; the selected path records median/p95 soil time,
      memory, latency, and per-profile budgets. The production gate is p95 update
      cost ≤2/4/6 ms and memory ≤96/256/512 MiB for low/balanced/high.
- [ ] Unsupported compute or allocation failure falls back cleanly to the coarse
      CPU/legacy visual path without changing product authority.
- [ ] Prototype, field, lifecycle, performance, and standalone tests pass.

## In scope

Persistent-field schema extensions, patch storage/solver prototype, activation
and settle adapters, read-only bucket proxy collision, quality budgets,
benchmark evidence, debug rendering, tests, and design decision record.

## Out of scope

Product authority cutover, bucket material ledger ownership, hydraulic forces,
full-field particles, arbitrary overhangs/caves, simultaneous-machine overlap,
or replacing Terrain3D/fallback presentation.

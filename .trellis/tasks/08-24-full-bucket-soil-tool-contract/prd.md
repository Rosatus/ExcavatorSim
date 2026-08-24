# Full bucket soil tool contract

## Goal and user value

Replace the single cutting-edge-origin trigger with a complete, model-specific
bucket interaction description so the rendered bucket can credibly cut, scrape,
push, grade, contain, and release soil.

## Requirements

- Define simplified local-space regions for SY205 and SY135: teeth/main edge,
  side cutters, floor/wear plate, outer back/sides, inner shell, and opening.
- Assign stable-soil and active-soil roles per region. Inner surfaces contain and
  guide active material; they do not independently erase stable terrain.
- Compose every region from the accepted fixed-step bucket pose identity and
  provide previous-to-current swept coverage for fast motion.
- Classify contact intent as cut, side_cut, scrape, push, back_drag, grade,
  compact, contain, entry, spill, dump, or none using motion direction, surface
  normal, overlap, and bucket orientation.
- Publish immutable, generation-scoped shadow telemetry and optional debug
  geometry. This child must not change terrain, bucket volume, Jolt motion, or
  existing parcel behavior.
- Keep descriptors in model contracts/data rather than hard-coding SY205 paths.

## Acceptance criteria

- [ ] Both models validate all required regions, finite transforms, dimensions,
      normals, opening orientation, and capacity/cavity consistency at load time.
- [ ] Debug views remain aligned throughout the accepted boom/arm/bucket range;
      no region visibly drifts or uses the wrong model after switching.
- [ ] Deterministic swept tests distinguish forward cut, side cut, floor scrape,
      back push/grade, inner containment, and dump opening without single-point
      tunneling.
- [ ] A resting or separating bucket produces no cut intent, and full-shell
      overlap cannot delete the whole enclosed terrain volume.
- [ ] Enabling shadow classification leaves terrain snapshots/revisions, bucket
      ledger, parcel snapshot, and accepted equipment motion unchanged.
- [ ] Focused contract/classifier/model-switch tests and the standalone matrix
      pass for SY205 and SY135.

## In scope

Model descriptor schema/data, validation, composed/swept proxy math, semantic
classification, debug visualization, read-only telemetry, tests, and specs.

## Out of scope

Terrain mutation, active-soil solving, bucket credit/debit, game-feel speed
changes, raw per-triangle GLB collision, or changing the rendered bucket asset.

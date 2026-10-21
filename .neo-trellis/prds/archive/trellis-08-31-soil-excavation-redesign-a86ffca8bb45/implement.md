# Implementation plan — arcade stamp v3

## Working rules

- This plan supersedes the unaccepted v2 cutover plan. Do not edit product code
  until the updated planning summary receives fresh user approval.
- Preserve unrelated `docs/procurement/` work and all Gateway/CAN behavior.
- Use Godot AI MCP for live scene, proxy alignment and runtime diagnostics.
- Run narrow deterministic code tests during development. Human Forward+ owns
  cut cleanliness and stutter judgment; run the broad matrix once after stable
  manual acceptance, with no paired soak.

## Phase 0 — Freeze failure evidence and rollback

- [x] Record the second manual failure (`most soil not removed`, continued
  stutter) and selected runtime solver evidence.
- [x] Keep current uncommitted v2 work intact as a selectable diagnostic path;
  do not make it the default.
- [x] Add a focused generation-bound enum/selection test for
  `arcade_stamp_v3` and existing rollback modes.

## Phase 1 — Pure arcade stamp builder

- [x] Add `arcade_excavation_stamp.gd` with a narrow input DTO: identity,
  previous/current cutting-edge segment, movement and terrain read view.
- [x] Implement movement/proximity hysteresis and teleport reset.
- [x] Rasterize swept segment quads/end caps onto support cells; interpolate
  along fast motion and fill interior gaps.
- [x] Apply width multiplier, minimum visible cut, depth cap, bounds and safety
  floor; emit sorted deterministic proposals and compact diagnostics.
- [x] Add product-grid tests for connected 5 m slow/fast trenches, no stationary
  repeat, no above-ground cut, no teleport bridge and both model widths.

Exit gate: a pure fixture produces a broad connected trench without calling the
v2 classifier or material lifecycle.

## Phase 2 — Fixed-rate coalescer and terrain transaction

- [x] Add latest-minimum-per-cell accumulation with bounded capacity and dirty
  bounds.
- [x] Flush one typed `SoilCellPatch` at 10 Hz / 100 ms maximum latency using
  `TerrainCommitScheduler`; never force a derivative refresh every physics tick.
- [x] Preserve stale revision, generation and collider-failure rollback.
- [x] Add tests for unique sorted rows, deterministic bytes, coalescing,
  rejection without fill mutation, commit cadence and one revision per flush.

Exit gate: a continuous 60 Hz cut yields at most 10 terrain commits per second
and no per-tick Terrain3D/collider update.

## Phase 3 — Scalar bucket load and effects

- [x] Add a minimal `ArcadeBucketLoadState` compatible status snapshot.
- [x] Increment fill only from accepted changed volume; cap at one and reset at
  generation/model changes.
- [x] Route status to existing `SoilEffects`, payload feedback and UI without
  active aggregates, bucket cells or loose flux.
- [x] Add a bounded visual mound presenter: shared soil material, non-colliding
  pooled meshes, scale from released fill, placement at terrain height, oldest
  pile recycle and generation/reset cleanup.
- [x] Dump by clearing the scalar load, playing falling-soil/dust effects and
  placing one visual mound without any TerrainState or collider mutation.
- [ ] Test accepted/rejected cuts, capacity clamp, reset and presentation-density
  independence; assert mound creation/recycling cannot change terrain revision.

## Phase 4 — Product integration and tuning

- [x] Integrate the exclusive v3 branch in `ExcavationWorld` directly around
  sampled bucket pose and scheduler seams; bypass `SoilInteractionAuthority`.
- [ ] Use Godot MCP to verify SY205/SY135 cutting-edge proxy alignment, selected
  solver, commit frequency and no runtime errors.
- [x] Tune only supported parameters on the product `0.5 m` grid. Start with an
  intentionally aggressive width and depth rather than v2's 0.08 m cap.
- [ ] Verify Terrain3D material/vegetation, project collider, Jolt support,
  controls and pass-through mode are unchanged.

## Phase 5 — Stable-once verification

### Agent automated

- [x] editor parse;
- [x] new pure stamp and coalescer tests;
- [x] focused TerrainState/cell-patch/collider identity tests;
- [x] solver migration and bucket status/effects contract tests;
- [x] task/spec validation and `git diff --check`;
- [ ] one broad standalone Godot matrix only after the final relevant edit is
  stable and manual fixes have converged.

### Human manual

- [ ] SY205 Forward+, slow and fast 5 m strokes: broad connected trench, no tiny
  isolated marks, immediate readable feedback and no abnormal stutter.
- [ ] stationary/above-ground/teleport sanity checks.
- [ ] cut, fill and visual-pile dump presentation loop; confirm the pile is
  readable, non-colliding and does not raise the ground.
- [ ] short SY135 cut/alignment/no-error parity check.

## Cutover and cleanup

- [ ] Make `arcade_stamp_v3` the default only after human acceptance.
- [ ] Retain `point_brush_v1` rollback for one release.
- [ ] Plan deletion of the rejected v2 material lifecycle as a separate cleanup
  after v3 acceptance; do not combine that destructive removal with MVP landing.
- [ ] Rebuild dist/export only on explicit release request.

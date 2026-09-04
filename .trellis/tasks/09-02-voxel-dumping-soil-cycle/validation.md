# Validation - authoritative dump and soil cycle

## Agent checks

- `godot/client/tests/run_voxel_cutting_tests.ps1` passed on 2026-09-04.
- Latest evidence: `output/voxel_cutting/20260904-011950/run-summary.json`.
- The focused runner imports an isolated project, then covers cutter/queue,
  fixed-point material state, 100 ms coalesced partial/full dump, native repose,
  track compaction, re-cut, collision readiness, visual mound event, migration,
  and world integration contracts.
- The representative native deposit committed in 2.441 ms: 1.389 ms bounded
  coverage, 0.578 ms material accounting, 0.052 ms native edit, 0.221 ms
  digest, 0.026 ms readiness issue, and 0.017 ms support query. Its fixed-point
  conservation error was zero. This is a short headless sample, not a p95/p99
  or perceived-smoothness claim.
- Runtime dump now reserves/coalesces one landing-neighborhood batch for at
  most 100 ms, does not debit before commit, uses native MODE_ADD geometry,
  leaves no continuous settle frontier, and coalesces overlapping readiness.
- Bucket-fill presentation is quantized to 5% and 10 Hz with one reused
  ArrayMesh; snapshots are capped at 30 Hz and clods use an active/free pool.
  No paired soak, repeated visual automation, or distribution build was run.
- `git diff --check` passed.
- The stable-ground regression rejected 180 consecutive generation-valid track
  receipts before queue/SDF staging, with unchanged data revision and accepted
  proposal count. Material compactability is maintained incrementally instead
  of rescanning the sparse field per physics tick.
- SY135 now commits through native `VoxelTool.do_path`, with one authority
  transaction covering leading edges, inner/floor occupancy, approximate sparse
  mass coverage, and deep-insertion overburden cleanup. Focused tests cover
  coverage deduplication, deposit invalidation, native-path admission, and a
  real deep native commit.
- The final shallow representative coalesced cut measured 9.2 ms total versus
  about 42 ms for the prior exact GDScript path (roughly 78% lower). Its phase
  split was about 5.0 ms coverage, 2.3 ms material accounting, 1.4 ms native
  edit, 0.34 ms bounded digest, and 0.01 ms readiness issue. This is a focused
  indication, not a substitute for the pending Forward+ perceived-stutter
  review.
- `voxel_work_zone_config_test.gd` passed inside the 2026-09-03 foundation run,
  including retained readiness outside a partially overlapping edit. The later
  scene/reset probe in that run hit a native Godot/Voxel Tools crash while two
  independent Godot test runners were active; the isolated focused suite passed
  and no parser/fatal matches were present there.
- Godot 4.7.2 custom + Voxel Tools 1.7 editor filesystem scan completed with no
  new parser error after the final script changes.

## Human milestone

- [ ] Forward+ review: partial and full dump appearance.
- [ ] Forward+ review: stepped native pile growth is acceptable and not
  fluid-like; up to 100 ms visual growth latency is acceptable.
- [ ] Forward+ review: tracks traverse/compact loose piles without flattening
  untouched stable soil.
- [ ] Forward+ review: continuous falling/dumping no longer produces sustained
  stutter, and deposited soil can be excavated again.

The task remains active until the user explicitly accepts this Phase 3 visual
and interaction milestone.

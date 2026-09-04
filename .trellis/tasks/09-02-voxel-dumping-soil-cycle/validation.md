# Validation - authoritative dump and soil cycle

## Agent checks

- `godot/client/tests/run_voxel_cutting_tests.ps1` passed on 2026-09-04.
- Latest evidence: `output/voxel_cutting/20260904-112711/run-summary.json`.
- The focused runner imports an isolated project, then covers cutter/queue,
  fixed-point material state, 100 ms coalesced partial/full dump, native repose,
  track compaction, re-cut, collision readiness, visual mound event, migration,
  and world integration contracts.
- The final representative native deposit committed in 1.518 ms: 0.961 ms
  bounded coverage, 0.266 ms material accounting, 0.032 ms native edit, 0.120
  ms digest, 0.048 ms readiness issue, and 0.013 ms support query. Its bounded
  deposit timing window reported p95/p99 of 1.518/1.518 ms, below the 6/10 ms
  focused budgets, with zero fixed-point conservation error. This remains a
  short headless sample, not a perceived-smoothness claim.
- Runtime dump now reserves/coalesces one landing-neighborhood batch for at
  most 100 ms, does not debit before commit, uses native MODE_ADD geometry,
  leaves no continuous settle frontier, and coalesces overlapping readiness.
- Readiness is now canonical per generation and native 16-cubed mesh block;
  point support is O(1), compatible pending work coalesces, and different
  lower/raise/expected probes remain separate. A dirty block keeps its last
  acknowledged Jolt collider until replacement. Timeout retirement restores
  that fallback or removes an unconfirmed block instead of leaving permanent
  pending state. Mesh, collider, and end-to-end lag use bounded 64-sample
  average/max/p95/p99 windows.
- Authority telemetry now exposes bounded per-stage and per-operation timing
  windows for proposal generation, coverage, material accounting, native edit,
  digest, readiness issue, status construction, and commit. Allocation data is
  explicitly labeled as a variable-object-count proxy, not allocator bytes;
  the representative deposit proxy maximum was 248.
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
- The deep native regression now samples committed bucket-occupancy, floor, and
  overburden-cleanup centerlines against the real VoxelTerrain SDF. Separate
  SY135 regressions prove unengaged withdrawal, separating curl, and an inverted
  outer-back brush reject before mutation and preserve the stable SDF digest.
- The final shallow representative coalesced cut measured 9.358 ms total versus
  about 42 ms for the prior exact GDScript path (roughly 78% lower). Its phase
  split was about 5.0 ms coverage, 2.3 ms material accounting, 1.4 ms native
  edit, 0.34 ms bounded digest, and 0.01 ms readiness issue. This is a focused
  indication, not a substitute for the pending Forward+ perceived-stutter
  review.
- `voxel_work_zone_config_test.gd` is now part of the focused runner and passed,
  covering half-open block quantization, last-collider fallback, partial
  multi-block supersession, explicit timeout retirement, and rolling-window
  eviction statistics. The isolated focused suite reported no parser/fatal
  matches.
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

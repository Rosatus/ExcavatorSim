# Validation evidence — soil excavation redesign

## Revision and rollout configuration

- Base revision: `d1fe21dd3cc15ced394a439a81a12aff9e80cf48`
- Branch: `main`
- Evidence applies to the uncommitted task worktree on 2026-08-31.
- Product release default remains `point_brush_v1` until human acceptance.
- `surface_patch_v2_shadow` and `surface_patch_v2` are generation-scoped,
  selectable rollout modes; no live writer hot-switch is allowed.

## Automated evidence

The stable fast soil matrix passed once:

- `surface_sweep_patch_test.gd`
- `terrain_cell_patch_test.gd`
- `terrain_cell_patch_collider_test.gd`
- `soil_surface_authority_test.gd`
- `loose_soil_flux_test.gd`
- `soil_interaction_authority_test.gd`
- `active_soil_patch_test.gd`
- `soil_authority_migration_test.gd`
- `bucket_soil_tool_test.gd`
- `terrain_state_test.gd`
- `terrain_collider_chunk_test.gd`

After the final compaction and classified push integration, editor parse plus
`surface_sweep_patch_test.gd`, `loose_soil_flux_test.gd`, and
`soil_surface_authority_test.gd` passed. The low/balanced/high active-soil p95
capture passed at approximately `0.552 / 0.609 / 0.742 ms`, below the
`2 / 4 / 6 ms` gates; memory remained below the declared profile limits.

The final integration audit found and fixed two rollout blockers: active-patch
generation is now compared with `TerrainState.world_generation`, and shadow
mode keeps the selected v1 product writer while v2 remains observation-only.
Editor parse plus `soil_surface_authority_test.gd`,
`soil_authority_migration_test.gd`, and
`soil_interaction_authority_test.gd` passed after those fixes. The shadow
regression now compares its authoritative result with the pure v1 baseline.

`python ./.trellis/scripts/task.py validate
.trellis/tasks/08-31-soil-excavation-redesign` passed all 7 implement and 5
check context entries. `git diff --check` reported no whitespace errors.

Known pre-existing test noise remains limited to duplicate terrain texture UIDs
and dummy-renderer/resource leak diagnostics at headless editor/test exit; the
commands returned success and no new script parse error was reported.

## Deliberately pending

- One full standalone matrix after human-driven fixes are stable.
- SY205/SY135 Forward+ manual trench, alignment, pile/push/dump, fast/slow
  stroke, collider-lag, quality and Terrain3D fallback checks.
- Product-default cutover from `point_brush_v1` to `surface_patch_v2`.
- Release export/dist rebuild, only after acceptance and explicit request.

## Arcade stamp v3 implementation checkpoint

The approved visual-first candidate is implemented but remains opt-in. The new
path uses only the accepted cutting-edge sweep, a 100 ms latest-minimum cell
coalescer and one typed terrain patch. It bypasses the v2 semantic classifier,
active material authority and loose-flux solver. Accepted terrain volume drives
only scalar visual fill; dumping clears that state and emits a bounded,
non-colliding visual mound event.

Godot AI MCP rescanned the project after registering the new classes. The live
editor remained ready on `res://scenes/main.tscn`, stopped, and produced no new
script errors after the scan. A separate read-only review found two issues that
were corrected before the stable matrix: rejected terrain patches now retain
their targets for the next-window retry, and the old active-soil prototype
toggle cannot instantiate v2 objects while v3 is selected.

The following focused stable-once matrix passed:

- headless editor parse;
- `arcade_excavation_stamp_test.gd` (both models, slow/fast and connected 5 m
  coverage, stationary/above/teleport guards, 100 ms cadence, accepted-only
  fill and injected rejection retry);
- `arcade_excavation_world_test.gd` (clean selection, scalar payload, no v2
  runtime objects, prototype-toggle isolation);
- `soil_effects_visual_mound_test.gd` (dedupe, bounded recycling, generation
  clear and no mound collision node);
- `soil_authority_migration_test.gd`;
- `terrain_cell_patch_test.gd`;
- `terrain_cell_patch_collider_test.gd` (`flush_us=5224` in this run);
- `bucket_passthrough_mode_test.gd`.

Known pre-existing noise was unchanged: duplicate demo/project Terrain3D texture
UID warnings, the Terrain3D interpolation deprecation warning, and dummy-renderer
exit leak diagnostics. Human SY205/SY135 Forward+ cleanliness, feel and stutter
acceptance remains deliberately pending; v3 is not the default and no release
build is authorized yet.

## Manual acceptance iteration 2 — failed; v2 abandoned as product candidate

The second Forward+ retest still showed abnormal stutter and failed to remove
most contacted soil. The visible outcome remained dominated by tiny marks. The
second-round geometry, read-view and collider optimizations therefore did not
meet the product goal even though focused automated tests passed.

The task has returned to planning with a new candidate, `arcade_stamp_v3`.
`surface_patch_v2` remains only an unaccepted diagnostic/rollback path. No
product-default cutover, commit, archive or release build is authorized from the
v2 evidence above.

## Manual acceptance iteration 1 — failed and corrected

The first product v2 manual pass was rejected: the bucket produced only small
marks and the scene became abnormal/stuttery. The task therefore returned from
the finish gate to implementation; this is not accepted visual evidence.

Root-cause corrections now in the worktree:

- product geometry tests use the real `129x129 @ 0.5 m` grid in addition to the
  synthetic 0.25 m fixture;
- diagonal floor/back box faces align to contract outward normals, far-point
  rotation controls sweep sampling, and continuous overlap can recover a sparse
  point-classifier miss without weakening explicit active/rest/separation
  denials;
- idle sweep and repeated patch validation use lightweight copy-on-write layer
  views instead of full surface synthesis/duplication/encoding/SHA each tick;
- successful patch commits avoid redundant authority snapshots and collider
  chunks are 16 cells rather than 32;
- the runtime solver setter creates a clean generation boundary instead of
  silently changing only the requested value;
- transitional bucket status is bounds-safe. Godot MCP reproduced and fixed an
  SY135 `_build_fill_profile` out-of-bounds error that could interrupt the main
  loop during the switch.

Focused editor/tests passed after these changes:

- `surface_sweep_patch_test.gd`
- `terrain_cell_patch_test.gd`
- `terrain_cell_patch_collider_test.gd`
- `terrain_collider_chunk_test.gd`
- `soil_authority_migration_test.gd`
- `soil_surface_authority_test.gd`
- `soil_interaction_authority_test.gd`

Godot AI MCP then switched the live SY135 main scene from v1 to v2 and observed
requested=selected=`surface_patch_v2`, a 35-cell x/z fill profile, no soil
runtime error, and an idle v2 sample of approximately `5 us` input-view setup
plus `35 us` sweep build. The existing unrelated missing CAN gateway and
Terrain3D deprecation warnings remained.

A final independent audit additionally tightened reserved aggregate slots,
made failed model/pose drains retain the current authority before contract
reconfiguration, and moved settlement/repose flux to the same lightweight
terrain read view. The product-size `129x129 @ 0.5 m` collider transaction test
passed with a representative successful cell-patch flush of approximately
`1875 us`; this is focused headless evidence, not a substitute for the pending
Forward+ feel/stutter recheck.

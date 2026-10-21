# Validation - continuous voxel bucket cutting

## Automated candidate

- Focused runner: `godot/client/tests/run_voxel_cutting_tests.ps1`
- Candidate evidence: `output/voxel_cutting/20260903-100348/run-summary.json`
- Custom editor: Godot `4.7.2.stable.custom_build.ed1daf0bf`, Voxel Tools 1.7.
- Covered: import/parser, both-model cutter including rotation-only motion,
  queue ordering, fixed-point material field, real VoxelTerrain authority,
  stale/duplicate/full-capacity no-op behavior, render-cadence determinism,
  sole-owner migration, reset, and selected-world legacy hot-path isolation.
- Representative three-input coalesced edit: queue peak `1`, coalesced `2`,
  affected samples `454`, affected cells `687`, revision `1`, conservation
  error `0`, commit `43.029 ms` (within the declared 50 ms scheduler window).
- Connected editor runtime switch confirmed owner `voxel`, configured `true`,
  `legacy_runtime=false`, and `parcel_runtime=false`.
- A forced disk reload followed by default main-scene launch confirmed the same
  voxel selection and absence of legacy/parcel runtime without runtime toggles.

## Manual-test support adjustment

- Focused runner after the terrain-domain/capacity change:
  `output/voxel_cutting/20260903-112127/run-summary.json` (`passed: true`, no
  fatal log matches).
- The construction-site profile contract independently passed with a
  `129 x 161` (`64 x 80 m`) map. This contains the complete voxel ownership
  domain through `Z=40 m`; the prior 64 m square stopped at `Z=32 m`.
- World integration samples prove authoritative solid soil at both `Y=-1.0 m`
  and `Y=-5.5 m`.
- Main-scene `voxel_unlimited_bucket_for_testing` is enabled and maps to a
  large finite `1000 m3` ledger capacity. Status retains the model contract
  capacity separately and identifies the active override.
- Godot AI MCP filesystem scan reported no new parser errors, and editor
  inspection confirmed voxel mode, `voxel_bucket_v1`, and the test capacity
  switch on the persisted `ExcavationWorld` node.

## Terrain ownership regression diagnosis

- Human screenshots disproved the earlier source-domain-only diagnosis: the
  visible symptom contained holes outside the fence, retained hard terrain
  inside it, and hard terrain immediately below a voxel cut.
- Root cause category: cross-layer contract plus test-coverage gap. Terrain3D
  1.0.x snaps each imported image chunk to its containing native region, while
  the adapter passed the semantic map's non-aligned `(-32, -40)` origin. Source
  bytes were correct but both native height and hole pixels were displaced.
- The adapter now pads the `129 x 161` semantic map into a `256 x 256` native
  raster at region-aligned origin `(-64, -64)` before import. Logical terrain
  bytes, voxel bounds, soil depth, and the incremental logical overlay remain
  unchanged.
- Direct native checks pass at three voxel-owned points and three exterior /
  half-open boundary points. Evidence:
  `output/terrain_native_mask/20260903-115206`.
- The prior fix failed because it enlarged the semantic source domain but did
  not verify where Terrain3D placed that domain after native import.

## Human milestone

- Accepted by the user on 2026-09-03 after rebuilding/restarting the main scene
  with the native Terrain3D region-alignment fix. Phase 2 is approved to close
  and Phase 3 dumping/soil-cycle work may begin.

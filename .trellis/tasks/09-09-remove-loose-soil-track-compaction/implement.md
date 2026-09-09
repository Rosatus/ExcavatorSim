# Implementation plan

1. Inventory the call graph and status schema for loose soil, track compaction, and settle; identify exact branches in `VoxelSoilMaterialField` and `VoxelExcavationAuthority`.
2. Implement direct stable repose-angle dump commit, including immediate stable material classification and preserved volume/mass ledger.
3. Remove mobile/loose flux, track-contact receipts, compaction admission/queue/commit, and automatic settle scheduling while preserving cut/deposit/re-cut paths.
4. Update dependent UI/status/configuration and delete or rewrite obsolete tests and fixtures.
5. Add regression coverage for dump → stable slope → re-dig and conservation across the cycle.
6. Run Godot parser/import checks and soil, excavation, bucket, dump, conservation, and re-dig test suites; review diff for dead references.

## Cleanup progress
- Removed voxel compaction admission module, dedicated tests and slope fixture.
- Removed per-frame Jolt compaction receipt allocation and world forwarding helper.
- Removed automatic settle frontier and background queue arbitration.
- Soil queue now admits only deposits, using bounded FIFO.
- Updated affected test sources; execution and validation are human-owned per user instruction. No tests run.
- Implemented single stable cell ledger and direct deposit commit; removed flight escrow and exact compaction/settle material branches.
- Updated VFX to event timestamps/TTL, independent of terrain ownership.
- Retired old product mode selection/fallback; legacy source types remain dormant compatibility dependencies.
- Removed loose flux solver and its standalone test.
- Updated material, authority, mode, visual and completion test sources. No tests or Godot validation executed; human acceptance confirmed by the user on 2026-09-09.
- Manual: restart/reset scene; both models cut/dump/re-cut; repeated dumps form stable slopes; idle and track passage leave geometry unchanged; rejected dumps keep inventory; VFX expires without replay.

## Acceptance and closeout
- User confirmed testing complete on 2026-09-09 and authorized commit, push and archive.
- Validation was human-owned; no automated test or lint/type-check pass is claimed.

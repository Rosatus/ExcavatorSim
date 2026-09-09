# Journal - rosatus (Part 2)

> Continuation from `journal-1.md` (archived at ~2000 lines)
> Started: 2026-09-01

---



## Session 54: Fix managed Gateway offline custom authority

**Date**: 2026-09-01
**Task**: Fix managed Gateway offline custom authority
**Branch**: `main`

### Summary

Decoupled Godot-managed per-ID custom authority from transient PC001 handshake availability, added managed TCP process and React regressions, updated contracts, rebuilt the Windows Gateway, and copied the verified package into godot/dist/windows/can_gateway.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `17487c2` | (see git log) |
| `c5118ad` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 55: Gateway DBC TCP 统一与 PC001 测试客户端

**Date**: 2026-09-02
**Task**: Gateway DBC TCP 统一与 PC001 测试客户端
**Branch**: `main`

### Summary

统一 Windows/Linux Gateway 默认 PC001 TCP 与新版 DBC channel 路由，完成 Web authority/runtime 更新、跨平台发行验证，并新增独立 PySide6 PC001 TCP 监视客户端及 Windows 包。

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `a7b01c1` | (see git log) |
| `070dfe7` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 56: Gateway restart status and stable Web layout

**Date**: 2026-09-02
**Task**: Gateway restart status and stable Web layout
**Branch**: `main`

### Summary

Replaced the misleading ICT toggle with owned Gateway lifecycle control, added realtime Godot telemetry liveness, stabilized the CAN table layout, rebuilt verified Windows/Linux Gateway test distributions, and archived the Trellis task.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `af69a0d` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 57: Voxel work-zone foundation

**Date**: 2026-09-03
**Task**: Voxel work-zone foundation
**Branch**: `main`

### Summary

Added the bounded north-side Voxel Tools work zone, exclusive Terrain3D/hard-collider ownership mask, regional collision-readiness tickets, Jolt track support integration, reset lifecycle, focused benchmarks and accepted Forward+ human validation.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `b5b483b` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 58: Continuous voxel bucket cutting accepted

**Date**: 2026-09-03
**Task**: Continuous voxel bucket cutting accepted
**Branch**: `main`

### Summary

Implemented and validated continuous voxel cutting, fixed Terrain3D native region alignment, enabled large finite manual-test bucket capacity, and recorded human Forward+ acceptance.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `5695f13` | (see git log) |
| `32f538e` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 59: Gateway Web and cached distribution wrap-up

**Date**: 2026-09-04
**Task**: Gateway Web and cached distribution wrap-up
**Branch**: `main`

### Summary

Reviewed the Gateway Web changes, preserved protocol DBC bytes, added a cached Gateway-only Windows/Linux distribution builder with packaged smoke and transactional replacement, documented it as the preferred Gateway packaging path, and archived the completed lightweight task.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `854e471` | (see git log) |
| `573edc1` | (see git log) |
| `2c9b770` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 60: Soil visuals and excavation controls accepted

**Date**: 2026-09-08
**Task**: Soil visuals and excavation controls accepted
**Branch**: `main`

### Summary

User accepted soil surface deposition, release visuals, wider SY135 boom/arm limits, full-bucket cutting with explicit discarded-mass accounting, and high-outlet unloading. Task archived at user request. Validation limited to Godot script parsing and static/hash checks; runtime acceptance owned by user. Parallel worldbuilding work remains outside these commits.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `6da1a96` | (see git log) |
| `7192b4f` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 61: Cutting performance and optional diagnostics

**Date**: 2026-09-08
**Task**: Cutting performance and optional diagnostics
**Branch**: `main`

### Summary

Optimized native coverage ordering and SDF buffer reuse; added default-off cutting diagnostics with throttled aggregation and readiness epochs. Targeted cutting, world, work-zone and queue checks pass. Existing broad authority and soil-effects failures reproduced on baseline and documented in archived result. User accepted delivery and authorized commit, push and archive.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `30b2f22` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 62: Complete soil release visuals and recorded bucket residual repair

**Date**: 2026-09-08
**Task**: Complete soil release visuals and recorded bucket residual repair
**Branch**: `main`

### Summary

Delivered conserved soil flight and delayed landing, irregular soil visuals, dump completion, geometry-only recuts, continuous lift retention, and tooth-to-floor lip coverage. Recorded live user motion reproduced residual SDF; eight observed targets and five final focused checks pass. User confirmed the issue fully resolved and authorized commit, push, and archive. Representative native commit 16.110 ms; unrelated plugin/worldbuilding/config changes preserved.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `689a70f` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 63: Stable soil migration completed

**Date**: 2026-09-09
**Task**: Stable soil migration completed
**Branch**: `main`

### Summary

Replaced loose soil, compaction and settling with voxel-only stable deposits; preserved cut, bucket accounting and re-cut. User confirmed manual testing complete on 2026-09-09. Automated checks were human-owned and not run by the agent. Archived the migration task; excluded unrelated addon, worldbuilding and local configuration edits.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `a288f73` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 64: Game menu and control HUD completed

**Date**: 2026-09-09
**Task**: Game menu and control HUD completed
**Branch**: `main`

### Summary

Implemented automatic entry, Esc/gamepad pause menu, confirmed reset, persistent CAN/Gateway/TCP controls, device-aware cross-layout HUD and restrained animated background. Removed persistent machine/payload panel per user review. Five focused contracts passed with relevant follow-up reruns and parser checks. User authorized commit, push and archive; no separate GPU visual or comprehensive gamepad-feel pass claimed. Unrelated addon, worldbuilding and local configuration changes excluded.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `bb4bb58` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 65: Bucket soil shape and cavity visibility

**Date**: 2026-09-09
**Task**: Bucket soil shape and cavity visibility
**Branch**: `main`

### Summary

Implemented measured SY135/SY205 lining profiles, natural contained fill growth, per-instance bucket material correction and contact-scale SSAO. Five focused Godot tests passed; existing scene cleanup warnings documented. User accepted the result and requested commit, push and archive. Updated visual contract and archived current task; unrelated plugin, configuration and worldbuilding changes remain untouched.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `b5b6264` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 66: SY135 fill tilt and rigid bucket following

**Date**: 2026-09-09
**Task**: SY135 fill tilt and rigid bucket following
**Branch**: `main`

### Summary

Implemented 6-degree SY135 forward fill tilt and bucket-frame inherited attachment to eliminate snapshot phase lag. Added replacement-before-validation cleanup and regressions for stale poses, model switching, failure recovery and both teardown orders. Five focused Godot tests passed. User requested commit, push and archive; unrelated work remains untouched.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `65dedd7` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete

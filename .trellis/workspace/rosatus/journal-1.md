# Journal - rosatus (Part 1)

> AI development session journal
> Started: 2026-08-06

---



## Session 1: Bootstrap ExcavatorSim and migrate reusable BabylonSim backend

**Date**: 2026-08-06
**Task**: Bootstrap ExcavatorSim and migrate reusable BabylonSim backend
**Branch**: `main`

### Summary

Initialized E:/projects/ExcavatorSim with Git, Trellis, and CodeGraph; captured Godot desktop architecture and authority boundaries; migrated the Python kinematics/terrain/replay/protocol backend, tests, assets, provenance, notices, and verification scripts; added backend-only specs and Godot handoff docs; passed pixi verify, backend smoke, and terrain benchmark while preserving a clean BabylonSim source checkout.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `10b5a29` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Phase 2 Implementation Notes: Jolt articulated work equipment

**Date**: 2026-08-17
**Task**: `08-17-jolt-articulated-equipment`
**Branch**: `main`

### Summary

Implemented the opt-in Phase 2 Jolt-authoritative five-body/four-joint open
chain for SY205 and SY135. Versioned rig contracts now bind visual rest frames,
joint anchors, collision policy and actuator shaping. One post-step snapshot
drives both GLB pivots and local truth, while BucketSoilState payload mass/COM
is applied through a bounded monotonic tick-boundary adapter.

### Key Contracts

- Jolt owns chassis, upper, boom, arm and bucket state only in
  `jolt_authoritative`; the default remains `python_kinematic`.
- Hinge motor velocity is sign-inverted once at the Jolt adapter to match the
  rig/visual/truth right-handed axis convention.
- SY205 passive linkage remains visual-only and runs after physical pivots.
- Legacy `BucketGroundLiftReaction` is disabled in authoritative mode.
- Terrain mutation and production hydraulic/contact calibration remain deferred.
- Standalone Godot tests must use the console executable so the runner waits for
  the real process and propagates its exit code.

### Testing

- Godot 4.7.1 standalone matrix: 16/16 scripts passed, including the new
  dual-model articulated equipment suite.
- Godot AI MCP: live SY205/SY135 five-body/four-joint rigs, model/rig truth
  identity, physical boom command, pivot diagnostics and single runtime checked.
- `pixi run verify`: Ruff, mypy, 158 backend tests, provenance and path checks passed.
- `pixi run backend-smoke`: passed.
- Trellis task validation and `git diff --check`: passed.

### Status

[OK] **Implementation and quality gates complete; awaiting commit/archive request.**


## Session 2: Integrate SY205 GLB into Godot

**Date**: 2026-08-10
**Task**: Integrate SY205 GLB into Godot
**Branch**: `main`

### Summary

Copied and hash-verified the combined SY205 GLB, mapped its five authoritative motion pivots, added a Godot-local visual manifest and parity-ready fixtures, integrated it into the main scene, validated it through Godot MCP and headless tests, and recorded the M1.5 Trellis milestone and embedded-texture import policy.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `32f693a` | (see git log) |
| `9951470` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 3: M2 Godot motion vertical slice

**Date**: 2026-08-10
**Task**: M2 Godot motion vertical slice
**Branch**: `main`

### Summary

Implemented and validated the Godot M2 connected motion slice: WebSocket hello/ack with honest input_snapshot and commands capabilities, strict shared JSON normalization, safe zero-armed input and lifecycle command correlation, reconnect/session/epoch/view-revision guards, calibrated five-frame SY205 presentation mapping, operator diagnostics UI, and deterministic fake-transport/parity tests. Verified Godot 4.7.1 headless/import and focused tests, MCP live backend start/pause/reset and non-zero motion, clean logs, pixi run verify, task context validation, and diff check. Archived the completed M2 task; left MCP configuration, editor project settings, addon files, and generated UID files untouched outside the commits.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `1552414` | (see git log) |
| `618ff56` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 4: M3 motion-only backend profile

**Date**: 2026-08-11
**Task**: M3 motion-only backend profile
**Branch**: `main`

### Summary

Implemented and verified opt-in motion-only Python runtime; preserved legacy protocol behavior, added capability gating, CLI/pixi launcher, tests, backend runtime profile spec, and archived the milestone. Godot MCP had no active session; headless import and CLI health fallback checks passed.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `8ab3269` | (see git log) |
| `8a811a4` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 5: M4 deterministic Godot terrain core

**Date**: 2026-08-11
**Task**: M4 deterministic Godot terrain core
**Branch**: `main`

### Summary

Implemented Godot-owned deterministic terrain state with stable/loose Float32 layers, ordered brush edits, reset generation guards, derived ArrayMesh rendering, and main-scene integration. Godot MCP runtime checks confirmed repeatability, stale rejection, reset identity, and mesh presence; pixi run verify passed with 124 backend tests.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `8594314` | (see git log) |
| `b2960a7` | (see git log) |
| `164946c` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 6: M5 deterministic excavation gameplay loop

**Date**: 2026-08-11
**Task**: M5 deterministic excavation gameplay loop
**Branch**: `main`

### Summary

Implemented Godot BucketSoilState and ExcavationWorld with deterministic fixed-step cut/deposit, grid-volume-conserving inventory, explicit bucket contact proxy, reset/generation guards, optional chunked static collider fail-open adapter, UI dig/deposit controls, and tests. Godot 4.7 MCP scene smoke was clean; headless M4/M5/foundation/motion/GLB tests passed; pixi run verify passed with 124 backend tests.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `c8cfecb` | (see git log) |
| `65523a6` | (see git log) |
| `e1f6995` | (see git log) |
| `4cc5f06` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 7: M6 realistic visual pass

**Date**: 2026-08-11
**Task**: M6 realistic visual pass
**Branch**: `main`

### Summary

Added realistic Forward+ procedural sky/ambient light, shadowed key light, follow camera, soil PBR material, high/balanced/low quality budgets, bounded generation-gated GPU soil effects and visual smoke tests. MCP runtime confirmed environment/material/effects/quality nodes, 60 FPS cap and reset clears particle emission; headless visual contract passed; pixi run verify passed with 124 backend tests.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `87d509d` | (see git log) |
| `be736cd` | (see git log) |
| `5b21c02` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 8: M7 integration release candidate

**Date**: 2026-08-11
**Task**: M7 integration release candidate
**Branch**: `main`

### Summary

Added scene-level release candidate test using MotionClient fake WebSocket seams: hello/view-state, authoritative visual pose, local dig/deposit/reset, reconnect epoch cleanup and stale guards. ExcavationWorld now carries authority_generation and SoilEffects clears on authority or terrain generation changes. Added Godot test matrix README and explicit legacy Python terrain/recording/replay retention decision. All 7 Godot headless contracts passed, MCP main scene/runtime smoke was clean at 60 FPS cap, pixi run verify passed with 124 backend tests.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `3c2625b` | (see git log) |
| `03c71e1` | (see git log) |
| `1b4c98d` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 9: Godot realistic client parent release candidate

**Date**: 2026-08-11
**Task**: Godot realistic client parent release candidate
**Branch**: `main`

### Summary

Closed the 8-child Trellis roadmap M1 through M7. Parent acceptance criteria and implementation gates are checked, release-candidate retention docs preserve legacy Python terrain/recording/replay compatibility, and all child milestones are archived. Final Godot MCP scene screenshot showed the imported SY205 skin, shadowed lighting, terrain and operator UI; runtime held 60 FPS cap. Full standalone Godot matrix and pixi run verify passed.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `389ab38` | (see git log) |
| `b408904` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 10: Godot verification baseline and release evidence

**Date**: 2026-08-11
**Task**: Godot verification baseline and release evidence
**Branch**: `main`

### Summary

Audited all archived Godot M1-M7 tasks and closed release evidence gaps. Added explicit 1920x1080 viewport settings while retaining Forward+/D3D12/Jolt and responsive stretch, added a fail-fast PowerShell runner for the seven standalone Godot SceneTree tests, documented standalone/MCP/backend-smoke/verify boundaries and exact MCP smoke sequence, verified MCP 4.7.1 live runtime with real motion-only backend start/reset generation transitions and 1920x1080 screenshot, ran backend-smoke, pixi verify (124 tests), task validation, GLB SHA256 and five pivot manifest checks. Archived verification baseline task; left MCP-generated addon/editor/UID files and .codex/config.toml uncommitted as user/tool changes.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `69c54e8` | (see git log) |
| `805b603` | (see git log) |
| `43131d7` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 11: Record MCP verification boundary

**Date**: 2026-08-11
**Task**: Record MCP verification boundary
**Branch**: `main`

### Summary

Updated .trellis/spec/frontend/godot-mcp.md with the executable distinction between standalone SceneTree contracts and MCP McpTestSuite discovery, plus the 1920x1080 persisted viewport baseline check. No runtime authority or user asset changed.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `3754f92` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 12: Fix Godot joint coordinate parity

**Date**: 2026-08-11
**Task**: Fix Godot joint coordinate parity
**Branch**: `main`

### Summary

Converted authoritative Python Z-up frame transforms once at the Godot protocol boundary with full basis conjugation, preserved the SY205 GLB bytes and five-pivot hierarchy, added all-frame zero/swing/asymmetric parity plus bucket-tooth proxy regressions, documented the contract, and passed Godot matrix, MCP live smoke, backend smoke, and pixi verify.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `f79173b` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 13: 修复 SY205 被动四连杆机构

**Date**: 2026-08-11
**Task**: 修复 SY205 被动四连杆机构
**Branch**: `main`

### Summary

依据用户提供的 SY205_Godot_Import_Guide.md，在 Godot MotionPresentation 中重建 A/B/C/D 被动四连杆：arm-local Y-Z 圆交点、连续分支、不可达保留、B 摇臂与侧连杆控制器驱动；新增 manifest 契约、GLB/motion 回归测试和 frontend authority 规范。GLB 字节、五个 Python 权威 frame、后端协议均未改变。Godot 4.7.1 standalone matrix、MCP 四连杆 smoke、backend-smoke、pixi verify、Trellis validate 与 diff check 均通过。

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `c4c3184` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 14: 修复 SY205 局部枢轴运动链

**Date**: 2026-08-11
**Task**: 修复 SY205 局部枢轴运动链
**Branch**: `main`

### Summary

依据 SY205_Godot_Pivot_Definition_Guide.md 修复 Godot 端五个主枢轴的局部运动：整机根节点使用基准 delta，子枢轴使用相邻 Python frame 的局部单轴旋转 delta，保留导入 GLB 的销轴原点与层级；被动四连杆在主枢轴应用后重新求解，并在非法输入时保留最后有效姿态。补充指南驱动的 manifest/local_kinematics 与 pivot_contract 校验、boom/arm/bucket/asymmetric/恢复/不可达回归测试和协议文档。验证通过 pixi run verify（124 tests）、backend-smoke、Godot 4.7.1 standalone 7 项矩阵、Godot MCP 冷启动 smoke、Trellis validate 与 git diff --check。GLB SHA 未改变。

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `72374da` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 15: 建立机械 GLB 到 Godot 适配 Skill

**Date**: 2026-08-11
**Task**: 建立机械 GLB 到 Godot 适配 Skill
**Branch**: `main`

### Summary

创建项目级共享 skill godot-adapt-articulated-glb，用于在不依赖资产专用指南的情况下检查 Blender 机械 GLB、区分 observed/declared/validated/decision 证据、统一收集落盘前人工决策，并指导 Godot PackedScene 验证、局部枢轴适配与被动机构求解。新增无第三方运行依赖的确定性 GLB 2.0 检查器、稳定错误/跨引用 diagnostics、两份按需参考、OpenAI UI 元数据及 8 个单元/集成测试。fresh default agent 前向测试通过；official quick_validate、Ruff、strict mypy、pixi run verify（124 tests）、Trellis validation、git diff --check 全绿。

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `e96d03e` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 16: Activate GLB-derived SY205 URDF v4

**Date**: 2026-08-11
**Task**: Activate GLB-derived SY205 URDF v4
**Branch**: `main`

### Summary

Generated the deterministic SY205 URDF and evidence, preserved the old model as a future SY135 reference, activated the new URDF in the Python backend, aligned protocol and Godot model identity plus parity fixtures, updated provenance, passed backend and Godot standalone verification, and validated zero/asymmetric poses through Godot MCP.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `e78a3c8` | (see git log) |
| `020d82e` | (see git log) |
| `55bbee9` | (see git log) |
| `c9759a9` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 17: Fix Godot terrain winding

**Date**: 2026-08-12
**Task**: Fix Godot terrain winding
**Branch**: `main`

### Summary

Corrected generated terrain triangle winding for Godot back-face culling, added mesh index/normal regression coverage, and verified the brown terrain at runtime with CULL_BACK.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `4c7eb94` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 18: Refresh stale project documentation

**Date**: 2026-08-12
**Task**: Refresh stale project documentation
**Branch**: `main`

### Summary

Updated README, frontend spec index, and Godot integration boundary to reflect the completed M1-M7 Godot vertical slice, explicit legacy and motion-only runtime profiles, and current verification paths. pixi run verify passed with 145 backend tests; archived the Trellis task.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `a5b797b` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 19: Integrate Terrain3D terrain backend

**Date**: 2026-08-12
**Task**: Integrate Terrain3D terrain backend
**Branch**: `main`

### Summary

Integrated Terrain3D as a snapshot-driven presentation backend while preserving TerrainState and BucketSoilState authority; added fail-open fallback, Jolt Dynamic/Game collision validation, Godot 4.7.1 visual smoke, and the eight-script standalone matrix.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `75bdd09` | (see git log) |
| `e0230a2` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 20: Terrain3D official demo visual baseline

**Date**: 2026-08-13
**Task**: Terrain3D official demo visual baseline
**Branch**: `main`

### Summary

Adopted the official Terrain3D demo material stack as a minimal production asset closure, kept a flat deterministic excavation pad and stable/loose authority, added bounded rocks and grass exclusion, and verified Godot plus project quality gates.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `dcc9e66` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 21: Integrate Sky3D construction sky

**Date**: 2026-08-13
**Task**: Integrate Sky3D construction sky
**Branch**: `main`

### Summary

Integrated fixed-day Sky3D environment, corrected Terrain3D initialization and fallback behavior, added attribution, and passed full verification.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `559b2c6abcc6af50e4726fbfef667e0a6bfb50ab` | (see git log) |
| `c2cac52a4727c90c20eb886d9e337ff2ca7b4964` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 22: 建立项目概念与工程架构文档

**Date**: 2026-08-13
**Task**: 建立项目概念与工程架构文档
**Branch**: `main`

### Summary

新增面向非技术人员的概念架构图（Mermaid 与内嵌 SVG）及面向工程协作的详细架构地图，覆盖 Python/Pinocchio、Godot-first 与 legacy profile、协议/时序、权威边界、坐标资产、测试发布和未来座舱/CAN 目标；README 增加阅读入口，并为历史专项文档补充 profile scope 注记。相关 Trellis 任务已归档。

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `746e880` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 23: Add SY135 model switching

**Date**: 2026-08-15
**Task**: Add SY135 model switching
**Branch**: `main`

### Summary

Imported the SY135 articulated GLB, added reviewed model registries and fresh-session SY205/SY135 switching across Python and Godot, isolated replay/recording/model identity, and verified backend plus Godot runtime behavior.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `4a3fe56` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 24: Tracked chassis locomotion

**Date**: 2026-08-15
**Task**: Tracked chassis locomotion
**Branch**: `main`

### Summary

Implemented default-disabled Godot-local skid-steer locomotion for SY205/SY135 with independent track inputs, terrain support, generation-gated Jolt hints, lifecycle resets, tests, and live Godot MCP validation.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `07301c7` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete

## Session 25: Automatic soil interaction

**Date**: 2026-08-15
**Task**: Automatic soil interaction
**Branch**: `main`

### Summary

Replaced production Dig/Deposit interaction with fixed-step articulated bucket
contact classification and a bounded bucket-local cellular soil lifecycle.
TerrainState remains the coarse logical terrain owner; Terrain3D, GPU flow, and
capped Jolt hero clods are presentation/collision consumers. Added model-specific
SY205/SY135 proxies, automatic cut/carry/spill/dump, transfer cleanup, and an
optional negotiated `bucket_load_feedback_v1` observation path to Python.

### Validation

- Godot AI MCP live negotiation and payload mirror validated on `client@c72d`.
- Balanced/high MCP captures recorded in
  `.trellis/tasks/08-15-automatic-soil-interaction/research/performance-baseline.md`.
- Godot standalone matrix: 12 scripts passed; automatic gameplay includes 1,800
  fixed steps per model.
- Backend: Ruff, mypy, and 153 pytest tests passed.

### Status

[IN PROGRESS] **Implementation complete; awaiting final Trellis quality gate and commit**


## Session 25: Automatic bucket soil interaction

**Date**: 2026-08-15
**Task**: Automatic bucket soil interaction
**Branch**: `main`

### Summary

Implemented automatic articulated bucket cut/carry/spill/dump with bounded cellular occupancy, scheduled TerrainState commits, visual flow and pooled clods, model-specific SY205/SY135 contracts, and optional negotiated bucket_load_feedback_v1. Validated with Godot AI MCP, 12 standalone Godot tests, balanced/high captures, backend 153 tests, pixi verify, smoke, provenance, and diff checks. Committed, pushed, and archived 08-15-automatic-soil-interaction.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `864bd7e` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 26: Bucket ground lift reaction

**Date**: 2026-08-17
**Task**: Bucket ground lift reaction
**Branch**: `main`

### Summary

Added bounded Godot-local bucket rear/shell support reaction with heave, pitch and roll composition, raw-contact feedback isolation, lifecycle clearing, model coverage, and a reliable Windows Godot standalone matrix runner. Verified pixi checks, 153 backend tests, and 12 Godot headless suites.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `98c0cce` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 27: Authority contract and shadow state

**Date**: 2026-08-17
**Task**: Authority contract and shadow state
**Branch**: `main`

### Summary

Planned the Jolt authority migration and implemented Phase 0 strict rig/truth contracts, negotiated observational shadow transport, isolated Python diagnostics, SY205/SY135 coverage, and full Godot/backend verification while retaining python_kinematic as the default authority.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `710eb59` | (see git log) |
| `823bab7` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 28: Jolt chassis and track authority

**Date**: 2026-08-17
**Task**: `08-17-jolt-chassis-track-authority`
**Branch**: `main`

### Summary

Implemented the opt-in Phase 1 `jolt_authoritative` chassis/track profile for
SY205 and SY135 while keeping `python_kinematic` as the default and freezing work
equipment. Added strict hash-bound rig contracts, one Jolt `RigidBody3D`, compound
collision, distributed bilateral traction/braking/slip, terrain identity gates,
local authoritative truth, lifecycle/model-switch cleanup, and architecture/spec
updates.

### Review Fixes

- Marked ray-probe contacts with `jolt_contact_manifold_unavailable` instead of
  presenting zero impulse/penetration as measured manifold data.
- Cleared non-finite rigid-body velocities and exposed quality flags.
- Prevented failed authoritative model switches from reporting legacy locomotion
  state as an active Jolt rig.
- Tightened truth to five unique named bodies/four unique named joints and rig
  schema body inertia/shape-size bounds; added WebSocket rejection coverage for
  authoritative truth on the shadow transport.
- Kept `TerrainCommitScheduler` as the sole normal terrain-revision collider writer;
  the Jolt runtime stops forces across stale identity gaps.

### Testing

- `pixi run verify`: passed, 158 backend tests.
- `pixi run backend-smoke`: passed.
- Godot 4.7.1 standalone matrix: 15/15 scripts passed.
- `git diff --check`: passed.
- Godot AI MCP: live SY205/SY135 rig, contact identity, and local-only truth verified.

### Status

[OK] **Implementation and quality gates complete; awaiting commit/archive request.**


## Session 28: Jolt chassis and track authority

**Date**: 2026-08-17
**Task**: Jolt chassis and track authority
**Branch**: `main`

### Summary

Completed and archived Phase 1 Jolt-authoritative chassis/track runtime with versioned rig and truth contracts, isolated backend validation, lifecycle safety, documentation, and full backend/Godot quality gates.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `ee0f39a` | (see git log) |
| `fe03ad1` | (see git log) |
| `c1c1324` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 29: Jolt articulated equipment authority

**Date**: 2026-08-17
**Task**: Jolt articulated equipment authority
**Branch**: `main`

### Summary

Implemented and verified the Phase 2 five-body, four-joint Jolt articulated equipment runtime for SY205 and SY135, including bounded actuation, payload coupling, shared post-step truth, visual following, and lifecycle coverage; archived the completed Trellis task.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `88369b8` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 30: Hybrid work equipment and excavation coupling

**Date**: 2026-08-17
**Task**: `08-17-jolt-terrain-excavation-coupling`
**Branch**: `main`

### Summary

Implemented the Phase 3 hybrid authority path: one dynamic Jolt chassis,
bounded kinematic slew/boom/arm/bucket motion, query-only bucket proxies,
idempotent soil interaction batches, and capped later-tick chassis support
wrenches. `TerrainState`, `BucketSoilState`, and `TerrainCommitScheduler` remain
the logical soil and terrain authorities; `python_kinematic` remains default.

### Main Changes

- Added `KinematicArticulationState` and `BucketProxySweeper` with shared
  accepted-FK/query identity for SY205 and SY135.
- Added cutting/carry/spill/dump/support/blocked classification, one transaction
  per interaction key, consumed contact IDs, and stale/duplicate fail-closed
  behavior.
- Added force, torque, rate, heave, tilt and continuous-contact caps for
  shell/rear support; fixed doubled torque, duration re-arm, teardown safety,
  and stable runtime naming.
- Extended local authoritative truth/schema with one body, four kinematic
  frames, query epoch/tick/terrain/motion identity, soil batch, payload load
  factor, and queued/applied wrench.
- Made model-specific bucket cell-grid replacement coherent and fill-profile
  reads fail closed during a transient mismatch found through Godot AI MCP.

### Testing

- `pixi run verify`: passed, 159 backend tests.
- `pixi run backend-smoke`: passed.
- Godot 4.7.1 standalone matrix: 17/17 scripts passed.
- Trellis context validation and `git diff --check`: passed.
- Godot AI MCP: live SY205 and SY135 hybrid runtime/truth/grid identity verified;
  default authority profile restored to `python_kinematic`.

### Status

[OK] **Implementation complete and quality gates passed; task remains active
until the user requests commit/push/archive.**


## Session 30: Complete hybrid Jolt terrain excavation coupling

**Date**: 2026-08-18
**Task**: Complete hybrid Jolt terrain excavation coupling
**Branch**: `main`

### Summary

Implemented and verified hybrid Jolt authoritative chassis with bounded kinematic work equipment, bucket-only terrain queries, automatic excavate/carry/spill/dump soil transactions, capped chassis support wrench, shared truth identity, and SY205/SY135 lifecycle coverage. Passed backend, Godot standalone, task validation, and MCP checks; archived the completed coupling task.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `815b6b3` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 31: Sensor telemetry gateway

**Date**: 2026-08-18
**Task**: Sensor telemetry gateway
**Branch**: `main`

### Summary

Implemented and verified Godot-to-Python sensor telemetry with strict layouts, lifecycle clearing, capability gating, bounded export, and live MCP validation; archived the completed Phase 4 task.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `3ca489a` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete

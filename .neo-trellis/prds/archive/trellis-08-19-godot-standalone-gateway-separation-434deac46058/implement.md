# Implementation Plan

## Phase A: Establish local control plane
- [x] Add `ProductSession` with local authority identity, lifecycle, generation, focus-safe equipment input, model selection, and status signals.
- [x] Add focused offline integration coverage for stopped/start/pause/reset, epoch/generation rotation, model switching, and no transport startup.
- [x] Wire it into `main.tscn` without changing explicit Python profiles.

## Phase B: Move consumers off transport authority
- [x] Route UI and F6/F7/F8 through `ProductSession`.
- [x] Gate Jolt track/equipment commands on local lifecycle and focus.
- [x] Route local model activation, truth identity, excavation invalidation, and reset through local signals.
- [x] Keep Python view_state behind explicit `python_kinematic`/`jolt_shadow` gates.
- [x] Verify reset no longer relies on transport `pose_cleared` and Gateway reconnect cannot reset local state.

## Phase C: Make Gateway opt-in
- [x] Add gateway settings and prevent disabled preflight/socket/retry work.
- [x] Separate UI labels for local authority/lifecycle and Gateway state.
- [x] Verify enabled Gateway receives telemetry and disconnect is fail-open through gateway/sensor regression coverage.

## Phase D: Offline model/product integration
- [x] Make UI model selection local and atomic for SY205/SY135.
- [x] Add/register `offline_product_test.gd` covering main-scene startup, lifecycle, model switches, Jolt singularity, truth identity, and transient clearing.
- [ ] Run Godot MCP smoke with backend stopped for both models, tracks, excavation, pause, reset.

## Phase E: Separate Python Gateway and archive compatibility
- [x] Replace ambiguous Pixi `start` with `start-gateway`.
- [x] Split Gateway and Pinocchio compatibility dependencies into explicit Pixi features/environments without moving/deleting source.
- [x] Preserve compatibility launchers and targeted backend tests.
- [x] Add assertions that Gateway does not import/construct Pinocchio or publish product pose.

## Phase F: Docs/release boundary
- [x] Update README, architecture, Godot integration, release-candidate, runtime profiles, and client boundary.
- [x] Mark Pinocchio/URDF motion, Python terrain, recording, replay as archived compatibility.
- [x] Document direct editor/project/export startup and optional Gateway separately.

## Validation
- [x] Gateway-only backend tests/smoke in lightweight environment.
- [x] Full compatibility `verify` in documented compatibility environment.
- [x] Godot standalone matrix with Godot 4.7.1, including offline test.
- [x] Godot editor headless import exits 0.
- [ ] Godot MCP live offline smoke passes SY205/SY135.
- [ ] Export dependency inspection proves no Python/Pixi/URDF runtime requirement.
- [x] `git diff --check` and Trellis validation pass.

## Review Gates
- [x] No default startup network attempt or `waiting for Python` state.
- [x] Exactly one local lifecycle/model/authority writer.
- [x] Exactly one Jolt runtime and visible model after switches/resets.
- [x] Gateway reconnect/disconnect cannot mutate local truth.
- [x] Compatibility profiles remain explicit/tested; no archived source is deleted.

## Archive Disposition

- The offline MCP smoke covered lifecycle, reset generation rotation, and SY205/SY135 switching without Python.
- Extended live track/excavation behavior is intentionally transferred to the follow-up interaction-stability task because the newly reported chassis jitter and terrain/bucket defects make that evidence obsolete.
- Export-package dependency inspection remains a release-hardening follow-up; source/runtime dependency separation and the standalone matrix already prove the default Godot path does not import or launch Python/Pixi/URDF components.

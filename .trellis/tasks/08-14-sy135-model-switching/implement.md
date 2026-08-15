# SY135 Model Switching Implementation Plan

## Phase A. Preserve And Validate The Asset

- [x] Record the external source path, byte count, SHA-256, inspection evidence, and copy authorization.
- [x] Copy the GLB unchanged to `godot/client/assets/visual/SY135_excavator_godot.glb`; verify byte identity immediately.
- [x] Run a headless Godot import and an inspection probe for exact paths, transforms, scales, materials/textures, bounds, and unexpected resources.
- [x] Validate zero, each isolated positive joint pose, one asymmetric pose, and zero restore against the existing SY135 URDF.
- [x] Confirm no re-authoring evidence is required; source pivots remain unchanged.

Rollback point: remove only the newly copied repository asset/import metadata and planning-generated SY135 contracts; the external source remains untouched.

## Phase B. Create Reviewed Model Contracts

- [x] Add a schema-validated backend model registry with SY205 default and SY135 descriptors, versions, paths, hashes, and calibration bindings.
- [x] Add the Godot model catalog and a cross-catalog consistency check.
- [x] Add the SY135 visual manifest from validated imported evidence, with exact frame map, local kinematics, no passive linkage, and `REF_BUCKET_TIP` excavation contact.
- [x] Generate a deterministic SY135 Pinocchio parity fixture using the same zero/isolated/asymmetric pose matrix used for presentation tests.
- [x] Update provenance without changing the SY135 reference URDF bytes or its prohibition as an SY205 rollback model.

## Phase C. Backend Fresh-Session Selection

- [x] Add typed model registry loading/resolution and retain SY205 path aliases as defaults.
- [x] Add `RuntimeSessionManager` to construct/start/stop one `RuntimeController` per selected descriptor.
- [x] Add `--model` CLI selection with `sy205` default.
- [x] Make `/health`, `/api/model`, WebSocket hello/state, replay, recording exchange, and RRD metadata consume the manager's selected descriptor.
- [x] Refuse model replacement while another established WebSocket session remains active.
- [x] Ensure every successful selection creates fresh runtime, stream/recording epochs, input router, queues, recording/replay state, and caches.

Rollback point: restore `create_app(RuntimeController)` and the fixed SY205 startup path; registry artifacts remain inert.

## Phase D. Protocol And Godot Reconnect

- [x] Extend the v3 schema/normalizers with requested/selected model IDs and descriptor-specific model versions.
- [x] Add stable error codes for unknown, unavailable, busy, and contract-mismatched models.
- [x] Add desired/active model state to `MotionClient`; switch by zeroing input, disconnecting, clearing generation state, and reconnecting with the requested ID.
- [x] Do not report ready until the matching server identity and bundled Godot descriptor are both validated.
- [x] Add the operator UI selector with clear switching/fault/active states and SY205 default.

## Phase E. Dynamic Presentation And Excavation Binding

- [x] Replace the fixed main-scene SY205 instance with one active-model owner under `PresentationRoot`.
- [x] Parameterize `MotionPresentation` manifest/fixture/root loading and reset every model-specific cache on activation.
- [x] Preserve SY205 four-bar behavior; support an explicit `none` passive-linkage policy for SY135.
- [x] Retarget `CameraRig` from the active `base_link` after activation.
- [x] Move bucket contact resolution behind `MotionPresentation`; retain SY205's current offset and use validated SY135 `REF_BUCKET_TIP`.
- [x] Preserve `TerrainState` while clearing bucket soil, tooth history, particles, and stale derived work on model changes.

Rollback point: restore the fixed `SY205Excavator` scene instance and fixed presentation contract.

## Phase F. Tests And Documentation

- [x] Parameterize/add Godot asset contract tests for both GLBs and their model-specific manifests/fixtures.
- [x] Add `SY205 -> SY135 -> SY205` reconnect/activation tests covering one visual, camera, pose, bucket contact, clearing, and terrain preservation.
- [x] Add backend registry, CLI, model-session, dynamic endpoint, handshake/version, active-session conflict, recording/replay isolation, and cross-model import rejection tests.
- [x] Update production smoke/provenance checks and project architecture/integration/visual-model documentation.
- [x] Run `git diff --check` and task validation.

## Validation Commands

```powershell
pixi run verify
pixi run backend-smoke
& godot/client/tests/run_standalone_matrix.ps1
```

Also run the existing standalone-path/provenance checks included by `pixi run verify`, a Godot Forward+ runtime smoke, and capture visual evidence for both models at neutral and asymmetric poses.

## Review Gates

- [x] Source/repository GLB bytes and SHA match.
- [x] SY135 Godot import and mechanics gate is fully green before runtime activation work continues.
- [x] Model identity is derived from one selected descriptor at every backend and client boundary.
- [x] No active-session hot mutation, cross-model recording/replay, or visual fallback path remains.
- [x] SY205 default behavior and all pre-existing quality gates remain green.

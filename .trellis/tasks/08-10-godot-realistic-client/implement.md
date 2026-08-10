# Implementation Plan

## Phase 0 — Human review gates

1. [x] Confirm the realistic Forward+ baseline: modern Windows desktop, 1920×1080, target 60 FPS.
2. [x] Confirm the deferred GLB contract: authoring remains user-owned and the delivered asset exposes five identifiable independently movable parts.
3. [x] Treat local terrain colliders as Godot-owned presentation/gameplay support that never feeds authority transforms back to Python.

## Delivery model

This parent task is delivered through sequential, independently verifiable child milestones. Only one implementation milestone should be active at a time. A milestone is checked, committed, and handed back before the next begins; later milestones may revise the plan but must not silently expand an earlier scope.

| Milestone | Planned child task | Depends on | Demonstrable exit |
|---|---|---|---|
| M1 | `godot-foundation` | Planning approval | Godot opens/runs a reproducible main scene with five placeholder frame nodes and a test harness. |
| M1.5 | `godot-glb-adaptation` | M1 | The supplied combined SY205 GLB is copied, imported, mapped to five protocol frame aliases, and statically validated. |
| M2 | `motion-vertical-slice` | M1.5 | Existing Python backend drives the delivered GLB rig; keyboard/gamepad input, lifecycle and reconnect work. |
| M3 | `motion-only-backend` | M2 | Opt-in Python profile runs motion without terrain/recording/replay and keeps `pixi run verify` green. |
| M4 | `deterministic-terrain-core` | M1 | Same seed/commands reproduce the same Godot terrain; mesh and generation reset are tested. |
| M5 | `excavation-gameplay-loop` | M2 + M4 | Bucket interaction edits terrain and tracks local volume; collider failure does not stop the client. |
| M6 | `realistic-visual-pass` | M2 | Realistic lighting/camera/materials and soil FX polish the already-integrated SY205 asset at the performance baseline. |
| M7 | `integration-release-candidate` | M3 + M5 + M6 | Connect, operate, dig, reset and reconnect pass end-to-end at the approved performance target. |

## M1 — Godot foundation

1. [ ] Add a reproducible main scene and source directories under `godot/client/`.
2. [ ] Keep `.godot/`, `.cache/` and exports ignored; add a headless/import smoke path.
3. [ ] Configure Forward+, D3D12 and Jolt as non-fatal presentation defaults.
4. [ ] Build stable placeholder nodes for base, upper structure, boom, arm and bucket.
5. [ ] Establish Godot-side test conventions and verify the scene through MCP.

Exit gate: editor state, filesystem scan, scene hierarchy and project smoke all pass without the Python backend.

## M1.5 — Supplied SY205 GLB adaptation

1. [x] Copy and hash-verify the user-supplied combined GLB under `godot/client/assets/visual/`.
2. [x] Validate the imported pivot hierarchy and publish a Godot-local five-frame mapping manifest.
3. [x] Preserve the imported linkage hierarchy as visual-only auxiliaries and keep the placeholder foundation as rollback.
4. [x] Capture imported rest transforms and pass a frame-parity-ready calibration contract to M2.

Exit gate: the delivered GLB imports, renders, and resolves all five frame aliases with no backend/protocol changes. [x]

## M2 — Connected motion vertical slice

1. [x] Implement WebSocket hello/ack, motion snapshot decoding and connection status.
2. [x] Implement keyboard/mouse and generic gamepad mappings with zero-input arming and safe disconnect.
3. [x] Implement start/pause/reset, acknowledgements and reconnect behavior.
4. [x] Add generation/sequence guards and interpolation only within one motion generation.
5. [x] Compare the five imported SY205 transforms against the checked-in Godot frame-parity fixture.

Exit gate: a user can connect to the existing backend, move all four joints, disconnect/reconnect safely and observe frame-parity-correct imported SY205 motion. [x]

## M3 — Motion-only backend profile

1. [x] Add an opt-in profile that keeps `Simulator` and `InputRouter` but does not require terrain, recording or replay workers.
2. [x] Preserve lifecycle, input sequence, safety, error and frame-transform contracts.
3. [x] Add capability negotiation and focused startup/reset/stop/disconnect tests.
4. [x] Verify the M2 wire/client contract against both legacy and motion-only
   sessions; live Godot MCP was unavailable during this check, so the client
   editor/game connection remains a handoff smoke rather than a live visual
   acceptance review.

Exit gate: `pixi run verify` passes and the client behaves identically for motion under both backend profiles. [x]

## M4 — Deterministic Godot terrain core

1. [x] Implement versioned seeded terrain initialization with a stable grid representation.
2. [x] Implement fixed-step, monotonically ordered terrain edit commands.
3. [x] Build the derived mesh with generation-gated asynchronous updates.
4. [x] Add reset/rebuild and same-seed/same-command repeatability fixtures.

Exit gate: terrain repeatability tests pass on the supported Windows/Godot runtime and stale jobs cannot overwrite a newer generation. [x]

## M5 — Excavation gameplay loop

1. [x] Implement bucket/terrain intersection against deterministic world state.
2. [x] Implement Godot-owned bucket volume accounting and deposit/dig commands.
3. [x] Add chunked/static terrain colliders without feeding transforms back to Python.
4. [x] Prove graceful operation when colliders or local physics are disabled.

Exit gate: the placeholder bucket can dig and deposit deterministically, reset cleanly, and continue when local physics is unavailable. [x]

## M6 — Realistic visual pass and soil effects

1. [x] Add realistic environment lighting, camera behavior, PBR defaults and scalable quality settings.
2. [x] Add bounded soil clumps, dust and falling-soil effects driven by Godot world state.
3. [x] Profile terrain mesh, collider and effects at 1920×1080 against the 60 FPS target.
4. [x] Refine the integrated SY205 materials and local presentation calibration without changing motion/terrain modules.
5. [x] Recheck scale, bounds, materials and frame parity after visual polish.

Exit gate: the delivered SY205 visual pass is stable at the approved performance baseline and disposable effects never alter deterministic state. [x]

## M7 — Integration release candidate

1. [x] Run end-to-end connect, operate, dig, deposit, reset, disconnect and reconnect scenarios.
2. [x] Run no-physics degradation and stale-generation fault injection.
3. [x] Complete full backend and Godot checks plus final human visual/input review.
4. [x] Decide separately whether legacy Python terrain/replay code should remain, be deprecated or be archived.

Exit gate: all parent PRD acceptance criteria pass; any deferred asset polish is explicitly recorded rather than blocking unrelated functionality. [x]

## Validation commands and review gates

- Backend: `pixi run verify`.
- Godot MCP: `mcp__godot_ai__editor_manage({"op":"state"})`, filesystem scan, scene hierarchy inspection and project test runner where available.
- Godot: headless project import/start smoke using the installed Godot editor once the main scene exists.
- Determinism: same seed + same command sequence -> same terrain/bucket-volume result on the supported runtime.
- Pose parity: compare five frame transforms against the existing fixture within the approved tolerance.
- Final human review: visual realism, camera feel, input comfort, performance and GLB material/collision quality.

## Risky files and rollback points

- Backend runtime/protocol files: keep motion-only changes opt-in; rollback by disabling the profile.
- `godot/client/project.godot`: review renderer, physics and plugin changes before committing.
- GLB import settings and manifest: rollback by restoring the prior import metadata; never silently change frame identifiers.
- Terrain/world scripts: preserve seed/version fixtures so a failed algorithm can be replaced without corrupting visual assets.

Implementation must not start until the planning summary is approved and `task.py start` is explicitly run.
